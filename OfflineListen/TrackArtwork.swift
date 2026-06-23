import UIKit
import MediaPlayer

/// Generates the placeholder artwork used wherever a track has no embedded
/// cover image: the small leading icon in CarPlay list rows, and the larger
/// Now Playing artwork that surfaces on the lock screen, Control Center and the
/// CarPlay Now Playing screen.
///
/// Downloaded tracks carry no artwork, so without this the CarPlay Now Playing
/// screen (which is dominated by the cover image) would be blank. The image is a
/// simple accent-coloured gradient with the track's category glyph centred on
/// it, matching the in-app player's artwork tile.
enum TrackArtwork {
    /// The SF Symbol that represents a track's category (song / podcast / video).
    static func symbolName(for track: Track) -> String {
        switch track.playbackCategory {
        case .video: return "film"
        case .podcast: return "mic"
        case .song: return "music.note"
        }
    }

    /// A template symbol image for a CarPlay list row's leading icon.
    static func listImage(for track: Track) -> UIImage? {
        UIImage(systemName: symbolName(for: track))
    }

    /// Now Playing artwork for the lock screen / Control Center / CarPlay. The
    /// pixels are rendered lazily by the system through the request handler, so
    /// constructing this is cheap; `PlaybackManager` still caches it per track to
    /// avoid re-creating it on every 2 Hz now-playing refresh.
    static func nowPlayingArtwork(for track: Track) -> MPMediaItemArtwork {
        let symbol = symbolName(for: track)
        let bounds = CGSize(width: 600, height: 600)
        return MPMediaItemArtwork(boundsSize: bounds) { size in
            render(symbol: symbol, size: size)
        }
    }

    private static func render(symbol: String, size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let accent = UIColor(named: "AccentColor") ?? .systemBlue
            let colors = [
                accent.withAlphaComponent(0.85).cgColor,
                accent.withAlphaComponent(0.45).cgColor
            ]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors as CFArray,
                                         locations: [0, 1]) {
                context.cgContext.drawLinearGradient(
                    gradient,
                    start: .zero,
                    end: CGPoint(x: size.width, y: size.height),
                    options: [])
            }
            let config = UIImage.SymbolConfiguration(pointSize: size.height * 0.35, weight: .medium)
            if let glyph = UIImage(systemName: symbol, withConfiguration: config)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) {
                let origin = CGPoint(x: (size.width - glyph.size.width) / 2,
                                     y: (size.height - glyph.size.height) / 2)
                glyph.draw(in: CGRect(origin: origin, size: glyph.size))
            }
        }
    }
}
