//
//  Theme.swift
//  slapss
//
//  App-wide color theme. A theme swaps the ACCENT layer only — the mesh
//  palette (full-screen alert, popover hero, onboarding and About cards),
//  the pill, hero text tints and the gradient CTA. Neutral surfaces and ink (Tokens.paper*/ink*) are
//  intentionally theme-independent, as is light/dark mode, which continues to
//  follow the system appearance on an orthogonal axis.
//
//  Persistence lives in AppSettings.theme. Views consume colors via
//  `settings.theme.accents.<name>` so a theme change re-renders through the
//  normal ObservableObject invalidation path (static tokens wouldn't
//  reliably re-render sub-structs SwiftUI has decided to skip).
//

import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    /// The original slapss look — peach/rose/sky popover, orange-magenta-purple mesh.
    case sunset
    /// Blues, lavender and sea green.
    case ocean
    /// Greens, sage and soft amber.
    case forest

    var id: String { rawValue }

    /// Localization key for the display name ("theme.sunset" etc.).
    var localizationKey: String { "theme.\(rawValue)" }

    /// Which MeshBackground palette the full-screen overlay uses. `.cool` and
    /// `.forest` already existed in MeshBackground (previously unused).
    var meshPalette: MeshBackground.Palette {
        switch self {
        case .sunset: return .sunset
        case .ocean:  return .cool
        case .forest: return .forest
        }
    }

    var accents: Accents {
        switch self {
        case .sunset: return Self.sunsetAccents
        case .ocean:  return Self.oceanAccents
        case .forest: return Self.forestAccents
        }
    }

    /// The themed color set. Field names mirror the former Tokens entries.
    /// The pastel blob colors, the brand gradient, the dark hero's top color
    /// and `joinBg` went with the sticker hero in 2.2.0.
    struct Accents {
        let pillBg: Color
        let pillInk: Color
        let pulseDot: Color

        let heroTitle: Color
        let heroTime: Color
        let heroMeta: Color

        /// Base colors the mesh falls off into on the light / dark cards.
        let heroBgLight: Color
        let heroBgDarkBottom: Color

        /// The primary CTA everywhere since 2.2.0 (alert, popover Join,
        /// onboarding buttons): gradient fill and glow. Flat colors, no
        /// light/dark variant. Previously hardcoded green (0x2da14a) across
        /// all themes; themed in 1.8.1 so the CTA follows the accent and
        /// doesn't sink into the forest theme's green mesh.
        let overlayCtaTop: Color
        let overlayCtaBottom: Color
    }

    // MARK: - Palettes

    /// Identical to the pre-theming values — existing users see no change.
    private static let sunsetAccents = Accents(
        pillBg: .themed(light: 0xFFFFFF, lightAlpha: 0.55, dark: 0xFFD6A8, darkAlpha: 0.12),
        pillInk: .themed(light: 0xA35A18, dark: 0xFFD6A8),
        pulseDot: .themed(light: 0xE8732A, dark: 0xFF9447),
        heroTitle: .themed(light: 0x3A2A1A, dark: 0xFBF2E1),
        heroTime: .themed(light: 0x7A5230, dark: 0xD8C5A8),
        heroMeta: .themed(light: 0x7A5230, dark: 0xC9B89A),
        heroBgLight: Color(rgb: 0xFFF7EC),
        heroBgDarkBottom: Color(rgb: 0x25202D),
        overlayCtaTop: Color(rgb: 0xE8732A),
        overlayCtaBottom: Color(rgb: 0xC2571F)
    )

    private static let oceanAccents = Accents(
        pillBg: .themed(light: 0xFFFFFF, lightAlpha: 0.55, dark: 0xA8D4FF, darkAlpha: 0.12),
        pillInk: .themed(light: 0x1B5E8A, dark: 0xA8D4FF),
        pulseDot: .themed(light: 0x2E7CC4, dark: 0x5CA8E8),
        heroTitle: .themed(light: 0x1A2A3A, dark: 0xE1EDFB),
        heroTime: .themed(light: 0x30527A, dark: 0xA8C4DC),
        heroMeta: .themed(light: 0x30527A, dark: 0x9AB6CC),
        heroBgLight: Color(rgb: 0xEFF6FC),
        heroBgDarkBottom: Color(rgb: 0x1F2733),
        overlayCtaTop: Color(rgb: 0x2E7CC4),
        overlayCtaBottom: Color(rgb: 0x1F5C99)
    )

    private static let forestAccents = Accents(
        pillBg: .themed(light: 0xFFFFFF, lightAlpha: 0.55, dark: 0xC2E8C2, darkAlpha: 0.12),
        pillInk: .themed(light: 0x2E6B42, dark: 0xC2E8C2),
        pulseDot: .themed(light: 0x3E9A5C, dark: 0x55B878),
        heroTitle: .themed(light: 0x1E3324, dark: 0xE6F5E2),
        heroTime: .themed(light: 0x3E6B4C, dark: 0xAECDAE),
        heroMeta: .themed(light: 0x3E6B4C, dark: 0x9FC09F),
        heroBgLight: Color(rgb: 0xF2F8EF),
        heroBgDarkBottom: Color(rgb: 0x1E2A21),
        overlayCtaTop: Color(rgb: 0x3E9A5C),
        overlayCtaBottom: Color(rgb: 0x2E7444)
    )
}

