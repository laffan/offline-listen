import SwiftUI
import AVFoundation
import AVKit
import UIKit

/// Loads a track's saved album art off disk, memoized so the player and mini
/// player don't re-decode a JPEG on every render (NSCache is thread-safe and
/// sheds under memory pressure). Keyed by file name — one artwork file per
/// track id — so an entry only goes stale when that file is *re*-written
/// (Get Album Art over an existing cover), which is what `invalidate` is for.
enum TrackArtwork {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(for track: Track) -> UIImage? {
        track.artworkFileName.flatMap(image(named:))
    }

    static func image(named name: String) -> UIImage? {
        if let hit = cache.object(forKey: name as NSString) { return hit }
        guard let image = UIImage(contentsOfFile: AppPaths.artwork.appendingPathComponent(name).path) else {
            return nil
        }
        cache.setObject(image, forKey: name as NSString)
        return image
    }

    /// Drops the memoized image for `fileName` so the next read re-decodes
    /// the file — called when artwork is re-fetched over the same name.
    static func invalidate(fileName: String) {
        cache.removeObject(forKey: fileName as NSString)
    }
}

/// The same memoized loader for **folder** covers (`AppPaths.folderArtwork`) —
/// an album downloaded whole from a discography wears its release cover as the
/// thumbnail on its Library row, and the folder list redraws often enough that
/// re-reading the JPEG per row would show.
enum FolderArtwork {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(for folder: Folder) -> UIImage? {
        guard let name = folder.artworkFileName else { return nil }
        if let hit = cache.object(forKey: name as NSString) { return hit }
        guard let image = UIImage(contentsOfFile: AppPaths.folderArtwork.appendingPathComponent(name).path) else {
            return nil
        }
        cache.setObject(image, forKey: name as NSString)
        return image
    }

    static func invalidate(fileName: String) {
        cache.removeObject(forKey: fileName as NSString)
    }
}

/// The cover a folder can show above its tracks: its own downloaded art when
/// it has some (an album pulled down whole from a discography), or — for a
/// folder assembled any other way — the art its tracks *share*, when every one
/// of them carries the same image. A folder of unrelated songs has no cover
/// and shows none.
///
/// "The same image" has to be decided on content, not on file names: each
/// track's cover is saved under its own track id, so an album's twelve
/// identical covers are twelve identical *files*. Sizes are compared first
/// (two different covers essentially never match on the byte), and only then
/// the bytes, so a mixed folder is ruled out after one comparison. The answer
/// is memoized against the folder's exact set of artwork files, so opening a
/// folder costs the read once rather than once per redraw.
/// Main-actor because its memo is a plain dictionary — every caller is a
/// SwiftUI body or the artwork fetch's main-actor tail, so it never needs to
/// be more than that.
@MainActor
enum FolderCover {
    /// signature → the artwork file every track shares (nil = they don't).
    private static var cache: [String: String?] = [:]
    private static let cacheLimit = 64

    /// Forgets every decision. The memo is keyed by which artwork *files* a
    /// folder's tracks point at, so it can't notice one of those files being
    /// rewritten in place (Get Album Art over an existing cover) — that's
    /// what this is for.
    static func invalidate() {
        cache.removeAll()
    }

    static func image(for folder: Folder, tracks: [Track]) -> UIImage? {
        if let own = FolderArtwork.image(for: folder) { return own }
        guard let shared = sharedArtworkName(of: folder.id, tracks: tracks) else { return nil }
        return TrackArtwork.image(named: shared)
    }

    /// Nothing this big is an album, and reading every cover in a folder of
    /// hundreds to find that out would be a real cost for a cosmetic answer.
    private static let maxTracksToCompare = 100

    private static func sharedArtworkName(of folderID: UUID, tracks: [Track]) -> String? {
        let names = tracks.map { $0.artworkFileName ?? "" }
        // One cover missing is enough to say the folder doesn't have one.
        guard !names.isEmpty, names.count <= maxTracksToCompare, !names.contains("") else { return nil }
        let signature = "\(folderID.uuidString)|\(names.joined(separator: "|"))"
        if let cached = cache[signature] { return cached }
        let resolved = resolveShared(names)
        if cache.count >= cacheLimit { cache.removeAll() }
        cache[signature] = resolved
        return resolved
    }

