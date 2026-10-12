import AppKit
import SwiftUI

@main
@MainActor
enum MenuBarQuotaTests {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let renderer = ImageRenderer(content:
            MenuBarQuotaLabel(claudeFraction: 0.30, codexFraction: 0.12, isDark: true)
                .background(Color.black))
        renderer.scale = 8
        let bitmap = NSBitmapImageRep(cgImage: renderer.cgImage!)
        // The inner circle is centred at (12, 10) points with a 3.75-point radius.
        // Sample its centreline well away from the requested 88% endpoint.
        func brightness(at fraction: Double) -> CGFloat {
            let angle = fraction * 2 * Double.pi
            let x = Int(((12 + 3.75 * sin(angle)) * 8).rounded())
            let y = Int(((10 - 3.75 * cos(angle)) * 8).rounded())
            return bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!.redComponent
        }
        let filled = brightness(at: 0.85)
        let gapAfterEnd = brightness(at: 0.90)
        let gapBeforeStart = brightness(at: 0.98)
        guard filled > 0.8, gapAfterEnd < 0.4, gapBeforeStart < 0.4 else {
            print("88% inner ring is inaccurate: filled=\(filled), gaps=\(gapAfterEnd), \(gapBeforeStart)")
            exit(1)
        }
        for isDark in [false, true] {
            let cases: [(remaining: Int, hex: UInt32)] = [
                (100, isDark ? 0xF5F5F7 : 0x1D1D1F),
                (76, isDark ? 0xF5F5F7 : 0x1D1D1F),
                (75, 0xFFD60A), (51, 0xFFD60A),
                (50, 0xFF9F0A), (26, 0xFF9F0A),
                (25, 0xFF453A), (8, 0xFF453A),
            ]
            for (remaining, hex) in cases {
                let usedFraction = 1 - Double(remaining) / 100
                let colorRenderer = ImageRenderer(content:
                    MenuBarQuotaLabel(claudeFraction: usedFraction, codexFraction: usedFraction,
                                      isDark: isDark, showsPercentages: false)
                        .background(isDark ? Color.black : Color.white))
                colorRenderer.scale = 8
                let colors = NSBitmapImageRep(cgImage: colorRenderer.cgImage!)
                func ringColor(radius: Double) -> NSColor {
                    let angle = 0.03 * 2 * Double.pi
                    let x = Int(((12 + radius * sin(angle)) * 8).rounded())
                    let y = Int(((10 - radius * cos(angle)) * 8).rounded())
                    return colors.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                }
                let expected = [Double((hex >> 16) & 0xFF) / 255,
                                Double((hex >> 8) & 0xFF) / 255,
                                Double(hex & 0xFF) / 255]
                for radius in [7.25, 3.75] {
                    let actual = ringColor(radius: radius)
                    let components = [actual.redComponent, actual.greenComponent, actual.blueComponent]
                    guard zip(components, expected).allSatisfy({ abs($0 - $1) < 0.1 }) else {
                        print("Quota ring color is incorrect: dark=\(isDark), remaining=\(remaining), radius=\(radius)")
                        exit(1)
                    }
                }
            }
        }
        print("Quota ring proportion and color checks passed")
    }
}
