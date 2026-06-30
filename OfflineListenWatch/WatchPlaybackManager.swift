import Foundation
import AVFoundation
import MediaPlayer

/// Audio playback for the watch's Listen pane and the watch Now Playing UI.
/// Mirrors the core of the phone's `PlaybackManager`: an `AVPlayer` driving the
/// `.playback` audio session, with `MPNowPlayingInfoCenter` /
/// `MPRemoteCommandCenter` so the system transport works. Audio only — no video,
/// no chapters. Podcasts resume from their saved playhead; songs start over.
@MainActor
final class WatchPlaybackManager: NSObject, ObservableObject {
    @Published var currentTrack: WatchTrack?
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0

    private let player = AVPlayer()
    private let store: WatchLibraryStore

    private var queue: [WatchTrack] = []
    private var index = 0
    private var ticker: Timer?
    private var endObserver: NSObjectProtocol?
    private var lastPersist = Date.distantPast

    /// User's output preference (Bluetooth vs Speaker); applied to the session.
    var preferredOutput: WatchAudioOutput {
        get { WatchAudioOutput(rawValue: UserDefaults.standard.string(forKey: Self.outputKey) ?? "") ?? .bluetooth }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.outputKey)
            configureAudioSession()
        }
    }
    private static let outputKey = "watchAudioOutput"

    init(store: WatchLibraryStore) {
        self.store = store
        super.init()
        configureAudioSession()
        setupRemoteCommands()
    }

    // MARK: - Public control

    /// Starts `track`, building the autoplay queue from `pool` (the list the user
    /// tapped within). Playback advances straight through the queue in order.
    func play(_ track: WatchTrack, in pool: [WatchTrack]) {
        queue = pool.isEmpty ? [track] : pool
        index = queue.firstIndex(where: { $0.id == track.id }) ?? 0
        loadCurrent(autoPlay: true, startAt: startPosition(for: track))
    }

    func togglePlayPause() {
        guard currentTrack != nil else { return }
        if isPlaying { pause() } else { resume() }
    }

    func next() {
        guard !queue.isEmpty, index + 1 < queue.count else { return }
        index += 1
        loadCurrent(autoPlay: true, startAt: startPosition(for: queue[index]))
    }

    func previous() {
        guard !queue.isEmpty else { return }
        if currentTime > 3 || index == 0 {
            seek(to: 0)
            return
        }
        index -= 1
        loadCurrent(autoPlay: true, startAt: startPosition(for: queue[index]))
    }

    func skipForward(_ seconds: Double = 30) { seek(to: currentTime + seconds) }
    func skipBackward(_ seconds: Double = 15) { seek(to: currentTime - seconds) }

    func seek(to time: Double) {
        let upperBound = duration > 0 ? duration : time
        let target = max(0, min(time, upperBound))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        currentTime = target
        updateNowPlaying()
        persistState()
    }

    private func startPosition(for track: WatchTrack) -> Double {
        guard track.remembersPosition else { return 0 }
        return store.tracks.first(where: { $0.id == track.id })?.lastPosition ?? track.lastPosition
    }

    // MARK: - Engine

    private func loadCurrent(autoPlay: Bool, startAt: Double = 0) {
        guard queue.indices.contains(index) else { return }
        let track = queue[index]
        currentTrack = track
        currentTime = 0
        duration = track.duration
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
            currentTime = startAt
        }

        isPlaying = autoPlay
        if autoPlay {
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()
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

    private func handleTrackFinished() {
        if let track = currentTrack, track.remembersPosition {
            store.updatePosition(for: track.id, to: 0)
        }
        if index + 1 < queue.count {
            index += 1
            loadCurrent(autoPlay: true, startAt: startPosition(for: queue[index]))
        } else {
            seek(to: 0)
            pause()
        }
    }

    private func persistState() {
        guard let track = currentTrack, track.remembersPosition else { return }
        store.updatePosition(for: track.id, to: currentTime)
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
        let now = player.currentTime().seconds
        if now.isFinite, abs(currentTime - now) > 0.01 {
            currentTime = now
        }
        if duration <= 0,
           let itemDuration = player.currentItem?.duration.seconds,
           itemDuration.isFinite, itemDuration > 0 {
            duration = itemDuration
        }
        updateNowPlaying()
        if Date().timeIntervalSince(lastPersist) > 5 {
            persistState()
        }
    }

    // MARK: - Audio session

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // watchOS routes audio at the system level (Bluetooth when connected,
            // otherwise the built-in speaker). We set the playback category; the
            // user's preference is surfaced in Settings and steers the system
            // route picker rather than forcing a port here.
            try session.setCategory(.playback, mode: .default)
        } catch {
            print("[WatchPlaybackManager] audio session error: \(error)")
        }
    }

    // MARK: - Now Playing / remote commands

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in self?.resume(); return .success }
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePlayPause(); return .success }
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 30
            self?.skipForward(interval); return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            self?.skipBackward(interval); return .success
        }
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime); return .success
        }
    }

    private func updateNowPlaying() {
        // Note: watchOS ignores `MPNowPlayingInfoCenter.playbackState` for
        // third-party apps (it needs a private entitlement), so we don't set it —
        // only the now-playing metadata, which the system does surface.
        let center = MPNowPlayingInfoCenter.default()
        guard let track = currentTrack else {
            center.nowPlayingInfo = nil
            return
        }
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
    }
}

/// The watch's audio-output preference, surfaced in Settings.
enum WatchAudioOutput: String, CaseIterable, Identifiable {
    case bluetooth
    case speaker

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .bluetooth: return "Bluetooth"
        case .speaker: return "Speaker"
        }
    }
    var systemImage: String {
        switch self {
        case .bluetooth: return "headphones"
        case .speaker: return "speaker.wave.2.fill"
        }
    }
}
