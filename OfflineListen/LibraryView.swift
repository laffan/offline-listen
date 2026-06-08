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
    @State private var showArchived = false

    var body: some View {
        NavigationStack {
            Group {
                if library.activeTracks.isEmpty {
                    ContentUnavailableViewCompat(
                        title: library.tracks.isEmpty ? "Your library is empty" : "No active tracks",
                        systemImage: "music.note.list",
                        description: library.tracks.isEmpty
                            ? "Downloaded tracks appear here, ready to play offline."
                            : "Everything is archived — open the Archived folder above."
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
            .navigationDestination(isPresented: $showArchived) {
                ArchivedTracksView(onPlay: onPlay, share: $share)
            }
        }
    }

    private var trackList: some View {
        List(selection: $selection) {
            ForEach(library.activeTracks) { track in
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
                Button {
                    library.setArchived(track, true)
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                .tint(.indigo)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button {
                    library.setKind(track, .song)
                } label: {
                    Label("Song", systemImage: "music.note")
                }
                .tint(.gray)
                Button {
                    library.setKind(track, .podcast)
                } label: {
                    Label("Podcast", systemImage: "mic.fill")
                }
                .tint(.purple)
            }

        if editMode.isEditing {
            base
        } else {
            base.onTapGesture {
                playback.play(track, in: library.activeTracks)
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
                    Button {
                        archiveSelected()
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                    Button(role: .destructive) {
                        deleteSelected()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
                .disabled(selection.isEmpty)
            }
        } else if !library.archivedTracks.isEmpty {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    showArchived = true
                } label: {
                    Label("Archived (\(library.archivedTracks.count))", systemImage: "archivebox")
                }
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
            .disabled(library.activeTracks.isEmpty && !editMode.isEditing)
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

    private func archiveSelected() {
        for track in selectedTracks() {
            library.setArchived(track, true)
        }
        endEditing()
    }

    private func deleteSelected() {
        for track in selectedTracks() {
            library.delete(track)
        }
        endEditing()
    }

    private func endEditing() {
        selection.removeAll()
        withAnimation { editMode = .inactive }
    }
}

/// The "Archived" folder: a simple list of archived tracks with swipe actions to
/// unarchive, share, or delete. Tapping plays within the archived set.
struct ArchivedTracksView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackManager

    let onPlay: () -> Void
    @Binding var share: SharePayload?

    var body: some View {
        Group {
            if library.archivedTracks.isEmpty {
                ContentUnavailableViewCompat(
                    title: "No archived tracks",
                    systemImage: "archivebox",
                    description: "Swipe a track in your library and tap Archive to move it here."
                )
            } else {
                List {
                    ForEach(library.archivedTracks) { track in
                        TrackRow(track: track, isCurrent: playback.currentTrack?.id == track.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                playback.play(track, in: library.archivedTracks)
                                onPlay()
                            }
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
                                Button {
                                    library.setArchived(track, false)
                                } label: {
                                    Label("Unarchive", systemImage: "tray.and.arrow.up")
                                }
                                .tint(.indigo)
                            }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Archived")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TrackRow: View {
    let track: Track
    let isCurrent: Bool

    private var hasArtist: Bool {
        !track.artist.isEmpty && track.artist.lowercased() != "unknown"
    }

    private var progress: Double {
        track.duration > 0 ? min(track.lastPosition / track.duration, 1) : 0
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: track.kind == .podcast ? "mic.fill" : "music.note")
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.body)
                    .lineLimit(1)

                if track.kind == .podcast {
                    ProgressView(value: progress)
                        .tint(.accentColor)
                    if track.duration > 0 {
                        Text("\(track.lastPosition.asPlaybackTime) / \(track.duration.asPlaybackTime)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } else if hasArtist {
                    Text(track.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if track.kind != .podcast, track.duration > 0 {
                Text(track.duration.asPlaybackTime)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 4)
    }
}
