import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// Colors and metrics taken from the design canvas. Light and dark are two
/// separate sets rather than one set with opacity tweaks, matching the source.
struct Theme {
    var textPrimary: Color
    var textSecondary: Color
    var textTertiary: Color
    var cardFill: Color
    var cardStroke: Color
    var cardInnerStroke: Color
    var panelFill: Color
    var panelStroke: Color
    var panelInnerStroke: Color
    var separator: Color
    var chartGuide: Color
    var shareTrack: Color
    var track: Color
    var segmentedFill: Color
    var segmentedSelected: Color
    var segmentedSelectedText: Color
    var badgeFill: Color
    var badgeText: Color
    var cost: Color
    var pillFill: Color
    var menuFill: Color
    var accent: Color
    var warning: Color
    var danger: Color
    var positive: Color
    /// Liquid Glass leans toward this, so the text keeps its contrast over
    /// whatever sits behind the panel.
    var glassTint: Color
    var heatmap: [Color]
    /// Each tool's color where their shares are drawn together.
    var claudeSeries: Color
    var codexSeries: Color
    var geminiSeries: Color
    /// Model colors in allocation order, shared by the share bar and legend.
    var modelPalette: [Color]

    static let light = Theme(
        textPrimary: Color(hex: 0x1D1D1F),
        textSecondary: Color(hex: 0x6E6E73),
        textTertiary: Color(hex: 0xAEAEB2),
        cardFill: Color.white.opacity(0.55),
        cardStroke: Color.black.opacity(0.06),
        cardInnerStroke: Color.white.opacity(0.8),
        panelFill: Color(hex: 0xF6F6F8).opacity(0.62),
        panelStroke: Color.black.opacity(0.14),
        panelInnerStroke: Color.white.opacity(0.7),
        separator: Color(hex: 0xE5E5EA),
        chartGuide: Color(hex: 0xEEEEF2),
        shareTrack: Color(hex: 0xE0E0E6),
        track: Color(hex: 0xE5E5EA),
        segmentedFill: Color.black.opacity(0.07),
        segmentedSelected: .white,
        segmentedSelectedText: Color(hex: 0x1D1D1F),
        badgeFill: Color(hex: 0xF2E9E4),
        badgeText: Color(hex: 0xB8572F),
        cost: Color(hex: 0x5B44B8),
        pillFill: Color(hex: 0xE3E3E8),
        menuFill: Color(hex: 0xF6F6F8),
        accent: Color(hex: 0x6E56CF),
        warning: Color(hex: 0xFF9F0A),
        danger: Color(hex: 0xFF3B30),
        positive: Color(hex: 0x34C759),
        glassTint: Color.white.opacity(0.35),
        heatmap: [Color(hex: 0xEBEBF0), Color(hex: 0xDDD5F6), Color(hex: 0xB9AAEC),
                  Color(hex: 0x9380DC), Color(hex: 0x6E56CF)],
        claudeSeries: Color(hex: 0xD97757),
        codexSeries: Color(hex: 0x0A84FF),
        geminiSeries: Color(hex: 0x12A594),
        modelPalette: [Color(hex: 0x1BAF7A), Color(hex: 0xEDA100), Color(hex: 0xE87BA4),
                       Color(hex: 0x008300), Color(hex: 0x6250D6), Color(hex: 0xE34948),
                       Color(hex: 0x397BC9), Color(hex: 0xA46536), Color(hex: 0x1696A3),
                       Color(hex: 0x9C3E9C), Color(hex: 0x7A801D), Color(hex: 0xD5671D)]
    )

