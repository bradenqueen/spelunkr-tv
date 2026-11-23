import SwiftUI

/// Renders a spelunkr.tv pixel-art channel logomark using SwiftUI `Canvas`.
/// Exact port of the site's `FO`, `CR` (run/rect merging), and `ku` (HSV palette derivation).
struct LogomarkView: View {
    let rows: [String]
    let primaryColor: String?
    var size: CGFloat = 48

    private struct PixelRect {
        let x: Int
        let y: Int
        let w: Int
        var h: Int
        let token: Character
    }

    var body: some View {
        let gridSize = max(1, rows.count)
        let snapped = Self.snappedSize(target: size, grid: gridSize)
        let palette = Self.palette(primaryHex: primaryColor)
        let rects = Self.mergedRects(rows: rows)

        Canvas { context, canvasSize in
            let cell = canvasSize.width / CGFloat(gridSize)
            for rect in rects {
                let color = palette[rect.token] ?? palette["p"]!
                let frame = CGRect(
                    x: CGFloat(rect.x) * cell,
                    y: CGFloat(rect.y) * cell,
                    width: CGFloat(rect.w) * cell,
                    height: CGFloat(rect.h) * cell
                )
                context.fill(Path(frame), with: .color(color))
            }
        }
        .frame(width: snapped, height: snapped)
        .frame(width: size, height: size)
    }

    // MARK: - Site port: IR, CR, ku, OR, Mf, Pf

    /// Port of `IR(size, grid)`: largest integer multiple of `grid` that fits in `size`.
    private static func snappedSize(target: CGFloat, grid: Int) -> CGFloat {
        let g = CGFloat(grid)
        let scale = max(1, floor(target / g))
        return g * scale
    }

    /// Port of `CR(rows)`: merges horizontal runs and adjacent vertical runs of identical pixels.
    private static func mergedRects(rows: [String]) -> [PixelRect] {
        var result: [PixelRect] = []
        var active: [String: Int] = [:] // key -> index in result

        for (y, row) in rows.enumerated() {
            let chars = Array(row)
            var seen = Set<String>()
            var x = 0
            while x < chars.count {
                let ch = chars[x]
                var end = x + 1
                while end < chars.count && chars[end] == ch { end += 1 }
                if ch != "." {
                    let w = end - x
                    let key = "\(x):\(w):\(ch)"
                    if let idx = active[key], result[idx].y + result[idx].h == y {
                        result[idx].h += 1
                    } else {
                        active[key] = result.count
                        result.append(PixelRect(x: x, y: y, w: w, h: 1, token: ch))
                    }
                    seen.insert(key)
                }
                x = end
            }
            for key in Array(active.keys) where !seen.contains(key) {
                active.removeValue(forKey: key)
            }
        }
        return result
    }

    /// Fixed palette slots `TR` from spelunkr.tv.
    private static let fixedPalette: [Character: Color] = [
        "k": Color(rgbHex: 0x0B0F26),
        "n": Color(rgbHex: 0x2A3580),
        "s": Color(rgbHex: 0x8899CC),
        "p": Color(rgbHex: 0xE8EAF0),
        "g": Color(rgbHex: 0xFFD740),
        "o": Color(rgbHex: 0xD2500C),
        "r": Color(rgbHex: 0xC8143C),
    ]

    /// Port of `ku(primaryHex)` with `AR` shade/light HSV shifts and `RR = #666666` fallback.
    private static func palette(primaryHex: String?) -> [Character: Color] {
        let hex = validSixHex(primaryHex) ?? "#666666"
        let (h, s, v) = hexToHSV(hex)

        // AR.shade: { hueToward: 255, hueStep: 14, satMul: 1.1, valueMul: 0.6 }
        let shadeH = shiftHue(h, toward: 255, step: 14)
        let shadeS = min(100, s * 1.1)
        let shadeV = v * 0.6

        // AR.light: { hueToward: 50, hueStep: 10, satMul: 0.6, valueLift: 0.6 }
        let lightH = shiftHue(h, toward: 50, step: 10)
        let lightS = s * 0.6
        let lightV = v + (100 - v) * 0.6

        var map = fixedPalette
        map["c"] = Color(hex: hex) ?? Color(rgbHex: 0x666666)
        map["d"] = hsvToColor(h: shadeH, s: shadeS, v: shadeV)
        map["l"] = hsvToColor(h: lightH, s: lightS, v: lightV)
        return map
    }

    private static func validSixHex(_ input: String?) -> String? {
        guard let raw = input?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let cleaned = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        guard cleaned.count == 6, UInt32(cleaned, radix: 16) != nil else { return nil }
        return "#\(cleaned.lowercased())"
    }

    /// Port of `OR(hex)` -> (h: 0...360, s: 0...100, v: 0...100).
    private static func hexToHSV(_ hex: String) -> (Double, Double, Double) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = UInt32(cleaned, radix: 16) ?? 0x666666
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0

        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC
        var h = 0.0
        if delta > 0 {
            if maxC == r {
                h = ((g - b) / delta + (g < b ? 6 : 0)) / 6.0
            } else if maxC == g {
                h = ((b - r) / delta + 2) / 6.0
            } else {
                h = ((r - g) / delta + 4) / 6.0
            }
        }
        let s = maxC > 0 ? (delta / maxC) * 100.0 : 0.0
        return (h * 360.0, s, maxC * 100.0)
    }

    /// Port of `Pf(hue, toward, step)`.
    private static func shiftHue(_ h: Double, toward: Double, step: Double) -> Double {
        let diff = (toward - h + 540).truncatingRemainder(dividingBy: 360) - 180
        let sign: Double = diff > 0 ? 1 : (diff < 0 ? -1 : 0)
        let shifted = h + sign * min(step, abs(diff)) + 360
        return shifted.truncatingRemainder(dividingBy: 360)
    }

    /// Port of `Mf(h, s, v)`.
    private static func hsvToColor(h: Double, s: Double, v: Double) -> Color {
        let sn = s / 100.0
        let vn = v / 100.0
        func channel(_ n: Double) -> Double {
            let k = (n + h / 60.0).truncatingRemainder(dividingBy: 6.0)
            let kPos = k < 0 ? k + 6.0 : k
            let f = vn - vn * sn * max(0.0, min(kPos, min(4.0 - kPos, 1.0)))
            return (f * 255.0).rounded() / 255.0
        }
        return Color(red: channel(5), green: channel(3), blue: channel(1))
    }
}

private extension Color {
    init(rgbHex: UInt32) {
        self.init(
            red: Double((rgbHex >> 16) & 0xFF) / 255.0,
            green: Double((rgbHex >> 8) & 0xFF) / 255.0,
            blue: Double(rgbHex & 0xFF) / 255.0
        )
    }
}
