import CoreGraphics
import Foundation

// Procedural abstract backgrounds in the Sintonia palette (graphite + band colors).

struct RGB {
    var r: Double, g: Double, b: Double
    init(_ hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }
    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
    static func + (a: RGB, b: RGB) -> RGB { RGB(r: a.r + b.r, g: a.g + b.g, b: a.b + b.b) }
    static func * (a: RGB, k: Double) -> RGB { RGB(r: a.r * k, g: a.g * k, b: a.b * k) }
    func mix(_ o: RGB, _ t: Double) -> RGB { self * (1 - t) + o * t }
    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
}

enum Palette {
    static let graphite = RGB(0x0B0C10)
    static let ink = RGB(0x14161C)
    static let teal = RGB(0x1AD9C5)
    static let amber = RGB(0xF5A623)
    static let violet = RGB(0xA855F7)
    static let coral = RGB(0xF2545B)
    static let indigo = RGB(0x5B6CF9)
}

enum BackgroundStyle: String, CaseIterable {
    case ribbons, interference, orbs, contours
}

/// Deterministic hash noise in [0, 1).
@inline(__always) func hash(_ x: Int, _ y: Int, _ seed: Int) -> Double {
    var h = UInt64(bitPattern: Int64(x &* 374_761_393 &+ y &* 668_265_263 &+ seed &* 2_147_483_647))
    h = (h ^ (h >> 13)) &* 1_274_126_177
    h ^= h >> 16
    return Double(h & 0xFFFF) / 65_536
}

/// Renders `style` into a width×height sRGB bitmap and returns it as a CGImage.
func renderBackground(_ style: BackgroundStyle, width: Int, height: Int, seed: Int, accentA: RGB, accentB: RGB) -> CGImage {
    var px = [UInt8](repeating: 0, count: width * height * 4)
    let w = Double(width), h = Double(height)
    let minDim = min(w, h)

    func put(_ x: Int, _ y: Int, _ c: RGB) {
        // Film grain keeps large gradients from banding and adds texture.
        let grain = (hash(x, y, seed) - 0.5) * 0.035
        let i = (y * width + x) * 4
        px[i] = UInt8(max(0, min(255, (c.r + grain) * 255)))
        px[i + 1] = UInt8(max(0, min(255, (c.g + grain) * 255)))
        px[i + 2] = UInt8(max(0, min(255, (c.b + grain) * 255)))
        px[i + 3] = 255
    }

    // Shared vignette base: graphite with a lifted center.
    func base(_ u: Double, _ v: Double) -> RGB {
        let dx = u - 0.5, dy = (v - 0.42) * (h / w)
        let d = (dx * dx + dy * dy).squareRoot()
        return Palette.ink.mix(Palette.graphite, min(1, d * 1.6))
    }

    switch style {
    case .ribbons:
        // Stacked glowing sine ribbons: sum of Gaussians around each ribbon's curve.
        let ribbons = 9
        for y in 0..<height {
            let v = Double(y) / h
            for x in 0..<width {
                let u = Double(x) / w
                var c = base(u, v)
                for k in 0..<ribbons {
                    let t = Double(k) / Double(ribbons - 1)
                    let center = 0.18 + 0.64 * t + 0.07 * sin(u * 5.2 + Double(k) * 0.9 + Double(seed))
                    let wave = center + 0.035 * sin(u * 17 + Double(k) * 1.7) * sin(u * 2.3 + Double(seed) * 0.5)
                    let dist = abs(v - wave) * h / minDim
                    let core = exp(-pow(dist / 0.0028, 2))
                    let glow = exp(-pow(dist / 0.03, 2)) * 0.22
                    let color = accentA.mix(accentB, t)
                    c = c + color * ((core * 0.9 + glow) * (0.35 + 0.65 * sin(Double.pi * u)))
                }
                put(x, y, c)
            }
        }

    case .interference:
        // Two point sources with slightly different wavelengths: the visual of a beat.
        let s1 = (x: 0.22 * w, y: 0.30 * h), s2 = (x: 0.82 * w, y: 0.74 * h)
        let k1 = 2 * Double.pi / (minDim * 0.055), k2 = 2 * Double.pi / (minDim * 0.050)
        for y in 0..<height {
            let fy = Double(y)
            for x in 0..<width {
                let fx = Double(x)
                let r1 = ((fx - s1.x) * (fx - s1.x) + (fy - s1.y) * (fy - s1.y)).squareRoot()
                let r2 = ((fx - s2.x) * (fx - s2.x) + (fy - s2.y) * (fy - s2.y)).squareRoot()
                let a1 = cos(k1 * r1) * exp(-r1 / (minDim * 1.4))
                let a2 = cos(k2 * r2) * exp(-r2 / (minDim * 1.4))
                let sum = (a1 + a2) * 0.5
                let ridge = pow(max(0, sum), 3.0)
                let t = r1 / (r1 + r2 + 1)
                var c = base(fx / w, fy / h)
                c = c + accentA.mix(accentB, t) * (ridge * 0.75)
                put(x, y, c)
            }
        }

    case .orbs:
        // Soft light orbs (mesh-gradient feel).
        let orbs: [(x: Double, y: Double, r: Double, c: RGB, a: Double)] = [
            (0.15, 0.18, 0.55, accentA, 0.55),
            (0.92, 0.38, 0.50, accentB, 0.45),
            (0.30, 0.88, 0.60, Palette.violet, 0.40),
            (0.75, 0.95, 0.35, accentA, 0.30),
        ]
        for y in 0..<height {
            let v = Double(y) / h
            for x in 0..<width {
                let u = Double(x) / w
                var c = base(u, v)
                for o in orbs {
                    let dx = (u - o.x) * w / minDim, dy = (v - o.y) * h / minDim
                    let d2 = (dx * dx + dy * dy) / (o.r * o.r)
                    c = c + o.c * (exp(-d2 * 2.2) * o.a)
                }
                // Fine concentric rings as a nod to sound.
                let rr = (((u - 0.5) * w) * ((u - 0.5) * w) + ((v - 0.45) * h) * ((v - 0.45) * h)).squareRoot() / minDim
                let ring = pow(max(0, cos(rr * 90)), 40) * 0.05 * exp(-rr * 1.5)
                c = c + RGB(r: 1, g: 1, b: 1) * ring
                put(x, y, c)
            }
        }

    case .contours:
        // Topographic iso-lines of a smooth interference field.
        for y in 0..<height {
            let v = Double(y) / h
            for x in 0..<width {
                let u = Double(x) / w
                let px2 = u * w / minDim, py2 = v * h / minDim
                let f = sin(px2 * 3.1 + Double(seed)) * cos(py2 * 2.3)
                    + 0.6 * sin((px2 + py2) * 4.7 + 1.3)
                    + 0.35 * cos(px2 * 7.9 - py2 * 5.1)
                let bands = 14.0
                let frac = (f * bands).truncatingRemainder(dividingBy: 1)
                let line = exp(-pow(min(abs(frac), 1 - abs(frac)) / 0.06, 2))
                let t = (f + 2) / 4
                var c = base(u, v)
                c = c + accentA.mix(accentB, max(0, min(1, t))) * (line * 0.55 * (0.4 + 0.6 * sin(Double.pi * v)))
                put(x, y, c)
            }
        }
    }

    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let provider = CGDataProvider(data: Data(px) as CFData)!
    return CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: cs, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
    )!
}
