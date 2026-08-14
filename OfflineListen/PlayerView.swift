import SwiftUI
import AVFoundation
import AVKit

/// Loads a track's saved album art off disk, memoized so the player and mini
/// player don't re-decode a JPEG on every render (NSCache is thread-safe and
/// sheds under memory pressure). Keyed by file name — one artwork file per
/// track id — so an entry only goes stale when that file is *re*-written
/// (Get Album Art over an existing cover), which is what `invalidate` is for.
enum TrackArtwork {
    private static let cache = NSCache<NSString, PlatformImage>()

    static func image(for track: Track) -> PlatformImage? {
        track.artworkFileName.flatMap(image(named:))
    }

    static func image(named name: String) -> PlatformImage? {
        if let hit = cache.object(forKey: name as NSString) { return hit }
        guard let image = PlatformImage(contentsOfFile: AppPaths.artwork.appendingPathComponent(name).path) else {
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
/// re-reading the JPEG per row would show. A cover the *user* assigned wins
/// over the downloaded one (see `Folder.coverArtworkFileName`), which is what
/// leaves the downloaded file intact for **Reset Album Art** to return to.
enum FolderArtwork {
    private static let cache = NSCache<NSString, PlatformImage>()

    static func image(for folder: Folder) -> PlatformImage? {
        guard let name = folder.coverArtworkFileName else { return nil }
        if let hit = cache.object(forKey: name as NSString) { return hit }
        guard let image = PlatformImage(contentsOfFile: AppPaths.folderArtwork.appendingPathComponent(name).path) else {
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

    static func image(for folder: Folder, tracks: [Track]) -> PlatformImage? {
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

    /// Called when the player is swiped down — the root takes it back to the
    /// Library, which is where it was almost certainly opened from. Defaulted,
    /// so the screen still stands alone in a preview.
    var onSwipeDown: () -> Void = {}

    /// Whether captions are drawn over a video that has them. Shared with
    /// Settings (which styles them) through `UserDefaults`, so the CC button
    /// here and the toggle there are the same switch.
    @AppStorage(SubtitleSettings.enabledKey) private var subtitlesEnabled = true

    /// Whether the control overlay is visible in fullscreen video.
    @State private var showVideoControls = true
    /// The brief "Subtitles on/off" flash after the CC button is tapped.
    @State private var captionsNotice: String?
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
            // No title, and nothing else needs the bar here — so it goes, and
            // the artwork gets the height. (Fullscreen video hides it too;
            // hiding it twice is harmless.)
            .navigationBarTitleDisplayMode(.inline)
            #if !os(macOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            // Swipe the player down to put it away, the way a now-playing card
            // behaves everywhere else. `.gesture` rather than
            // `.simultaneousGesture` so anything inside that wants a drag —
            // the scrubber, most of all — keeps it; this only picks up drags
            // nothing else claimed. Fullscreen video opts out (`.subviews`
            // leaves the children's own gestures alone): there the picture
            // owns the screen, and a stray downward drag shouldn't dump you
            // out of the film.
            .gesture(swipeDown, including: isFullscreenVideo ? .subviews : .all)
        }
        .statusBarHidden(isFullscreenVideo)
        // A fresh track starts framed normally — the old one's fullscreen
        // shouldn't swallow the next thing that plays (least of all an audio
        // track, which has no picture to fill it).
        .onChange(of: playback.currentTrack?.id) { _ in
            portraitFullscreen = false
        }
    }

    /// The swipe that puts the player away: **down**, and decisively so.
    /// The distance floor keeps a lazy thumb-drag from closing the screen, and
    /// the width test keeps a sideways drag — the one that moves between tabs
    /// — from reading as one.
    private var swipeDown: some Gesture {
        DragGesture(minimumDistance: 30, coordinateSpace: .local)
            .onEnded { value in
                guard value.translation.height > 90,
                      abs(value.translation.width) < value.translation.height else { return }
                onSwipeDown()
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
                    // Both of these go *after* the tap target so they sit on
                    // top of it: captions must not swallow the tap, and the CC
                    // button must get its own.
                    .overlay(alignment: .bottom) { subtitleLayer(for: track) }
                    .overlay(alignment: .topTrailing) {
                        captionsButton(for: track).padding(8)
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

            // Captions ride above the picture whether the controls are up or
            // not — they're part of the film, not part of the transport — and
            // lift clear of the control panel while it's showing.
            if let track = playback.currentTrack {
                VStack {
                    Spacer()
                    subtitleLayer(for: track)
                        .padding(.bottom, showVideoControls ? 150 : 24)
                }
            }

            if showVideoControls {
                VStack {
                    HStack(spacing: 10) {
                        Spacer()
                        if let track = playback.currentTrack {
                            captionsButton(for: track)
                        }
                        if portraitFullscreen {
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
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
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
        // Fullscreen video hides the app's chrome. macOS has neither bar to
        // hide — the window's own toolbar stays put — so this is iOS-only.
        #if !os(macOS)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        #endif
        // Rotating into landscape surfaces the controls (there's no other cue
        // that they're there); a deliberate tap into portrait fullscreen asked
        // for a clean picture, so it starts with them out of the way.
        .onAppear { showVideoControls = !portraitFullscreen }
    }

    private func hasArtist(_ track: Track) -> Bool {
        !track.artist.isEmpty && track.artist.lowercased() != "unknown"
    }

    // MARK: - Subtitles

    /// The track's captured captions. Read from the library's live copy rather
    /// than playback's snapshot: the capture is best-effort and lands a moment
    /// *after* the download, so a video started straight away picks them up
    /// when they arrive.
    private func cues(for track: Track) -> [SubtitleCue] {
        SubtitleStore.cues(for: library.track(withID: track.id) ?? track)
    }

    /// The caption line itself, drawn over the bottom of the picture in the
    /// size, colour and backdrop chosen in Settings. Never takes a touch — the
    /// picture underneath still toggles fullscreen or the controls.
    @ViewBuilder
    private func subtitleLayer(for track: Track) -> some View {
        let lines = cues(for: track)
        VStack(spacing: 8) {
            // Says what the CC button just did. Without it, turning captions
            // on during a silent stretch — a title sequence, a scene with no
            // dialogue — is indistinguishable from a button that does nothing.
            if let captionsNotice {
                Text(captionsNotice)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.opacity)
            }
            if subtitlesEnabled, !lines.isEmpty {
                SubtitleOverlay(player: playback.player,
                                progress: playback.progress,
                                cues: lines)
            }
        }
        .padding(.bottom, 10)
        .allowsHitTesting(false)
    }

    /// The CC button, shown only on a video that actually has captions —
    /// nothing is worse than a control that does nothing.
    @ViewBuilder
    private func captionsButton(for track: Track) -> some View {
        let lines = cues(for: track)
        if track.isVideo, !lines.isEmpty {
            Button {
                subtitlesEnabled.toggle()
                announceCaptions(lines.count)
            } label: {
                Image(systemName: subtitlesEnabled ? "captions.bubble.fill" : "captions.bubble")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(subtitlesEnabled ? Color.accentColor : Color.white)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel(subtitlesEnabled ? "Hide subtitles" : "Show subtitles")
        }
    }

    /// Flashes what the toggle did, and logs it — the pair of facts that say
    /// whether a caption that didn't appear is a broken switch or a quiet
    /// moment in the film.
    private func announceCaptions(_ count: Int) {
        let notice = subtitlesEnabled ? "Subtitles on · \(count) lines" : "Subtitles off"
        appLog(notice, level: .debug, category: SubtitleFetcher.category)
        withAnimation { captionsNotice = notice }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard captionsNotice == notice else { return }
            withAnimation { captionsNotice = nil }
        }
    }

    /// The saved album art, when the track has any — falling back to the
    /// gradient placeholder. Artwork lands moments *after* a download (it's
    /// fetched best-effort once the track exists), so the library's live copy
    /// is consulted rather than playback's snapshot.
    @ViewBuilder
    private func artworkView(_ track: Track) -> some View {
        let live = library.track(withID: track.id) ?? track
        if let image = TrackArtwork.image(for: live) {
            Image(platformImage: image)
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

                    // The offset sits *outside* the animation on purpose, and
                    // the order of these three lines is the whole reason the
                    // thumb tracks the bar's tip.
                    //
                    // `.animation(_:value:)` governs every animatable change
                    // inside the view it wraps that lands in a transaction
                    // where `isScrubbing` changed — and picking the thumb up
                    // *is* such a transaction, since the same event that moves
                    // the playhead is the one that sets `isScrubbing`. With the
                    // offset inside, the fill below snapped to the finger while
                    // the circle eased after it over 0.12s: the two came apart
                    // at the start of every drag, and again on release. Only
                    // the grow-and-lift belongs in the animation; where the
                    // thumb *is* has to be as immediate as the bar it caps.
                    Circle()
                        .fill(Color.white)
                        .frame(width: thumbSize, height: thumbSize)
                        .shadow(radius: isScrubbing ? 4 : 2, y: 1)
                        .scaleEffect(isScrubbing ? 1.15 : 1)
                        .animation(.easeOut(duration: 0.12), value: isScrubbing)
                        .offset(x: usable * fraction)
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

/// The caption line over a video.
///
/// It prefers its **own** periodic observer on the player to the app's 2 Hz
/// progress ticker: half a second is nothing for a scrubber and plainly late
/// for a subtitle, which has to change on the word. Five reads a second cost
/// nothing (the cue lookup is a binary search over an array already in memory)
/// and the observer only exists while a captioned video is on screen.
///
/// It is not, however, allowed to be a *single point of failure*. The app's own
/// ticker — the one the scrubber runs on, which is visibly working whenever
/// anything is playing — stands in **whenever the fine clock isn't currently
/// delivering**, not merely until its first tick. That distinction is the fix
/// for captions that showed for a moment and then stopped: an observer that
/// starts and later goes quiet left the overlay reading a frozen playhead for
/// good, so every cue after that moment "wasn't playing yet", and only turning
/// captions off and on — which builds a new overlay, and with it a new clock —
/// brought them back. Now a clock that goes quiet is simply ignored (and
/// re-armed), and the captions keep running off the ticker meanwhile.
private struct SubtitleOverlay: View {
    let player: AVPlayer
    /// The app's own playhead, as the floor under the finer clock below.
    @ObservedObject var progress: PlaybackProgress
    let cues: [SubtitleCue]

    @StateObject private var clock = SubtitleClock()

    @AppStorage(SubtitleSettings.sizeKey) private var size = SubtitleTextSize.medium.rawValue
    @AppStorage(SubtitleSettings.colorKey) private var colorHex = SubtitleSettings.defaultColorHex
    @AppStorage(SubtitleSettings.backdropKey) private var backdrop = SubtitleBackdrop.dim.rawValue

    private var textSize: CGFloat {
        (SubtitleTextSize(rawValue: size) ?? .medium).points
    }

    private var textColor: Color {
        Color(mixtapeHex: colorHex) ?? .white
    }

    private var backdropOpacity: Double {
        (SubtitleBackdrop(rawValue: backdrop) ?? .dim).opacity
    }

    /// The playhead the cue is looked up against: the fine clock while it's
    /// actually delivering, the app's ticker whenever it isn't. Re-read on
    /// every redraw — and the ticker's own 2 Hz redraws are what notice a
    /// clock that has gone quiet.
    ///
    /// Handing over between them never runs the playhead *backwards*: the
    /// ticker's reading can be half a second older than the fine clock's last
    /// one, and a caption that has just ended would flicker back on. Beyond a
    /// second's difference the ticker wins outright — that's a seek, where
    /// going backwards is the whole point.
    private var time: Double {
        if clock.isFresh { return clock.time }
        let ticker = progress.currentTime
        return (clock.time > ticker && clock.time - ticker < 1) ? clock.time : ticker
    }

    var body: some View {
        // A `ZStack`, emphatically **not** a `Group`. A Group is transparent —
        // modifiers on it are applied to each of its children — so with a
        // conditional caption as the only child, the lifecycle hooks below
        // belonged to *the caption*, not to the overlay: `onAppear` fired
        // whenever a line came up and `onDisappear` whenever one ended, which
        // took the clock down with it. That made an oscillator. Stopping the
        // clock falls back to the app's 2 Hz ticker, whose reading is up to
        // half a second older; the older time still lands inside the cue that
        // just ended, so the caption came back, which started the clock, which
        // jumped the time forward, which ended the caption, which stopped the
        // clock — round and round as fast as the main thread allowed. The
        // hundreds of "overlay up"/"clock ticking" pairs at one playhead in
        // the log are that loop spinning. A real container owns the hooks
        // itself: they run once when the overlay appears and once when it goes.
        // An empty ZStack draws nothing and takes no space, exactly as the
        // Group did.
        ZStack {
            if let cue = cues.cue(at: time) {
                Text(cue.text)
                    .font(.system(size: textSize, weight: .semibold))
                    .foregroundStyle(textColor)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(backdropOpacity),
                                in: RoundedRectangle(cornerRadius: 6))
                    // A dark outline is what keeps unbacked captions legible
                    // over a bright shot.
                    .shadow(color: .black.opacity(0.9), radius: 2)
                    .padding(.horizontal, 16)
            }
        }
        .onAppear {
            clock.follow(player)
            // Which of the two things that can go wrong has gone wrong is not
            // guessable from the outside — captions that never appear look the
            // same whether nothing was captured, the cues sit at the wrong
            // times, or the playhead never moved. So the mount says what it
            // has, and the first tick says the clock is live.
            appLog("Subtitle overlay up: \(cues.count) cue(s), first at \(cueRange). Playhead \(progress.currentTime.asPlaybackTime).",
                   level: .debug, category: SubtitleFetcher.category)
        }
        // The app's ticker doubles as the fine clock's watchdog: every half
        // second it both redraws this line (so a stalled clock is noticed and
        // stepped around) and gives the observer a chance to be re-armed.
        .onChange(of: progress.currentTime) { _ in
            clock.reviveIfStalled(player)
        }
        .onDisappear { clock.stop() }
    }

    private var cueRange: String {
        guard let first = cues.first, let last = cues.last else { return "—" }
        return "\(first.start.asPlaybackTime), last ends \(last.end.asPlaybackTime)"
    }
}

/// A 5 Hz playhead reader for the caption overlay, torn down with the view that
/// owns it (an orphaned `AVPlayer` time observer outlives its view and keeps
/// firing).
@MainActor
private final class SubtitleClock: ObservableObject {
    @Published var time: Double = 0
    /// When the observer last delivered a tick. The overlay reads *this*
    /// rather than a "has it ever ticked" flag: an observer that starts and
    /// later stops is the failure that leaves a caption line frozen, and a
    /// one-way flag can't tell that apart from a healthy clock.
    private var lastTick = Date.distantPast
    /// When the observer was last re-armed, so a player that will never tick
    /// (paused, or between items) is retried about once a second rather than
    /// on every redraw.
    private var lastRevival = Date.distantPast

    /// How recent a tick has to be to be worth reading. The observer runs at
    /// 5 Hz, so most of a second without one means it has stopped.
    private static let freshness: TimeInterval = 1

    /// True while the fine clock is actually delivering. False before its
    /// first tick, and false again if it goes quiet — both cases the overlay
    /// answers by reading the app's own ticker instead.
    var isFresh: Bool { Date().timeIntervalSince(lastTick) < Self.freshness }

    private var observer: Any?
    private weak var player: AVPlayer?

    func follow(_ player: AVPlayer) {
        guard observer == nil else { return }
        self.player = player
        let now = player.currentTime().seconds
        time = now.isFinite ? now : 0
        // Hopped onto the main actor the way every other player callback in
        // the app is, rather than assumed onto it from a queue argument.
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { [weak self] current in
            let seconds = current.seconds
            guard seconds.isFinite else { return }
            Task { @MainActor in self?.tick(seconds) }
        }
    }

    private func tick(_ seconds: Double) {
        if !isFresh {
            appLog("Caption clock ticking at \(seconds.asPlaybackTime).",
                   level: .debug, category: SubtitleFetcher.category)
        }
        lastTick = Date()
        time = seconds
    }

    /// Puts a stalled observer back. Called off the app's own ticker, which
    /// keeps going whenever the film does — so a clock that quietly stopped
    /// (the reason captions used to need turning off and on again) recovers
    /// its 5 Hz on its own, and the captions read the 2 Hz ticker in the
    /// meantime rather than a frozen number.
    func reviveIfStalled(_ player: AVPlayer) {
        // A paused player is *meant* to be quiet, and so is the ticker the
        // fallback reads — the caption simply stays where it is. Only a clock
        // that has stopped while the film is running is a fault.
        guard player.rate != 0, observer != nil, !isFresh,
              Date().timeIntervalSince(lastRevival) >= Self.freshness else { return }
        lastRevival = Date()
        appLog("Caption clock has gone quiet — re-arming its observer (captions are running off the app's ticker meanwhile).",
               level: .debug, category: SubtitleFetcher.category)
        stop()
        follow(player)
    }

    func stop() {
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        player = nil
        lastTick = .distantPast
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

    /// The bar's proportions, gathered so its height is one decision rather
    /// than three. Together they make it about 20 points taller than it was:
    /// a cover you can make out, and transport buttons you can hit without
    /// aiming.
    private enum Metrics {
        static let artwork: CGFloat = 40
        static let button: CGFloat = 36
        static let verticalPadding: CGFloat = 11
    }

    var body: some View {
        if let track = playback.currentTrack {
            VStack(spacing: 0) {
                MiniPlayerProgressLine(progress: playback.progress)

                HStack(spacing: 10) {
                    Button(action: onOpen) {
                        HStack(spacing: 12) {
                            // A tiny cover when the track has art (checked
                            // against the library's live copy — art can land
                            // after playback started); the kind icon otherwise.
                            if let image = TrackArtwork.image(for: library.track(withID: track.id) ?? track) {
                                Image(platformImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: Metrics.artwork, height: Metrics.artwork)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            } else {
                                Image(systemName: icon(for: track))
                                    .font(.subheadline)
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 20)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                if hasArtist(track) {
                                    Text(track.artist)
                                        .font(.caption)
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
                            .frame(width: Metrics.button, height: Metrics.button)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

                    Button {
                        playback.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .frame(width: Metrics.button, height: Metrics.button)
                            .contentShape(Rectangle())
                    }
                    .disabled(playback.nextTrack == nil)
                    .accessibilityLabel("Next track")
                }
                .font(.body)
                .buttonStyle(.borderless)
                .padding(.horizontal, 14)
                .padding(.vertical, Metrics.verticalPadding)
            }
            .background(.bar)
            .overlay(alignment: .top) {
                Color.appSeparator.frame(height: 0.5)
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
#if canImport(UIKit)
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
#else
/// The Mac's `AVPlayerView` fills the same role as iOS's `AVPlayerViewController`
/// here: the picture and PiP only, with its own controls off so the app's
/// control suite stays the single one on screen.
struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer
    var allowsPiP = true

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.allowsPictureInPicturePlayback = allowsPiP
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }
}
#endif