// MARK: - Dynamic color helper

private extension Color {
    /// Appearance-dynamic color from two hex literals. Mirrors the
    /// `Color(light:dark:)` helper that is file-private to ContentView.swift —
    /// duplicated here (with a distinct name) rather than widening that
    /// helper's access.
    static func themed(
        light: UInt32, lightAlpha: Double = 1.0,
        dark: UInt32, darkAlpha: Double = 1.0
    ) -> Color {
        Color(NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [
                .darkAqua, .vibrantDark,
                .accessibilityHighContrastDarkAqua,
                .accessibilityHighContrastVibrantDark
            ]) != nil
            return isDark
                ? NSColor(Color(rgb: dark, alpha: darkAlpha))
                : NSColor(Color(rgb: light, alpha: lightAlpha))
        })
    }
}

// MARK: - Theme picker (shared by Settings and Onboarding)

/// Three theme cards in a row: a still of the theme's alert mesh plus the
/// localized name. The selected card gets an accent border. Writes
/// straight to `AppSettings.theme`, so both call sites get live preview
/// behavior for free (the popover hero, onboarding hero, and number badges
/// all re-render from the same published property).
struct ThemeSwatchPicker: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var lm: LocalizationManager

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AppTheme.allCases) { theme in
                ThemeSwatchCard(
                    theme: theme,
                    isSelected: settings.theme == theme,
                    label: lm[theme.localizationKey]
                ) {
                    settings.theme = theme
                }
            }
        }
    }
}

private struct ThemeSwatchCard: View {
    let theme: AppTheme
    let isSelected: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                // A still frame of the theme's actual full-screen alert
                // backdrop, so the choice shows what will hit the screen.
                MeshBackground(palette: theme.meshPalette, energy: 0.4, animating: false)
                    .frame(height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(label)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .padding(6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.secondary.opacity(isSelected ? 0.10 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(
                        isSelected ? theme.accents.overlayCtaTop : Color.secondary.opacity(0.25),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickCursor()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Shared surfaces (2.2.0 design language)

extension View {
    /// The design language's "brand moment" surface: the theme's mesh (a
    /// small, calmer version of the full-screen alert's backdrop) under a
    /// specular top highlight, clipped to a continuous rounded rect with a
    /// top-lit hairline edge and a soft shadow. Used by the popover hero,
    /// the onboarding welcome card and the About banner.
    ///
    /// `animating` must follow real visibility wherever the view can outlive
    /// what's on screen (the popover, a window left open behind others).
    func meshCard(theme: AppTheme, cornerRadius: CGFloat, energy: Double = 0, animating: Bool) -> some View {
        modifier(MeshCard(theme: theme, cornerRadius: cornerRadius, energy: energy, animating: animating))
    }

    /// The alert's primary-button fill, at any size: theme gradient, light
    /// hairline, soft glow in its own color. Disabled falls back to a flat
    /// neutral fill with no glow.
    func ctaFill(_ accents: AppTheme.Accents, cornerRadius: CGFloat, enabled: Bool = true) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .foregroundStyle(.white)
            .background(
                enabled
                    ? AnyShapeStyle(LinearGradient(colors: [accents.overlayCtaTop, accents.overlayCtaBottom],
                                                   startPoint: .top, endPoint: .bottom))
                    : AnyShapeStyle(Color.secondary.opacity(0.45)),
                in: shape
            )
            .overlay(shape.strokeBorder(.white.opacity(enabled ? 0.18 : 0.08), lineWidth: 1))
            .shadow(color: enabled ? accents.overlayCtaTop.opacity(0.35) : .clear, radius: 8, x: 0, y: 3)
    }
}

private struct MeshCard: ViewModifier {
    let theme: AppTheme
    let cornerRadius: CGFloat
    let energy: Double
    let animating: Bool
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                ZStack {
                    MeshBackground(
                        palette: theme.meshPalette,
                        energy: energy,
                        base: dark ? theme.accents.heroBgDarkBottom : theme.accents.heroBgLight,
                        // Calmer than the alert so text on it stays readable;
                        // a pastel wash in light mode.
                        tint: dark ? 0.55 : 0.3,
                        animating: animating
                    )
                    .animation(.easeInOut(duration: 1.5), value: energy)
                    .transaction { $0.disablesAnimations = false }

                    LinearGradient(
                        colors: [.white.opacity(dark ? 0.10 : 0.45), .white.opacity(0)],
                        startPoint: .top,
                        endPoint: UnitPoint(x: 0.5, y: 0.45)
                    )
                    if dark {
                        // Keeps lower text readable where the mesh is brightest.
                        LinearGradient(colors: [.black.opacity(0), .black.opacity(0.25)],
                                       startPoint: .top, endPoint: .bottom)
                    }
                }
                .allowsHitTesting(false)
            }
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(dark ? 0.22 : 0.9),
                                 dark ? .white.opacity(0.05) : Color(rgb: 0x1F1D2B, alpha: 0.10)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            )
            .shadow(color: dark ? .black.opacity(0.55) : Color(rgb: 0x3A2A1A, alpha: 0.14),
                    radius: dark ? 14 : 10, x: 0, y: dark ? 8 : 4)
    }
}
