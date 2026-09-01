//
//  BrowserWindowOpener.swift
//  slapss
//
//  Honours the two join-in-browser preferences (new window / built-in
//  display). The decisions live in `BrowserPlacement` and `ScreenPlacement`;
//  this file is the only part that touches NSWorkspace, NSScreen and Apple
//  events.
//
//  Two routes, chosen by what the default browser supports:
//
//   1. Launch arguments — the equivalent of `open -na "<browser>" --args
//      --new-window <url>`. Chromium and Firefox understand it, Chromium can
//      also place the window with `--window-position`. Costs the user no
//      permission at all.
//   2. Apple events — Safari has no new-window flag, and no browser can be
//      asked to move a window that already exists. This needs the Automation
//      TCC grant (System Settings → Privacy & Security → Automation), which
//      macOS asks for the first time an event is actually sent.
//
//  Every failure path ends in a plain `NSWorkspace.open`, so a refused or
//  never-granted permission costs the user their window placement and never
//  their meeting.
//

import AppKit
import CoreServices
import Foundation

@MainActor
enum BrowserWindowOpener {
    /// Whether Slapss may send Apple events to the default browser. Read with
    /// `askUserIfNeeded: false`, so checking never raises the system prompt —
    /// Settings can show the current state without the user being asked
    /// anything.
    enum AutomationStatus {
        case granted
        case denied
        /// Never asked, or the browser isn't running so macOS can't say yet.
        case undetermined
    }

    /// How long to wait for a freshly opened browser window to exist before
    /// trying to move it, and the one retry after that. Both are guesses about
    /// a foreign app's launch time, which is why the retry exists.
    private static let firstPlacementDelay: TimeInterval = 0.5
    private static let retryPlacementDelay: TimeInterval = 1.2

    // MARK: - Entry point

    /// Applies `placement` when opening `url`.
    ///
    /// - Returns: true when this type took responsibility for opening the URL.
    ///   False means the caller should fall back to `NSWorkspace.open` — the
    ///   preferences are both off, or the default browser couldn't be resolved.
    static func open(_ url: URL, placement: BrowserPlacement) -> Bool {
        // A browser we can't name is a browser we can't drive: bail out so the
        // caller does the plain open rather than reporting success for work
        // that then silently doesn't happen.
        guard !placement.isBrowserDecides,
              let browserURL = defaultBrowserURL(),
              let bundleIdentifier = Bundle(url: browserURL)?.bundleIdentifier
        else { return false }

        let family = BrowserFamily.forBundleIdentifier(bundleIdentifier)
        let fill = placement.forcesBuiltInDisplay ? ScreenPlacement.fillBounds(of: currentScreens()) : nil
        // Geometry the browser can't be asked to apply over Apple events is
        // dropped rather than attempted and failed — Firefox has no scriptable
        // `bounds`. It still reaches `launchArguments`, which is a separate
        // route with its own capability check.
        let bounds = family.supportsWindowPlacementScript ? fill : nil

        if let arguments = family.launchArguments(for: url, placement: placement, bounds: fill) {
            launch(browserURL, arguments: arguments) { launched in
                guard launched else {
                    NSWorkspace.shared.open(url)
                    return
                }
                // Chromium placed the window itself via --window-position.
                if let bounds, !placement.placesWindowWithArguments(in: family) {
                    placeFrontWindow(of: bundleIdentifier, at: bounds, after: firstPlacementDelay, retrying: true)
                }
            }
            return true
        }

        // Apple-event route: Safari, and a best-effort attempt at a browser we
        // don't recognise. The URL is opened in the script's completion so it
        // is opened exactly once — never both by the script and by the
        // fallback.
        if placement.opensNewWindow, family.supportsNewWindowScript {
            runScript(newWindowScript(bundleIdentifier: bundleIdentifier, url: url)) { errorNumber in
                if errorNumber != nil { NSWorkspace.shared.open(url) }
                if let bounds {
                    placeFrontWindow(of: bundleIdentifier, at: bounds, after: firstPlacementDelay, retrying: true)
                }
            }
            return true
        }

        NSWorkspace.shared.open(url)
        if let bounds {
            placeFrontWindow(of: bundleIdentifier, at: bounds, after: firstPlacementDelay, retrying: true)
        }
        return true
    }

    // MARK: - Browser resolution

    /// The app registered for https. Probing with a real URL rather than
    /// reading LaunchServices preferences keeps this to public API.
    static func defaultBrowserURL() -> URL? {
        guard let probe = URL(string: "https://example.com") else { return nil }
        return NSWorkspace.shared.urlForApplication(toOpen: probe)
    }

