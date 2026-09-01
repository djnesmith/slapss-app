//
//  BrowserPlacementTests.swift
//  slapssTests
//

import XCTest
@testable import slapss

/// Which browser gets driven how, and — the part that decides whether the user
/// is ever asked for a TCC grant — which combinations need Apple events.
final class BrowserFamilyTests: XCTestCase {

    func testSafariAndTechnologyPreviewAreSafari() {
        XCTAssertEqual(BrowserFamily.forBundleIdentifier("com.apple.Safari"), .safari)
        XCTAssertEqual(BrowserFamily.forBundleIdentifier("com.apple.SafariTechnologyPreview"), .safari)
    }

    /// The user's default browser reports `com.apple.safari` in lower case in
    /// some LaunchServices paths, so matching must be case-insensitive.
    func testBundleIdentifierMatchingIgnoresCase() {
        XCTAssertEqual(BrowserFamily.forBundleIdentifier("COM.APPLE.SAFARI"), .safari)
    }

    /// Release, beta, dev, canary and nightly channels all have to land in the
    /// right family — hence prefix matching rather than an exact-match list.
    func testChromiumChannelsAndForksAreChromium() {
        for identifier in [
            "com.google.Chrome",
            "com.google.Chrome.canary",
            "com.google.Chrome.beta",
            "org.chromium.Chromium",
            "com.brave.Browser.nightly",
            "com.microsoft.edgemac",
            "com.vivaldi.Vivaldi",
            "com.operasoftware.Opera",
            "company.thebrowser.Browser",
        ] {
            XCTAssertEqual(BrowserFamily.forBundleIdentifier(identifier), .chromium, identifier)
        }
    }

    func testMozillaChannelsAreFirefox() {
        XCTAssertEqual(BrowserFamily.forBundleIdentifier("org.mozilla.firefox"), .firefox)
        XCTAssertEqual(BrowserFamily.forBundleIdentifier("org.mozilla.nightly"), .firefox)
    }

    func testUnrecognizedOrMissingIdentifierIsUnknown() {
        XCTAssertEqual(BrowserFamily.forBundleIdentifier("com.example.SomeBrowser"), .unknown)
        XCTAssertEqual(BrowserFamily.forBundleIdentifier(nil), .unknown)
    }

    // MARK: - Launch arguments

    private static let url = URL(string: "https://meet.google.com/abc-defg-hij")!
    private static let bounds = ScreenPlacement.WindowBounds(left: 0, top: 2160, right: 1728, bottom: 3277)

    /// The permission-free path: Chromium takes both the new window and its
    /// position as launch arguments. `--window-position` uses the same
    /// top-left origin as AppleScript's `bounds`, so the values pass straight
    /// through.
    func testChromiumTakesNewWindowAndGeometryAsArguments() {
        let arguments = BrowserFamily.chromium.launchArguments(
            for: Self.url,
            placement: BrowserPlacement(opensNewWindow: true, forcesBuiltInDisplay: true),
            bounds: Self.bounds
        )

        XCTAssertEqual(arguments, [
            "--new-window",
            "--window-position=0,2160",
            "--window-size=1728,1117",
            Self.url.absoluteString,
        ])
    }

    func testChromiumWithoutBuiltInDisplayOmitsGeometry() {
        let arguments = BrowserFamily.chromium.launchArguments(
            for: Self.url,
            placement: BrowserPlacement(opensNewWindow: true, forcesBuiltInDisplay: false),
            bounds: nil
        )

        XCTAssertEqual(arguments, ["--new-window", Self.url.absoluteString])
    }

    /// Firefox understands the new-window flag (single dash) but has no
    /// geometry flags, so the window is placed afterwards with an Apple event.
    func testFirefoxTakesNewWindowButNotGeometry() {
        let arguments = BrowserFamily.firefox.launchArguments(
            for: Self.url,
            placement: BrowserPlacement(opensNewWindow: true, forcesBuiltInDisplay: true),
            bounds: Self.bounds
        )

        XCTAssertEqual(arguments, ["-new-window", Self.url.absoluteString])
    }