    private static func resolveShared(_ names: [String]) -> String? {
        let urls = names.map(AppPaths.artwork.appendingPathComponent)
        guard let referenceURL = urls.first,
              let referenceSize = try? referenceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              referenceSize > 0 else { return nil }
        // Sizes first, from the directory entries alone: two different covers
        // essentially never weigh the same, so a mixed folder is ruled out
        // without opening a single file.
        for url in urls.dropFirst() {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size == referenceSize else { return nil }
        }
        guard let reference = try? Data(contentsOf: referenceURL) else { return nil }
        for url in urls.dropFirst() where url != referenceURL {
            guard let data = try? Data(contentsOf: url), data == reference else { return nil }
        }
        return names[0]
    }
}

struct PlayerView: View {
    @EnvironmentObject private var playback: PlaybackManager
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// Whether the control overlay is visible in fullscreen video.
    @State private var showVideoControls = true
    /// Set by tapping the picture in portrait: the video takes over the screen
    /// (title, transport, nav and tab bars all out of the way) until it's
    /// tapped back down. Landscape goes fullscreen on its own, by orientation.
    @State private var portraitFullscreen = false

    /// Whether the picture is currently filling the screen — landscape
    /// (compact height) with a video track, or portrait after a tap on it.
    private var isFullscreenVideo: Bool {
        guard playback.currentTrack?.isVideo == true else { return false }
        return verticalSizeClass == .compact || portraitFullscreen
    }

    var body: some View {
        NavigationStack {
            Group {
                if let track = playback.currentTrack {
                    if isFullscreenVideo {
                        fullscreenVideo
                    } else {
                        playerBody(track)
                    }
                } else {
                    ContentUnavailableViewCompat(
                        title: "Nothing playing",
                        systemImage: "play.circle",
                        description: "Pick a track from your library to start listening."
                    )
                }
            }
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
        }
        .statusBarHidden(isFullscreenVideo)
        // A fresh track starts framed normally — the old one's fullscreen
        // shouldn't swallow the next thing that plays (least of all an audio
        // track, which has no picture to fill it).
        .onChange(of: playback.currentTrack?.id) { _ in
            portraitFullscreen = false
        }
    }

