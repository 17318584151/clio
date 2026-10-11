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
        print("Inner quota ring proportion checks passed")
    }
}
