//
//  ScreenPlacementTests.swift
//  slapssTests
//

import CoreGraphics
import XCTest
@testable import slapss

/// The AppKit → AppleScript/Chromium coordinate conversion, exercised against
/// the two-display arrangement the feature was written for (a 4K Dell as the
/// main display with the 16" built-in panel below it) plus the single-display
/// and clamshell cases.
///
/// The whole point of these: AppKit measures y upward from the *primary*
/// display's bottom-left, while both window-placement APIs measure y downward
/// from its top-left. A display below the main one therefore has a negative
/// `frame.origin.y` in AppKit and a large positive `top` here.
final class ScreenPlacementTests: XCTestCase {

    // MARK: - Fixtures

    /// Dell U4320Q, main display, menu bar along its top.
    private static let dell = ScreenPlacement.Screen(
        isBuiltIn: false,
        frame: CGRect(x: 0, y: 0, width: 3840, height: 2160),
        visibleFrame: CGRect(x: 0, y: 0, width: 3840, height: 2135)
    )

    /// The built-in panel arranged directly below the Dell. 1728x1117 points
    /// is the 3456x2234 Retina panel at its default scaling.
    private static let builtInBelow = ScreenPlacement.Screen(
        isBuiltIn: true,
        frame: CGRect(x: 0, y: -1117, width: 1728, height: 1117),
        visibleFrame: CGRect(x: 0, y: -1117, width: 1728, height: 1117)
    )

    /// Same panel arranged to the right of the Dell, bottom edges aligned.
    private static let builtInBeside = ScreenPlacement.Screen(
        isBuiltIn: true,
        frame: CGRect(x: 3840, y: 0, width: 1728, height: 1117),
        visibleFrame: CGRect(x: 3840, y: 0, width: 1728, height: 1117)
    )

