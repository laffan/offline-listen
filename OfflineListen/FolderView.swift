import SwiftUI

/// A user folder: its tracks with tap-to-play and swipe actions, plus
/// drag-to-reorder via the Reorder toolbar toggle. Folders can nest — any
/// subfolders list above the tracks — and a mixtape folder shows its cover
/// banner up top and an Edit Cover button below its tracks.
struct FolderDetailView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackManager

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
    /// The subfolder a swipe-Delete is asking about (see `DeleteFolderConfirm`).
    @State private var deletingFolder: Folder?
    @State private var editingCover = false
    /// The album-art sheet, and the change/reset dialog a tap on the sleeve
    /// opens first.
    @State private var editingAlbumArt = false
    @State private var albumArtOptions = false

    private var folder: Folder? {
        library.folders.first { $0.id == folderID }
    }

    private var isMixtape: Bool {
        folder?.isMixtape ?? false
    }

    private var isAlbum: Bool {
        folder.map { library.isAlbumFolder($0) } ?? false
    }

    /// The one artist an album belongs to — what the **Discography** button at
    /// the foot of the list opens. Nil for a folder that isn't an album, and
    /// for an album whose tracks name more than one artist: a compilation has
    /// no single catalogue to send anyone to.
    private var albumArtist: String? {
        guard isAlbum else { return nil }
        return library.folderArtist(of: folderID)
    }

    private var tracks: [Track] {
        library.tracks(in: folderID)
    }

    private var subfolders: [Folder] {
        library.childFolders(of: folderID)
    }

    var body: some View {
        Group {
            // An album keeps its screen even while empty — the sleeve is where
            // its art is set, so a placeholder would strand it.
            if tracks.isEmpty && subfolders.isEmpty && !isMixtape && !isAlbum {
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
        .editModeEnvironment($editMode)
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
        .sheet(isPresented: $editingAlbumArt) {
            if let folder {
                AlbumCoverEditor(folder: folder)
            }
        }
        .confirmationDialog("Album Art", isPresented: $albumArtOptions, titleVisibility: .visible) {
            Button("Change Album Art") { editingAlbumArt = true }
            // Only offered once there's something of the user's to undo.
            if folder?.customArtworkFileName != nil {
                Button("Reset Album Art", role: .destructive) {
                    if let folder { library.resetAlbumArtwork(folder) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(folder?.artworkFileName == nil
                 ? "The art is cropped to a square and applied to every song in the folder. Resetting drops it for a colour."
                 : "The art is cropped to a square and applied to every song in the folder. Resetting puts back the cover this album was downloaded with.")
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
        .deleteFolderConfirm(for: $deletingFolder)
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
            } else {
                coverHeader
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
                // An album is one artist's record, so the catalogue it came
                // from is one tap from the record itself.
                if let albumArtist {
                    discographyRow(albumArtist)
                }
            }
        }
        .listStyle(.plain)
        .miniPlayerClearance()
    }

    /// The album sleeve, when this folder has one to show: its downloaded
    /// cover, the one the user framed, or the artwork every track in it
    /// shares. Sits above everything else, so a folder that *is* a record
    /// looks like one. A mixtape has its own banner instead and never reaches
    /// here.
    ///
    /// On an **album** the sleeve is also the way into its art: tapping it
    /// offers to change the cover or reset it. A folder that merely happens to
    /// show shared artwork isn't one, so its sleeve stays a picture.
    @ViewBuilder
    private var coverHeader: some View {
        if let folder {
            let cover = FolderCover.image(for: folder, tracks: tracks)
            if library.isAlbumFolder(folder) {
                Section {
                    Button {
                        albumArtOptions = true
                    } label: {
                        AlbumCoverArt(folder: folder, image: cover, cornerRadius: 10)
                            .frame(width: 220, height: 220)
                            .shadow(radius: 6, y: 3)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Album art — change or reset")
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                }
            } else if let cover {
                Section {
                    Image(platformImage: cover)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 220, maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .shadow(radius: 6, y: 3)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                }
            }
        }
    }

    /// The **Discography** row at the foot of an album: the artist's catalogue,
    /// read live from Spotify — the same browser the Every Noise map and a
    /// Browse Artist source push.
    private func discographyRow(_ artist: String) -> some View {
        NavigationLink(value: LibraryRoute.discography(artist)) {
            Label("Discography", systemImage: "square.stack")
                .frame(maxWidth: .infinity)
        }
        .accessibilityLabel("Browse \(artist)'s discography")
        .listRowSeparator(.hidden)
    }

    private func subfolderRow(_ subfolder: Folder) -> some View {
        NavigationLink(value: LibraryRoute.folder(subfolder.id)) {
            FolderRowLabel(folder: subfolder,
                           count: library.trackCount(in: subfolder.id),
                           playingHere: isPlaying(in: subfolder))
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deletingFolder = subfolder
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
        return library.folder(subfolder.id, contains: id)
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
                GetAlbumArtButton(track: track)
                ConvertFormatButton(track: track)
                if track.hasChapters {
                    Button {
                        splittingTrack = track
                    } label: {
                        Label("Break Chapters into Playlist", systemImage: "list.bullet.indent")
                    }
                }
                TrackSourceButtons(track: track)
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

/// An album folder's artist, as their live catalogue — the shared
/// `DiscographyBrowserView` behind the **Discography** button at the foot of
/// an album. All a library folder knows about the artist is their *name*, so
/// the provider is left to resolve it through Spotify's search, exactly as a
/// typed Artist source does.
///
/// It needs the Settings ▸ Spotify credentials, like every other way into the
/// catalogue; without them it says so rather than pushing an empty screen.
struct LibraryDiscographyView: View {
    let artistName: String

    @EnvironmentObject private var spotifySettings: SpotifySettingsStore
    @EnvironmentObject private var aiSettings: AISettingsStore
    @EnvironmentObject private var browse: BrowseStore

    var body: some View {
        if let client = spotifySettings.client {
            DiscographyBrowserView(
                title: artistName,
                provider: SpotifyDiscographyProvider(client: client,
                                                     artistName: artistName,
                                                     aiSettings: aiSettings),
                // Same as the Every Noise push: liking a record enough to
                // open its catalogue is the moment you'd follow the artist.
                addSource: DiscographyAddSource(
                    isAdded: {
                        browse.sources.contains {
                            $0.kind == .artist
                                && $0.artistSourceMode == .spotifyDiscography
                                && $0.input.caseInsensitiveCompare(artistName) == .orderedSame
                        }
                    },
                    add: {
                        browse.addSource(kind: .artist, name: artistName,
                                         input: artistName,
                                         artistMode: .spotifyDiscography)
                    }))
        } else {
            ContentUnavailableViewCompat(
                title: "Couldn't load the discography",
                systemImage: "exclamationmark.triangle",
                description: "Add Spotify credentials in Settings ▸ Spotify first."
            )
            .navigationTitle(artistName)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// The Library's **Inbox** tab: every active track that hasn't been listened to
/// yet. Tracks leave automatically once playback starts, or via Mark Played.
struct InboxView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackManager

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
                                GetAlbumArtButton(track: track)
                                ConvertFormatButton(track: track)
                                if track.hasChapters {
                                    Button {
                                        splittingTrack = track
                                    } label: {
                                        Label("Break Chapters into Playlist", systemImage: "list.bullet.indent")
                                    }
                                }
                                TrackSourceButtons(track: track)
                            }
                    }
                }
                .listStyle(.plain)
                .miniPlayerClearance()
            }
        }
        // No title of its own — it's a tab of the Library, not a screen you
        // pushed into, and the tab bar above already names it.
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

/// The Library's **Recent** tab: what you've played, most recent first.
///
/// A log rather than a place — the tracks live wherever they normally do, and
/// nothing here moves or deletes them. A track appears once per listen (with
/// consecutive repeats collapsed), which is why rows are keyed by the *entry*
/// and not by the track. Playback continues through the distinct tracks in the
/// list, so a repeat doesn't send `next` backwards.
struct RecentTracksView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackManager

    let onPlay: () -> Void
    @Binding var share: SharePayload?

    @State private var editingTrack: Track?
    @State private var chapterContext: ChapterContext?
    @State private var confirmingClear = false

    private var entries: [RecentListenRow] { library.recentListenEntries }
    /// The playback queue: each track once, in the order it was last heard.
    private var queue: [Track] { library.recentTracks }

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableViewCompat(
                    title: "Nothing played yet",
                    systemImage: "clock.arrow.circlepath",
                    description: "Tracks appear here as you play them — most recent first."
                )
            } else {
                List {
                    ForEach(entries) { pair in
                        TrackRow(
                            track: pair.track,
                            isCurrent: playback.currentTrack?.id == pair.track.id,
                            onShowChapters: {
                                chapterContext = ChapterContext(track: pair.track, queue: queue)
                            },
                            trailingDetail: relativeDate(pair.entry.date)
                        )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                playback.play(pair.track, in: queue)
                                onPlay()
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                // Removes the log entry only — the track itself
                                // is untouched, wherever it lives.
                                Button(role: .destructive) {
                                    library.removeRecentListen(pair.entry.id)
                                } label: {
                                    Label("Remove", systemImage: "clock.badge.xmark")
                                }
                                Button {
                                    share = SharePayload(urls: [pair.track.fileURL])
                                } label: {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                                .tint(.blue)
                            }
                            .contextMenu {
                                Button {
                                    editingTrack = pair.track
                                } label: {
                                    Label("Edit Metadata", systemImage: "pencil")
                                }
                                SendToWatchButton(track: pair.track)
                                AIOrganizeButton(track: pair.track)
                                GetAlbumArtButton(track: pair.track)
                                ConvertFormatButton(track: pair.track)
                                TrackSourceButtons(track: pair.track)
                            }
                    }
                }
                .listStyle(.plain)
                .miniPlayerClearance()
            }
        }
        // See InboxView: a tab of the Library, so no title of its own.
        .editMetadataSheet(for: $editingTrack)
        .sheet(item: $chapterContext) { context in
            ChapterListView(track: context.track, queue: context.queue, onPlay: onPlay)
        }
        .toolbar {
            if !entries.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Clear", role: .destructive) { confirmingClear = true }
                }
            }
        }
        .confirmationDialog("Clear the Recent list?",
                            isPresented: $confirmingClear,
                            titleVisibility: .visible) {
            Button("Clear", role: .destructive) { library.clearRecentListens() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This only empties the list of what you've played. No tracks are deleted.")
        }
    }

    /// "2h ago" / "yesterday" — when this listen happened, on the row's
    /// trailing edge where a library row shows its duration.
    private func relativeDate(_ date: Date) -> String {
        date.formatted(.relative(presentation: .numeric))
    }
}
