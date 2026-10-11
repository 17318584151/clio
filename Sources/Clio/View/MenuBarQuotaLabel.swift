import SwiftUI

/// Remaining weekly quota: Claude on the outer ring, Codex on the inner ring.
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

    static func remainingPercent(_ usedFraction: Double?) -> Int? {
        usedFraction.map { Int(((1 - min(1, max(0, $0))) * 100).rounded()) }
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
                    .trim(from: 0, to: 1 - min(1, max(0, usedFraction)))
                    // Flat endpoints keep the visible arc within its quota proportion.
                    .stroke(color(for: Self.remainingPercent(usedFraction)),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
        }
        .padding(0.75)
        .frame(width: size, height: size)
    }

    private func percentage(_ usedFraction: Double?) -> some View {
        let remaining = Self.remainingPercent(usedFraction)
        return Text(remaining.map { "\($0)%" } ?? "—")
            .foregroundStyle(color(for: remaining))
            .fixedSize()
    }

    private func color(for remaining: Int?) -> Color {
        guard let remaining else { return foreground.opacity(0.5) }
        if remaining < 20 { return Color(hex: 0xFF453A) }
        if remaining <= 50 { return Color(hex: 0xFF9F0A) }
        return foreground
    }
}
