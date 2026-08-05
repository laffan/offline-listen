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

/// What a **borrowed** lock screen should show — see `RemoteAudioSource`.
/// Deliberately not a `Track`: the thing borrowing it is auditioning something
/// that isn't in the library yet, so all it can offer is the metadata the list
/// it came from knew.
struct RemoteAudioInfo {
    /// A stable id for the thing playing, so the watch can tell one from the next.
    var id: UUID
    var title: String
    var artist: String
    var duration: Double
    var elapsed: Double
    var isPlaying: Bool
    var artwork: MPMediaItemArtwork?
}

/// A player *other than* the library's own that is making sound and should own
/// the lock screen while it does — today, the Browse preview modal.
///
/// Two players sharing one `MPNowPlayingInfoCenter` is not a thing iOS
/// arbitrates for you: whoever writes last wins, and `PlaybackManager`'s ticker
/// writes twice a second, so an unannounced second player is simply invisible on
/// the lock screen. The same goes for `MPRemoteCommandCenter` — the transport
/// buttons act on whatever the targets were wired to, which was always the
/// library player, even when the audio you could hear was a preview.
///
/// So a preview *borrows* both (`PlaybackManager.beginRemoteAudio`) and hands
/// them back when it closes.
@MainActor
protocol RemoteAudioSource: AnyObject {
    /// Nil while the borrower has nothing to show — the lock screen then falls
    /// back to the library player.
    var remoteAudioInfo: RemoteAudioInfo? { get }
    func remotePlay()
    func remotePause()
    func remoteTogglePlayPause()
    func remoteNext()
    func remotePrevious()
    func remoteSeek(to time: Double)
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
    /// Consecutive ticks on which the player reported `.paused` while we still
    /// believed it was playing — see `checkForSilentStop()`.
    private var stoppedTicks = 0
    /// Consecutive ticks on which the **playhead** hasn't moved while the
    /// player still claims to be playing. The other, load-bearing half of the
    /// watchdog: a file that runs out of samples early doesn't pause, it
    /// stalls — see `checkForSilentStop()`.
    private var stalledTicks = 0
    /// Consecutive ticks spent waiting for a swapped-in item to become
    /// playable. Bounded, so a file that neither loads nor reports a failure
    /// can't end the queue in silence.
    private var loadingTicks = 0
    /// The playhead as of the previous tick, for the stall check above.
    /// Negative means "no reading yet", which counts as movement.
    private var lastTickPosition: Double = -1
    /// True once the playhead has actually advanced for the item now loaded.
    /// Until then the track hasn't begun, and an item that hasn't begun reads
    /// exactly like one that has run out — which is why `ranOutOfMedia` waits
    /// for this.
    private var playheadHasMoved = false
    /// True once the current track's end has been acted on. The end is reported
    /// by three independent routes (the end notification, the failure
    /// notification, and the rate/watchdog pair below) and they can easily
    /// arrive together; whichever gets there first owns it, because acting on
    /// the second would skip the song we just advanced to.
    private var didFinishCurrent = false
    /// The player's rate, watched directly. See `playerRateChanged()`.
    private var rateObservation: NSKeyValueObservation?
    /// The current item's load status. An item that fails outright posts no
    /// end-of-play notification at all — left unwatched it stops the queue dead.
    private var itemStatusObservation: NSKeyValueObservation?
    /// The current track's album art for the lock screen / Control Center,
    /// loaded once per track change — `updateNowPlaying` runs at 2 Hz and
    /// must never touch the disk.
    private var lockScreenArtwork: MPMediaItemArtwork?
    /// The Browse preview modal while it has borrowed the lock screen (see
    /// `beginRemoteAudio`). Weak on purpose: a modal torn down without handing
    /// back mustn't keep the lock screen hostage.
    private weak var remoteAudio: (any RemoteAudioSource)?

    private var hasRestored = false
    private var lastPersist = Date.distantPast
    private let library: LibraryStore

