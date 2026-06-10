import SwiftUI
import AVFoundation
import AVKit
import UIKit

struct PlayerView: View {
    @EnvironmentObject private var playback: PlaybackManager
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// Whether the control overlay is visible in fullscreen (landscape) video.
    @State private var showVideoControls = true

    /// Landscape (compact height) with a video track → fullscreen video.
    private var isFullscreenVideo: Bool {
        playback.currentTrack?.isVideo == true && verticalSizeClass == .compact
    }

    var body: some View {
        NavigationStack {
            Group {
                if let track = playback.currentTrack {
                    if track.isVideo, verticalSizeClass == .compact {
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
    }

    private func playerBody(_ track: Track) -> some View {
        VStack(spacing: 28) {
            Spacer()

            if track.isVideo {
                // Edge-to-edge video surface; transport is our own control suite
                // below, identical to audio's.
                NativeVideoPlayer(player: playback.player)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(Color.black)
            } else {
                artwork
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
            }
            .padding(.horizontal)

            scrubber
            controls

            Spacer()
        }
        .padding(.vertical)
    }

    /// Landscape video: the picture fills the screen (nav/tab bars hidden) and a
    /// tap anywhere toggles the floating control suite.
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
        .onAppear { showVideoControls = true }
    }

    private func hasArtist(_ track: Track) -> Bool {
        !track.artist.isEmpty && track.artist.lowercased() != "unknown"
    }

    private var artwork: some View {
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
        PlayerScrubber(progress: playback.progress) { time in
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
}

/// The slider + time labels. The only view observing `PlaybackProgress`, so the
/// 2 Hz playhead ticker re-renders just this and not whole screens.
private struct PlayerScrubber: View {
    @ObservedObject var progress: PlaybackProgress
    let onSeek: (Double) -> Void

    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0

    var body: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubTime : progress.currentTime },
                    set: { scrubTime = $0 }
                ),
                in: 0...max(progress.duration, 1),
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing {
                        onSeek(scrubTime)
                    }
                }
            )

            HStack {
                Text((isScrubbing ? scrubTime : progress.currentTime).asPlaybackTime)
                Spacer()
                Text(progress.duration.asPlaybackTime)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .padding(.horizontal)
    }
}

/// Native video surface backed by `AVPlayerViewController`, used purely for the
/// picture and PiP — its system controls are disabled so the app's own control
/// suite (the same one audio gets) drives playback.
private struct NativeVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.videoGravity = .resizeAspect
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
    }
}
