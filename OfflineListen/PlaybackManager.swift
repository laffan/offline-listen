import Foundation
import AVFoundation
import MediaPlayer

#if canImport(KSPlayer)
import KSPlayer
#endif

/// Drives playback for the player screen and the lock screen / Control Center.
///
/// The success criterion is *offline background playback with the phone locked*.
/// That is achieved by three things, independent of the engine:
///   1. `UIBackgroundModes = [audio]` in Info.plist.
///   2. An `AVAudioSession` configured with the `.playback` category.
///   3. `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` for lock-screen UI.
///
/// The engine itself is **KSPlayer** when the package is linked, with an
/// `AVAudioPlayer` fallback so the app still plays audio before KSPlayer is added.
@MainActor
final class PlaybackManager: NSObject, ObservableObject {
    @Published var currentTrack: Track?
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0

    private var queue: [Track] = []
    private var index = 0
    private var ticker: Timer?

    #if canImport(KSPlayer)
    private var ksPlayer: KSMEPlayer?
    #else
    private var avPlayer: AVAudioPlayer?
    #endif

    override init() {
        super.init()
        configureAudioSession()
        setupRemoteCommands()
        #if canImport(KSPlayer)
        KSOptions.canBackgroundPlay = true
        #endif
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
        #if canImport(KSPlayer)
        ksPlayer?.seek(time: target) { [weak self] _ in
            Task { @MainActor in
                self?.currentTime = target
                self?.updateNowPlaying()
            }
        }
        #else
        avPlayer?.currentTime = target
        currentTime = target
        updateNowPlaying()
        #endif
    }

    // MARK: - Engine

    private func loadCurrent(autoPlay: Bool) {
        guard queue.indices.contains(index) else { return }
        let track = queue[index]
        currentTrack = track
        currentTime = 0
        duration = track.duration
        stopEngine()

        #if canImport(KSPlayer)
        let options = KSOptions()
        let player = KSMEPlayer(url: track.fileURL, options: options)
        ksPlayer = player
        if autoPlay { player.play() }
        #else
        do {
            let player = try AVAudioPlayer(contentsOf: track.fileURL)
            player.delegate = self
            player.prepareToPlay()
            avPlayer = player
            duration = player.duration
            if autoPlay { player.play() }
        } catch {
            print("[PlaybackManager] AVAudioPlayer error: \(error)")
        }
        #endif

        isPlaying = autoPlay
        try? AVAudioSession.sharedInstance().setActive(true)
        startTicker()
        updateNowPlaying()
    }

    private func resume() {
        #if canImport(KSPlayer)
        ksPlayer?.play()
        #else
        avPlayer?.play()
        #endif
        isPlaying = true
        try? AVAudioSession.sharedInstance().setActive(true)
        startTicker()
        updateNowPlaying()
    }

    private func pause() {
        #if canImport(KSPlayer)
        ksPlayer?.pause()
        #else
        avPlayer?.pause()
        #endif
        isPlaying = false
        updateNowPlaying()
    }

    private func stopEngine() {
        ticker?.invalidate()
        ticker = nil
        #if canImport(KSPlayer)
        ksPlayer?.pause()
        ksPlayer = nil
        #else
        avPlayer?.stop()
        avPlayer = nil
        #endif
    }

    // MARK: - Progress polling

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        #if canImport(KSPlayer)
        guard let player = ksPlayer else { return }
        currentTime = player.currentPlaybackTime
        if player.duration > 0 { duration = player.duration }
        #else
        guard let player = avPlayer else { return }
        currentTime = player.currentTime
        #endif

        if isPlaying, duration > 0, currentTime >= duration - 0.4 {
            handleTrackFinished()
        }
        updateNowPlaying()
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

#if !canImport(KSPlayer)
extension PlaybackManager: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.handleTrackFinished() }
    }
}
#endif
