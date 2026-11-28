import AppKit
import SwiftUI

@main
@MainActor
enum MenuBarQuotaTests {
    // Without percentages the label is 26×13 points: 4-point horizontal and
    // 2-point vertical padding around two 18×3 bars spaced 3 points apart.
    static let scale = 8.0
    static let barStart = 4.0
    static let barWidth = 18.0
    static let fiveHourY = 3.5
    static let weekY = 9.5

    static func render(_ label: MenuBarQuotaLabel, background: Color) -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: label.background(background))
        renderer.scale = scale
        return NSBitmapImageRep(cgImage: renderer.cgImage!)
    }

    static func color(_ bitmap: NSBitmapImageRep, fraction: Double, y: Double) -> NSColor {
        let x = Int(((barStart + barWidth * fraction) * scale).rounded())
        return bitmap.colorAt(x: x, y: Int((y * scale).rounded()))!.usingColorSpace(.deviceRGB)!
    }

    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let bitmap = render(MenuBarQuotaLabel(fiveHourFraction: 0.30, weekFraction: 0.12,
                                              isDark: true, showsPercentages: false),
                            background: .black)
        for (used, y) in [(0.30, fiveHourY), (0.12, weekY)] {
            let filled = color(bitmap, fraction: used - 0.04, y: y).redComponent
            let gap = color(bitmap, fraction: used + 0.04, y: y).redComponent
            guard filled > 0.8, gap < 0.4 else {
                print("\(Int(used * 100))% used bar is inaccurate: filled=\(filled), gap=\(gap)")
                exit(1)
            }
        }
        for isDark in [false, true] {
            let cases: [(used: Int, hex: UInt32)] = [
                (24, isDark ? 0xF5F5F7 : 0x1D1D1F),
                (25, 0xFFD60A), (49, 0xFFD60A),
                (50, 0xFF9F0A), (74, 0xFF9F0A),
                (75, 0xFF453A), (92, 0xFF453A), (100, 0xFF453A),
            ]
            for (used, hex) in cases {
                let usedFraction = Double(used) / 100
                let colors = render(MenuBarQuotaLabel(fiveHourFraction: usedFraction, weekFraction: usedFraction,
                                                      isDark: isDark, showsPercentages: false),
                                    background: isDark ? .black : .white)
                let expected = [Double((hex >> 16) & 0xFF) / 255,
                                Double((hex >> 8) & 0xFF) / 255,
                                Double(hex & 0xFF) / 255]
                for y in [fiveHourY, weekY] {
                    let actual = color(colors, fraction: 0.15, y: y)
                    let components = [actual.redComponent, actual.greenComponent, actual.blueComponent]
                    guard zip(components, expected).allSatisfy({ abs($0 - $1) < 0.1 }) else {
                        print("Quota bar color is incorrect: dark=\(isDark), used=\(used), y=\(y)")
                        exit(1)
                    }
                }
            }
        }
        print("Quota bar proportion and color checks passed")
    }
}