    static let dark = Theme(
        textPrimary: Color(hex: 0xF5F5F7),
        textSecondary: Color(hex: 0x98989D),
        textTertiary: Color(hex: 0x8A8A8F),
        cardFill: Color.white.opacity(0.07),
        cardStroke: Color.white.opacity(0.08),
        cardInnerStroke: Color.white.opacity(0.06),
        panelFill: Color(hex: 0x28282C).opacity(0.6),
        panelStroke: Color.black.opacity(0.5),
        panelInnerStroke: Color.white.opacity(0.14),
        separator: Color.white.opacity(0.1),
        chartGuide: Color.white.opacity(0.08),
        shareTrack: Color.white.opacity(0.12),
        track: Color(hex: 0x48484A),
        segmentedFill: Color.black.opacity(0.35),
        segmentedSelected: Color.white.opacity(0.18),
        segmentedSelectedText: Color(hex: 0xF5F5F7),
        badgeFill: Color(hex: 0x4A4A4F),
        badgeText: Color(hex: 0xF5F5F7),
        cost: Color(hex: 0xB6A8FF),
        pillFill: Color(hex: 0x1F1F21),
        menuFill: Color(hex: 0x2C2C2E),
        accent: Color(hex: 0x9D8CFF),
        warning: Color(hex: 0xFF9F0A),
        danger: Color(hex: 0xFF453A),
        positive: Color(hex: 0x30D158),
        glassTint: Color.black.opacity(0.35),
        heatmap: [Color.white.opacity(0.08), Color(hex: 0x3A2F73), Color(hex: 0x5846B0),
                  Color(hex: 0x7B67E0), Color(hex: 0xB6A8FF)],
        claudeSeries: Color(hex: 0xD0704F),
        codexSeries: Color(hex: 0x0A84FF),
        geminiSeries: Color(hex: 0x2DBBA8),
        modelPalette: [Color(hex: 0x199E70), Color(hex: 0xC98500), Color(hex: 0xD55181),
                       Color(hex: 0x008300), Color(hex: 0x9085E9), Color(hex: 0xE66767),
                       Color(hex: 0x69A5EB), Color(hex: 0xC18C5D), Color(hex: 0x46B9C6),
                       Color(hex: 0xCA73CA), Color(hex: 0xABB44E), Color(hex: 0xEC944B)]
    )

    static func resolve(_ scheme: ColorScheme, preset: ThemePreset = .indigo) -> Theme {
        var theme: Theme = scheme == .dark ? .dark : .light
        preset.apply(to: &theme, dark: scheme == .dark)
        return theme
    }

    /// Liquid Glass lets far more of the backdrop through than the frosted
    /// material, so an opaque empty cell can match the card it sits on.
    var onGlass: Theme {
        var theme = self
        theme.heatmap[0] = textPrimary.opacity(0.08)
        return theme
    }

    func categorySeries(_ category: ModelCategory) -> Color {
        switch category {
        case .claudeCode: return claudeSeries
        case .codex: return codexSeries
        case .gemini: return geminiSeries
        case .other: return textSecondary
        }
    }

    func series(_ tool: Tool) -> Color {
        categorySeries(ModelCategory(legacyTool: tool))
    }

    func modelColor(at index: Int) -> Color {
        if index < modelPalette.count { return modelPalette[index] }
        let hue = (0.53 + Double(index - modelPalette.count) * 0.618033988749895)
            .truncatingRemainder(dividingBy: 1)
        return Color(hue: hue, saturation: 0.65, brightness: 0.78)
    }

    /// Ring and bar color for a quota window: monochrome below half, orange
    /// from 50%, red from 80%.
    func quotaColor(_ fraction: Double?, base: Color? = nil) -> Color {
        guard let fraction else { return base ?? accent }
        if fraction >= 0.8 { return danger }
        if fraction >= 0.6 { return warning }
        return base ?? accent
    }
}