    private func playerBody(_ track: Track) -> some View {
        VStack(spacing: 28) {
            Spacer()

            if track.isVideo {
                // Edge-to-edge video surface; transport is our own control suite
                // below, identical to audio's. Tapping the picture hands the
                // whole screen over to it.
                NativeVideoPlayer(player: playback.player)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(Color.black)
                    .overlay {
                        // The tap target sits above the player rather than on
                        // it: AVPlayerViewController swallows gestures of its own.
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation { portraitFullscreen = true }
                            }
                    }
            } else {
                artworkView(track)
            }

            VStack(spacing: 6) {
                Text(track.title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if hasArtist(track) {
                    Text(track.artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if track.hasChapters {
                    CurrentChapterLabel(progress: playback.progress, chapters: track.chapters)
                }
            }
            .padding(.horizontal)

            scrubber
            VStack(spacing: 14) {
                controls
                queueNeighbours
            }

            Spacer()
        }
        .padding(.vertical)
    }

    /// Fullscreen video: the picture fills the screen (nav/tab bars hidden) and
    /// a tap anywhere toggles the floating control suite. Reached by rotating to
    /// landscape, or by tapping the picture in portrait — where the controls
    /// also carry the way back out.
    private var fullscreenVideo: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            NativeVideoPlayer(player: playback.player)
                .ignoresSafeArea()

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation { showVideoControls.toggle() }
                }

            if showVideoControls {
                VStack {
                    if portraitFullscreen {
                        HStack {
                            Spacer()
                            Button {
                                withAnimation { portraitFullscreen = false }
                            } label: {
                                Image(systemName: "arrow.down.right.and.arrow.up.left")
                                    .font(.title3)
                                    .padding(10)
                                    .background(.ultraThinMaterial, in: Circle())
                            }
                            .accessibilityLabel("Exit fullscreen")
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)
                    }
                    Spacer()
                    VStack(spacing: 14) {
                        scrubber
                        controls
                    }
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        // Rotating into landscape surfaces the controls (there's no other cue
        // that they're there); a deliberate tap into portrait fullscreen asked
        // for a clean picture, so it starts with them out of the way.
        .onAppear { showVideoControls = !portraitFullscreen }
    }

    private func hasArtist(_ track: Track) -> Bool {
        !track.artist.isEmpty && track.artist.lowercased() != "unknown"
    }

    /// The saved album art, when the track has any — falling back to the
    /// gradient placeholder. Artwork lands moments *after* a download (it's
    /// fetched best-effort once the track exists), so the library's live copy
    /// is consulted rather than playback's snapshot.
    @ViewBuilder
    private func artworkView(_ track: Track) -> some View {
        let live = library.track(withID: track.id) ?? track
        if let image = TrackArtwork.image(for: live) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 260, height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .shadow(radius: 12, y: 6)
        } else {
            placeholderArtwork
        }
    }

    private var placeholderArtwork: some View {
        RoundedRectangle(cornerRadius: 20)
            .fill(LinearGradient(
                colors: [Color.accentColor.opacity(0.65), Color.accentColor.opacity(0.25)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .frame(width: 240, height: 240)
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: 80))
                    .foregroundStyle(.white.opacity(0.9))
            )
            .shadow(radius: 12, y: 6)
    }

    private var scrubber: some View {
        PlayerScrubber(progress: playback.progress,
                       chapters: playback.currentTrack?.chapters ?? []) { time in
            playback.seek(to: time)
        }
    }

    private var controls: some View {
        HStack(spacing: 24) {
            Button {
                playback.previous()
            } label: {
                Image(systemName: "backward.fill").font(.title2)
            }

            Button {
                playback.skipBackward()
            } label: {
                Image(systemName: "gobackward.15").font(.title)
            }

            Button {
                playback.togglePlayPause()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
            }

            Button {
                playback.skipForward()
            } label: {
                Image(systemName: "goforward.30").font(.title)
            }

            Button {
                playback.next()
            } label: {
                Image(systemName: "forward.fill").font(.title2)
            }
        }
        .foregroundStyle(Color.accentColor)
    }

    /// What's on either side of the current track in the queue, under the
    /// transport: the previous track on the left, the next on the right. Each
    /// is tappable and jumps straight to that track. A side with nothing there
    /// (the start or end of the list) simply leaves its half empty.
    @ViewBuilder
    private var queueNeighbours: some View {
        let previous = playback.previousTrack
        let next = playback.nextTrack
        if previous != nil || next != nil {
            HStack(alignment: .top, spacing: 16) {
                if let previous {
                    QueueNeighbourLabel(label: "Previous Track",
                                        track: previous,
                                        alignment: .leading) {
                        playback.playPreviousTrack()
                    }
                }
                Spacer(minLength: 0)
                if let next {
                    QueueNeighbourLabel(label: "Next Track",
                                        track: next,
                                        alignment: .trailing) {
                        playback.next()
                    }
                }
            }
            .padding(.horizontal)
        }
    }
}

/// One side of the next/previous pair under the transport: a small caption
/// label over the track's title and artist. Deliberately quiet — it's context,
/// not a second set of controls — but tappable, since a row naming a track
/// invites a tap.
private struct QueueNeighbourLabel: View {
    let label: String
    let track: Track
    let alignment: HorizontalAlignment
    let action: () -> Void

    private var hasArtist: Bool {
        !track.artist.isEmpty && track.artist.lowercased() != "unknown"
    }

