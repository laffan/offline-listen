import SwiftUI

/// The Listen pane: the now-playing transport — title/artist, a scrubber, and
/// play/pause, skip ±, and next/previous. Mirrors the iPhone player's core suite.
struct WatchListenView: View {
    @EnvironmentObject private var playback: WatchPlaybackManager

    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false

    var body: some View {
        NavigationStack {
            content
        }
    }

    private var content: some View {
        ScrollView {
            if let track = playback.currentTrack {
                VStack(spacing: 10) {
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

                    scrubber

                    HStack {
                        Text(playback.currentTime.asPlaybackTime)
                        Spacer()
                        Text(playback.duration.asPlaybackTime)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                    transport
                }
                .padding(.vertical, 4)
            } else {
                ContentUnavailableCompat(
                    title: "Nothing playing",
                    systemImage: "play.circle",
                    description: "Pick a track from the List to start listening."
                )
                .padding(.top, 20)
            }
        }
        .navigationTitle("Listen")
        .onChange(of: playback.currentTime) { newValue in
            if !isScrubbing { scrubValue = newValue }
        }
    }

    private var scrubber: some View {
        Slider(
            value: Binding(
                get: { isScrubbing ? scrubValue : playback.currentTime },
                set: { scrubValue = $0 }
            ),
            in: 0...max(playback.duration, 1),
            onEditingChanged: { editing in
                isScrubbing = editing
                if !editing { playback.seek(to: scrubValue) }
            }
        )
        .tint(.accentColor)
    }

    private var transport: some View {
        VStack(spacing: 10) {
            HStack(spacing: 18) {
                Button { playback.previous() } label: {
                    Image(systemName: "backward.fill")
                }
                Button { playback.togglePlayPause() } label: {
                    Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.largeTitle)
                }
                Button { playback.next() } label: {
                    Image(systemName: "forward.fill")
                }
            }
            HStack(spacing: 28) {
                Button { playback.skipBackward() } label: {
                    Image(systemName: "gobackward.15")
                }
                Button { playback.skipForward() } label: {
                    Image(systemName: "goforward.30")
                }
            }
            .font(.title3)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}
