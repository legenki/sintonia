import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Generates App Store marketing posters (EN/RU) plus the background layers used by the Figma layouts.
//
// Usage (from the repo root):
//   swiftc -O Tools/AppStoreArt/*.swift -o /tmp/sintonia-art && /tmp/sintonia-art <mac-captures-dir>
// Inputs:  docs/appstore/screenshots/{iphone-6.9,ipad-13}/*.png and <mac-captures-dir>/{player,library,studio}.jpg
// Outputs: docs/appstore/marketing/{en,ru}/*.jpg, plus backgrounds and manifest.json in docs/appstore/marketing/layers/

let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let macCaptures = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/appstore/screenshots/mac")
let shots = repo.appendingPathComponent("docs/appstore/screenshots")
let outRoot = repo.appendingPathComponent("docs/appstore/marketing")
let layersDir = outRoot.appendingPathComponent("layers")
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

// MARK: - Copy

struct Copy { let eyebrow: String; let title: String; let subtitle: String }

enum Device { case phone(String), tablet(String), macSingle(String), macPair(String, String) }

struct Poster {
    let id: String
    let size: CGSize
    let style: BackgroundStyle
    let seed: Int
    let accentA: RGB
    let accentB: RGB
    let device: Device
    let en: Copy
    let ru: Copy
}

let phone = CGSize(width: 1320, height: 2868)
let tablet = CGSize(width: 2064, height: 2752)
let mac = CGSize(width: 1440, height: 900)

let posters: [Poster] = [
    Poster(id: "iphone-1-player", size: phone, style: .ribbons, seed: 1, accentA: Palette.teal, accentB: Palette.amber,
           device: .phone("iphone-6.9/iphone-1-player.png"),
           en: Copy(eyebrow: "LISTEN", title: "Tune in to\nyour rhythm", subtitle: "Binaural, monaural and isochronic\ntones, generated live"),
           ru: Copy(eyebrow: "СЛУШАЙТЕ", title: "Настройтесь\nна свой ритм", subtitle: "Бинауральные, монауральные\nи изохронные тоны вживую")),
    Poster(id: "iphone-2-library", size: phone, style: .orbs, seed: 2, accentA: Palette.amber, accentB: Palette.teal,
           device: .phone("iphone-6.9/iphone-2-library.png"),
           en: Copy(eyebrow: "18 SESSIONS", title: "Ready when\nyou are", subtitle: "Focus, relax, sleep, meditate,\nstudy and create"),
           ru: Copy(eyebrow: "18 СЕССИЙ", title: "Всё готово\nк прослушиванию", subtitle: "Фокус, отдых, сон, медитация,\nучёба и творчество")),
    Poster(id: "iphone-3-studio", size: phone, style: .interference, seed: 3, accentA: Palette.teal, accentB: Palette.violet,
           device: .phone("iphone-6.9/iphone-3-studio.png"),
           en: Copy(eyebrow: "STUDIO", title: "Design your\nown sound", subtitle: "Up to 10 voices, five waveforms\nand colored noise"),
           ru: Copy(eyebrow: "СТУДИЯ", title: "Создайте\nсвой звук", subtitle: "До 10 голосов, пять форм волны\nи цветной шум")),
    Poster(id: "iphone-4-curves", size: phone, style: .contours, seed: 4, accentA: Palette.teal, accentB: Palette.amber,
           device: .phone("iphone-6.9/iphone-4-curves.png"),
           en: Copy(eyebrow: "AUTOMATION", title: "Shape every\nminute", subtitle: "Draw how beat, carrier and\nvolume evolve over time"),
           ru: Copy(eyebrow: "АВТОМАТИЗАЦИЯ", title: "Управляйте\nкаждой минутой", subtitle: "Задайте кривыми, как меняются\nбиения, несущая и громкость")),

    Poster(id: "ipad-1-player", size: tablet, style: .ribbons, seed: 5, accentA: Palette.teal, accentB: Palette.amber,
           device: .tablet("ipad-13/ipad-1-player.png"),
           en: Copy(eyebrow: "LISTEN", title: "See the sound you hear", subtitle: "A live stereo oscilloscope follows every beat"),
           ru: Copy(eyebrow: "СЛУШАЙТЕ", title: "Смотрите, что слышите", subtitle: "Живой стереоосциллограф следит за каждым биением")),
    Poster(id: "ipad-2-library", size: tablet, style: .orbs, seed: 6, accentA: Palette.amber, accentB: Palette.violet,
           device: .tablet("ipad-13/ipad-2-library.png"),
           en: Copy(eyebrow: "18 SESSIONS", title: "A session for every moment", subtitle: "30 to 45 minutes, from deep focus to deep sleep"),
           ru: Copy(eyebrow: "18 СЕССИЙ", title: "Сессия на любой случай", subtitle: "От 30 до 45 минут — от глубокого фокуса до сна")),
    Poster(id: "ipad-3-studio", size: tablet, style: .contours, seed: 7, accentA: Palette.teal, accentB: Palette.indigo,
           device: .tablet("ipad-13/ipad-3-studio.png"),
           en: Copy(eyebrow: "STUDIO", title: "Your studio, side by side", subtitle: "Mixer rack and curve editor on one screen"),
           ru: Copy(eyebrow: "СТУДИЯ", title: "Вся студия на одном экране", subtitle: "Микшерный рэк и редактор кривых рядом")),

    Poster(id: "mac-1-studio", size: mac, style: .interference, seed: 8, accentA: Palette.teal, accentB: Palette.amber,
           device: .macSingle("studio.jpg"),
           en: Copy(eyebrow: "SINTONIA FOR MAC", title: "A full studio on your desktop", subtitle: ""),
           ru: Copy(eyebrow: "SINTONIA ДЛЯ MAC", title: "Полноценная студия на рабочем столе", subtitle: "")),
    Poster(id: "mac-2-player", size: mac, style: .ribbons, seed: 9, accentA: Palette.amber, accentB: Palette.teal,
           device: .macPair("player.jpg", "library.jpg"),
           en: Copy(eyebrow: "PLAYER + LIBRARY", title: "Play, browse, focus", subtitle: ""),
           ru: Copy(eyebrow: "ПЛЕЕР И БИБЛИОТЕКА", title: "Слушайте, выбирайте, работайте", subtitle: "")),
]

