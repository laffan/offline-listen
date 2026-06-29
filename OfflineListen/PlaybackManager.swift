import Foundation
import AVFoundation
import MediaPlayer

/// Drives playback for the player screen and the lock screen / Control Center.
///
/// Offline background playback (phone locked) is achieved by:
///   1. `UIBackgroundModes = [audio]` in Info.plist.
///   2. An `AVAudioSession` configured with the `.playback` category.
///   3. `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` for lock-screen UI.
///
/// Uses `AVPlayer` so it can play both audio (`.m4a`) and video (`.mp4`); for
/// video, the player screen attaches a layer to show the picture, while audio
/// keeps playing in the background.
/// Fast-changing playback state, isolated from `PlaybackManager` so only the
/// views that render it (the scrubber) re-render on the 2 Hz ticker — anything
/// observing `PlaybackManager` itself (library lists, toolbar menus) would
/// otherwise refresh constantly, visibly pulsing and dismissing open menus.
@MainActor
final class PlaybackProgress: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
}

@MainActor
final class PlaybackManager: NSObject, ObservableObject {
    @Published var currentTrack: Track?
    @Published var isPlaying = false
    /// Playhead + duration; deliberately not `@Published` properties here (see
    /// `PlaybackProgress`).
    let progress = PlaybackProgress()

    var currentTime: Double { progress.currentTime }
    var duration: Double { progress.duration }

    /// Exposed so the player screen can render video for video tracks.
    let player = AVPlayer()

    private var queue: [Track] = []
    private var index = 0
    private var ticker: Timer?
    private var endObserver: NSObjectProtocol?

    private var hasRestored = false
    private var lastPersist = Date.distantPast
    private let library: LibraryStore

    private enum Keys {
        static let trackID = "lastTrackID"
    }

    init(library: LibraryStore) {
        self.library = library
        super.init()
        // Keep a video's audio playing when the app is backgrounded / locked.
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        configureAudioSession()
        setupRemoteCommands()
    }

    // MARK: - Public control

    /// Starts `track`, building the autoplay queue from `tracks`.
    ///
    /// `restrictToCategory` controls how the next track is chosen when one
    /// finishes. In the **auto-aggregated** lists (the unfiled library root, the
    /// Inbox) types are mixed together, so autoplay stays within the media
    /// category you started — songs play on, podcasts/videos are skipped. A
    /// **folder/playlist is deliberately curated**, though, so it plays straight
    /// through in list order regardless of type; pass `false` there.
    /// `startAt` overrides the natural start position — used to jump to a chapter.
    func play(_ track: Track, in tracks: [Track], startAt: Double? = nil, restrictToCategory: Bool = true) {
        let pool = tracks.isEmpty ? [track] : tracks
        queue = restrictToCategory ? pool.filter { $0.playbackCategory == track.playbackCategory } : pool
        if queue.isEmpty { queue = [track] }
        index = queue.firstIndex(where: { $0.id == track.id }) ?? 0
        loadCurrent(autoPlay: true, startAt: startAt ?? startPosition(for: track))
    }

    func togglePlayPause() {
        guard currentTrack != nil else { return }
        if isPlaying { pause() } else { resume() }
    }

    func next() {
        // Advance within the (already category-filtered) queue; stop at the end
        // rather than wrapping, so a list plays through once.
        guard !queue.isEmpty, index + 1 < queue.count else { return }
        index += 1
        loadCurrent(autoPlay: true, startAt: startPosition(for: queue[index]))
    }

    func previous() {
        guard !queue.isEmpty else { return }
        // Restart current track if we're more than 3s in, or it's the first one.
        if currentTime > 3 || index == 0 {
            seek(to: 0)
            return
        }
        index -= 1
        loadCurrent(autoPlay: true, startAt: startPosition(for: queue[index]))
    }

    /// Jumps the current track to a chapter marker.
    func seek(toChapter chapter: Chapter) {
        seek(to: chapter.start)
    }

    /// Where a track should begin: podcasts and videos resume from their
    /// freshest saved playhead; songs always start at 0.
    private func startPosition(for track: Track) -> Double {
        guard track.remembersPosition else { return 0 }
        return library.tracks.first(where: { $0.id == track.id })?.lastPosition ?? track.lastPosition
    }

    func seek(to time: Double) {
        let upperBound = duration > 0 ? duration : time
        let target = max(0, min(time, upperBound))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        progress.currentTime = target
        updateNowPlaying()
        persistState()
    }

    /// Restores the last-played track (paused), unless playback is already
    /// underway. Podcasts and videos restore at their saved playhead; songs at 0.
    func restoreLastSession() {
        guard !hasRestored else { return }
        hasRestored = true
        guard currentTrack == nil else { return }

        guard let idString = UserDefaults.standard.string(forKey: Keys.trackID),
              let id = UUID(uuidString: idString),
              let track = library.tracks.first(where: { $0.id == id }) else { return }

        let pool = track.isArchived ? library.archivedTracks : library.activeTracks
        let sameCategory = pool.filter { $0.playbackCategory == track.playbackCategory }
        queue = sameCategory.contains(where: { $0.id == id }) ? sameCategory : [track]
        index = queue.firstIndex(where: { $0.id == id }) ?? 0
        loadCurrent(autoPlay: false, startAt: startPosition(for: track))
    }