    private var textAlignment: TextAlignment {
        alignment == .trailing ? .trailing : .leading
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: alignment, spacing: 2) {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.tertiary)
                Text(track.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if hasArtist {
                    Text(track.artist)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .multilineTextAlignment(textAlignment)
            .frame(maxWidth: 170, alignment: alignment == .trailing ? .trailing : .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The scrub bar + time labels. The only view observing `PlaybackProgress`, so
/// the 2 Hz playhead ticker re-renders just this and not whole screens.
///
/// Hand-built rather than a `Slider` because a slider only responds to a drag
/// *from the thumb*: tapping the bar somewhere ahead does nothing, so jumping
/// around a track meant dragging the playhead all the way there. Here a tap and
/// a drag are the same gesture — press anywhere and playback goes to that point.
private struct PlayerScrubber: View {
    @ObservedObject var progress: PlaybackProgress
    var chapters: [Chapter] = []
    let onSeek: (Double) -> Void

    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0

    /// The bar's own metrics. `hitHeight` is what the finger gets — much taller
    /// than the drawn bar, so a tap near it still counts.
    private let barHeight: CGFloat = 4
    private let thumbSize: CGFloat = 14
    private let hitHeight: CGFloat = 28

    private var displayedTime: Double {
        isScrubbing ? scrubTime : progress.currentTime
    }

    private var fraction: CGFloat {
        guard progress.duration > 0 else { return 0 }
        return CGFloat(min(max(displayedTime / progress.duration, 0), 1))
    }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                // The thumb's radius is reserved at both ends so it can't be
                // drawn half off the edge at 0% or 100%.
                let usable = max(geo.size.width - thumbSize, 1)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(width: usable, height: barHeight)
                        .offset(x: thumbSize / 2)

                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: usable * fraction, height: barHeight)
                        .offset(x: thumbSize / 2)

                    chapterDots(usable: usable)

                    Circle()
                        .fill(Color.white)
                        .frame(width: thumbSize, height: thumbSize)
                        .shadow(radius: isScrubbing ? 4 : 2, y: 1)
                        .offset(x: usable * fraction)
                        .scaleEffect(isScrubbing ? 1.15 : 1)
                        .animation(.easeOut(duration: 0.12), value: isScrubbing)
                }
                // Full width so the whole bar takes touches, not just as far as
                // the widest child reaches.
                .frame(width: geo.size.width, height: hitHeight, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(
                    // `minimumDistance: 0` is what makes a plain tap work: the
                    // gesture fires on touch-down and ends without any movement.
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isScrubbing = true
                            scrubTime = time(atX: value.location.x, usable: usable)
                        }
                        .onEnded { value in
                            let target = time(atX: value.location.x, usable: usable)
                            scrubTime = target
                            isScrubbing = false
                            onSeek(target)
                        }
                )
            }
            .frame(height: hitHeight)

            HStack {
                Text(displayedTime.asPlaybackTime)
                Spacer()
                Text(progress.duration.asPlaybackTime)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .padding(.horizontal)
    }

    /// Where in the track a touch at `x` lands, clamped to the bar's ends.
    private func time(atX x: CGFloat, usable: CGFloat) -> Double {
        guard progress.duration > 0 else { return 0 }
        let position = (x - thumbSize / 2) / usable
        return Double(min(max(position, 0), 1)) * progress.duration
    }

    /// Small dots along the bar at each chapter's start. Hidden until we know
    /// the duration. They carry no gesture of their own, so a tap that lands on
    /// one still falls through to the bar and seeks.
    @ViewBuilder
    private func chapterDots(usable: CGFloat) -> some View {
        if progress.duration > 0, chapters.count > 1 {
            ForEach(chapters) { chapter in
                let at = CGFloat(min(max(chapter.start / progress.duration, 0), 1))
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: 1))
                    .frame(width: 5, height: 5)
                    .offset(x: thumbSize / 2 + usable * at - 2.5)
            }
        }
    }
}

/// One-line label showing the chapter the playhead is currently in. Observes the
/// 2 Hz progress ticker (only this view re-renders) so it updates as playback
/// crosses a chapter boundary.
private struct CurrentChapterLabel: View {
    @ObservedObject var progress: PlaybackProgress
    let chapters: [Chapter]

    var body: some View {
        if let chapter = chapters.chapter(at: progress.currentTime) {
            Text(chapter.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .multilineTextAlignment(.center)
                .lineLimit(1)
        }
    }
}

/// The low-profile transport that rides above the tab bar on every screen but
/// the Player itself, so what's playing stays reachable without navigating back
/// to it: a thin progress line, what's playing, play/pause and next. Tapping
/// the title opens the Player.
///
/// Renders nothing at all when nothing is playing — as a `safeAreaInset` that
/// means it also takes up no room, which is what keeps anything else anchored
/// to the bottom (the Every Noise scan/artist bars) sitting flush with the tab
/// bar until there's a track.
struct MiniPlayerBar: View {
    @EnvironmentObject private var playback: PlaybackManager
    @EnvironmentObject private var library: LibraryStore

    /// Switches to the Player tab — the mini player is a shortcut to it, not a
    /// replacement.
    let onOpen: () -> Void

