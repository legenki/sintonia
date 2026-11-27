import MediaPlayer
import SwiftUI
import SynthCore
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Generative Lock Screen / Control Center artwork that reflects the current brainwave band.
@MainActor
enum NowPlayingArtwork {
    private static let pointSize: CGFloat = 512
    private static var cache: [BrainwaveBand: MPMediaItemArtwork] = [:]

    /// Returns cached artwork for `band`, rendering it on first use.
    static func artwork(for band: BrainwaveBand) -> MPMediaItemArtwork? {
        if let cached = cache[band] {
            return cached
        }
        let renderer = ImageRenderer(content: NowPlayingArtworkView(band: band))
        renderer.proposedSize = ProposedViewSize(width: pointSize, height: pointSize)
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else {
            return nil
        }
        let artwork = makeArtwork(ArtworkImageBox(cgImage: cgImage))
        cache[band] = artwork
        return artwork
    }

    /// MediaPlayer calls the image handler on its own queue, so it must not inherit main-actor isolation.
    nonisolated private static func makeArtwork(_ box: ArtworkImageBox) -> MPMediaItemArtwork {
        let size = CGSize(width: box.pixelWidth, height: box.pixelWidth)
        return MPMediaItemArtwork(boundsSize: size) { @Sendable _ in box.image }
    }

    /// Greek letter used for each band on the artwork and in the subtitle line.
    static func glyph(for band: BrainwaveBand) -> String {
        switch band {
        case .delta: return "δ"
        case .theta: return "θ"
        case .alpha: return "α"
        case .beta: return "β"
        case .gamma: return "γ"
        }
    }
}

/// Holds a platform image so the `@Sendable` artwork handler can return it.
private final class ArtworkImageBox: @unchecked Sendable {
    let pixelWidth: CGFloat
    #if os(iOS)
    let image: UIImage
    init(cgImage: CGImage) {
        pixelWidth = CGFloat(cgImage.width)
        image = UIImage(cgImage: cgImage)
    }
    #elseif os(macOS)
    let image: NSImage
    init(cgImage: CGImage) {
        pixelWidth = CGFloat(cgImage.width)
        image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
    #endif
}

/// Square artwork: band-tinted glow, a brainwave trace whose density follows the band, and the band letter.
struct NowPlayingArtworkView: View {
    let band: BrainwaveBand

    private var accent: Color { band.accentColor }

    /// Visible cycles of the trace: slow delta waves look long and calm, gamma looks dense.
    private var cycles: Double {
        switch band {
        case .delta: return 1.5
        case .theta: return 2.5
        case .alpha: return 4
        case .beta: return 6.5
        case .gamma: return 10
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                Color(studioHex: 0x07080B)

                RadialGradient(
                    colors: [accent.opacity(0.55), accent.opacity(0.12), .clear],
                    center: UnitPoint(x: 0.5, y: 0.42),
                    startRadius: 0,
                    endRadius: side * 0.62
                )

                ForEach(0..<3) { ring in
                    Circle()
                        .stroke(accent.opacity(0.16 - Double(ring) * 0.04), lineWidth: side * 0.004)
                        .frame(width: side * (0.5 + CGFloat(ring) * 0.22))
                        .offset(y: -side * 0.08)
                }

                Text(verbatim: NowPlayingArtwork.glyph(for: band))
                    .font(.system(size: side * 0.36, weight: .light, design: .serif))
                    .foregroundStyle(.white.opacity(0.94))
                    .shadow(color: accent.opacity(0.9), radius: side * 0.05)
                    .offset(y: -side * 0.14)

                trace(side: side)
                    .stroke(accent.opacity(0.35), style: StrokeStyle(lineWidth: side * 0.03, lineCap: .round))
                    .blur(radius: side * 0.02)
                trace(side: side)
                    .stroke(accent, style: StrokeStyle(lineWidth: side * 0.008, lineCap: .round))

                VStack(spacing: side * 0.012) {
                    Spacer()
                    Text(verbatim: band.localizedTitle.uppercased())
                        .font(.system(size: side * 0.06, weight: .semibold))
                        .tracking(side * 0.012)
                        .foregroundStyle(accent)
                    Text(verbatim: band.frequencyRangeLabel)
                        .font(.system(size: side * 0.038, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.55))
                }
                .padding(.bottom, side * 0.07)
            }
            .frame(width: side, height: side)
        }
    }

    /// One sine trace across the lower third, faded at both ends by its amplitude envelope.
    private func trace(side: CGFloat) -> Path {
        Path { path in
            let steps = 240
            let baseline = side * 0.68
            let amplitude = side * 0.055
            let inset = side * 0.08
            let width = side - inset * 2
            for step in 0...steps {
                let t = Double(step) / Double(steps)
                let envelope = sin(t * .pi)
                let y = baseline - amplitude * envelope * sin(t * cycles * 2 * .pi)
                let point = CGPoint(x: inset + width * t, y: y)
                if step == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
        }
    }
}

#Preview {
    HStack {
        ForEach(BrainwaveBand.allCases, id: \.self) { band in
            NowPlayingArtworkView(band: band).frame(width: 160, height: 160)
        }
    }
}
