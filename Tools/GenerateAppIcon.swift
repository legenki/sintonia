// Regenerates the Sintonia app icon PNGs in App/Resources/Assets.xcassets/AppIcon.appiconset.
// Usage: swiftc -O Tools/GenerateAppIcon.swift -o /tmp/gen-icon && /tmp/gen-icon App/Resources/Assets.xcassets/AppIcon.appiconset

import AppKit
import CoreGraphics
import Foundation

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// Draws the Sintonia mark into a square `rect` of `ctx`.
func drawArtwork(_ ctx: CGContext, rect: CGRect) {
    let s = rect.width
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    // Background: deep graphite with a warm center glow.
    let bg = CGGradient(colorsSpace: cs, colors: [rgb(0x23262E), rgb(0x101216), rgb(0x08090C)] as CFArray, locations: [0, 0.6, 1])!
    ctx.drawRadialGradient(bg, startCenter: CGPoint(x: rect.midX, y: rect.midY + s * 0.08), startRadius: 0,
                           endCenter: CGPoint(x: rect.midX, y: rect.midY), endRadius: s * 0.75, options: [.drawsAfterEndLocation])
    let glow = CGGradient(colorsSpace: cs, colors: [rgb(0xF5A623, 0.20), rgb(0xF5A623, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: rect.midX, y: rect.midY), startRadius: 0,
                           endCenter: CGPoint(x: rect.midX, y: rect.midY), endRadius: s * 0.42, options: [])

    // Two slightly detuned sine waves (L teal, R amber) whose sum beats: the visual of entrainment.
    func wave(cycles: Double, phase: Double, amp: CGFloat, color: CGColor, width: CGFloat) {
        let path = CGMutablePath()
        let x0 = rect.minX + s * 0.12, x1 = rect.maxX - s * 0.12
        let steps = 600
        for i in 0...steps {
            let u = Double(i) / Double(steps)
            let x = x0 + (x1 - x0) * CGFloat(u)
            // Window so both waves taper to the center line at the edges.
            let window = CGFloat(sin(Double.pi * u))
            let y = rect.midY + amp * window * CGFloat(sin(2 * Double.pi * cycles * u + phase))
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        // Soft neon glow via blurred shadow, then the colored tube, then a hot white-ish core.
        ctx.setShadow(offset: .zero, blur: s * 0.06, color: color.copy(alpha: 0.95)!)
        ctx.addPath(path); ctx.setStrokeColor(color); ctx.setLineWidth(width); ctx.strokePath()
        ctx.setShadow(offset: .zero, blur: s * 0.02, color: color)
        ctx.addPath(path); ctx.setStrokeColor(color); ctx.setLineWidth(width); ctx.strokePath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        let core = NSColor(cgColor: color)!.blended(withFraction: 0.55, of: .white)!.cgColor
        ctx.addPath(path); ctx.setStrokeColor(core); ctx.setLineWidth(width * 0.38); ctx.strokePath()
        ctx.restoreGState()
    }
    ctx.setBlendMode(.screen)
    wave(cycles: 2.5, phase: 0, amp: s * 0.20, color: rgb(0x1AD9C5), width: s * 0.034)
    wave(cycles: 3.0, phase: .pi, amp: s * 0.16, color: rgb(0xF5A623), width: s * 0.034)
    ctx.setBlendMode(.normal)
}

func render(size: Int, mac: Bool, to url: URL) {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let info = mac ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: info)!
    let full = CGRect(x: 0, y: 0, width: size, height: size)
    if mac {
        // macOS: 824/1024 rounded-rect body with a soft drop shadow, transparent margin.
        let inset = CGFloat(size) * 100 / 1024
        let body = full.insetBy(dx: inset, dy: inset).offsetBy(dx: 0, dy: CGFloat(size) * 0.01)
        let radius = body.width * 0.225
        let shape = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -CGFloat(size) * 0.012), blur: CGFloat(size) * 0.03, color: rgb(0x000000, 0.45))
        ctx.addPath(shape); ctx.setFillColor(rgb(0x101216)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(shape); ctx.clip()
        drawArtwork(ctx, rect: body)
        ctx.restoreGState()
        ctx.addPath(shape)
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.08)); ctx.setLineWidth(CGFloat(size) * 0.004); ctx.strokePath()
    } else {
        drawArtwork(ctx, rect: full)
    }
    let image = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
render(size: 1024, mac: false, to: out.appendingPathComponent("AppIcon-iOS-1024.png"))
for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    render(size: pt * scale, mac: true, to: out.appendingPathComponent("AppIcon-mac-\(pt)@\(scale)x.png"))
}
print("ok")
