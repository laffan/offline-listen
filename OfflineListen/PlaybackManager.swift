import Foundation
import AVFoundation
import MediaPlayer
import UIKit

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

    /// Called whenever now-playing state changes, with a snapshot the watch can
    /// mirror as a remote control (or `nil` when nothing is playing). Wired to
    /// `WatchSync` in the app entry; throttling lives there.
    var onNowPlayingChange: ((RemoteNowPlaying?) -> Void)?

    private var queue: [Track] = []
    private var index = 0
    private var ticker: Timer?
    private var endObserver: NSObjectProtocol?
    /// Fires when an item gives up partway — a decode error near the end, say.
    /// Left unwatched it stranded the queue: playback stopped and nothing
    /// moved it on.
    private var failObserver: NSObjectProtocol?
    /// Interruption / route-change observers, live for the app's lifetime.
    private var sessionObservers: [NSObjectProtocol] = []
    /// Consecutive ticks on which the player was stopped while we still
    /// believed it was playing — see `checkForSilentStop()`.
    private var stoppedTicks = 0
    /// The current track's album art for the lock screen / Control Center,
    /// loaded once per track change — `updateNowPlaying` runs at 2 Hz and
    /// must never touch the disk.
    private var lockScreenArtwork: MPMediaItemArtwork?

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
        observeAudioSession()
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
    /// `countsAsListened: false` keeps the track in the Inbox even though it
    /// starts playing — used by the preview modal's save handoff, where the
    /// user auditioned the track but hasn't "listened" to it from the library.
    func play(_ track: Track, in tracks: [Track], startAt: Double? = nil,
              restrictToCategory: Bool = true, countsAsListened: Bool = true) {
        let pool = tracks.isEmpty ? [track] : tracks
        queue = restrictToCategory ? pool.filter { $0.playbackCategory == track.playbackCategory } : pool
        if queue.isEmpty { queue = [track] }
        index = queue.firstIndex(where: { $0.id == track.id }) ?? 0
        loadCurrent(autoPlay: true, startAt: startAt ?? startPosition(for: track),
                    countsAsListened: countsAsListened)
    }

    func togglePlayPause() {
        guard currentTrack != nil else { return }
        if isPlaying { pause() } else { resume() }
    }

    /// What `next()` would play, or nil at the end of the queue — the Player
    /// screen labels its next/previous buttons with these.
    var nextTrack: Track? {
        queue.indices.contains(index + 1) ? queue[index + 1] : nil
    }

    /// The queue entry before the current one, or nil at the start. Note this
    /// is *not* what `previous()` always does: that restarts the current track
    /// when you're more than three seconds in.
    var previousTrack: Track? {
        queue.indices.contains(index - 1) ? queue[index - 1] : nil
    }

    func next() {
        // Advance within the (already category-filtered) queue; stop at the end
        // rather than wrapping, so a list plays through once.
        guard !queue.isEmpty, index + 1 < queue.count else { return }
        index += 1
        loadCurrent(autoPlay: true, startAt: startPosition(for: queue[index]))
    }

    /// Goes straight to the previous queue entry — what tapping a row that
    /// *names* the previous track should do, where `previous()`'s "restart the
    /// current track" behaviour would read as a dead tap.
    func playPreviousTrack() {
        guard queue.indices.contains(index - 1) else { return }
        index -= 1
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

    private func loadCurrent(autoPlay: Bool, startAt: Double = 0, countsAsListened: Bool = true) {
        guard queue.indices.contains(index) else { return }
        let track = queue[index]
        currentTrack = track
        progress.currentTime = 0
        progress.duration = track.duration
        // The queue holds snapshots; the library's live copy has the artwork
        // if it arrived after this queue was built.
        let liveTrack = library.track(withID: track.id) ?? track
        lockScreenArtwork = TrackArtwork.image(for: liveTrack).map { image in
            MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        updateTransportButtons()
        releaseItemObservers()
        stoppedTicks = 0

        let item = AVPlayerItem(url: track.fileURL)
        // Swapped straight in, never through nil. Dropping the old item first
        // leaves the player with nothing to play for an instant, and in the
        // background that gap of silence is exactly when iOS suspends an audio
        // app — which is how a locked phone could stop dead between tracks
        // instead of rolling on to the next one.
        player.replaceCurrentItem(with: item)
        observeItem(item)

        if startAt > 0 {
            player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600))
            progress.currentTime = startAt
        }

        isPlaying = autoPlay
        if autoPlay {
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()
            // Starting playback counts as listened — the track leaves the
            // Inbox and joins the Recent log. (The preview-save handoff opts
            // out: an auditioned save should still land in the Inbox.)
            if countsAsListened {
                library.markPlayed(track.id)
                library.recordListen(track.id)
            }
        } else {
            // `replaceCurrentItem` inherits the player's rate, so an item
            // swapped in while playing would otherwise start on its own.
            player.pause()
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
        // Flag first, then the player: the watchdog in `tick()` reads a stopped
        // player as "the track ended" *unless* we're the ones who stopped it.
        isPlaying = false
        stoppedTicks = 0
        player.pause()
        updateNowPlaying()
        persistState()
    }

    /// Watches one item for the two ways it can end: normally, and by giving
    /// up. Both advance the queue — a file that fails three seconds from the
    /// end shouldn't be the last thing you hear.
    private func observeItem(_ item: AVPlayerItem) {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleTrackFinished(reason: "played to the end") }
        }
        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] note in
            let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
                .localizedDescription ?? "unknown error"
            Task { @MainActor in
                self?.handleTrackFinished(reason: "stopped early (\(message))")
            }
        }
    }

    private func releaseItemObservers() {
        for observer in [endObserver, failObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        endObserver = nil
        failObserver = nil
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
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // `.common`, not the default mode: scrolling a list puts the run loop
        // in tracking mode and stops a plain scheduled timer dead, and the
        // end-of-track watchdog below has to keep running while the user drags
        // through the library.
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
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
        checkForSilentStop()
        updateNowPlaying()
        if Date().timeIntervalSince(lastPersist) > 5 {
            persistState()
        }
    }

    /// The end-of-track watchdog, and the reason autoplay can be trusted.
    ///
    /// `AVPlayerItemDidPlayToEndTime` is the primary signal but it is not
    /// sufficient on its own: something outside the app can stop the audio
    /// without it (a call, Siri, an alarm, headphones pulled), and a file
    /// whose container over-reports its length — AVFoundation reads some
    /// HE-AAC/SBR audio as roughly twice its real duration, the same quirk
    /// `tick()` refuses to trust for the scrubber — runs out of samples at a
    /// timestamp the player never considers "the end", so the notification
    /// simply never comes and the queue sits there for good.
    ///
    /// A player that has stopped while we still think it's playing is the
    /// ground truth, whatever the notification did. Two consecutive ticks
    /// (~1s) before acting, so a seek or a momentary stall can't be mistaken
    /// for a stop.
    private func checkForSilentStop() {
        guard isPlaying, player.timeControlStatus == .paused else {
            stoppedTicks = 0
            return
        }
        stoppedTicks += 1
        guard stoppedTicks >= 2 else { return }
        stoppedTicks = 0
        if isAtEnd {
            handleTrackFinished(reason: "the player stopped at the end of the track")
        } else {
            // Stopped mid-track: something took the audio away. Reflect that
            // rather than showing a play state that isn't happening — and
            // don't skip the track the user was in the middle of.
            appLog("Playback stopped mid-track (interrupted) — showing it as paused.",
                   level: .debug, category: "Player")
            isPlaying = false
            updateNowPlaying()
            persistState()
        }
    }

    /// Whether the playhead has reached the end of the media, judged against
    /// **both** clocks: the item's own duration and the duration recorded at
    /// download time. They disagree on the over-reporting files described
    /// above, and whichever one the audio actually ran out on, the track is
    /// over.
    private var isAtEnd: Bool {
        let now = player.currentTime().seconds
        guard now.isFinite, now > 0 else { return false }
        let tolerance = 1.5
        if let item = player.currentItem?.duration.seconds,
           item.isFinite, item > 0, now >= item - tolerance {
            return true
        }
        let recorded = currentTrack?.duration ?? 0
        return recorded > 0 && now >= recorded - tolerance
    }

    private func handleTrackFinished(reason: String) {
        // A finished podcast or video resets so a later tap starts it fresh.
        if let track = currentTrack, track.remembersPosition {
            library.updatePosition(for: track.id, to: 0)
        }
        stoppedTicks = 0
        // Auto-advance to the next track in the (category-filtered) queue and keep
        // going to the end of the list; stop, rather than loop, once it's done.
        if index + 1 < queue.count {
            index += 1
            appLog("Advancing to \"\(queue[index].title)\" — \(reason).",
                   level: .debug, category: "Player")
            loadCurrent(autoPlay: true, startAt: startPosition(for: queue[index]))
        } else {
            appLog("End of the queue — \(reason).", level: .debug, category: "Player")
            seek(to: 0)
            pause()
        }
    }

    // MARK: - Interruptions

    /// Audio the app doesn't control: a phone call, Siri, an alarm, or the
    /// headphones being pulled out. iOS pauses the player and says so here.
    /// Without this the app went on claiming to be playing — the lock screen
    /// agreed — while the track it was on never finished, so the queue never
    /// moved again until playback was poked by hand.
    private func observeAudioSession() {
        // `object: nil` deliberately: these are posted about the shared
        // session, and there is only one, but which object they name has
        // varied across iOS releases — filtering on it is how an observer
        // silently never fires.
        let center = NotificationCenter.default
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        })
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleRouteChange(note) }
        })
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            // The system has already stopped the audio; catch up with it.
            guard isPlaying else { return }
            appLog("Audio interrupted — pausing.", level: .debug, category: "Player")
            isPlaying = false
            stoppedTicks = 0
            updateNowPlaying()
            persistState()
        case .ended:
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            guard options.contains(.shouldResume), currentTrack != nil, !isPlaying else { return }
            appLog("Interruption over — resuming.", level: .debug, category: "Player")
            resume()
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
              reason == .oldDeviceUnavailable, isPlaying else { return }
        // Headphones pulled / Bluetooth gone: iOS pauses so nothing blares out
        // of the speaker. Reflect it instead of drifting out of step.
        isPlaying = false
        stoppedTicks = 0
        updateNowPlaying()
        persistState()
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
            lockScreenArtwork = nil
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
        if let lockScreenArtwork {
            info[MPMediaItemPropertyArtwork] = lockScreenArtwork
        }
        center.nowPlayingInfo = info
        // iOS 13+ uses an explicit playback state to decide whether (and how) to
        // present the Now Playing controls on the lock screen; without it the
        // controls can fail to surface or get stuck out of sync with playback.
        center.playbackState = isPlaying ? .playing : .paused
        broadcastRemoteState()
    }

    /// Pushes the current now-playing snapshot to the watch (so it can act as a
    /// remote). Driven off `updateNowPlaying`, which fires on every transition and
    /// on the ticker; `WatchSync` throttles the actual sends.
    private func broadcastRemoteState() {
        guard let track = currentTrack else {
            onNowPlayingChange?(nil)
            return
        }
        onNowPlayingChange?(RemoteNowPlaying(
            trackID: track.id,
            title: track.title,
            artist: track.artist,
            duration: duration,
            elapsed: currentTime,
            isPlaying: isPlaying,
            isPodcast: track.playbackCategory == .podcast))
    }
}
