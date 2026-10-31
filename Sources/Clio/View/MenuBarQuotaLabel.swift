import SwiftUI

/// Used quota: Claude on the outer ring, Codex on the inner ring.
struct MenuBarQuotaLabel: View {
    var claudeFraction: Double?
    var codexFraction: Double?
    var isDark: Bool
    var isSelected = false
    var showsPercentages = true
    var tokenText: String?

    private var foreground: Color {
        isDark ? Color(hex: 0xF5F5F7) : Color(hex: 0x1D1D1F)
    }

    static func usedPercent(_ usedFraction: Double?) -> Int? {
        usedFraction.map { Int((min(1, max(0, $0)) * 100).rounded()) }
    }

    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                ring(claudeFraction, size: 16)
                ring(codexFraction, size: 9)
            }
            if showsPercentages {
                percentage(claudeFraction)
                percentage(codexFraction)
            }
            if let tokenText {
                Text(tokenText)
                    .foregroundStyle(foreground)
                    .fixedSize()
            }
        }
        .font(.system(size: 12, weight: .medium))
        .monospacedDigit()
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(foreground.opacity(0.16))
            }
        }
    }

    private func ring(_ usedFraction: Double?, size: CGFloat) -> some View {
        ZStack {
            Circle()
                .stroke(foreground.opacity(0.22), lineWidth: 1.5)
            if let usedFraction {
                Circle()
                    .trim(from: 0, to: min(1, max(0, usedFraction)))
                    // Flat endpoints keep the visible arc within its quota proportion.
                    .stroke(color(for: Self.usedPercent(usedFraction)),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
        }
        .padding(0.75)
        .frame(width: size, height: size)
    }

    private func percentage(_ usedFraction: Double?) -> some View {
        let used = Self.usedPercent(usedFraction)
        return Text(used.map { "\($0)%" } ?? "—")
            .foregroundStyle(color(for: used))
            .fixedSize()
    }

    private func color(for used: Int?) -> Color {
        guard let used else { return foreground.opacity(0.5) }
        if used >= 75 { return Color(hex: 0xFF453A) }
        if used >= 50 { return Color(hex: 0xFF9F0A) }
        if used >= 25 { return Color(hex: 0xFFD60A) }
        return foreground
    }
}
