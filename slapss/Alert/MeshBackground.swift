//
//  MeshBackground.swift
//  slapss
//
//  Animated mesh-gradient backdrop. A 4×4 `MeshGradient` whose four inner
//  control points drift on slow, offset sine cycles so the motion feels
//  organic — no mechanical pulses or sweeps.
//
//  `energy` (0…1) is how close the meeting is: the drift widens and a faster
//  second cycle blends in as it rises, so the backdrop visibly wakes up when
//  the meeting is about to start. The drift *speed* never changes, only the
//  amplitude, so a change in energy can't make the points jump. The view is
//  Animatable on `energy`, so callers animate a state change and the mesh
//  eases into it frame by frame.
//
//  Until 2.2.0 this was three blurred radial blobs on `repeatForever`
//  animations, which can't change their amplitude mid-cycle without
//  restarting (a visible jump), so the backdrop couldn't react to the
//  meeting getting closer. `MeshGradient` needs macOS 15 and is why the
//  deployment target moved to 15.0. It is not cheaper: measured on a
//  single 3456×2234 display, total CPU (app + WindowServer) came out about
//  the same, with the work moving from WindowServer into the app.
//

import SwiftUI

struct MeshBackground: View, Animatable {
    enum Palette {
        case warm, cool, sunset, forest, urgent

        fileprivate var colors: [Color] {
            switch self {
            case .warm:
                return [Color(rgb: 0xc97a3a), Color(rgb: 0x6b4a8a), Color(rgb: 0x3a5a8a)]
            case .cool:
                return [Color(rgb: 0x2d6cb0), Color(rgb: 0x5a3a8a), Color(rgb: 0x3a8a7a)]
            case .sunset:
                return [Color(rgb: 0xe06b3a), Color(rgb: 0xa83a6b), Color(rgb: 0x5a3a8a)]
            case .forest:
                return [Color(rgb: 0x3a8a5a), Color(rgb: 0x2d6c5a), Color(rgb: 0x5a6c3a)]
            case .urgent:
                return [Color(rgb: 0xd04a3a), Color(rgb: 0x8a3a3a), Color(rgb: 0x6b2d3a)]
            }
        }
    }

    let palette: Palette
    /// 0 = calm (meeting minutes away), 1 = the meeting is starting / running.
    var energy: Double = 0
    /// What the translucent edges fall off into. The overlay's near-black by
    /// default; the popover hero passes its own card color.
    var base: Color = Color(rgb: 0x0c0c10)
    /// Multiplies every palette color's opacity. 1 for the overlay; the
    /// popover hero uses less so text on it stays readable (and a pastel
    /// wash in light mode).
    var tint: Double = 1
    /// False pauses the drift. The popover passes its real visibility: the
    /// MenuBarExtra view graph never goes away, so an always-on timeline
    /// would redraw with nothing on screen (see CLAUDE.md).
    var animating = true

    var animatableData: Double {
        get { energy }
        set { energy = newValue }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // 20 fps: the fastest point moves ~200 pt/s at full energy across a
        // gradient with no edges, so the steps don't read, and every frame is
        // a full-screen redraw (times the number of mirrored displays).
        // Paused under Reduce Motion: the mesh renders once and stays still.
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: reduceMotion || !animating)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            MeshGradient(
                width: 4,
                height: 4,
                points: points(t: t),
                colors: colors,
                background: base,
                smoothsColors: true
            )
            // A touch brighter and more saturated as the meeting closes in.
            .saturation(1 + 0.15 * energy)
            .brightness(0.04 * energy)
        }
        // The edge colors are translucent and the overlay window is clear, so
        // without an opaque base the desktop would show through the corners.
        .background(base)
        .ignoresSafeArea()
    }

    /// Outer ring stays pinned to the edges (a mesh must cover its bounds);
    /// the four inner points drift. Each has its own period so they never
    /// line up into an obvious pulse.
    private func points(t: Double) -> [SIMD2<Float>] {
        let calm = 0.06 + 0.04 * energy          // slow drift amplitude
        let lively = 0.025 * energy              // faster ripple, only when energy > 0
        func drift(_ x: Double, _ y: Double, _ px: Double, _ py: Double, _ phase: Double) -> SIMD2<Float> {
            let dx = sin(t * 2 * .pi / px + phase) * calm + sin(t * 2 * .pi / (px / 5) + phase) * lively
            let dy = cos(t * 2 * .pi / py + phase) * calm + cos(t * 2 * .pi / (py / 5) + phase) * lively
            return SIMD2(Float(x + dx), Float(y + dy))
        }
        return [
            [0, 0], [0.33, 0], [0.67, 0], [1, 0],
            [0, 0.33], drift(0.33, 0.36, 22, 26, 0.0), drift(0.67, 0.33, 28, 24, 1.7), [1, 0.33],
            [0, 0.67], drift(0.33, 0.67, 32, 30, 3.1), drift(0.67, 0.64, 26, 34, 4.4), [1, 0.67],
            [0, 1], [0.33, 1], [0.67, 1], [1, 1],
        ]
    }

    /// Same composition as the old blob layout: first color upper-left of
    /// center, second lower-right, third through the middle, dark corners so
    /// the card in the center gets the color and the edges fall off.
    private var colors: [Color] {
        let c = palette.colors.map { $0.opacity(tint) }
        let edge = 0.35
        return [
            base, c[0].opacity(edge), c[2].opacity(edge), base,
            c[0].opacity(edge + 0.1), c[0], c[2], c[1].opacity(edge),
            c[2].opacity(edge), c[2], c[1], c[1].opacity(edge + 0.1),
            base, c[2].opacity(edge), c[1].opacity(edge), base,
        ]
    }
}

extension Color {
    /// Convenience init for hex like `0xRRGGBB`.
    init(rgb: UInt32, alpha: Double = 1.0) {
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            opacity: alpha
        )
    }
}