// MARK: - Image helpers

func loadImage(_ url: URL) -> CGImage {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError("Cannot load \(url.path)") }
    return img
}

func makeContext(_ size: CGSize, opaque: Bool) -> CGContext {
    let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
    let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs, bitmapInfo: info)!
    // Top-left origin for layout math.
    ctx.translateBy(x: 0, y: size.height)
    ctx.scaleBy(x: 1, y: -1)
    ctx.interpolationQuality = .high
    return ctx
}

/// Draws `image` into `rect` in the flipped (top-left) context without mirroring it.
func drawImage(_ ctx: CGContext, _ image: CGImage, in rect: CGRect) {
    ctx.saveGState()
    ctx.translateBy(x: rect.minX, y: rect.maxY)
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
    ctx.restoreGState()
}

func write(_ image: CGImage, to url: URL, jpeg: Bool) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let type = (jpeg ? UTType.jpeg : UTType.png).identifier as CFString
    let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil)!
    let props: [CFString: Any] = jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.92] : [:]
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    CGImageDestinationFinalize(dest)
}

// MARK: - Device frames (rendered as standalone transparent layers)

/// A stylized phone/tablet body around `screen`, with a soft colored glow, as a transparent image.
func framedDevice(_ screen: CGImage, screenWidth: CGFloat, bodyRadiusRatio: CGFloat, bezelRatio: CGFloat, glow: RGB) -> CGImage {
    let aspect = CGFloat(screen.height) / CGFloat(screen.width)
    let bezel = screenWidth * bezelRatio
    let body = CGSize(width: screenWidth + bezel * 2, height: screenWidth * aspect + bezel * 2)
    let pad = body.width * 0.12
    let canvas = CGSize(width: body.width + pad * 2, height: body.height + pad * 2)
    let ctx = makeContext(canvas, opaque: false)
    let bodyRect = CGRect(x: pad, y: pad, width: body.width, height: body.height)
    let bodyRadius = body.width * bodyRadiusRatio
    let bodyPath = CGPath(roundedRect: bodyRect, cornerWidth: bodyRadius, cornerHeight: bodyRadius, transform: nil)

    // Colored ambient glow + drop shadow.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: pad * 0.9, color: glow.cg.copy(alpha: 0.55))
    ctx.addPath(bodyPath); ctx.setFillColor(RGB(0x050506).cg); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: pad * 0.18), blur: pad * 0.35, color: CGColor(gray: 0, alpha: 0.7))
    ctx.addPath(bodyPath); ctx.setFillColor(RGB(0x050506).cg); ctx.fillPath()
    ctx.restoreGState()

    // Titanium-like edge.
    ctx.addPath(bodyPath)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.16)); ctx.setLineWidth(max(2, bezel * 0.18)); ctx.strokePath()

    let screenRect = bodyRect.insetBy(dx: bezel, dy: bezel)
    let screenRadius = max(0, bodyRadius - bezel)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: screenRect, cornerWidth: screenRadius, cornerHeight: screenRadius, transform: nil))
    ctx.clip()
    drawImage(ctx, screen, in: screenRect)
    ctx.restoreGState()
    return ctx.makeImage()!
}

