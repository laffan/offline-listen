import SwiftUI
import AVFoundation
import UIKit

struct PlayerView: View {
    @EnvironmentObject private var playback: PlaybackManager

    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0

    var body: some View {
        NavigationStack {
            Group {
                if let track = playback.currentTrack {
                    playerBody(track)
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
    }

    private func playerBody(_ track: Track) -> some View {
        VStack(spacing: 28) {
            Spacer()

            if track.isVideo {
                VideoSurface(player: playback.player)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal)
                    .shadow(radius: 12, y: 6)
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
        .padding()
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
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubTime : playback.currentTime },
                    set: { scrubTime = $0 }
                ),
                in: 0...max(playback.duration, 1),
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing {
                        playback.seek(to: scrubTime)
                    }
                }
            )

            HStack {
                Text((isScrubbing ? scrubTime : playback.currentTime).asPlaybackTime)
                Spacer()
                Text(playback.duration.asPlaybackTime)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .padding(.horizontal)
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

/// A plain `AVPlayerLayer`-backed view (no built-in controls — we use our own).
private struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        view.playerLayer.player = player
    }

    final class PlayerLayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