    /// Ticks (at 2 Hz) a frozen playhead is given before the track is called
    /// over regardless of where the playhead sits. Local files have nothing to
    /// buffer, so six seconds of "playing" without the clock moving is not a
    /// stall it recovers from.
    private static let stalledTickLimit = 12
    /// The same, for a playhead frozen with the item's buffer already drained.
    /// Shorter, because that combination is close to conclusive on a local
    /// file — but not instant, since an item still getting going can read the
    /// same way for a moment.
    private static let drainedTickLimit = 6
    /// Ticks a freshly swapped-in item gets to become playable. Generous: a
    /// cold read on a locked phone with the CPU throttled is genuinely slow.
    private static let loadingTickLimit = 40

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
        observePlayerRate()
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
        // A library track starting is the borrower's cue that it's over — the
        // preview modal's Save hand-off is exactly this call.
        remoteAudio = nil
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
        // Moving the playhead puts the track back in play, whatever we thought
        // of it a moment ago — otherwise a track rewound at the end of the
        // queue could never report finishing again.
        didFinishCurrent = false
        resetStopDetection()
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
        updateTransportButtons()
        releaseItemObservers()
        resetStopDetection()
        didFinishCurrent = false

        // Everything between the old item stopping and the new one playing is
        // silence, and a background audio app is alive *because* it is playing
        // — so the swap is held under a background assertion. Without it a
        // locked phone can have the app suspended mid-swap and simply never
        // start the next track.
        BackgroundActivity.bridging("Track change") {
            let item = AVPlayerItem(url: track.fileURL)
            // Swapped straight in, never through nil. Dropping the old item
            // first leaves the player with nothing to play for an instant,
            // which is exactly the gap described above.
            player.replaceCurrentItem(with: item)
            observeItem(item)

            if startAt > 0 {
                player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600))
                progress.currentTime = startAt
            }

            isPlaying = autoPlay
            if autoPlay {
                AudioSession.activate()
                player.play()
            } else {
                // `replaceCurrentItem` inherits the player's rate, so an item
                // swapped in while playing would otherwise start on its own.
                player.pause()
            }
        }

        // Past the hand-off, so nothing that touches the disk sits between the
        // two items. The artwork is a JPEG read and decode (memoized, but an
        // `NSCache` is emptied under background memory pressure), and the
        // library writes are a JSON encode apiece.
        loadLockScreenArtwork(for: track)
        // Starting playback counts as listened — the track leaves the Inbox and
        // joins the Recent log. (The preview-save handoff opts out: an
        // auditioned save should still land in the Inbox.)
        if autoPlay, countsAsListened {
            library.markPlayed(track.id)
            library.recordListen(track.id)
        }
        startTicker()
        updateNowPlaying()
        persistState()
    }

    /// The album art the lock screen and Control Center draw, read once per
    /// track change — `updateNowPlaying` runs at 2 Hz and must never touch the
    /// disk.
    private func loadLockScreenArtwork(for track: Track) {
        // The queue holds snapshots; the library's live copy has the artwork if
        // it arrived after this queue was built.
        let liveTrack = library.track(withID: track.id) ?? track
        lockScreenArtwork = TrackArtwork.image(for: liveTrack).map { image in
            MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
    }

    private func resume() {
        AudioSession.activate()
        player.play()
        isPlaying = true
        // The playhead reading the watchdog last took was from before the
        // pause, so comparing against it would read as a stall.
        resetStopDetection()
        startTicker()
        updateNowPlaying()
    }

    private func pause() {
        // Flag first, then the player: the watchdog in `tick()` reads a stopped
        // player as "the track ended" *unless* we're the ones who stopped it.
        isPlaying = false
        resetStopDetection()
        player.pause()
        updateNowPlaying()
        persistState()
    }

    /// Watches one item for the three ways it can end: normally, by giving up
    /// partway, and by never loading at all. All three advance the queue — a
    /// file that fails three seconds from the end shouldn't be the last thing
    /// you hear, and one that won't open at all shouldn't be either.
    private func observeItem(_ item: AVPlayerItem) {
        // Each handler re-checks that `item` is *still* what's loaded: these are
        // delivered asynchronously, so a notification about the track we just
        // advanced away from can land after the advance and would otherwise
        // skip the one that replaced it.
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                self.handleTrackFinished(reason: "played to the end")
            }
        }
        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] note in
            let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
                .localizedDescription ?? "unknown error"
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                self.handleTrackFinished(reason: "stopped early (\(message))")
            }
        }
        // An item whose asset never becomes playable posts *neither*
        // notification — it just sits at rate 0 forever. Nothing watched for
        // that, so a single unreadable file ended the queue in silence.
        itemStatusObservation = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "unknown error"
            Task { @MainActor in
                guard let self, self.player.currentItem === item, self.isPlaying else { return }
                self.handleTrackFinished(reason: "the file wouldn't load (\(message))")
            }
        }
    }

    private func releaseItemObservers() {
        for observer in [endObserver, failObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        endObserver = nil
        failObserver = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
    }

    /// The player's rate is the *fastest* signal that a track has run out —
    /// faster than the 0.5 s ticker, and it arrives whatever mode the run loop
    /// happens to be in. That matters most with the phone locked: a background
    /// audio app is alive because it is playing, so a second of silence spent
    /// waiting for the watchdog's second tick is a second in which iOS may
    /// suspend it before the next track ever starts.
    private func observePlayerRate() {
        rateObservation = player.observe(\.timeControlStatus) { [weak self] _, _ in
            Task { @MainActor in self?.playerRateChanged() }
        }
    }

    private func playerRateChanged() {
        guard isPlaying, player.timeControlStatus == .paused, isAtEnd else { return }
        handleTrackFinished(reason: "the player's rate dropped at the end of the track")
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
        // The duration recorded at download (track.duration, and what the
        // library shows) is authoritative: it comes from the source's own
        // metadata, while AVFoundation over-reports the length of some
        // HE-AAC/SBR audio by about double — 306s for a 153s song, measured.
        //
        // The item's figure is read only when we never got a recorded one, or
        // when the file is the *shorter* of the two: that's the direction that
        // isn't the over-read, and holding the longer number there leaves the
        // bar short of an end the playhead has already reached. Adopting the
        // longer one is what put the scrubber halfway back through a track that
        // had just finished, so it doesn't happen — the track now *ends* at the
        // recorded duration instead (see `isPastRecordedEnd`).
        if let itemDuration = player.currentItem?.duration.seconds,
           itemDuration.isFinite, itemDuration > 0,
           progress.duration <= 0 || itemDuration < progress.duration - 2 {
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
    /// simply never comes.
    ///
    /// **What that second case actually looks like is the thing this watchdog
    /// used to get wrong.** It only ever asked whether the player had *paused*,
    /// and an item that runs out of samples short of its declared duration does
    /// not pause: `AVPlayer` believes there is more media coming and sits in
    /// `.waitingToPlayAtSpecifiedRate` for good. So the notification never
    /// arrived, the rate observer (which wants `.paused` too) never fired, and
    /// the watchdog written for exactly this file kept resetting its own
    /// counter — three routes to "this track is over" and the queue stopped
    /// dead between two songs, with nothing on a locked screen to say why.
    ///
    /// The ground truth is the **playhead**, not the rate: a clock that has
    /// stopped while we still think we're playing means playback has stopped,
    /// whatever `timeControlStatus` claims. Two consecutive ticks (~1s) before
    /// acting, so a seek or a momentary hitch can't be mistaken for the end.
    private func checkForSilentStop() {
        guard isPlaying else {
            resetStopDetection()
            return
        }
        // An item that hasn't finished loading is not a stopped one — and this
        // is the difference between a locked phone and an unlocked one. A
        // freshly swapped-in item reports `.paused` until its asset is ready,
        // and in the background (cold file, throttled CPU) that can outlast the
        // two ticks below. The watchdog then read the *new* track's playhead,
        // found it nowhere near the end, concluded "stopped mid-track" and
        // marked playback paused — one second after autoplay had just started
        // it. From outside, autoplay simply stopped working while locked.
        //
        // The wait is bounded, though: an item that never becomes playable and
        // never reports `.failed` either (it just sits at `.unknown`) would
        // otherwise switch the watchdog off for the rest of the session.
        guard player.currentItem?.status == .readyToPlay else {
            stoppedTicks = 0
            stalledTicks = 0
            lastTickPosition = -1
            loadingTicks += 1
            guard loadingTicks >= Self.loadingTickLimit else { return }
            loadingTicks = 0
            handleTrackFinished(reason: "the file never became playable")
            return
        }
        loadingTicks = 0

        // The container can claim more than the file holds, and when it does
        // nothing stalls: the samples run out at the real end and the player
        // carries on running its clock through silence that isn't there, all
        // the way to the length it thinks the track is. None of the checks
        // below can see that — the playhead is moving, the player is playing —
        // so the queue waited out the phantom remainder, which on a doubled
        // file is the length of the song over again. The recorded duration
        // wins that argument, and the track ends there.
        if isPastRecordedEnd, let recorded = currentTrack?.duration {
            handleTrackFinished(
                reason: "the audio ran out at the \(Int(recorded))s recorded at download, which the file over-states")
            return
        }

        let position = player.currentTime().seconds
        let advanced = position.isFinite && lastTickPosition >= 0
            && abs(position - lastTickPosition) > 0.05
        // A reading we can't compare with anything yet counts as movement, so
        // the first tick after a track change can't start the stall count off
        // on the wrong foot.
        let moved = advanced || !position.isFinite || lastTickPosition < 0
        lastTickPosition = position.isFinite ? position : -1
        if advanced { playheadHasMoved = true }

        if player.timeControlStatus == .paused {
            stalledTicks = 0
            stoppedTicks += 1
            guard stoppedTicks >= 2 else { return }
            stoppedTicks = 0
            // Both clocks count here, unlike during playback: the player has
            // genuinely stopped, so a playhead resting at or past *either*
            // stated end has run out of audio rather than been interrupted. A
            // drained buffer says the same thing from the other direction — a
            // real interruption (a call, Siri) stops a player whose buffer is
            // still full, so this only reads true when the file itself ended.
            if isAtEnd || stoppedAtRecordedEnd || ranOutOfMedia {
                handleTrackFinished(reason: "the player stopped at the end of the track")
            } else {
                // Stopped mid-track: something took the audio away. Reflect that
                // rather than showing a play state that isn't happening — and
                // don't skip the track the user was in the middle of. The
                // numbers go in the line because this is the one branch that
                // ends a listening session without advancing.
                appLog("Playback stopped at \(Int(currentTime))s of \(Int(duration))s (interrupted) — showing it as paused.",
                       level: .debug, category: "Player")
                isPlaying = false
                updateNowPlaying()
                persistState()
            }
            return
        }

        // Still "playing" as far as the player is concerned — the stalled case.
        stoppedTicks = 0
        guard !moved else {
            stalledTicks = 0
            return
        }
        stalledTicks += 1
        // At the end by either clock, one second of a frozen playhead is
        // conclusive. Short of that, a drained buffer on a file with nothing
        // left to stream in says the samples ran out even though both clocks
        // claim otherwise — a slower call, since a cold item can read that way
        // for a moment before it gets going.
        if isAtEnd || stoppedAtRecordedEnd {
            guard stalledTicks >= 2 else { return }
            stalledTicks = 0
            handleTrackFinished(reason: "the playhead stopped at the end of the track")
        } else if ranOutOfMedia, stalledTicks >= Self.drainedTickLimit {
            stalledTicks = 0
            handleTrackFinished(reason: "the file ran out of audio before its stated end")
        } else if stalledTicks >= Self.stalledTickLimit {
            // Frozen somewhere in the middle, for longer than any local file
            // legitimately takes to recover. Better to move the queue on than
            // to leave the listening session ended in silence.
            stalledTicks = 0
            handleTrackFinished(
                reason: "playback stalled for \(Int(Double(Self.stalledTickLimit) / 2))s with the file offering nothing more")
        }
    }

    /// Clears every counter the watchdog keeps. Called wherever playback state
    /// changes under our own hand — a load, a seek, a pause, a resume — so a
    /// reading taken before the change can't be compared with one taken after.
    private func resetStopDetection() {
        stoppedTicks = 0
        stalledTicks = 0
        loadingTicks = 0
        lastTickPosition = -1
        playheadHasMoved = false
    }

    /// Whether the current item has drained its buffer with nothing coming to
    /// refill it. Local files have nothing to stream, so once the playhead has
    /// also frozen this means the samples ran out — which is the end of the
    /// track even when the container claims there is more to come.
    ///
    /// A track that hasn't started yet hasn't run out of anything — a cold item
    /// on a locked phone reads the same way — so this only speaks once the
    /// playhead has been seen to move for the item now loaded.
    private var ranOutOfMedia: Bool {
        guard playheadHasMoved, let item = player.currentItem else { return false }
        return item.isPlaybackBufferEmpty && !item.isPlaybackLikelyToKeepUp
    }

    /// Whether the playhead has reached the end of the media.
    ///
    /// Judged against the **item's** clock, because that is the timeline the
    /// playhead itself lives in. This used to take whichever of the two clocks
    /// — the item's and the duration recorded at download — the playhead
    /// reached first, and that is wrong in the common direction: a file that
    /// runs *longer* than its metadata said (which is exactly what the Player
    /// shows when the elapsed time climbs past the stated length) was "at the
    /// end" from the moment it passed the recorded figure, so any momentary
    /// pause in the back half of a track ended it early.
    ///
    /// The recorded duration still has a job — a playhead that has *stopped*
    /// at or past it has run out of audio whatever the container claims — but
    /// that only makes sense once the clock has frozen, so it lives in
    /// `stoppedAtRecordedEnd` and is consulted by the watchdog alone.
    private var isAtEnd: Bool {
        let now = player.currentTime().seconds
        guard now.isFinite, now > 0 else { return false }
        let tolerance = 1.5
        if let item = player.currentItem?.duration.seconds, item.isFinite, item > 0 {
            return now >= item - tolerance
        }
        let recorded = currentTrack?.duration ?? 0
        return recorded > 0 && now >= recorded - tolerance
    }

    /// The over-read, caught while the player is still nominally playing.
    ///
    /// AVFoundation reads some HE-AAC/SBR audio as roughly twice its real
    /// length — 306s for a 153s song, in the case that turned this up. The
    /// samples run out at the true end, but the item still believes there is
    /// half a track to come, so it doesn't stop or stall: it runs its clock on
    /// through silence to the length it thinks the file is. Every stop check
    /// there is looks for something that has *halted*, and nothing here has.
    ///
    /// The two conditions together are what identify it: the file claiming
    /// *far* more than the source metadata recorded, and the playhead past the
    /// recorded end. That is the audio being over, whatever the container says
    /// is left.
    ///
    /// The gap has to be large before the recorded figure is allowed to end a
    /// track early — a quarter as long again, and at least ten seconds — so
    /// that ordinary slop between a container and its metadata (a muxed video
    /// running a second or two past, a rounded feed duration) never clips
    /// anything. An over-read is around double; nothing else comes close.
    private var isPastRecordedEnd: Bool {
        guard let recorded = currentTrack?.duration, recorded > 0,
              let item = player.currentItem?.duration.seconds, item.isFinite,
              item > max(recorded * 1.25, recorded + 10) else { return false }
        let now = player.currentTime().seconds
        return now.isFinite && now >= recorded
    }

    /// The same disagreement seen with the playhead already stopped, where the
    /// margin can be looser — nothing is going to move again either way.
    private var stoppedAtRecordedEnd: Bool {
        let now = player.currentTime().seconds
        let recorded = currentTrack?.duration ?? 0
        return now.isFinite && recorded > 0 && now >= recorded - 1.5
    }

    private func handleTrackFinished(reason: String) {
        // Whichever of the end signals arrives first owns the advance. They
        // routinely overlap — the notification and the rate change are the same
        // event seen twice — and acting on the second would skip the track the
        // first one just started. Cleared by `loadCurrent` and by any seek.
        guard !didFinishCurrent else { return }
        didFinishCurrent = true
        // A finished podcast or video resets so a later tap starts it fresh.
        if let track = currentTrack, track.remembersPosition {
            library.updatePosition(for: track.id, to: 0)
        }
        resetStopDetection()
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
    /// macOS posts none of these — there's no audio session to be interrupted
    /// on, and a Mac losing its headphones keeps playing out of the speakers —
    /// so the whole mechanism compiles out there.
    private func observeAudioSession() {
        #if os(iOS)
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
        #endif
    }

    #if os(iOS)
    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            // The system has already stopped the audio; catch up with it —
            // whichever player it was that lost it.
            if let remoteAudio {
                appLog("Audio interrupted — pausing the preview.", level: .debug, category: "Player")
                remoteAudio.remotePause()
                return
            }
            guard isPlaying else { return }
            appLog("Audio interrupted — pausing.", level: .debug, category: "Player")
            isPlaying = false
            resetStopDetection()
            updateNowPlaying()
            persistState()
        case .ended:
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            guard options.contains(.shouldResume) else { return }
            if let remoteAudio {
                appLog("Interruption over — resuming the preview.", level: .debug, category: "Player")
                remoteAudio.remotePlay()
                return
            }
            guard currentTrack != nil, !isPlaying else { return }
            appLog("Interruption over — resuming.", level: .debug, category: "Player")
            resume()
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
              reason == .oldDeviceUnavailable else { return }
        // Headphones pulled / Bluetooth gone: iOS pauses so nothing blares out
        // of the speaker. Reflect it instead of drifting out of step.
        if let remoteAudio {
            remoteAudio.remotePause()
            return
        }
        guard isPlaying else { return }
        isPlaying = false
        resetStopDetection()
        updateNowPlaying()
        persistState()
    }
    #endif

    // MARK: - Audio session

    private func configureAudioSession() {
        AudioSession.configureForPlayback()
    }

    // MARK: - Lending the lock screen out

    /// Hands the lock screen, Control Center and the watch transport to
    /// `source` — the Browse preview modal, which is what's actually making
    /// sound while it's open.
    ///
    /// Without this the modal was invisible from outside the app: the ticker
    /// below rewrites `MPNowPlayingInfoCenter` twice a second from the library
    /// player, so a preview's title and artist were overwritten as fast as they
    /// could have been set, and the lock screen's next-track button walked the
    /// library queue you couldn't hear instead of the album you were
    /// auditioning.
    func beginRemoteAudio(_ source: any RemoteAudioSource) {
        remoteAudio = source
        // The ticker is what republishes now-playing, and it only starts once a
        // library track has been loaded — a preview can easily be the first
        // thing that plays in a session.
        startTicker()
        updateTransportButtons()
        updateNowPlaying()
    }

    /// Hands the lock screen back to the library player. A no-op unless
    /// `source` is the current borrower, so a modal torn down after another one
    /// took over can't snatch it from the newcomer.
    func endRemoteAudio(_ source: any RemoteAudioSource) {
        guard remoteAudio === source else { return }
        remoteAudio = nil
        updateTransportButtons()
        updateNowPlaying()
    }

    /// The borrower's cue that something changed (a new track, play/pause, a
    /// scrub, artwork arriving) and the lock screen should be redrawn now
    /// rather than on the next tick.
    func remoteAudioDidChange(_ source: any RemoteAudioSource) {
        guard remoteAudio === source else { return }
        updateTransportButtons()
        updateNowPlaying()
    }

    // MARK: - The transport as the outside world sees it

    // Every control that isn't the in-app Player screen — the lock screen,
    // Control Center, the headphones, the watch — comes through these, and they
    // route to whatever is actually making sound. The Player screen keeps
    // calling `next()` / `previous()` / `togglePlayPause()` directly, because
    // it is only ever showing the library player.

    func remotePlay() {
        if let remoteAudio { remoteAudio.remotePlay() } else { resume() }
    }

    func remotePause() {
        if let remoteAudio { remoteAudio.remotePause() } else { pause() }
    }

    func remoteTogglePlayPause() {
        if let remoteAudio { remoteAudio.remoteTogglePlayPause() } else { togglePlayPause() }
    }

    func remoteNext() {
        if let remoteAudio { remoteAudio.remoteNext() } else { next() }
    }

    func remotePrevious() {
        if let remoteAudio { remoteAudio.remotePrevious() } else { previous() }
    }

    func remoteSeek(to time: Double) {
        if let remoteAudio { remoteAudio.remoteSeek(to: time) } else { seek(to: time) }
    }

    func remoteSkipForward(_ seconds: Double = 30) {
        if let remoteAudio {
            remoteAudio.remoteSeek(to: (remoteAudio.remoteAudioInfo?.elapsed ?? 0) + seconds)
        } else {
            skipForward(seconds)
        }
    }

    func remoteSkipBackward(_ seconds: Double = 15) {
        if let remoteAudio {
            remoteAudio.remoteSeek(to: max(0, (remoteAudio.remoteAudioInfo?.elapsed ?? 0) - seconds))
        } else {
            skipBackward(seconds)
        }
    }

    // MARK: - Lock screen

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            self?.remotePlay(); return .success
        }
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            self?.remotePause(); return .success
        }
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.remoteTogglePlayPause(); return .success
        }

        // The lock screen / Control Center only renders three transport buttons
        // (one centre play/pause plus two side buttons), and it can show EITHER
        // next/previous-track OR skip-forward/backward — not both. Which pair the
        // side buttons show is chosen per track in `updateTransportButtons()`:
        // songs/videos get next/previous-track, podcasts get the 30s/15s jumps
        // (more useful for long episodes). Targets for all four are installed
        // here; only their `isEnabled` flags are toggled as the track changes.
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.remoteNext(); return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.remotePrevious(); return .success
        }

        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 30
            self?.remoteSkipForward(interval)
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            self?.remoteSkipBackward(interval)
            return .success
        }
        updateTransportButtons()
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.remoteSeek(to: event.positionTime)
            return .success
        }
    }

    /// Picks which pair of side buttons the lock screen shows for the current
    /// track: next/previous-track for songs and videos, 30s/15s jumps for
    /// podcasts. iOS renders only one pair, so the other is disabled.
    private func updateTransportButtons() {
        let center = MPRemoteCommandCenter.shared()
        // A preview is a song being auditioned out of a list — its side buttons
        // walk that list, never the podcast jumps.
        let useTrackButtons = remoteAudio != nil
            || (currentTrack.map { $0.playbackCategory != .podcast } ?? false)
        center.nextTrackCommand.isEnabled = useTrackButtons
        center.previousTrackCommand.isEnabled = useTrackButtons
        center.skipForwardCommand.isEnabled = !useTrackButtons
        center.skipBackwardCommand.isEnabled = !useTrackButtons
    }

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        // A borrower owns the lock screen outright while it's making sound —
        // including through the silent gap where it's fetching its next track,
        // which is when the library player's own (paused) metadata would
        // otherwise flicker back in.
        if let remoteAudio, let borrowed = remoteAudio.remoteAudioInfo {
            publish(borrowed, to: center)
            return
        }
        guard let track = currentTrack else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            lockScreenArtwork = nil
            onNowPlayingChange?(nil)
            return
        }
        publish(RemoteAudioInfo(id: track.id,
                                title: track.title,
                                artist: track.artist,
                                duration: duration,
                                elapsed: currentTime,
                                isPlaying: isPlaying,
                                artwork: lockScreenArtwork),
                to: center,
                isPodcast: track.playbackCategory == .podcast)
    }

    /// Writes one snapshot to the lock screen / Control Center and mirrors it to
    /// the watch. The library player and a borrower go through the same call, so
    /// a preview appears exactly as a library track does — title, artist, cover,
    /// scrubber and all.
    private func publish(_ info: RemoteAudioInfo,
                         to center: MPNowPlayingInfoCenter,
                         isPodcast: Bool = false) {
        var payload: [String: Any] = [
            MPMediaItemPropertyTitle: info.title,
            MPMediaItemPropertyArtist: info.artist,
            MPMediaItemPropertyPlaybackDuration: info.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: info.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: info.isPlaying ? 1.0 : 0.0
        ]
        payload[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        if let artwork = info.artwork {
            payload[MPMediaItemPropertyArtwork] = artwork
        }
        center.nowPlayingInfo = payload
        // iOS 13+ uses an explicit playback state to decide whether (and how) to
        // present the Now Playing controls on the lock screen; without it the
        // controls can fail to surface or get stuck out of sync with playback.
        center.playbackState = info.isPlaying ? .playing : .paused
        // The watch acts as a remote off the same snapshot; `WatchSync`
        // throttles the actual sends.
        onNowPlayingChange?(RemoteNowPlaying(trackID: info.id,
                                            title: info.title,
                                            artist: info.artist,
                                            duration: info.duration,
                                            elapsed: info.elapsed,
                                            isPlaying: info.isPlaying,
                                            isPodcast: isPodcast))
    }
}
