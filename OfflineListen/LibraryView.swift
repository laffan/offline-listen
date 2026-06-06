import SwiftUI
import UIKit

/// Identifiable payload so a share sheet can be presented via `.sheet(item:)`.
struct SharePayload: Identifiable {
    let id = UUID()
    let urls: [URL]
}

/// Bridges `UIActivityViewController` (the system share sheet) into SwiftUI so
/// downloaded files can be shared/exported (AirDrop, Files, Messages, …).
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackManager

    /// Called after a track starts playing so the parent can switch to the player tab.
    let onPlay: () -> Void

    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<Track.ID>()
    @State private var share: SharePayload?

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
                    trackList
                }
            }
            .navigationTitle("Library")
            .toolbar { toolbarContent }
            .environment(\.editMode, $editMode)
            .sheet(item: $share) { payload in
                ActivityView(items: payload.urls)
            }
        }
    }

    private var trackList: some View {
        List(selection: $selection) {
            ForEach(library.tracks) { track in
                row(for: track)
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private func row(for track: Track) -> some View {
        let base = TrackRow(track: track, isCurrent: playback.currentTrack?.id == track.id)
            .contentShape(Rectangle())
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    library.delete(track)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                Button {
                    share = SharePayload(urls: [track.fileURL])
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .tint(.blue)
            }

        if editMode.isEditing {
            base
        } else {
            base.onTapGesture {
                playback.play(track, in: library.tracks)
                onPlay()
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if editMode.isEditing {
            ToolbarItem(placement: .navigationBarLeading) {
                Menu {
                    Button {
                        shareSelected()
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .disabled(selection.isEmpty)

                    Button(role: .destructive) {
                        deleteSelected()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(selection.isEmpty)
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
                .disabled(selection.isEmpty)
            }
        }

        ToolbarItem(placement: .navigationBarTrailing) {
            Button(editMode.isEditing ? "Done" : "Select") {
                withAnimation {
                    if editMode.isEditing {
                        editMode = .inactive
                        selection.removeAll()
                    } else {
                        editMode = .active
                    }
                }
            }
        }
    }

    private func selectedTracks() -> [Track] {
        library.tracks.filter { selection.contains($0.id) }
    }

    private func shareSelected() {
        let urls = selectedTracks().map { $0.fileURL }
        guard !urls.isEmpty else { return }
        share = SharePayload(urls: urls)
    }

    private func deleteSelected() {
        for track in selectedTracks() {
            library.delete(track)
        }
        selection.removeAll()
        withAnimation { editMode = .inactive }
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