    var body: some View {
        if let track = playback.currentTrack {
            VStack(spacing: 0) {
                MiniPlayerProgressLine(progress: playback.progress)

                HStack(spacing: 10) {
                    Button(action: onOpen) {
                        HStack(spacing: 10) {
                            // A tiny cover when the track has art (checked
                            // against the library's live copy — art can land
                            // after playback started); the kind icon otherwise.
                            if let image = TrackArtwork.image(for: library.track(withID: track.id) ?? track) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 28, height: 28)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                            } else {
                                Image(systemName: icon(for: track))
                                    .font(.footnote)
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 16)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(track.title)
                                    .font(.footnote.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                if hasArtist(track) {
                                    Text(track.artist)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open the player — \(track.title)")

                    Button {
                        playback.togglePlayPause()
                    } label: {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

                    Button {
                        playback.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .disabled(playback.nextTrack == nil)
                    .accessibilityLabel("Next track")
                }
                .font(.subheadline)
                .buttonStyle(.borderless)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
            .background(.bar)
            .overlay(alignment: .top) {
                Color(.separator).frame(height: 0.5)
            }
        }
    }

    private func hasArtist(_ track: Track) -> Bool {
        !track.artist.isEmpty && track.artist.lowercased() != "unknown"
    }

    private func icon(for track: Track) -> String {
        if track.isVideo { return "film" }
        return track.kind == .podcast ? "mic.fill" : "music.note"
    }
}

/// The hairline playhead across the top of the mini player. Split out so the
/// 2 Hz ticker redraws two points of height and nothing else — the bar's labels
/// and buttons don't observe it.
private struct MiniPlayerProgressLine: View {
    @ObservedObject var progress: PlaybackProgress

    var body: some View {
        GeometryReader { geo in
            let fraction = progress.duration > 0
                ? CGFloat(min(max(progress.currentTime / progress.duration, 0), 1))
                : 0
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: geo.size.width * fraction)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 2)
        .background(Color.secondary.opacity(0.2))
    }
}

/// How tall the mini player currently is, published down the tab's view tree
/// (0 with nothing loaded).
///
/// A safe-area inset is enough for ordinary content — lists scroll clear of the
/// bar on their own. It is *not* enough for a screen that opts out of the
/// bottom safe area and then pins its own bar there: the Every Noise maps run
/// edge to edge under the tab bar (`ignoresSafeArea(edges: .bottom)`), so their
/// scan and artist bars are positioned against the screen's bottom rather than
/// the inset one, and would sit behind the mini player. Those bars read this
/// and lift themselves by it.
private struct MiniPlayerHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var miniPlayerHeight: CGFloat {
        get { self[MiniPlayerHeightKey.self] }
        set { self[MiniPlayerHeightKey.self] = newValue }
    }
}

/// Carries the measured height back up out of the inset.
private struct MiniPlayerHeightPreference: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Attaches the mini player beneath a tab's content and publishes its height.
private struct MiniPlayerBarModifier: ViewModifier {
    let onOpen: () -> Void

    /// Measured rather than assumed — the bar grows with the user's type size.
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .environment(\.miniPlayerHeight, height)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                MiniPlayerBar(onOpen: onOpen)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: MiniPlayerHeightPreference.self,
                                                   value: geo.size.height)
                        }
                    )
            }
            .onPreferenceChange(MiniPlayerHeightPreference.self) { height = $0 }
    }
}

extension View {
    /// Attaches the mini player beneath a tab's content. A safe-area inset
    /// rather than an overlay, so lists scroll clear of it; screens that ignore
    /// the bottom safe area read `\.miniPlayerHeight` to clear it themselves.
    func miniPlayerBar(onOpen: @escaping () -> Void) -> some View {
        modifier(MiniPlayerBarModifier(onOpen: onOpen))
    }

    /// Bottom clearance equal to the mini player's current height, applied
    /// **directly to a scrollable container** (List, Form, ScrollView).
    ///
    /// The bar itself rides as a safe-area inset *outside* each tab's
    /// `NavigationStack`, and the UIKit-backed containers inside the stack
    /// never pick that extra inset up (the navigation controller hosts its
    /// screens in child hosting controllers that only see UIKit's own safe
    /// area) — so their last rows hid behind the bar. Re-declaring the
    /// published height as a local inset on the container is what actually
    /// makes its content scroll clear; with nothing playing the height is 0
    /// and this is a no-op.
    func miniPlayerClearance() -> some View {
        modifier(MiniPlayerClearanceModifier())
    }
}

/// See `View.miniPlayerClearance()`.
private struct MiniPlayerClearanceModifier: ViewModifier {
    @Environment(\.miniPlayerHeight) private var miniPlayerHeight

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: miniPlayerHeight)
        }
    }
}

/// Native video surface backed by `AVPlayerViewController`, used purely for the
/// picture and PiP — its system controls are disabled so the app's own control
/// suite (the same one audio gets) drives playback. Shared with the Browse
/// preview modal, which turns PiP off (a transient temp-file preview shouldn't
/// detach into a floating window).
struct NativeVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    var allowsPiP = true

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false
        controller.allowsPictureInPicturePlayback = allowsPiP
        controller.canStartPictureInPictureAutomaticallyFromInline = allowsPiP
        controller.videoGravity = .resizeAspect
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
    }
}
