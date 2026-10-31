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
        // Sample its centreline around the requested 12% used endpoint.
        func brightness(at fraction: Double) -> CGFloat {
            let angle = fraction * 2 * Double.pi
            let x = Int(((12 + 3.75 * sin(angle)) * 8).rounded())
            let y = Int(((10 - 3.75 * cos(angle)) * 8).rounded())
            return bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!.redComponent
        }
        let filled = brightness(at: 0.08)
        let gapAfterEnd = brightness(at: 0.18)
        let gapBeforeStart = brightness(at: 0.98)
        guard filled > 0.8, gapAfterEnd < 0.4, gapBeforeStart < 0.4 else {
            print("12% used inner ring is inaccurate: filled=\(filled), gaps=\(gapAfterEnd), \(gapBeforeStart)")
            exit(1)
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
                        print("Quota ring color is incorrect: dark=\(isDark), used=\(used), radius=\(radius)")
                        exit(1)
                    }
                }
            }
        }
        print("Quota ring proportion and color checks passed")
    }
}
