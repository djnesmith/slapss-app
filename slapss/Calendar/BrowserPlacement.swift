//
//  BrowserPlacement.swift
//  slapss
//
//  Pure decision layer for the two join-in-browser preferences. No AppKit,
//  no Apple events — just "given these preferences and this browser, what has
//  to happen, and does it need the Automation grant?"
//

import Foundation

/// The two independent preferences, resolved into one value so every join
/// path (popover, overlay, notification action) carries the same thing.
nonisolated struct BrowserPlacement: Equatable {
    /// Open the join link in a brand-new browser window instead of reusing an
    /// existing window or tab.
    var opensNewWindow: Bool
    /// Put that window on the laptop's built-in display rather than wherever
    /// the browser would have put it.
    var forcesBuiltInDisplay: Bool

    /// Today's behaviour: hand the URL to `NSWorkspace` and let the browser
    /// decide. Both preferences ship off, so this is what existing users get.
    static let browserDecides = BrowserPlacement(opensNewWindow: false, forcesBuiltInDisplay: false)

    var isBrowserDecides: Bool { self == .browserDecides }

    /// Whether honouring this placement in `browser` needs the Automation
    /// (Apple events) TCC grant.
    ///
    /// Chromium and Firefox accept a new-window request as launch arguments,
    /// and Chromium can position that window itself, so those combinations
    /// cost the user no permission at all. Everything else — Safari in any
    /// form, and moving a window that already exists — has to be driven with
    /// an Apple event.
    /// The grant is only ever asked for when it would actually achieve
    /// something. Firefox exposes no scriptable `bounds`, so its
    /// built-in-display half returns false here and is reported as unsupported
    /// instead of trading a permission for nothing.
    func requiresAutomation(in browser: BrowserFamily) -> Bool {
        if isBrowserDecides { return false }

        var needsAppleEvent = false

        if opensNewWindow, browser.newWindowArgument == nil {
            needsAppleEvent = browser.supportsNewWindowScript
        }

        if forcesBuiltInDisplay, !placesWindowWithArguments(in: browser) {
            needsAppleEvent = needsAppleEvent || browser.supportsWindowPlacementScript
        }

        return needsAppleEvent
    }

    /// True when the window's position comes from launch arguments — only
    /// possible for a window the browser is creating in the same breath.
    /// Chromium can do it; nothing can position a window it already has.
    func placesWindowWithArguments(in browser: BrowserFamily) -> Bool {
        opensNewWindow && browser.supportsWindowGeometryArguments
    }

    /// Whether every part of this placement can actually be carried out in
    /// `browser`. False means a toggle is on that cannot do anything, which
    /// Settings says out loud rather than leaving the user with a preference
    /// that silently never applies.
    func isFullySupported(in browser: BrowserFamily) -> Bool {
        guard forcesBuiltInDisplay else { return true }
        return placesWindowWithArguments(in: browser) || browser.supportsWindowPlacementScript
    }
}

/// Browser families that matter for opening a window, keyed off the bundle
/// identifier of whatever handles `https` — never off a hardcoded browser.
nonisolated enum BrowserFamily: Equatable {
    case safari
    case chromium
    case firefox
    /// Handles https, but we know nothing about its command line. Treated as
    /// scriptable-if-the-user-allows-it and otherwise left alone.
    case unknown

    /// Matched on bundle-identifier prefixes so beta, dev, canary and nightly
    /// channels (`com.google.Chrome.canary`, `org.mozilla.nightly`, …) land in
    /// the right family without enumerating every build.
    private static let prefixes: [(prefix: String, family: BrowserFamily)] = [
        ("com.apple.safari", .safari),
        ("com.google.chrome", .chromium),
        ("org.chromium.", .chromium),
        ("com.brave.browser", .chromium),
        ("com.microsoft.edgemac", .chromium),
        ("com.vivaldi.", .chromium),
        ("com.operasoftware.", .chromium),
        ("company.thebrowser.", .chromium),
        ("org.mozilla.", .firefox),
    ]

    static func forBundleIdentifier(_ identifier: String?) -> BrowserFamily {
        guard let identifier else { return .unknown }
        let lowered = identifier.lowercased()
        return prefixes.first { lowered.hasPrefix($0.prefix) }?.family ?? .unknown
    }

    /// The flag this family understands for "open this URL in a new window".
    /// Chromium takes two dashes, Firefox one. Safari has no equivalent — the
    /// only way in is `make new document`, hence nil.
    var newWindowArgument: String? {
        switch self {
        case .chromium: return "--new-window"
        case .firefox: return "-new-window"
        case .safari, .unknown: return nil
        }
    }

    /// Whether this family can be asked to place the new window itself.
    /// Chromium's `--window-position` takes the same top-left-origin screen
    /// coordinates as AppleScript's window `bounds`, so
    /// `ScreenPlacement.WindowBounds` feeds both without conversion.
    var supportsWindowGeometryArguments: Bool { self == .chromium }

    /// Whether asking this family for a new window over Apple events is worth
    /// attempting. `make new document` is how Safari opens a window, and it is
    /// a common enough idiom to be worth trying on a browser we don't
    /// recognise; a family that already has a command-line flag never gets
    /// here.
    var supportsNewWindowScript: Bool {
        switch self {
        case .safari, .unknown: return true
        case .chromium, .firefox: return false
        }
    }

    /// Whether `set bounds of front window` can be expected to work.
    ///
    /// Firefox is excluded deliberately: it ships essentially no AppleScript
    /// dictionary and has no scriptable `bounds` on a window, so sending the
    /// event would cost the user an Automation grant and then fail anyway.
    /// Positioning Firefox would need the Accessibility API — a different,
    /// heavier grant this feature does not ask for.
    var supportsWindowPlacementScript: Bool {
        switch self {
        case .safari, .chromium, .unknown: return true
        case .firefox: return false
        }
    }

    /// Launch arguments equivalent to `open -na "<browser>" --args …`.
    /// Returns nil when this family can't be driven from the command line, in
    /// which case the caller falls back to Apple events.
    func launchArguments(
        for url: URL,
        placement: BrowserPlacement,
        bounds: ScreenPlacement.WindowBounds?
    ) -> [String]? {
        guard placement.opensNewWindow, let newWindowArgument else { return nil }

        var arguments = [newWindowArgument]
        if placement.forcesBuiltInDisplay, supportsWindowGeometryArguments, let bounds {
            arguments.append("--window-position=\(bounds.left),\(bounds.top)")
            arguments.append("--window-size=\(bounds.width),\(bounds.height)")
        }
        arguments.append(url.absoluteString)
        return arguments
    }
}