    func testSafariHasNoCommandLineRoute() {
        XCTAssertNil(BrowserFamily.safari.launchArguments(
            for: Self.url,
            placement: BrowserPlacement(opensNewWindow: true, forcesBuiltInDisplay: true),
            bounds: Self.bounds
        ))
    }

    /// Moving a window that already exists can't be expressed as a launch
    /// argument by any browser — a launch argument only shapes a *new* window.
    func testBuiltInDisplayAloneHasNoCommandLineRoute() {
        XCTAssertNil(BrowserFamily.chromium.launchArguments(
            for: Self.url,
            placement: BrowserPlacement(opensNewWindow: false, forcesBuiltInDisplay: true),
            bounds: Self.bounds
        ))
    }
}

final class BrowserPlacementTests: XCTestCase {

    /// Both preferences off is the shipped default and must never cost a
    /// permission or divert away from plain `NSWorkspace.open`.
    func testDefaultPlacementNeedsNothing() {
        XCTAssertEqual(
            BrowserPlacement.browserDecides,
            BrowserPlacement(opensNewWindow: false, forcesBuiltInDisplay: false)
        )
        XCTAssertTrue(BrowserPlacement.browserDecides.isBrowserDecides)
        for browser in [BrowserFamily.safari, .chromium, .firefox, .unknown] {
            XCTAssertFalse(BrowserPlacement.browserDecides.requiresAutomation(in: browser), "\(browser)")
        }
    }

    /// The one combination that is completely permission-free, and the reason
    /// the Settings toggles ask about the *resulting* placement rather than
    /// the one being flipped.
    func testChromiumNewWindowOnBuiltInDisplayNeedsNoAutomation() {
        let placement = BrowserPlacement(opensNewWindow: true, forcesBuiltInDisplay: true)
        XCTAssertFalse(placement.requiresAutomation(in: .chromium))
    }

    func testChromiumNewWindowAloneNeedsNoAutomation() {
        let placement = BrowserPlacement(opensNewWindow: true, forcesBuiltInDisplay: false)
        XCTAssertFalse(placement.requiresAutomation(in: .chromium))
    }

    /// Chromium can position a window it is creating, not one it already has.
    func testChromiumBuiltInDisplayAloneNeedsAutomation() {
        let placement = BrowserPlacement(opensNewWindow: false, forcesBuiltInDisplay: true)
        XCTAssertTrue(placement.requiresAutomation(in: .chromium))
    }

    func testFirefoxNewWindowAloneNeedsNoAutomation() {
        let placement = BrowserPlacement(opensNewWindow: true, forcesBuiltInDisplay: false)
        XCTAssertFalse(placement.requiresAutomation(in: .firefox))
    }

    /// Safari — the case that has to work — needs the grant for either half.
    func testSafariNeedsAutomationForEitherPreference() {
        XCTAssertTrue(
            BrowserPlacement(opensNewWindow: true, forcesBuiltInDisplay: false)
                .requiresAutomation(in: .safari)
        )
        XCTAssertTrue(
            BrowserPlacement(opensNewWindow: false, forcesBuiltInDisplay: true)
                .requiresAutomation(in: .safari)
        )
    }

    func testUnknownBrowserNeedsAutomationForEitherPreference() {
        XCTAssertTrue(
            BrowserPlacement(opensNewWindow: true, forcesBuiltInDisplay: false)
                .requiresAutomation(in: .unknown)
        )
        XCTAssertTrue(
            BrowserPlacement(opensNewWindow: false, forcesBuiltInDisplay: true)
                .requiresAutomation(in: .unknown)
        )
    }