    static func defaultBrowserBundleIdentifier() -> String? {
        defaultBrowserURL().flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    /// User-facing browser name for the permission explanation ("Safari",
    /// "Google Chrome"). Falls back to the bundle identifier so the sentence
    /// is never left with a hole in it.
    static func defaultBrowserDisplayName() -> String? {
        guard let url = defaultBrowserURL() else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
        if name.isEmpty { return Bundle(url: url)?.bundleIdentifier }
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    static func defaultBrowserFamily() -> BrowserFamily {
        BrowserFamily.forBundleIdentifier(defaultBrowserBundleIdentifier())
    }

    // MARK: - Permission

    /// Current Automation permission for the default browser. Never prompts.
    static func automationStatus() -> AutomationStatus {
        guard let bundleIdentifier = defaultBrowserBundleIdentifier() else { return .undetermined }
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        guard let descriptor = target.aeDesc else { return .undetermined }
        // askUserIfNeeded: false — this is the whole reason the check is safe
        // to run from Settings. With true it would raise the system prompt.
        let status = AEDeterminePermissionToAutomateTarget(
            descriptor, typeWildCard, typeWildCard, false
        )
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return .undetermined
        }
    }

    // MARK: - Launch-argument route

    private static func launch(
        _ browserURL: URL,
        arguments: [String],
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        let configuration = NSWorkspace.OpenConfiguration()
        // `open -n`: a second instance parses the arguments and hands them to
        // the running copy through the browser's own single-instance lock,
        // which is what turns --new-window into a window rather than a second
        // browser. Without this the arguments are ignored when the browser is
        // already running.
        configuration.createsNewApplicationInstance = true
        configuration.arguments = arguments
        configuration.activates = true

        NSWorkspace.shared.openApplication(at: browserURL, configuration: configuration) { application, error in
            // Both halves matter: an error is an outright failure, and a nil
            // application means LaunchServices reported success without giving
            // us a process to point at.
            let launched = error == nil && application != nil
            Task { @MainActor in completion(launched) }
        }
    }

    // MARK: - Apple-event route

    /// Safari opens a new window for every new document; there is no flag
    /// equivalent, which is the whole reason this feature needs Automation.
    /// Also tried on an unrecognised browser — `make new document` is a common
    /// idiom, and a browser that doesn't understand it just errors and falls
    /// back to a plain open.
    private static func newWindowScript(bundleIdentifier: String, url: URL) -> String {
        """
        tell application id \(appleScriptLiteral(bundleIdentifier))
            activate
            make new document with properties {URL:\(appleScriptLiteral(url.absoluteString))}
        end tell
        """
    }

    /// `bounds` on a window is Standard Suite, so the same script moves
    /// Safari, Chromium and most other scriptable browsers.
    private static func setBoundsScript(bundleIdentifier: String, bounds: ScreenPlacement.WindowBounds) -> String {
        """
        tell application id \(appleScriptLiteral(bundleIdentifier))
            set bounds of front window to {\(bounds.left), \(bounds.top), \(bounds.right), \(bounds.bottom)}
        end tell
        """
    }

    private static func placeFrontWindow(
        of bundleIdentifier: String,
        at bounds: ScreenPlacement.WindowBounds,
        after delay: TimeInterval,
        retrying: Bool
    ) {
        let script = setBoundsScript(bundleIdentifier: bundleIdentifier, bounds: bounds)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            runScript(script) { errorNumber in
                guard let errorNumber else { return }
                // -1743 is a refused (or not yet granted) Automation
                // permission: the window stays where the browser put it and
                // the meeting is already open, so there is nothing to retry. A
                // missing window (-1728) or a browser still launching (-600) is
                // worth one more try — the delay above is a guess about someone
                // else's app.
                let worthRetrying = errorNumber == -1728 || errorNumber == -600
                if retrying, worthRetrying {
                    placeFrontWindow(of: bundleIdentifier, at: bounds, after: retryPlacementDelay, retrying: false)
                }
            }
        }
    }

    /// Apple events are sent on a private serial queue, never on the main
    /// thread. `NSAppleScript.executeAndReturnError` is synchronous and exposes
    /// no timeout, and the *first* send is also when macOS presents the
    /// Automation consent dialog. A join happens while the full-screen overlay
    /// is up — a borderless `.screenSaver`-level window covering every display
    /// — so blocking the main thread there freezes the overlay with no way out:
    /// ESC and Return are handled on that run loop, and so are
    /// `AlertScheduler`'s timers and watchdog.
    ///
    /// A fresh `NSAppleScript` per call, used only on this queue, keeps to the
    /// one-thread-per-instance rule.
    ///
    /// - Parameter completion: called on the main actor with nil on success,
    ///   otherwise the AppleScript error number.
    private static let scriptQueue = DispatchQueue(label: "com.cancetin.slapss.applescript")

    private static func runScript(_ source: String, completion: @escaping @MainActor (Int?) -> Void) {
        scriptQueue.async {
            var errorNumber: Int? = -1
            if let script = NSAppleScript(source: source) {
                var error: NSDictionary?
                script.executeAndReturnError(&error)
                errorNumber = error.map { $0[NSAppleScript.errorNumber] as? Int ?? -1 }
            }
            Task { @MainActor in completion(errorNumber) }
        }
    }

    /// Quotes a value as an AppleScript string literal. Meeting URLs come from
    /// calendar data, so backslashes and quotes have to be escaped rather than
    /// trusted — otherwise a crafted URL would end the literal and the rest
    /// would be compiled as script.
    static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: - Screens

    /// Reads the current display arrangement into the plain values
    /// `ScreenPlacement` works on.
    static func currentScreens() -> [ScreenPlacement.Screen] {
        NSScreen.screens.map { screen in
            ScreenPlacement.Screen(
                isBuiltIn: isBuiltIn(screen),
                frame: screen.frame,
                visibleFrame: screen.visibleFrame
            )
        }
    }

    /// `CGDisplayIsBuiltin` on the screen's display ID — no permission needed,
    /// and it doesn't care what the panel is called or how big it is.
    private static func isBuiltIn(_ screen: NSScreen) -> Bool {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return false }
        return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
    }
}
