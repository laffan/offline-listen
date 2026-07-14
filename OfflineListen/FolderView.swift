import SwiftUI

/// A user folder: its tracks with tap-to-play and swipe actions, plus
/// drag-to-reorder via the Reorder toolbar toggle. Folders can nest — any
/// subfolders list above the tracks — and a mixtape folder shows its cover
/// banner up top and an Edit Cover button below its tracks.
struct FolderDetailView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackManager
    @Environment(\.openURL) private var openURL

    let folderID: UUID
    let onPlay: () -> Void
    @Binding var share: SharePayload?

    @State private var editMode: EditMode = .inactive
    @State private var editingTrack: Track?
    @State private var chapterContext: ChapterContext?
    @State private var splittingTrack: Track?
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renamingFolder: Folder?
    @State private var renameText = ""
    @State private var editingCover = false

    private var folder: Folder? {
        library.folders.first { $0.id == folderID }
    }

    private var isMixtape: Bool {
        folder?.isMixtape ?? false
    }

    private var tracks: [Track] {
        library.tracks(in: folderID)
    }

    private var subfolders: [Folder] {
        library.childFolders(of: folderID)
    }

    var body: some View {
        Group {
            if tracks.isEmpty && subfolders.isEmpty && !isMixtape {
                ContentUnavailableViewCompat(
                    title: "Empty folder",
                    systemImage: "folder",
                    description: "Touch and hold a track in your library and choose Move to Folder to add it here."
                )
            } else {
                folderList
            }
        }
        .navigationTitle(isMixtape ? "" : (folder?.name ?? "Folder"))
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, $editMode)
        .editMetadataSheet(for: $editingTrack)
        .breakChaptersConfirm(for: $splittingTrack)
        .sheet(item: $chapterContext) { context in
            ChapterListView(track: context.track, queue: context.queue, onPlay: onPlay)
        }
        .sheet(isPresented: $editingCover) {
            if let folder {
                MixtapeCoverEditor(folder: folder)
            }
        }
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                library.createFolder(named: newFolderName, parent: folderID)
                newFolderName = ""
            }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        }
        .alert("Rename Folder", isPresented: renameAlertPresented, presenting: renamingFolder) { subfolder in
            TextField("Folder name", text: $renameText)
            Button("Rename") { library.renameFolder(subfolder, to: renameText) }
            Button("Cancel", role: .cancel) {}
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                // Mixtapes can't contain folders, so no subfolder creation there.
                if !isMixtape && !editMode.isEditing {
                    Button {
                        newFolderName = ""
                        showNewFolder = true
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                }
                Button(editMode.isEditing ? "Done" : "Reorder") {
                    withAnimation {
                        editMode = editMode.isEditing ? .inactive : .active
                    }
                }
                .disabled(tracks.count < 2 && !editMode.isEditing)
            }
        }
    }

    private var renameAlertPresented: Binding<Bool> {
        Binding(
            get: { renamingFolder != nil },
            set: { if !$0 { renamingFolder = nil } }
        )
    }

    private var folderList: some View {
        List {
            if let folder, folder.isMixtape {
                Section {
                    MixtapeHeaderBanner(folder: folder)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                }
            }
            if !subfolders.isEmpty {
                Section("Folders") {
                    ForEach(subfolders) { subfolder in
                        subfolderRow(subfolder)
                    }
                }
            }
            Section {
                ForEach(tracks) { track in
                    row(for: track)
                }
                .onMove { source, destination in
                    library.moveTracks(in: folderID, fromOffsets: source, toOffset: destination)
                }
                if isMixtape {
                    Button {
                        editingCover = true
                    } label: {
                        Label("Edit Cover", systemImage: "photo")
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.vertical, 4)
                    // No trailing rule under the last row — with one it reads
                    // as inset rather than centered.
                    .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
    }

    private func subfolderRow(_ subfolder: Folder) -> some View {
        NavigationLink(value: LibraryRoute.folder(subfolder.id)) {
            FolderRowLabel(folder: subfolder,
                           count: library.tracks(in: subfolder.id).count,
                           playingHere: isPlaying(in: subfolder))
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                library.deleteFolder(subfolder)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                renameText = subfolder.name
                renamingFolder = subfolder
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.orange)
            Button {
                library.setFolderArchived(subfolder, true)
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .tint(.indigo)
        }
        .contextMenu {
            FolderContextMenu(folder: subfolder)
        }
    }

    private func isPlaying(in subfolder: Folder) -> Bool {
        guard let id = playback.currentTrack?.id else { return false }
        return library.tracks(in: subfolder.id).contains { $0.id == id }
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
                    editingTrack = track
                } label: {
                    Label("Edit Metadata", systemImage: "pencil")
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
                SyncToLocalButton(track: track)
                SendToWatchButton(track: track)
                AIOrganizeButton(track: track)
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
                // A folder is a curated playlist: play straight through in list
                // order, not restricted to the first track's media type.
                playback.play(track, in: tracks, restrictToCategory: false)
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

    @State private var editingTrack: Track?
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
                                    editingTrack = track
                                } label: {
                                    Label("Edit Metadata", systemImage: "pencil")
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
                                SyncToLocalButton(track: track)
                                SendToWatchButton(track: track)
                                AIOrganizeButton(track: track)
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
        .editMetadataSheet(for: $editingTrack)
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