    /// Firefox has no scriptable window `bounds`, so the grant would buy the
    /// user nothing. It must not be asked for — an Automation prompt followed
    /// by a window that doesn't move is worse than saying up front that it
    /// can't be done.
    func testFirefoxIsNeverAskedForAutomation() {
        for placement in [
            BrowserPlacement(opensNewWindow: true, forcesBuiltInDisplay: false),
            BrowserPlacement(opensNewWindow: false, forcesBuiltInDisplay: true),
            BrowserPlacement(opensNewWindow: true, forcesBuiltInDisplay: true),
        ] {
            XCTAssertFalse(placement.requiresAutomation(in: .firefox), "\(placement)")
        }
    }

    /// …and the same fact has to reach the UI, or the toggle is on and inert
    /// with nothing said about it.
    func testFirefoxReportsBuiltInDisplayAsUnsupported() {
        XCTAssertFalse(
            BrowserPlacement(opensNewWindow: false, forcesBuiltInDisplay: true)
                .isFullySupported(in: .firefox)
        )
        XCTAssertFalse(
            BrowserPlacement(opensNewWindow: true, forcesBuiltInDisplay: true)
                .isFullySupported(in: .firefox)
        )
        // The new-window half works on Firefox via -new-window.
        XCTAssertTrue(
            BrowserPlacement(opensNewWindow: true, forcesBuiltInDisplay: false)
                .isFullySupported(in: .firefox)
        )
    }

    func testEveryOtherBrowserSupportsBothPreferences() {
        for browser in [BrowserFamily.safari, .chromium, .unknown] {
            XCTAssertTrue(
                BrowserPlacement(opensNewWindow: true, forcesBuiltInDisplay: true)
                    .isFullySupported(in: browser), "\(browser)"
            )
        }
    }

    /// Only Chromium, and only for a window it is creating in the same breath.
    func testOnlyChromiumPlacesTheWindowFromArguments() {
        let both = BrowserPlacement(opensNewWindow: true, forcesBuiltInDisplay: true)
        XCTAssertTrue(both.placesWindowWithArguments(in: .chromium))
        XCTAssertFalse(both.placesWindowWithArguments(in: .safari))
        XCTAssertFalse(both.placesWindowWithArguments(in: .firefox))

        let reuse = BrowserPlacement(opensNewWindow: false, forcesBuiltInDisplay: true)
        XCTAssertFalse(reuse.placesWindowWithArguments(in: .chromium))
    }
}

/// The preferences have two readers — the `AppSettings` instance the SwiftUI
/// environment holds, and a static read straight off UserDefaults for
/// `AppDelegate`, which handles the notification "Join" action before any
/// environment exists. They must agree, and both must default to off.
final class BrowserPlacementPersistenceTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "slapss.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    /// A missing key must read as off, not as "unset and therefore something
    /// else" — this is what keeps existing users on the old behaviour.
    func testUnsetPreferencesDefaultToBrowserDecides() {
        XCTAssertEqual(AppSettings(defaults: defaults).browserPlacement, .browserDecides)
        XCTAssertEqual(AppSettings.persistedBrowserPlacement(defaults: defaults), .browserDecides)
    }

    func testEachPreferenceRoundTripsIndependently() {
        let settings = AppSettings(defaults: defaults)

        settings.openMeetingsInNewWindow = true
        XCTAssertEqual(
            AppSettings.persistedBrowserPlacement(defaults: defaults),
            BrowserPlacement(opensNewWindow: true, forcesBuiltInDisplay: false)
        )

        settings.openMeetingsOnBuiltInDisplay = true
        XCTAssertEqual(
            AppSettings.persistedBrowserPlacement(defaults: defaults),
            BrowserPlacement(opensNewWindow: true, forcesBuiltInDisplay: true)
        )

        settings.openMeetingsInNewWindow = false
        XCTAssertEqual(
            AppSettings.persistedBrowserPlacement(defaults: defaults),
            BrowserPlacement(opensNewWindow: false, forcesBuiltInDisplay: true)
        )
    }

    /// The static reader and a freshly constructed instance must see the same
    /// thing — otherwise a join from the notification banner behaves
    /// differently from a join from the popover.
    func testStaticReaderAgreesWithAFreshInstance() {
        let settings = AppSettings(defaults: defaults)
        settings.openMeetingsInNewWindow = true
        settings.openMeetingsOnBuiltInDisplay = true

        XCTAssertEqual(
            AppSettings(defaults: defaults).browserPlacement,
            AppSettings.persistedBrowserPlacement(defaults: defaults)
        )
    }
}