/// Rounds a captured macOS window, repaints active traffic lights, and adds a shadow, as a transparent image.
func framedMacWindow(_ window: CGImage, lights: CGPoint, glow: RGB) -> CGImage {
    let size = CGSize(width: window.width, height: window.height)
    let pad: CGFloat = 70
    let canvas = CGSize(width: size.width + pad * 2, height: size.height + pad * 2)
    let ctx = makeContext(canvas, opaque: false)
    let rect = CGRect(x: pad, y: pad, width: size.width, height: size.height)
    let radius: CGFloat = 14
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 60, color: glow.cg.copy(alpha: 0.35))
    ctx.addPath(path); ctx.setFillColor(RGB(0x111216).cg); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 40, color: CGColor(gray: 0, alpha: 0.6))
    ctx.addPath(path); ctx.setFillColor(RGB(0x111216).cg); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    drawImage(ctx, window, in: rect)
    // Captures were taken from inactive windows; show the familiar active traffic lights.
    let colors: [UInt32] = [0xFF5F57, 0xFEBC2E, 0x28C840]
    for (i, hex) in colors.enumerated() {
        let c = CGPoint(x: rect.minX + lights.x + CGFloat(i) * 22.5, y: rect.minY + lights.y)
        ctx.setFillColor(RGB(hex).cg)
        ctx.fillEllipse(in: CGRect(x: c.x - 6.5, y: c.y - 6.5, width: 13, height: 13))
    }
    ctx.restoreGState()
    ctx.addPath(path)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12)); ctx.setLineWidth(1); ctx.strokePath()
    return ctx.makeImage()!
}

// MARK: - Text

/// Draws centered (or left-aligned) multi-line text with its top at `y`; returns the height used.
@discardableResult
func drawText(_ ctx: CGContext, _ text: String, font: NSFont, color: CGColor, x: CGFloat, y: CGFloat, width: CGFloat,
              tracking: CGFloat = 0, lineHeight: CGFloat = 1.05, align: NSTextAlignment = .center) -> CGFloat {
    guard !text.isEmpty else { return 0 }
    let para = NSMutableParagraphStyle()
    para.alignment = align
    para.lineHeightMultiple = lineHeight
    let attr = NSAttributedString(string: text, attributes: [
        .font: font, .foregroundColor: NSColor(cgColor: color)!, .paragraphStyle: para, .kern: tracking,
    ])
    let setter = CTFramesetterCreateWithAttributedString(attr)
    let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil)
    let height = ceil(fit.height)
    ctx.saveGState()
    // CoreText draws in a bottom-left system: flip back locally.
    ctx.translateBy(x: 0, y: y + height)
    ctx.scaleBy(x: 1, y: -1)
    let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: CGRect(x: x, y: 0, width: width, height: height), transform: nil), nil)
    CTFrameDraw(frame, ctx)
    ctx.restoreGState()
    return height
}

