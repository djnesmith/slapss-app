//
//  MediaPausePlan.swift
//  slapss
//
//  Pure decision layer for "pause playing media when I join". No AppKit, no
//  Apple events — which apps to address, when a player counts as playing, and
//  the exact scripts sent. `MediaPauser` is the thin side that runs them.
//
//  The one rule everything here serves: **only ever pause.** Nothing may start
//  playback and nothing may launch an app. That is why there is no media key
//  (a toggle, which macOS hands to Music — launching it — when nothing holds
//  Now Playing, or to a paused browser video, starting it), and why every
//  script re-checks `is running` before its `tell`.
//

import Foundation

nonisolated enum MediaTarget: CaseIterable, Equatable {
    case music, tv, spotify, vlc, safari, chrome

    var bundleIdentifier: String {
        switch self {
        case .music:   return "com.apple.Music"
        case .tv:      return "com.apple.TV"
        case .spotify: return "com.spotify.client"
        case .vlc:     return "org.videolan.vlc"
        case .safari:  return "com.apple.Safari"
        case .chrome:  return "com.google.Chrome"
        }
    }

    var isBrowser: Bool { self == .safari || self == .chrome }
}

/// What a player reports. `.unknown` covers anything unreadable, and is never
/// paused: acting on a state we cannot read is how a toggle starts playback.
nonisolated enum PlayerState: Equatable {
    case playing, notPlaying, unknown

    /// Parses the text of the state query's result. Music, TV and Spotify
    /// answer `player state` (`playing`/`paused`/`stopped`/…); VLC answers its
    /// `playing` boolean.
    init(appleScriptResult: String?) {
        switch appleScriptResult?.lowercased() {
        case "playing", "true":                                       self = .playing
        case "paused", "stopped", "false", "fast forwarding", "rewinding": self = .notPlaying
        default:                                                      self = .unknown
        }
    }
}

nonisolated enum MediaPausePlan {

    /// Podcasts is absent on purpose: it has no scripting dictionary
    /// (`sdef` returns -192), so it cannot be paused without a toggle.
    /// Anything not running is dropped here, before any script exists.
    static func targets(runningBundleIdentifiers: Set<String>) -> [MediaTarget] {
        MediaTarget.allCases.filter { runningBundleIdentifiers.contains($0.bundleIdentifier) }
    }

    static func shouldPause(_ state: PlayerState) -> Bool { state == .playing }

    /// Reads the player's state without changing it. Nil for browsers, and
    /// for TV, whose pause is sent without one (see `pauseScript`).
    static func stateQueryScript(for target: MediaTarget) -> String? {
        let property: String
        switch target {
        case .music, .spotify: property = "player state"
        case .vlc:             property = vlcPlaying
        case .tv, .safari, .chrome: return nil
        }
        return guarded(target, body: "return (\(property) as text)")
    }

    /// The pause itself, guarded again in-script so a state change between the
    /// query and this send cannot turn it into a start. VLC has no `pause` —
    /// its `play` toggles — so it is sent only while `playing` reads true.
    /// `stop` is never used: it loses the position.
    ///
    /// TV is paused unconditionally. Its scripting doesn't see streamed
    /// content — with an Apple TV stream playing, `player state` reads
    /// "stopped" and `current track` errors -1728 — so a state gate never
    /// fires. Its `pause` is a real pause: sent twice, the stream stayed
    /// paused (both verified 2026-10-07).
    static func pauseScript(for target: MediaTarget) -> String? {
        switch target {
        case .tv:
            return guarded(target, body: "pause")
        case .music, .spotify:
            return guarded(target, body: "if player state is playing then pause")
        case .vlc:
            return guarded(target, body: "if \(vlcPlaying) then \(vlcPlayToggle)")
        case .safari, .chrome:
            return nil
        }
    }

    /// Pauses media that is playing and touches nothing else: a paused or
    /// ended element is left alone, and there is no call that starts
    /// playback. Recurses into same-origin iframes. Out of reach: cross-origin
    /// iframes (most embeds), media inside shadow roots, `Audio` objects never
    /// attached to the document, and Web Audio graphs.
    static let pausePlayingMediaJavaScript =
        "(function(){var n=0;function p(d){d.querySelectorAll('video,audio').forEach(function(m){"
        + "if(!m.paused&&!m.ended){m.pause();n++}});"
        + "d.querySelectorAll('iframe').forEach(function(f){try{if(f.contentDocument)p(f.contentDocument)}catch(e){}})}"
        + "p(document);return n})()"

    /// Runs the JavaScript in every tab of every window. A tab that refuses
    /// (a blank or internal page) is skipped; the browser's "Allow JavaScript
    /// from Apple Events" refusal is re-raised, so the caller can say so once.
    ///
    /// - Parameter urlPrefix: limits the run to tabs whose URL starts with
    ///   it. Production passes nil; the debug probe uses it to stay inside its
    ///   own test window.
    static func browserScript(for target: MediaTarget, urlPrefix: String? = nil) -> String? {
        let run: String
        switch target {
        case .safari: run = "do JavaScript js in t"
        case .chrome: run = "execute t javascript js"
        default:      return nil
        }
        let filter = urlPrefix.map { "URL of t starts with \(BrowserWindowOpener.appleScriptLiteral($0))" } ?? "true"
        return guarded(target, body: """
            set js to \(BrowserWindowOpener.appleScriptLiteral(pausePlayingMediaJavaScript))
                repeat with w in windows
                    repeat with t in tabs of w
                        if \(filter) then
                            try
                                \(run)
                            on error msg number n
                                if msg contains "\(javaScriptDisabledMarker)" then error msg number n
                            end try
                        end if
                    end repeat
                end repeat
            """)
    }

    /// Both browsers name the setting in their refusal: Safari's says to
    /// enable "'Allow JavaScript from Apple Events' option in Safari's
    /// Develop menu", Chrome's "View > Developer > Allow JavaScript from Apple
    /// Events". English only — a localized refusal is logged as a plain error.
    static let javaScriptDisabledMarker = "Allow JavaScript from Apple Events"

    static func isJavaScriptDisabledError(_ message: String?) -> Bool {
        message?.contains(javaScriptDisabledMarker) ?? false
    }

    /// VLC's `playing` and `play`, as raw codes from its dictionary.
    /// `playing` is a property, so `«property AAPL»`: written as `«class AAPL»`
    /// it reads back as the word "playing" and fails as a boolean (-1700). VLC has
    /// no static `.sdef` (only a Cocoa `vlc.scriptSuite`), so compiling the
    /// English terms makes macOS launch VLC to ask for its terminology — and
    /// compiling happens before the in-script `is running` check can run.
    /// Raw codes compile without the app.
    static let vlcPlaying = "«property AAPL»"
    static let vlcPlayToggle = "«event VLC#VLC1»"

    /// `is running` does not launch the app; the `tell` inside is reached only
    /// when it is true. Covers a player quitting between the running check in
    /// Swift and the send.
    private static func guarded(_ target: MediaTarget, body: String) -> String {
        let app = "application id \(BrowserWindowOpener.appleScriptLiteral(target.bundleIdentifier))"
        return """
            if \(app) is running then
                with timeout of 3 seconds
                    tell \(app)
                        \(body)
                    end tell
                end timeout
            end if
            """
    }
}
