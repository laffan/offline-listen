import Foundation
import AVFoundation
import MediaPlayer

/// Drives playback for the player screen and the lock screen / Control Center.
///
/// The success criterion is *offline background playback with the phone locked*.
/// That is achieved by three things:
///   1. `UIBackgroundModes = [audio]` in Info.plist.
///   2. An `AVAudioSession` configured with the `.playback` category.
///   3. `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` for lock-screen UI.
///
/// Playback uses `AVAudioPlayer`, which plays the AAC/`.m4a` files produced by
/// the download pipeline and continues in the background once the audio session
/// is active.
@MainActor
final class PlaybackManager: NSObject, ObservableObject {
    @Published var currentTrack: Track?
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0

    private var queue: [Track] = []
    private var index = 0
    private var ticker: Timer?
    private var player: AVAudioPlayer?

    private var hasRestored = false
    private var lastPersist = Date.distantPast

    private enum Keys {
        static let trackID = "lastTrackID"
        static let position = "lastPosition"
    }

    override init() {
        super.init()
        configureAudioSession()
        setupRemoteCommands()
    }

    // MARK: - Public control

    func play(_ track: Track, in tracks: [Track]) {
        queue = tracks.isEmpty ? [track] : tracks
        index = queue.firstIndex(of: track) ?? 0
        loadCurrent(autoPlay: true)
    }

    func togglePlayPause() {
        guard currentTrack != nil else { return }
        if isPlaying { pause() } else { resume() }
    }

    func next() {
        guard !queue.isEmpty else { return }
        index = (index + 1) % queue.count
        loadCurrent(autoPlay: true)
    }

    func previous() {
        guard !queue.isEmpty else { return }
        // Restart current track if we're more than 3s in, else go to previous.
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        index = (index - 1 + queue.count) % queue.count
        loadCurrent(autoPlay: true)
    }

    func seek(to time: Double) {
        let target = max(0, min(time, duration))
        player?.currentTime = target
        currentTime = target
        updateNowPlaying()
        persistState()
    }

    /// Restores the track and playhead from the last session (paused), unless
    /// playback is already underway. Call once on launch with the library.
    func restoreLastSession(in tracks: [Track]) {
        guard !hasRestored else { return }
        hasRestored = true
        guard currentTrack == nil else { return }

        let defaults = UserDefaults.standard
        guard let idString = defaults.string(forKey: Keys.trackID),
              let id = UUID(uuidString: idString),
              let track = tracks.first(where: { $0.id == id }) else { return }

        queue = tracks
        index = tracks.firstIndex(of: track) ?? 0
        loadCurrent(autoPlay: false, startAt: defaults.double(forKey: Keys.position))
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
        currentTime = 0
        duration = track.duration
        stopEngine()

        do {
            let player = try AVAudioPlayer(contentsOf: track.fileURL)
            player.delegate = self
            player.prepareToPlay()
            self.player = player
            duration = player.duration
            if startAt > 0 {
                let clamped = min(startAt, player.duration)
                player.currentTime = clamped
                currentTime = clamped
            }
            if autoPlay { player.play() }
        } catch {
            print("[PlaybackManager] AVAudioPlayer error: \(error)")
        }

        isPlaying = autoPlay
        if autoPlay {
            try? AVAudioSession.sharedInstance().setActive(true)
            startTicker()
        }
        updateNowPlaying()
        persistState()
    }

    private func resume() {
        player?.play()
        isPlaying = true
        try? AVAudioSession.sharedInstance().setActive(true)
        startTicker()
        updateNowPlaying()
    }

    private func pause() {
        player?.pause()
        isPlaying = false
        updateNowPlaying()
        persistState()
    }

    private func persistState() {
        guard let track = currentTrack else { return }
        let defaults = UserDefaults.standard
        defaults.set(track.id.uuidString, forKey: Keys.trackID)
        defaults.set(currentTime, forKey: Keys.position)
        lastPersist = Date()
    }

    private func stopEngine() {
        ticker?.invalidate()
        ticker = nil
        player?.stop()
        player = nil
    }

    // MARK: - Progress polling

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let player else { return }
        currentTime = player.currentTime
        updateNowPlaying()
        if Date().timeIntervalSince(lastPersist) > 5 {
            persistState()
        }
    }

    private func handleTrackFinished() {
        if queue.count > 1 {
            next()
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

        center.playCommand.addTarget { [weak self] _ in
            self?.resume(); return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pause(); return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause(); return .success
        }
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
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime)
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
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
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

extension PlaybackManager: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.handleTrackFinished() }
    }
}