/// Largest size ≤ `size` at which `text` keeps its explicit line breaks (no extra wrapping) within `width`.
func fittedTitleSize(_ text: String, size: CGFloat, width: CGFloat, tracking: CGFloat) -> CGFloat {
    let lines = CGFloat(text.split(separator: "\n", omittingEmptySubsequences: false).count)
    var s = size
    while s > 20 {
        let attr = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: s, weight: .bold), .kern: -s * tracking])
        let setter = CTFramesetterCreateWithAttributedString(attr)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        if fit.height <= lines * s * 1.3 { return s }
        s -= 2
    }
    return s
}

var fittedTitles: [String: CGFloat] = [:]

// MARK: - Compose

let langs = ["en", "ru"]
try? FileManager.default.createDirectory(at: layersDir, withIntermediateDirectories: true)
var manifest: [[String: Any]] = []

for poster in posters {
    let W = poster.size.width, H = poster.size.height
    let bg = renderBackground(poster.style, width: Int(W), height: Int(H), seed: poster.seed,
                              accentA: poster.accentA, accentB: poster.accentB)
    write(bg, to: layersDir.appendingPathComponent("\(poster.id)-background.jpg"), jpeg: true)

    // Device layer and its placement.
    let isMac: Bool
    var deviceLayers: [(image: CGImage, rect: CGRect)] = []
    switch poster.device {
    case .phone(let file):
        isMac = false
        let img = framedDevice(loadImage(shots.appendingPathComponent(file)), screenWidth: 1320, bodyRadiusRatio: 0.135, bezelRatio: 0.035, glow: poster.accentA)
        let scale = 0.76 * W * 1.24 / CGFloat(img.width) // device body ≈ 76% of the poster width (layer has 12% padding per side)
        let size = CGSize(width: CGFloat(img.width) * scale, height: CGFloat(img.height) * scale)
        deviceLayers = [(img, CGRect(x: (W - size.width) / 2, y: H * 0.262 - size.height * 0.1 / 1.24, width: size.width, height: size.height))]
    case .tablet(let file):
        isMac = false
        let img = framedDevice(loadImage(shots.appendingPathComponent(file)), screenWidth: 2064, bodyRadiusRatio: 0.045, bezelRatio: 0.028, glow: poster.accentA)
        let scale = 0.78 * W * 1.24 / CGFloat(img.width) // device body ≈ 78% of the poster width
        let size = CGSize(width: CGFloat(img.width) * scale, height: CGFloat(img.height) * scale)
        deviceLayers = [(img, CGRect(x: (W - size.width) / 2, y: H * 0.215 - size.height * 0.1 / 1.24, width: size.width, height: size.height))]
    case .macSingle(let file):
        isMac = true
        let img = framedMacWindow(loadImage(macCaptures.appendingPathComponent(file)), lights: CGPoint(x: 16, y: 16), glow: poster.accentA)
        // 1:1 pixels; the window bleeds off the bottom edge.
        deviceLayers = [(img, CGRect(x: (W - CGFloat(img.width)) / 2, y: 175, width: CGFloat(img.width), height: CGFloat(img.height)))]
    case .macPair(let left, let right):
        isMac = true
        let a = framedMacWindow(loadImage(macCaptures.appendingPathComponent(left)), lights: CGPoint(x: 16, y: 16), glow: poster.accentA)
        let b = framedMacWindow(loadImage(macCaptures.appendingPathComponent(right)), lights: CGPoint(x: 27, y: 26), glow: poster.accentB)
        let gap: CGFloat = 36 - 140 // shadows overlap (each layer has 70 px padding)
        let total = CGFloat(a.width + b.width) + gap
        let x0 = (W - total) / 2
        deviceLayers = [
            // The 700 pt player window ends 20 pt above the canvas bottom (each layer has 70 pt padding).
            (b, CGRect(x: x0 + CGFloat(a.width) + gap, y: 150, width: CGFloat(b.width), height: CGFloat(b.height))),
            (a, CGRect(x: x0, y: H - 20 - 70 - 700, width: CGFloat(a.width), height: CGFloat(a.height))),
        ]
    }

    for lang in langs {
        let copy = lang == "en" ? poster.en : poster.ru
        let ctx = makeContext(poster.size, opaque: true)
        drawImage(ctx, bg, in: CGRect(origin: .zero, size: poster.size))
        // Soft scrim behind the headline so busy backgrounds never fight the copy.
        let scrimHeight = isMac ? H * 0.26 : H * 0.30
        let scrim = CGGradient(colorsSpace: cs, colors: [Palette.graphite.cg.copy(alpha: 0.78)!, Palette.graphite.cg.copy(alpha: 0)!] as CFArray, locations: [0.35, 1])!
        ctx.drawLinearGradient(scrim, start: .zero, end: CGPoint(x: 0, y: scrimHeight), options: [])
        for layer in deviceLayers { drawImage(ctx, layer.image, in: layer.rect) }

        // Text block.
        let unit = isMac ? H / 900 : W / 1320 * (poster.size == tablet ? 0.82 : 1)
        let eyebrowSize = (isMac ? 18 : 40) * unit
        let textWidthForFit = W * 0.86
        let titleSize = fittedTitleSize(copy.title, size: (isMac ? 46 : 112) * unit, width: textWidthForFit, tracking: 0.015)
        fittedTitles["\(lang)/\(poster.id)"] = titleSize
        let subSize = (isMac ? 0 : 50) * unit
        let textWidth = W * 0.86
        var y = isMac ? 52 * unit : H * 0.052
        y += drawText(ctx, copy.eyebrow, font: .systemFont(ofSize: eyebrowSize, weight: .heavy), color: poster.accentA.cg,
                      x: (W - textWidth) / 2, y: y, width: textWidth, tracking: eyebrowSize * 0.22)
        y += eyebrowSize * 0.45
        y += drawText(ctx, copy.title, font: .systemFont(ofSize: titleSize, weight: .bold), color: CGColor(gray: 1, alpha: 1),
                      x: (W - textWidth) / 2, y: y, width: textWidth, tracking: -titleSize * 0.015, lineHeight: 0.98)
        if subSize > 0 {
            y += subSize * 0.5
            drawText(ctx, copy.subtitle, font: .systemFont(ofSize: subSize, weight: .medium), color: CGColor(gray: 1, alpha: 0.72),
                     x: (W - textWidth) / 2, y: y, width: textWidth, lineHeight: 1.12)
        }
        write(ctx.makeImage()!, to: outRoot.appendingPathComponent("\(lang)/\(poster.id).jpg"), jpeg: true)
    }

    manifest.append([
        "id": poster.id, "width": W, "height": H,
        "background": "\(poster.id)-background.jpg",
        // Device layer rects (each includes the shadow padding) so the Figma layouts can match the posters.
        "devices": deviceLayers.map { l in
            ["x": l.rect.minX, "y": l.rect.minY, "width": l.rect.width, "height": l.rect.height]
        },
        "accent": String(format: "#%02X%02X%02X", Int(poster.accentA.r * 255), Int(poster.accentA.g * 255), Int(poster.accentA.b * 255)),
        "en": ["eyebrow": poster.en.eyebrow, "title": poster.en.title, "subtitle": poster.en.subtitle],
        "ru": ["eyebrow": poster.ru.eyebrow, "title": poster.ru.title, "subtitle": poster.ru.subtitle],
    ])
    print("rendered \(poster.id)")
}

for key in fittedTitles.keys.sorted() { print("title size \(key): \(fittedTitles[key]!)") }
let json = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
try json.write(to: layersDir.appendingPathComponent("manifest.json"))
print("done")
