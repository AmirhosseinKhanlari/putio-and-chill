import SwiftUI
import UIKit

struct RGB: Equatable, Sendable {
    var r: Double, g: Double, b: Double

    var color: Color { Color(red: r, green: g, blue: b) }

    /// Pushes saturation up and keeps brightness in a range that glows without washing out text.
    func vivid() -> RGB {
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        UIColor(red: r, green: g, blue: b, alpha: 1).getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        let out = UIColor(hue: h, saturation: min(1, s * 1.35 + 0.08), brightness: min(0.85, max(0.42, v * 1.25)), alpha: 1)
        var rr: CGFloat = 0, gg: CGFloat = 0, bb: CGFloat = 0
        out.getRed(&rr, green: &gg, blue: &bb, alpha: &a)
        return RGB(r: rr, g: gg, b: bb)
    }
}

struct AmbientPalette: Equatable, Sendable {
    var primary: RGB
    var secondary: RGB

    static let neutral = AmbientPalette(primary: RGB(r: 0.23, g: 0.3, b: 0.55), secondary: RGB(r: 0.2, g: 0.12, b: 0.3))

    /// Stable colors for titles without artwork (and for demo mode).
    static func seeded(_ seed: String) -> AmbientPalette {
        let hue = Double(stableHash(seed) % 360) / 360
        let primary = UIColor(hue: hue, saturation: 0.7, brightness: 0.75, alpha: 1)
        let secondary = UIColor(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.45, alpha: 1)
        return AmbientPalette(primary: rgb(primary), secondary: rgb(secondary))
    }

    static func extract(from image: CGImage) -> AmbientPalette {
        let width = 24, height = 14
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return .neutral }
        func average(columns: Range<Int>, rows: Range<Int>) -> RGB {
            var r = 0.0, g = 0.0, b = 0.0, n = 0.0
            for y in rows {
                for x in columns {
                    let i = (y * width + x) * 4
                    r += Double(pixels[i]); g += Double(pixels[i + 1]); b += Double(pixels[i + 2]); n += 1
                }
            }
            return RGB(r: r / n / 255, g: g / n / 255, b: b / n / 255)
        }
        return AmbientPalette(primary: average(columns: width / 2..<width, rows: 0..<height / 2).vivid(),
                              secondary: average(columns: 0..<width / 2, rows: height / 2..<height).vivid())
    }

    private static func rgb(_ color: UIColor) -> RGB {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return RGB(r: r, g: g, b: b)
    }
}

/// djb2; Swift's `hashValue` is randomized per launch.
func stableHash(_ text: String) -> Int {
    var hash = 5381
    for scalar in text.unicodeScalars { hash = ((hash << 5) &+ hash) &+ Int(scalar.value) }
    return abs(hash)
}
