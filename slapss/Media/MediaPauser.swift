//
//  MediaPauser.swift
//  slapss
//
//  Pauses whatever is playing, just before a meeting join URL opens.
//
//  Apple events only, and only to apps already running: Music, TV, Spotify
//  and VLC by their own pause, Safari and Chrome by JavaScript in each tab.
//  Every decision and script lives in `MediaPausePlan`; this file runs them.
//
//  Until this replaced it, the feature posted the system Play/Pause key. That
//  key is a toggle routed by macOS to whatever holds Now Playing, so with
//  nothing playing it launched Music, or started a paused Safari video
//  (measured 2026-10-07). No public API can say what the key will reach —
//  MediaRemote's now-playing query returns pid 0 to third-party apps on this
//  macOS — so it is gone rather than gated.
//

import AppKit
import os

@MainActor
enum MediaPauser {

    private nonisolated static let log = Logger(subsystem: "com.cancetin.slapss", category: "MediaPauser")

    /// Browsers already reported as refusing JavaScript from Apple Events.
    /// Said once per launch, not once per join.
    private static var reportedJavaScriptDisabled: Set<String> = []

    /// Same reasoning as `BrowserWindowOpener.runScript`: Apple events block
    /// and can raise the Automation consent dialog, so never on main.
    private static let queue = DispatchQueue(label: "com.cancetin.slapss.mediapause")

    /// Pauses every running player and browser tab that is playing, then calls
    /// `completion` on the main actor. The join waits for it, so a meeting tab
    /// opening at the same time is never itself paused.
    ///
    /// - Parameter urlPrefix: browsers only; see `MediaPausePlan.browserScript`.
    static func pausePlayingMedia(
        urlPrefix: String? = nil,
        completion: @escaping @MainActor () -> Void
    ) {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let targets = MediaPausePlan.targets(runningBundleIdentifiers: running)
        guard !targets.isEmpty else { completion(); return }

        queue.async {
            var refusedJavaScript: [String] = []
            for target in targets {
                if target.isBrowser {
                    guard let source = MediaPausePlan.browserScript(for: target, urlPrefix: urlPrefix) else { continue }
                    let error = run(source).error
                    if MediaPausePlan.isJavaScriptDisabledError(error) {
                        refusedJavaScript.append(target.bundleIdentifier)
                    } else if let error {
                        log.error("pause \(target.bundleIdentifier, privacy: .public): \(error, privacy: .public)")
                    }
                } else {
                    guard let pause = MediaPausePlan.pauseScript(for: target) else { continue }
                    // TV has no state query: its pause is sent as-is.
                    if let query = MediaPausePlan.stateQueryScript(for: target) {
                        let read = run(query)
                        let state = PlayerState(appleScriptResult: read.result)
                        // An unreadable state is never paused; log it so a broken
                        // query is visible.
                        if state == .unknown {
                            log.error("state \(target.bundleIdentifier, privacy: .public): \(read.error ?? read.result ?? "no result", privacy: .public)")
                        }
                        guard MediaPausePlan.shouldPause(state) else { continue }
                    }
                    if let error = run(pause).error {
                        log.error("pause \(target.bundleIdentifier, privacy: .public): \(error, privacy: .public)")
                    }
                }
            }
            Task { @MainActor in
                for id in refusedJavaScript where reportedJavaScriptDisabled.insert(id).inserted {
                    log.notice("\(id, privacy: .public) has \"Allow JavaScript from Apple Events\" off, so its tabs cannot be paused")
                }
                completion()
            }
        }
    }

    /// Runs one script on the calling (private) queue. A fresh `NSAppleScript`
    /// per call keeps to the one-thread-per-instance rule.
    private nonisolated static func run(_ source: String) -> (result: String?, error: String?) {
        guard let script = NSAppleScript(source: source) else { return (nil, "could not compile") }
        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)
        if let error {
            return (nil, error[NSAppleScript.errorMessage] as? String ?? "error \(error[NSAppleScript.errorNumber] ?? "?")")
        }
        return (descriptor.stringValue, nil)
    }
}