    /// Writes the current track + playhead so they survive app relaunch.
    func saveState() {
        persistState()
    }

    func skipForward(_ seconds: Double = 30) {
        seek(to: currentTime + seconds)
    }

    func skipBackward(_ seconds: Double = 15) {
        seek(to: currentTime - seconds)
    }

    // MARK: - Engine

    private func loadCurrent(autoPlay: Bool, startAt: Double = 0) {
        guard queue.indices.contains(index) else { return }
        let track = queue[index]
        currentTrack = track
        progress.currentTime = 0
        progress.duration = track.duration
        updateTransportButtons()
        stopEngine()

        let item = AVPlayerItem(url: track.fileURL)
        player.replaceCurrentItem(with: item)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleTrackFinished() }
        }

        if startAt > 0 {
            player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600))
            progress.currentTime = startAt
        }

        isPlaying = autoPlay
        if autoPlay {
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()
            // Starting playback counts as listened — the track leaves the Inbox.
            library.markPlayed(track.id)
        }
        startTicker()
        updateNowPlaying()
        persistState()
    }

    private func resume() {
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        isPlaying = true
        startTicker()
        updateNowPlaying()
    }

    private func pause() {
        player.pause()
        isPlaying = false
        updateNowPlaying()
        persistState()
    }

    private func stopEngine() {
        ticker?.invalidate()
        ticker = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private func persistState() {
        guard let track = currentTrack else { return }
        UserDefaults.standard.set(track.id.uuidString, forKey: Keys.trackID)
        // Podcasts and videos remember their playhead; songs don't.
        if track.remembersPosition {
            library.updatePosition(for: track.id, to: currentTime)
        }
        lastPersist = Date()
    }

    // MARK: - Progress polling

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        // Only publish real changes — the ticker also runs while paused, and
        // no-op sets would still fire objectWillChange on every tick.
        let now = player.currentTime().seconds
        if now.isFinite, abs(progress.currentTime - now) > 0.01 {
            progress.currentTime = now
        }
        // The duration recorded at download time (track.duration, shown in the
        // library) is authoritative. We only read it off the player item as a
        // fallback when we never got one — overwriting a known-good value here
        // is wrong because AVFoundation over-reports the duration of some
        // YouTube audio (HE-AAC/SBR streams report ~2x their real length), which
        // made the player show double the library's figure for the same track.
        if progress.duration <= 0,
           let itemDuration = player.currentItem?.duration.seconds,
           itemDuration.isFinite, itemDuration > 0 {
            progress.duration = itemDuration
        }
        updateNowPlaying()
        if Date().timeIntervalSince(lastPersist) > 5 {
            persistState()
        }
    }

    private func handleTrackFinished() {
        // A finished podcast or video resets so a later tap starts it fresh.
        if let track = currentTrack, track.remembersPosition {
            library.updatePosition(for: track.id, to: 0)
        }
        // Auto-advance to the next track in the (category-filtered) queue and keep
        // going to the end of the list; stop, rather than loop, once it's done.
        if index + 1 < queue.count {
            index += 1
            loadCurrent(autoPlay: true, startAt: startPosition(for: queue[index]))
        } else {
            seek(to: 0)
            pause()
        }
    }

    // MARK: - Audio session

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
        } catch {
            print("[PlaybackManager] audio session error: \(error)")
        }
    }

    // MARK: - Lock screen

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            self?.resume(); return .success
        }
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pause(); return .success
        }
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause(); return .success
        }

        // The lock screen / Control Center only renders three transport buttons
        // (one centre play/pause plus two side buttons), and it can show EITHER
        // next/previous-track OR skip-forward/backward — not both. Which pair the
        // side buttons show is chosen per track in `updateTransportButtons()`:
        // songs/videos get next/previous-track, podcasts get the 30s/15s jumps
        // (more useful for long episodes). Targets for all four are installed
        // here; only their `isEnabled` flags are toggled as the track changes.
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.next(); return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.previous(); return .success
        }

        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 30
            self?.skipForward(interval)
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            self?.skipBackward(interval)
            return .success
        }
        updateTransportButtons()
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime)
            return .success
        }
    }

    /// Picks which pair of side buttons the lock screen shows for the current
    /// track: next/previous-track for songs and videos, 30s/15s jumps for
    /// podcasts. iOS renders only one pair, so the other is disabled.
    private func updateTransportButtons() {
        let center = MPRemoteCommandCenter.shared()
        let useTrackButtons = currentTrack.map { $0.playbackCategory != .podcast } ?? false
        center.nextTrackCommand.isEnabled = useTrackButtons
        center.previousTrackCommand.isEnabled = useTrackButtons
        center.skipForwardCommand.isEnabled = !useTrackButtons
        center.skipBackwardCommand.isEnabled = !useTrackButtons
    }

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let track = currentTrack else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        center.nowPlayingInfo = info
        // iOS 13+ uses an explicit playback state to decide whether (and how) to
        // present the Now Playing controls on the lock screen; without it the
        // controls can fail to surface or get stuck out of sync with playback.
        center.playbackState = isPlaying ? .playing : .paused
    }
}
