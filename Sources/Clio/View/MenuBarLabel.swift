import SwiftUI

/// The app icon and optional combined token count.
/// Selection keeps the image size fixed.
struct MenuBarLabel: View {
    var text: String?
    var isDark: Bool
    var isSelected = false
    var appIcon: NSImage?

    private var foreground: Color {
        isDark ? Color(hex: 0xF5F5F7) : Color(hex: 0x1D1D1F)
    }

    var body: some View {
        HStack(spacing: 5) {
            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 16 * 1024 / 824, height: 16 * 1024 / 824)
                    .frame(width: 16, height: 16)
            }
            if let text {
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(foreground)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(foreground.opacity(0.16))
            }
        }
    }
}
