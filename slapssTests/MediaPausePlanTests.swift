//
//  MediaPausePlanTests.swift
//  slapssTests
//

import XCTest
@testable import slapss

/// The only-ever-pause rule: nothing not running is addressed, nothing not
/// playing is sent a command, and no script can start playback.
final class MediaPausePlanTests: XCTestCase {

    func testNothingRunningMeansNothingSent() {
        XCTAssertEqual(MediaPausePlan.targets(runningBundleIdentifiers: []), [])
        XCTAssertEqual(MediaPausePlan.targets(runningBundleIdentifiers: ["com.apple.finder"]), [])
    }

    /// The reported bug: Music not running must never be addressed.
    func testOnlyRunningAppsAreTargeted() {
        let targets = MediaPausePlan.targets(runningBundleIdentifiers: ["com.spotify.client", "com.apple.Safari"])
        XCTAssertEqual(targets, [.spotify, .safari])
        XCTAssertFalse(targets.contains(.music))
    }

    func testEveryTargetIsReachableByItsBundleIdentifier() {
        let all = Set(MediaTarget.allCases.map(\.bundleIdentifier))
        XCTAssertEqual(MediaPausePlan.targets(runningBundleIdentifiers: all), MediaTarget.allCases)
    }

    func testPodcastsIsNeverTargeted() {
        XCTAssertEqual(MediaPausePlan.targets(runningBundleIdentifiers: ["com.apple.podcasts"]), [])
    }

    func testPlayerStateParsing() {
        let cases: [(String?, PlayerState)] = [
            ("playing", .playing), ("true", .playing),
            ("paused", .notPlaying), ("stopped", .notPlaying), ("false", .notPlaying),
            ("fast forwarding", .notPlaying), ("rewinding", .notPlaying),
            (nil, .unknown), ("", .unknown), ("garbage", .unknown),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(PlayerState(appleScriptResult: input), expected, "\(String(describing: input))")
        }
    }

    func testOnlyPlayingIsPaused() {
        XCTAssertTrue(MediaPausePlan.shouldPause(.playing))
        XCTAssertFalse(MediaPausePlan.shouldPause(.notPlaying))
        XCTAssertFalse(MediaPausePlan.shouldPause(.unknown))
    }

    func testPlayersPauseOnlyWhilePlaying() {
        for target in [MediaTarget.music, .spotify] {
            let script = MediaPausePlan.pauseScript(for: target)!
            XCTAssertTrue(script.contains("if player state is playing then pause"), "\(target)")
            XCTAssertFalse(script.contains(" play\n") || script.hasSuffix(" play"), "\(target)")
        }
    }

    /// TV's scripting can't see a streamed video's state, and its `pause` is
    /// idempotent, so it is sent with no state check — but still only to a
    /// running TV, and never `play`.
    func testTVPausesUnconditionallyButOnlyWhenRunning() {
        XCTAssertNil(MediaPausePlan.stateQueryScript(for: .tv))
        let script = MediaPausePlan.pauseScript(for: .tv)!
        XCTAssertTrue(script.hasPrefix("if application id \"com.apple.TV\" is running then"))
        XCTAssertTrue(script.contains("tell application id \"com.apple.TV\"\n            pause\n"))
        XCTAssertFalse(script.contains("play"))
        XCTAssertFalse(script.contains("player state"))
    }

    /// VLC's `play` toggles, so it must be sent only behind `playing`, read in
    /// the same tell block. `stop` loses the position and is never used. Raw
    /// codes, because compiling VLC's English terms launches VLC.
    func testVLCTogglesOnlyWhilePlayingAndNeverStops() {
        let script = MediaPausePlan.pauseScript(for: .vlc)!
        XCTAssertTrue(script.contains("if «property AAPL» then «event VLC#VLC1»"))
        XCTAssertFalse(script.contains("stop"))
        XCTAssertFalse(script.contains("VLC#VLC2"))   // VLC's `stop`
        XCTAssertTrue(MediaPausePlan.stateQueryScript(for: .vlc)!.contains("«property AAPL» as text"))
        XCTAssertFalse(script.contains("«class AAPL»"))
        XCTAssertEqual(PlayerState(appleScriptResult: "true"), .playing)
        XCTAssertEqual(PlayerState(appleScriptResult: "false"), .notPlaying)
    }

    /// Every script re-checks `is running` before its tell, so a player that
    /// quit after the Swift-side check is not relaunched by the send.
    func testEveryScriptIsGuardedByIsRunning() {
        for target in MediaTarget.allCases {
            let scripts = [MediaPausePlan.stateQueryScript(for: target),
                           MediaPausePlan.pauseScript(for: target),
                           MediaPausePlan.browserScript(for: target)].compactMap { $0 }
            XCTAssertFalse(scripts.isEmpty, "\(target)")
            for script in scripts {
                XCTAssertTrue(
                    script.hasPrefix("if application id \"\(target.bundleIdentifier)\" is running then"),
                    "\(target): \(script)")
            }
        }
    }

    func testJavaScriptOnlyPausesAndNeverPlays() {
        let js = MediaPausePlan.pausePlayingMediaJavaScript
        XCTAssertFalse(js.contains("play("))
        XCTAssertFalse(js.contains(".play"))
        XCTAssertFalse(js.contains("autoplay"))
        XCTAssertTrue(js.contains("if(!m.paused&&!m.ended){m.pause()"))
    }

    func testBrowserScriptsUseEachBrowsersCommand() {
        XCTAssertTrue(MediaPausePlan.browserScript(for: .safari)!.contains("do JavaScript js in t"))
        XCTAssertTrue(MediaPausePlan.browserScript(for: .chrome)!.contains("execute t javascript js"))
        XCTAssertNil(MediaPausePlan.browserScript(for: .music))
        XCTAssertNil(MediaPausePlan.pauseScript(for: .safari))
    }

    func testBrowserScriptReachesEveryTabUnlessFiltered() {
        XCTAssertTrue(MediaPausePlan.browserScript(for: .safari)!.contains("if true then"))
        let filtered = MediaPausePlan.browserScript(for: .safari, urlPrefix: "file:///tmp/x.html")!
        XCTAssertTrue(filtered.contains("if URL of t starts with \"file:///tmp/x.html\" then"))
    }

    func testJavaScriptDisabledRefusalIsRecognised() {
        XCTAssertTrue(MediaPausePlan.isJavaScriptDisabledError(
            "You must enable the 'Allow JavaScript from Apple Events' option in Safari's Develop menu to use 'do JavaScript'."))
        XCTAssertTrue(MediaPausePlan.isJavaScriptDisabledError(
            "Executing JavaScript through AppleScript is turned off. To turn it on, from the menu bar, go to View > Developer > Allow JavaScript from Apple Events."))
        XCTAssertFalse(MediaPausePlan.isJavaScriptDisabledError("Can't get tab 1 of window 1."))
        XCTAssertFalse(MediaPausePlan.isJavaScriptDisabledError(nil))
    }
}
