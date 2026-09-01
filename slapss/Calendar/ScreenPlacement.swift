//
//  ScreenPlacement.swift
//  slapss
//
//  Pure geometry for the "always on the built-in display" preference.
//
//  Everything here is a function of plain values so it can be tested without
//  a window server, a second monitor, or any TCC grant. `NSScreen` is read in
//  `BrowserWindowOpener`, reduced to `Screen` values, and handed here.
//

import CoreGraphics

nonisolated enum ScreenPlacement {
    /// One connected display, reduced to what window placement needs.
    struct Screen: Equatable {
        /// `CGDisplayIsBuiltin` on the screen's `NSScreenNumber`. Public API,
        /// no permission required — this is why the built-in panel is
        /// identified by display ID rather than by guessing from its name or
        /// its size.
        let isBuiltIn: Bool
        /// Full display bounds in AppKit's global space: bottom-left origin,
        /// y growing upward, with the primary display's bottom-left at (0, 0).
        let frame: CGRect
        /// `frame` minus the menu bar and the Dock — where a window may
        /// actually be placed.
        let visibleFrame: CGRect
    }

    /// A window rectangle in the coordinate space shared by AppleScript's
    /// window `bounds` property and Chromium's `--window-position` /
    /// `--window-size` flags: top-left origin, y growing **downward**,
    /// measured from the primary display's top-left corner.
    struct WindowBounds: Equatable {
        let left: Int
        let top: Int
        let right: Int
        let bottom: Int

        var width: Int { right - left }
        var height: Int { bottom - top }
    }

    /// The display AppKit's global coordinate space is anchored to — the one
    /// whose frame origin is (0, 0), i.e. the display holding the menu bar.
    ///
    /// Deliberately **not** `NSScreen.main`: that returns the screen with the
    /// key window, which moves as the user clicks around and is nil when no
    /// window is key. The conversion below needs the fixed anchor, not the
    /// active one.
    static func primaryScreen(in screens: [Screen]) -> Screen? {
        screens.first { $0.frame.origin == .zero } ?? screens.first
    }

    /// Where a meeting window should go: the built-in panel when it's part of
    /// the current arrangement, otherwise the primary display. The fallback
    /// covers clamshell mode and a disconnected built-in panel — the feature
    /// degrades to "wherever it would have opened anyway" rather than picking
    /// an arbitrary external monitor.
    static func targetScreen(in screens: [Screen]) -> Screen? {
        screens.first(where: \.isBuiltIn) ?? primaryScreen(in: screens)
    }

    /// Converts an AppKit rect into the top-left-origin space AppleScript and
    /// Chromium both use.
    ///
    /// The two spaces disagree on the origin corner *and* on the direction of
    /// y, so a display sitting below the primary one has a negative
    /// `frame.origin.y` in AppKit and a large positive `top` here. Getting
    /// this backwards parks the window off-screen or on the very monitor the
    /// user turned the preference on to avoid, which is why it's a named
    /// function with tests instead of arithmetic inlined at the call site.
    static func windowBounds(for rect: CGRect, primaryFrame: CGRect) -> WindowBounds {
        let left = rect.minX - primaryFrame.minX
        let top = primaryFrame.maxY - rect.maxY
        return WindowBounds(
            left: Int(left.rounded()),
            top: Int(top.rounded()),
            right: Int((left + rect.width).rounded()),
            bottom: Int((top + rect.height).rounded())
        )
    }

    /// Bounds that fill the target display's usable area.
    ///
    /// The window is sized to the whole `visibleFrame` rather than moved at
    /// its current size: an existing browser window may be wider than the
    /// built-in panel, and a half-off-screen meeting is worse than a
    /// maximized one. One rule for both preferences keeps the result
    /// predictable.
    static func fillBounds(of screens: [Screen]) -> WindowBounds? {
        guard let target = targetScreen(in: screens),
              let primary = primaryScreen(in: screens)
        else { return nil }

        return windowBounds(for: target.visibleFrame, primaryFrame: primary.frame)
    }
}
