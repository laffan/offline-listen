import SwiftUI
import AVFoundation

/// The **video library** — the Library with its audio/video toggle on video.
/// Videos used to be one filter of the All tab, a row of text among a
/// library's worth of songs, which made something downloaded to *watch* hard
/// to find again. Here they're a grid of pictures, two across, each a frame
/// from **where you left off**, the most recently watched first; the ones
/// watched to the end gather in a **Watched** section beneath the rest.
///
/// A `ScrollView` rather than a `List`, for the reason the Folders tab's cover
/// view is one: each cell keeps its own tap and its own touch-and-hold menu.
struct VideoLibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackManager

    /// Switches to the Player once a video starts.
    let onPlay: () -> Void

    @State private var editingTrack: Track?

    private let columns = [
        GridItem(.flexible(), spacing: 12, alignment: .top),
        GridItem(.flexible(), spacing: 12, alignment: .top),
    ]

    /// Every active video, the most recently watched first. A video never
    /// played yet counts from its arrival, so a new download comes in at the
    /// top rather than sinking below everything you've ever seen.
    private var videos: [Track] {
        library.activeTracks
            .filter(\.isVideo)
            .map { (track: $0, at: library.lastPlayed($0.id) ?? $0.dateAdded) }
            .sorted { $0.at > $1.at }
            .map { $0.track }
    }

    var body: some View {
        // One pass, shared by both sections and the queue each cell plays in.
        let all = videos
        let watched = all.filter { library.isWatched($0.id) }
        let upNext = all.filter { !library.isWatched($0.id) }
        Group {
            if all.isEmpty {
                ContentUnavailableViewCompat(
                    title: "No videos yet",
                    systemImage: "film",
                    description: "Switch the Download section to Video and paste a link — the videos you download gather here."
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        if !upNext.isEmpty {
                            section(watched.isEmpty ? nil : "Up Next", videos: upNext)
                        }
                        if !watched.isEmpty {
                            section("Watched", videos: watched)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                    .padding(.bottom, 12)
                }
                .miniPlayerClearance()
            }
        }
        .editMetadataSheet(for: $editingTrack)
    }

    /// A titled grid. The first section goes untitled when it's the only one —
    /// a heading over everything says nothing.
    private func section(_ title: String?, videos: [Track]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(videos) { video in
                    cell(video, in: videos)
                }
            }
        }
    }

    private func cell(_ video: Track, in queue: [Track]) -> some View {
        Button {
            // A section plays on through itself: Up Next onward into what's
            // next to watch, Watched through what's been seen.
            playback.play(video, in: queue)
            onPlay()
        } label: {
            VideoCell(track: video,
                      isCurrent: playback.currentTrack?.id == video.id)
        }
        .buttonStyle(.plain)
        .contextMenu { menu(for: video) }
    }

    @ViewBuilder
    private func menu(for video: Track) -> some View {
        if library.isWatched(video.id) {
            Button {
                library.setWatched(video.id, false)
            } label: {
                Label("Mark as Unwatched", systemImage: "eye.slash")
            }
        } else {
            Button {
                library.setWatched(video.id, true)
                library.updatePosition(for: video.id, to: 0)
            } label: {
                Label("Mark as Watched", systemImage: "eye")
            }
        }
        if video.lastPosition > 1 {
            Button {
                library.updatePosition(for: video.id, to: 0)
            } label: {
                Label("Start Over", systemImage: "backward.end")
            }
        }
        Button {
            editingTrack = video
        } label: {
            Label("Edit Metadata", systemImage: "pencil")
        }
        CopyToFolderMenu(track: video)
        GetSubtitlesButton(track: video)
        ConvertFormatButton(track: video)
        TrackSourceButtons(track: video)
        Button {
            library.setArchived(video, true)
        } label: {
            Label("Archive", systemImage: "archivebox")
        }
        Button(role: .destructive) {
            library.delete(video)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

/// One video in the grid: the frame at its saved playhead, how far through it
/// is as a bar across the picture's foot, and its name beneath.
private struct VideoCell: View {
    let track: Track
    let isCurrent: Bool

    private var progress: Double {
        track.duration > 0 ? min(max(track.lastPosition / track.duration, 0), 1) : 0
    }

    /// What the corner says: the time left for one under way, the length for
    /// one not started (or finished, whose playhead has gone back to 0).
    private var timeLabel: String? {
        guard track.duration > 0 else { return nil }
        if track.lastPosition > 1 {
            return "\(max(0, track.duration - track.lastPosition).asPlaybackTime) left"
        }
        return track.duration.asPlaybackTime
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VideoThumbnail(track: track)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .bottom) {
                    if track.lastPosition > 1 {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(Color.white.opacity(0.35))
                                Rectangle().fill(Color.accentColor)
                                    .frame(width: geo.size.width * progress)
                            }
                        }
                        .frame(height: 3)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let timeLabel {
                        Text(timeLabel)
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                            .padding(.trailing, 5)
                            .padding(.bottom, track.lastPosition > 1 ? 8 : 5)
                    }
                }
                // After the bar, so the picture's rounded corners take it too.
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    // The one playing, outlined in the colour a playing row wears.
                    if isCurrent {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }

            Text(track.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if let artist = track.namedArtist {
                Text(artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The frame at a video's saved playhead — or, for one not started (or
/// finished, which puts the playhead back to 0), a few seconds in, past the
/// black a video usually opens on.
struct VideoThumbnail: View {
    let track: Track

    @State private var image: PlatformImage?

    private var time: Double { VideoFrames.time(for: track) }
    private var key: String { VideoFrames.key(for: track, at: time) }

    var body: some View {
        // The picture rides in an overlay so that filling the frame can't
        // also grow it: the cell's 16:9 is the backdrop's to decide.
        Color.black.opacity(0.85)
            .overlay {
                if let image {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "film")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .clipped()
        .task(id: key) {
            if let hit = VideoFrames.cached(key) {
                image = hit
                return
            }
            if let frame = await VideoFrames.frame(of: track, at: time) {
                image = frame
            }
        }
    }
}

/// Frames grabbed from video files for the grid, memoized under the track and
/// the playhead rounded to five seconds — so the picture follows where you
/// got to without a fresh grab for every second of a saved position.
enum VideoFrames {
    private static let cache = ImageCache(countLimit: 120, megabytes: 48)
    /// Two columns on a 3× phone: about 180 points, so ~540 pixels.
    private static let maxPixel: CGFloat = 540

    static func time(for track: Track) -> Double {
        if track.lastPosition > 1 { return track.lastPosition }
        return track.duration > 0 ? min(5, track.duration / 10) : 5
    }

    static func key(for track: Track, at time: Double) -> String {
        "\(track.id.uuidString)@\(Int(time / 5))|\(track.fileName)"
    }

    static func cached(_ key: String) -> PlatformImage? {
        cache.image(forKey: key) { nil }
    }

    static func frame(of track: Track, at time: Double) async -> PlatformImage? {
        let cacheKey = key(for: track, at: time)
        if let hit = cached(cacheKey) { return hit }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: track.fileURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        // Near enough is fine for a thumbnail, and a keyframe is far cheaper
        // to reach than the exact frame.
        let tolerance = CMTime(seconds: 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        guard let grabbed = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)) else {
            return nil
        }
        #if canImport(UIKit)
        let image = UIImage(cgImage: grabbed.image)
        #else
        let image = NSImage(cgImage: grabbed.image,
                            size: CGSize(width: grabbed.image.width, height: grabbed.image.height))
        #endif
        return cache.image(forKey: cacheKey) { image }
    }
}
