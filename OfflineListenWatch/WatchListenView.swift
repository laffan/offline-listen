import SwiftUI

/// The Listen pane. Normally shows the watch's own now-playing — title/artist, a
/// read-only progress bar, and previous / play-pause / next, with the **Digital
/// Crown adjusting volume**. When the **phone** is playing and the watch isn't,
/// it repurposes itself into a remote control ("Controlling iPhone"): the same
/// transport, driving the phone instead.
struct WatchListenView: View {
    @EnvironmentObject private var playback: WatchPlaybackManager
    @State private var crownVolume: Double = 1.0

    var body: some View {
        if playback.showsRemote, let remote = playback.remote {
            RemoteControlView(remote: remote)
        } else if let track = playback.currentTrack {
            localPlayer(track)
        } else {
            ContentUnavailableCompat(
                title: "Nothing playing",
                systemImage: "play.circle",
                description: "Pick a track from the List to start listening."
            )
        }
    }

    // MARK: - Local playback

    private func localPlayer(_ track: WatchTrack) -> some View {
        let progress = playback.duration > 0 ? min(playback.currentTime / playback.duration, 1) : 0
        return VStack(spacing: 7) {
            NowPlayingLabels(title: track.title, artist: track.artist)

            ProgressView(value: progress)
                .tint(.accentColor)

            TimeRow(elapsed: playback.currentTime, duration: playback.duration)

            // Mirrors the lock screen: podcasts get jump back/forward, songs get
            // previous/next track.
            TransportButtons(
                isPodcast: track.isPodcast,
                isPlaying: playback.isPlaying,
                onBackward: { track.isPodcast ? playback.skipBackward() : playback.previous() },
                onPlayPause: { playback.togglePlayPause() },
                onForward: { track.isPodcast ? playback.skipForward() : playback.next() }
            )
        }
        .padding(.horizontal, 8)
        // Keep this view focused so the Digital Crown drives volume rather than
        // scrolling. (No ScrollView, so the content must fit.)
        .focusable()
        .digitalCrownRotation($crownVolume, from: 0, through: 1, by: 0.02,
                              sensitivity: .low, isContinuous: false,
                              isHapticFeedbackEnabled: true)
        .onChange(of: crownVolume) { newValue in
            playback.setVolume(Float(newValue))
        }
        .onAppear { crownVolume = Double(playback.currentVolume) }
    }
}

/// The Listen pane repurposed as a remote for the phone: the same transport,
/// topped with a "Controlling iPhone" banner, sending commands to the phone.
private struct RemoteControlView: View {
    @EnvironmentObject private var playback: WatchPlaybackManager
    let remote: RemoteNowPlaying

    private var progress: Double {
        remote.duration > 0 ? min(remote.elapsed / remote.duration, 1) : 0
    }

    var body: some View {
        VStack(spacing: 7) {
            Label("Controlling iPhone", systemImage: "iphone.radiowaves.left.and.right")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)

            NowPlayingLabels(title: remote.title, artist: remote.artist)

            ProgressView(value: progress)
                .tint(.accentColor)

            TimeRow(elapsed: remote.elapsed, duration: remote.duration)

            TransportButtons(
                isPodcast: remote.isPodcast,
                isPlaying: remote.isPlaying,
                onBackward: { remote.isPodcast ? playback.remoteSkipBackward() : playback.remotePrevious() },
                onPlayPause: { playback.remoteTogglePlayPause() },
                onForward: { remote.isPodcast ? playback.remoteSkipForward() : playback.remoteNext() }
            )
        }
        .padding(.horizontal, 8)
    }
}

// MARK: - Shared pieces

/// Centered title with an optional artist line beneath.
private struct NowPlayingLabels: View {
    let title: String
    let artist: String

    private var hasArtist: Bool {
        !artist.isEmpty && artist.lowercased() != "unknown"
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if hasArtist {
                Text(artist)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// Elapsed / duration readout beneath the scrubber.
private struct TimeRow: View {
    let elapsed: Double
    let duration: Double

    var body: some View {
        HStack {
            Text(elapsed.asPlaybackTime)
            Spacer()
            Text(duration.asPlaybackTime)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
}

/// The three-button transport row, shared by local playback and the phone remote.
/// Podcasts get jump back/forward; songs (and videos) get previous/next.
private struct TransportButtons: View {
    let isPodcast: Bool
    let isPlaying: Bool
    let onBackward: () -> Void
    let onPlayPause: () -> Void
    let onForward: () -> Void

    var body: some View {
        HStack(spacing: 22) {
            Button(action: onBackward) {
                Image(systemName: isPodcast ? "gobackward.15" : "backward.fill")
            }
            Button(action: onPlayPause) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 46))
            }
            Button(action: onForward) {
                Image(systemName: isPodcast ? "goforward.30" : "forward.fill")
            }
        }
        .font(.title2)
        .buttonStyle(.plain)
        .padding(.top, 2)
    }
}