    /// Laptop on its own: built-in is also the primary display.
    private static let builtInAlone = ScreenPlacement.Screen(
        isBuiltIn: true,
        frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1092)
    )

    // MARK: - Screen selection

    func testTargetScreenPrefersTheBuiltInPanel() {
        XCTAssertEqual(
            ScreenPlacement.targetScreen(in: [Self.dell, Self.builtInBelow]),
            Self.builtInBelow
        )
    }

    /// Clamshell mode, or the panel disconnected: nothing is built in, so the
    /// feature degrades to the primary display rather than picking an
    /// arbitrary external monitor.
    func testTargetScreenFallsBackToPrimaryWhenNoBuiltInPanel() {
        let secondExternal = ScreenPlacement.Screen(
            isBuiltIn: false,
            frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        )

        XCTAssertEqual(
            ScreenPlacement.targetScreen(in: [secondExternal, Self.dell]),
            Self.dell
        )
    }

    /// The primary display is the one at the coordinate-space origin, whatever
    /// order `NSScreen.screens` happens to return.
    func testPrimaryScreenIsTheOriginDisplayNotTheFirstListed() {
        XCTAssertEqual(
            ScreenPlacement.primaryScreen(in: [Self.builtInBelow, Self.dell]),
            Self.dell
        )
    }

    func testNoScreensYieldsNoTarget() {
        XCTAssertNil(ScreenPlacement.targetScreen(in: []))
        XCTAssertNil(ScreenPlacement.fillBounds(of: []))
    }

    // MARK: - Coordinate conversion

    /// The regression that matters: the built-in panel sits *below* the main
    /// display, so its AppKit origin.y is -1117 while its AppleScript `top` is
    /// +2160 — the full height of the main display. Flipping the sign here is
    /// what puts the window off-screen.
    func testBuiltInBelowMainConvertsToPositiveTopBelowTheMainDisplay() {
        let bounds = ScreenPlacement.fillBounds(of: [Self.dell, Self.builtInBelow])

        XCTAssertEqual(
            bounds,
            ScreenPlacement.WindowBounds(left: 0, top: 2160, right: 1728, bottom: 3277)
        )
    }

    /// Side-by-side, bottom-aligned: the shorter panel's top is 1043pt down
    /// from the main display's top (2160 - 1117), and its left is the main
    /// display's full width.
    func testBuiltInBesideMainConvertsBothAxes() {
        let bounds = ScreenPlacement.fillBounds(of: [Self.dell, Self.builtInBeside])

        XCTAssertEqual(
            bounds,
            ScreenPlacement.WindowBounds(left: 3840, top: 1043, right: 5568, bottom: 2160)
        )
    }

    /// Single display: the only offset is the menu bar, so `top` is 25 rather
    /// than 0. A `top` of 0 would tuck the window's title bar under the menu.
    func testSingleBuiltInDisplayStartsBelowTheMenuBar() {
        let bounds = ScreenPlacement.fillBounds(of: [Self.builtInAlone])

        XCTAssertEqual(
            bounds,
            ScreenPlacement.WindowBounds(left: 0, top: 25, right: 1728, bottom: 1117)
        )
    }

    /// A Dock on the left inset of the target display must survive the
    /// conversion as a non-zero `left`.
    func testDockInsetSurvivesConversion() {
        let dockedLeft = ScreenPlacement.Screen(
            isBuiltIn: true,
            frame: CGRect(x: 0, y: -1117, width: 1728, height: 1117),
            visibleFrame: CGRect(x: 80, y: -1117, width: 1648, height: 1117)
        )

        XCTAssertEqual(
            ScreenPlacement.fillBounds(of: [Self.dell, dockedLeft]),
            ScreenPlacement.WindowBounds(left: 80, top: 2160, right: 1728, bottom: 3277)
        )
    }

    /// The arrangement this feature was actually built for, measured off the
    /// machine on 2026-09-01 rather than guessed: the Dell is primary at the
    /// origin and the built-in panel sits to its *right*, raised 228pt. Both
    /// axes are non-zero, so a conversion that dropped either one would still
    /// pass the fixtures above.
    ///
    /// The load-bearing assertion is `left`: 3840...5568 is exactly the
    /// built-in panel's span, and 0...3840 is the Dell's. Off-by-one on the
    /// origin puts the meeting back on the monitor the preference exists to
    /// avoid.
    func testRealMeasuredTwoDisplayArrangement() {
        let dell = ScreenPlacement.Screen(
            isBuiltIn: false,
            frame: CGRect(x: 0, y: 0, width: 3840, height: 2160),
            visibleFrame: CGRect(x: 0, y: 0, width: 3840, height: 2130)
        )
        let builtIn = ScreenPlacement.Screen(
            isBuiltIn: true,
            frame: CGRect(x: 3840, y: 228, width: 1728, height: 1117),
            visibleFrame: CGRect(x: 3840, y: 228, width: 1728, height: 1085)
        )

        let bounds = ScreenPlacement.fillBounds(of: [dell, builtIn])

        // top = 2160 - (228 + 1085)
        XCTAssertEqual(
            bounds,
            ScreenPlacement.WindowBounds(left: 3840, top: 847, right: 5568, bottom: 1932)
        )
    }

    func testWindowBoundsWidthAndHeightMatchTheSourceRect() {
        let bounds = ScreenPlacement.windowBounds(
            for: CGRect(x: 100, y: 200, width: 640, height: 480),
            primaryFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117)
        )

        XCTAssertEqual(bounds.width, 640)
        XCTAssertEqual(bounds.height, 480)
        // top = 1117 - (200 + 480)
        XCTAssertEqual(bounds.top, 437)
        XCTAssertEqual(bounds.left, 100)
    }

    /// Fractional point values (a scaled display, or a Dock inset that isn't a
    /// whole number) must round rather than truncate toward zero — AppleScript
    /// bounds are integers.
    func testFractionalRectsRoundRatherThanTruncate() {
        let bounds = ScreenPlacement.windowBounds(
            for: CGRect(x: 10.6, y: 0.4, width: 100.5, height: 200.5),
            primaryFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000)
        )

        XCTAssertEqual(bounds.left, 11)
        // top = 1000 - (0.4 + 200.5) = 799.1
        XCTAssertEqual(bounds.top, 799)
    }
}
