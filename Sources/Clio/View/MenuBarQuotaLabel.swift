import SwiftUI

/// Used quota of one account: 5-hour window on the top bar, weekly on the bottom bar.
struct MenuBarQuotaLabel: View {
    var fiveHourFraction: Double?
    var weekFraction: Double?
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
            VStack(spacing: 3) {
                bar(fiveHourFraction)
                bar(weekFraction)
            }
            if showsPercentages {
                percentage(fiveHourFraction)
                percentage(weekFraction)
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

    private func bar(_ usedFraction: Double?) -> some View {
        Capsule()
            .fill(foreground.opacity(0.22))
            .overlay(alignment: .leading) {
                if let usedFraction {
                    GeometryReader { proxy in
                        Rectangle()
                            .fill(color(for: Self.usedPercent(usedFraction)))
                            .frame(width: proxy.size.width * min(1, max(0, usedFraction)))
                    }
                }
            }
            // Clipping to the track keeps short fills inside its rounded ends.
            .clipShape(Capsule())
            .frame(width: 18, height: 3)
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