/// Regression cover for the wrong-window bug: creating the window and placing it
/// have to travel as ONE script. Observed on real hardware 2026-09-01 — sent as
/// two, `front window` in the second script was the user's pre-existing page, so
/// that window got moved to the built-in display and the meeting window stayed
/// where Safari put it.
final class NewWindowScriptTests: XCTestCase {

    private static let url = URL(string: "https://example.com/join")!
    private static let bounds = ScreenPlacement.WindowBounds(left: 3840, top: 848, right: 5568, bottom: 1932)

    func testNewWindowAndBoundsTravelInOneScript() {
        let script = BrowserWindowOpener.newWindowScript(
            bundleIdentifier: "com.apple.Safari",
            url: Self.url,
            bounds: Self.bounds
        )

        // One `tell` block, so the window just made is still the front one.
        XCTAssertEqual(script.components(separatedBy: "tell application id").count - 1, 1)
        XCTAssertTrue(script.contains("make new document"))
        XCTAssertTrue(script.contains("set bounds of front window to {3840, 848, 5568, 1932}"))
        // Ordering is what makes it correct: create, then place.
        let create = script.range(of: "make new document")!
        let place = script.range(of: "set bounds")!
        XCTAssertTrue(create.lowerBound < place.lowerBound)
    }

    /// Without the built-in-display preference the script must not mention
    /// bounds at all, or a plain new window would get repositioned.
    func testNewWindowWithoutBoundsOmitsPlacement() {
        let script = BrowserWindowOpener.newWindowScript(
            bundleIdentifier: "com.apple.Safari",
            url: Self.url,
            bounds: nil
        )

        XCTAssertTrue(script.contains("make new document"))
        XCTAssertFalse(script.contains("set bounds"))
    }

    /// A quote in a calendar-supplied URL must not be able to close the
    /// literal and let the remainder compile as script.
    func testQuoteInURLIsEscapedInsideTheScript() {
        let script = BrowserWindowOpener.newWindowScript(
            bundleIdentifier: "com.apple.Safari",
            url: URL(string: "https://example.com/a%22b")!,
            bounds: nil
        )

        // Exactly two unescaped quotes belong to each literal we emit.
        XCTAssertTrue(script.contains("{URL:\"https://example.com/a%22b\"}"))
    }
}

final class AppleScriptLiteralTests: XCTestCase {

    func testPlainURLIsQuoted() {
        XCTAssertEqual(
            BrowserWindowOpener.appleScriptLiteral("https://example.com/a"),
            "\"https://example.com/a\""
        )
    }

    /// Meeting URLs come out of calendar data. A quote in one would otherwise
    /// close the literal and leave the remainder to be compiled as script.
    func testQuotesAndBackslashesAreEscaped() {
        XCTAssertEqual(
            BrowserWindowOpener.appleScriptLiteral(#"a"b\c"#),
            #""a\"b\\c""#
        )
    }

    /// Backslash escaping has to happen before quote escaping, or the
    /// backslash inserted by the quote pass gets escaped in turn.
    func testEscapedQuoteIsNotDoubleEscaped() {
        XCTAssertEqual(
            BrowserWindowOpener.appleScriptLiteral(#"say \"hi\""#),
            #""say \\\"hi\\\"""#
        )
    }
}
