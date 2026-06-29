import SwiftUI

/// A user folder: its tracks with tap-to-play and swipe actions, plus
/// drag-to-reorder via the Reorder toolbar toggle.
struct FolderDetailView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackManager
    @Environment(\.openURL) private var openURL

    let folderID: UUID
    let onPlay: () -> Void
    @Binding var share: SharePayload?

    @State private var editMode: EditMode = .inactive
    @State private var renamingTrack: Track?
    @State private var chapterContext: ChapterContext?
    @State private var splittingTrack: Track?

    private var folder: Folder? {
        library.folders.first { $0.id == folderID }
    }

    private var tracks: [Track] {
        library.tracks(in: folderID)
    }

    var body: some View {
        Group {
            if tracks.isEmpty {
                ContentUnavailableViewCompat(
                    title: "Empty folder",
                    systemImage: "folder",
                    description: "Touch and hold a track in your library and choose Move to Folder to add it here."
                )
            } else {
                List {
                    ForEach(tracks) { track in
                        row(for: track)
                    }
                    .onMove { source, destination in
                        library.moveTracks(in: folderID, fromOffsets: source, toOffset: destination)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(folder?.name ?? "Folder")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, $editMode)
        .renameTrackAlert(for: $renamingTrack)
        .breakChaptersConfirm(for: $splittingTrack)
        .sheet(item: $chapterContext) { context in
            ChapterListView(track: context.track, queue: context.queue, onPlay: onPlay)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(editMode.isEditing ? "Done" : "Reorder") {
                    withAnimation {
                        editMode = editMode.isEditing ? .inactive : .active
                    }
                }
                .disabled(tracks.count < 2 && !editMode.isEditing)
            }
        }
    }

    @ViewBuilder
    private func row(for track: Track) -> some View {
        let base = TrackRow(
            track: track,
            isCurrent: playback.currentTrack?.id == track.id,
            onShowChapters: { chapterContext = ChapterContext(track: track, queue: tracks) }
        )
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
                    library.setFolder(track, nil)
                } label: {
                    Label("Remove", systemImage: "folder.badge.minus")
                }
                .tint(.indigo)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                // Song/podcast classification only applies to audio tracks.
                if !track.isVideo {
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
            }
            .contextMenu {
                Button {
                    renamingTrack = track
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Menu {
                    Button {
                        library.moveToInbox(track)
                    } label: {
                        Label("Inbox", systemImage: "tray")
                    }
                    ForEach(library.activeFolders.filter { $0.id != folderID }) { other in
                        Button {
                            library.setFolder(track, other.id)
                        } label: {
                            Label(other.name, systemImage: "folder")
                        }
                    }
                    Button(role: .destructive) {
                        library.setFolder(track, nil)
                    } label: {
                        Label("Remove from Folder", systemImage: "folder.badge.minus")
                    }
                } label: {
                    Label("Move to Folder", systemImage: "folder")
                }
                if track.hasChapters {
                    Button {
                        splittingTrack = track
                    } label: {
                        Label("Break Chapters into Playlist", systemImage: "list.bullet.indent")
                    }
                }
                if let url = URL(string: track.sourceURL) {
                    Button {
                        openURL(url)
                    } label: {
                        Label("View Original", systemImage: "safari")
                    }
                }
            }

        if editMode.isEditing {
            base
        } else {
            base.onTapGesture {
                playback.play(track, in: tracks)
                onPlay()
            }
        }
    }
}

/// The pinned Inbox: every active track that hasn't been listened to yet.
/// Tracks leave automatically once playback starts, or via Mark Played.
struct InboxView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackManager
    @Environment(\.openURL) private var openURL

    let onPlay: () -> Void
    @Binding var share: SharePayload?

    @State private var renamingTrack: Track?
    @State private var chapterContext: ChapterContext?
    @State private var splittingTrack: Track?

    private var tracks: [Track] {
        library.inboxTracks
    }

    var body: some View {
        Group {
            if tracks.isEmpty {
                ContentUnavailableViewCompat(
                    title: "Inbox zero",
                    systemImage: "tray",
                    description: "New downloads land here until you listen to them."
                )
            } else {
                List {
                    ForEach(tracks) { track in
                        TrackRow(
                            track: track,
                            isCurrent: playback.currentTrack?.id == track.id,
                            onShowChapters: { chapterContext = ChapterContext(track: track, queue: tracks) }
                        )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                playback.play(track, in: tracks)
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
                                    library.markPlayed(track.id)
                                } label: {
                                    Label("Mark Played", systemImage: "checkmark.circle")
                                }
                                .tint(.green)
                            }
                            .contextMenu {
                                Button {
                                    renamingTrack = track
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                if !library.activeFolders.isEmpty {
                                    Menu {
                                        ForEach(library.activeFolders) { folder in
                                            Button {
                                                // Leaving the Inbox for a folder also
                                                // clears the unlistened flag — the track
                                                // has been filed, so it shouldn't show
                                                // in both places.
                                                library.setFolder(track, folder.id)
                                                library.markPlayed(track.id)
                                            } label: {
                                                Label(folder.name, systemImage: "folder")
                                            }
                                        }
                                    } label: {
                                        Label("Move to Folder", systemImage: "folder")
                                    }
                                }
                                if track.hasChapters {
                                    Button {
                                        splittingTrack = track
                                    } label: {
                                        Label("Break Chapters into Playlist", systemImage: "list.bullet.indent")
                                    }
                                }
                                if let url = URL(string: track.sourceURL) {
                                    Button {
                                        openURL(url)
                                    } label: {
                                        Label("View Original", systemImage: "safari")
                                    }
                                }
                            }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Inbox")
        .navigationBarTitleDisplayMode(.inline)
        .renameTrackAlert(for: $renamingTrack)
        .breakChaptersConfirm(for: $splittingTrack)
        .sheet(item: $chapterContext) { context in
            ChapterListView(track: context.track, queue: context.queue, onPlay: onPlay)
        }
        .toolbar {
            if !tracks.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Mark All Played") {
                        library.markAllPlayed()
                    }
                }
            }
        }
    }
}