/// Accent, cost and heat map colors; the neutrals and the tools' own colors stay put.
enum ThemePreset: String, CaseIterable, Identifiable {
    case indigo, ocean, amber, rose, forest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .indigo: return "靛紫"
        case .ocean: return "海洋"
        case .amber: return "琥珀"
        case .rose: return "玫红"
        case .forest: return "森林"
        }
    }

    /// Accent, cost, then the four filled heat map levels.
    private func colors(dark: Bool) -> (accent: UInt32, cost: UInt32, heat: [UInt32]) {
        switch (self, dark) {
        case (.indigo, false): return (0x6E56CF, 0x5B44B8, [0xDDD5F6, 0xB9AAEC, 0x9380DC, 0x6E56CF])
        case (.indigo, true): return (0x9D8CFF, 0xB6A8FF, [0x3A2F73, 0x5846B0, 0x7B67E0, 0xB6A8FF])
        case (.ocean, false): return (0x0891B2, 0x0E7490, [0xCDEFF5, 0x8ED6E4, 0x3FB5CC, 0x0E7490])
        case (.ocean, true): return (0x4CC9E0, 0x7DE0F0, [0x164E5C, 0x1F7A8C, 0x2FA3BC, 0x7DE0F0])
        case (.amber, false): return (0xD97706, 0xB45309, [0xFBE8C4, 0xF6CD84, 0xE9A23B, 0xB45309])
        case (.amber, true): return (0xF5B041, 0xFAD58A, [0x5E3A0B, 0x8C5A14, 0xC98A22, 0xFAD58A])
        case (.rose, false): return (0xD6336C, 0xA61E4D, [0xFAD7E3, 0xF3A6C0, 0xE5668F, 0xA61E4D])
        case (.rose, true): return (0xFF7AA8, 0xFFB3CC, [0x6B2040, 0x9C3560, 0xD04F85, 0xFFB3CC])
        case (.forest, false): return (0x1F8552, 0x1F8552, [0xB9E3CD, 0x7DCBA3, 0x3FAA73, 0x1F8552])
        case (.forest, true): return (0x3FAA73, 0x6FD09B, [0x1F5C3E, 0x2F8557, 0x3FAA73, 0x6FD09B])
        }
    }

    func apply(to theme: inout Theme, dark: Bool) {
        let palette = colors(dark: dark)
        theme.accent = Color(hex: palette.accent)
        theme.cost = Color(hex: palette.cost)
        theme.heatmap.replaceSubrange(1..., with: palette.heat.map { Color(hex: $0) })
    }
}

/// Set while rendering to an image. `ImageRenderer` draws an AppKit-backed
/// view as a placeholder box, so those are left out of an off-screen pass.
private struct SnapshotKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isSnapshot: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.light
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// Whether the panel is drawn in Liquid Glass.
private struct LiquidGlassKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var liquidGlass: Bool {
        get { self[LiquidGlassKey.self] }
        set { self[LiquidGlassKey.self] = newValue }
    }
}

enum LiquidGlass {
    static var isAvailable: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }
}

extension View {
    /// Places the view on Liquid Glass in `shape` when `isOn`, from macOS 26.
    /// `clear` glass leaves what is behind it unblurred; `interactive` glass
    /// lights up under the pointer.
    @ViewBuilder
    func liquidGlass(_ isOn: Bool, in shape: some Shape, tint: Color? = nil,
                     clear: Bool = false, interactive: Bool = false) -> some View {
        if #available(macOS 26, *), isOn {
            glassEffect((clear ? Glass.clear : .regular).tint(tint).interactive(interactive), in: shape)
        } else {
            self
        }
    }
}

/// Measured off the design canvas. The panel's 320pt is its *content* width —
/// the artboard's card is 320 wide plus 12pt of padding on each side, so the
/// window itself is 344.
enum Metrics {
    static let panelContentWidth: CGFloat = 320
    static let panelPadding: CGFloat = 12
    static let panelWidth: CGFloat = panelContentWidth + panelPadding * 2
    static let cardRadius: CGFloat = 10
    static let panelRadius: CGFloat = 14
    /// Content width inside a card: 320 minus the card's own 12pt padding.
    static let cardContentWidth: CGFloat = panelContentWidth - 24
}
