import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackManager

    /// Called after a track starts playing so the parent can switch to the player tab.
    let onPlay: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if library.tracks.isEmpty {
                    ContentUnavailableViewCompat(
                        title: "Your library is empty",
                        systemImage: "music.note.list",
                        description: "Downloaded tracks appear here, ready to play offline."
                    )
                } else {
                    List {
                        ForEach(library.tracks) { track in
                            TrackRow(track: track, isCurrent: playback.currentTrack?.id == track.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    playback.play(track, in: library.tracks)
                                    onPlay()
                                }
                        }
                        .onDelete { offsets in
                            library.delete(at: offsets)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Library")
        }
    }
}

private struct TrackRow: View {
    let track: Track
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isCurrent ? "speaker.wave.2.fill" : "music.note")
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if track.duration > 0 {
                Text(track.duration.asPlaybackTime)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 4)
    }
}
