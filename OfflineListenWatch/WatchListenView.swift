import SwiftUI

/// The Listen pane: now-playing title/artist, a read-only progress bar, and
/// previous / play-pause / next. No nav header; the **Digital Crown adjusts
/// volume** while this pane is showing.
struct WatchListenView: View {
    @EnvironmentObject private var playback: WatchPlaybackManager
    @State private var crownVolume: Double = 1.0

    private var progress: Double {
        guard playback.duration > 0 else { return 0 }
        return min(playback.currentTime / playback.duration, 1)
    }

    var body: some View {
        if let track = playback.currentTrack {
            VStack(spacing: 7) {
                VStack(spacing: 2) {
                    Text(track.title)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    if !track.artist.isEmpty, track.artist.lowercased() != "unknown" {
                        Text(track.artist)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                ProgressView(value: progress)
                    .tint(.accentColor)

                HStack {
                    Text(playback.currentTime.asPlaybackTime)
                    Spacer()
                    Text(playback.duration.asPlaybackTime)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()

                HStack(spacing: 22) {
                    Button { playback.previous() } label: {
                        Image(systemName: "backward.fill")
                    }
                    Button { playback.togglePlayPause() } label: {
                        Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 46))
                    }
                    Button { playback.next() } label: {
                        Image(systemName: "forward.fill")
                    }
                }
                .font(.title2)
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
            .padding(.horizontal, 8)
            // Keep this view focused so the Digital Crown drives volume rather
            // than scrolling. (No ScrollView, so the content must fit.)
            .focusable()
            .digitalCrownRotation($crownVolume, from: 0, through: 1, by: 0.02,
                                  sensitivity: .low, isContinuous: false,
                                  isHapticFeedbackEnabled: true)
            .onChange(of: crownVolume) { newValue in
                playback.setVolume(Float(newValue))
            }
            .onAppear { crownVolume = Double(playback.currentVolume) }
        } else {
            ContentUnavailableCompat(
                title: "Nothing playing",
                systemImage: "play.circle",
                description: "Pick a track from the List to start listening."
            )
        }
    }
}
