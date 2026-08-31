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
    /// The artist a track's **View Discography** asked for.
    @State private var discographyRequest: DiscographyRequest?

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
        .discographySheet(for: $discographyRequest)
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
                ViewDiscographyButton(track: track, request: $discographyRequest)
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
    /// The artist a track's **View Discography** asked for.
    @State private var discographyRequest: DiscographyRequest?
    /// Multi-select, the same shape the **All** tab has: an inbox filled by a
    /// batch download is cleared in batches too.
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<Track.ID>()

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
                List(selection: $selection) {
                    ForEach(tracks) { track in
                        let row = TrackRow(
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
                                ViewDiscographyButton(track: track, request: $discographyRequest)
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
                        // Selecting is a mode you're in *instead* of playing:
                        // a tap ticks the row rather than starting the track.
                        if editMode.isEditing {
                            row
                        } else {
                            row.onTapGesture {
                                playback.play(track, in: tracks)
                                onPlay()
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .miniPlayerClearance()
            }
        }
        // No title of its own — it's a tab of the Library, not a screen you
        // pushed into, and the tab bar above already names it.
        .editModeEnvironment($editMode)
        .editMetadataSheet(for: $editingTrack)
        .breakChaptersConfirm(for: $splittingTrack)
        .discographySheet(for: $discographyRequest)
        .sheet(item: $chapterContext) { context in
            ChapterListView(track: context.track, queue: context.queue, onPlay: onPlay)
        }
        // Emptying the Inbox from under an open selection would leave a Done
        // button over nothing.
        .onChange(of: tracks.isEmpty) { empty in
            if empty, editMode.isEditing { endEditing() }
        }
        .toolbar { toolbarContent }
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
                    if !library.activeFolders.isEmpty {
                        Menu {
                            ForEach(library.activeFolders) { folder in
                                Button(folder.name) { moveSelected(to: folder.id) }
                            }
                        } label: {
                            Label("Move to Folder", systemImage: "folder")
                        }
                    }
                    Button {
                        markSelectedPlayed()
                    } label: {
                        Label("Mark Played", systemImage: "checkmark.circle")
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
        }
        if !tracks.isEmpty {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if !editMode.isEditing {
                    Button("Mark All Played") {
                        library.markAllPlayed()
                    }
                }
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
    }

    private func selectedTracks() -> [Track] {
        tracks.filter { selection.contains($0.id) }
    }

    /// Every bulk action follows the same order the Browse bulk download
    /// learned the hard way: leave select mode **first**, in its own
    /// transaction, and do the work on the next main-actor turn. A dozen row
    /// changes landing in the same update as the animated edit-mode teardown
    /// is what the `List` underneath doesn't survive.
    private func applyToSelection(_ work: @escaping @MainActor ([Track]) -> Void) {
        let picks = selectedTracks()
        endEditing()
        guard !picks.isEmpty else { return }
        Task { @MainActor in work(picks) }
    }

    private func shareSelected() {
        let picks = selectedTracks()
        endEditing()
        guard !picks.isEmpty else { return }
        Task { @MainActor in share = SharePayload(urls: picks.map(\.fileURL)) }
    }

    private func moveSelected(to folderID: UUID) {
        applyToSelection { picks in
            for track in picks {
                // Filing a track is deciding about it, so it leaves the Inbox
                // — the same rule the single-track menu follows.
                library.setFolder(track, folderID)
                library.markPlayed(track.id)
            }
        }
    }

    private func markSelectedPlayed() {
        applyToSelection { picks in
            for track in picks { library.markPlayed(track.id) }
        }
    }

    private func deleteSelected() {
        applyToSelection { picks in
            for track in picks { library.delete(track) }
        }
    }

    private func endEditing() {
        selection.removeAll()
        withAnimation { editMode = .inactive }
    }
}

/// The Library's **Recent** tab: what you've played, most recent first.
///
/// A log rather than a place — the tracks live wherever they normally do, and
/// nothing here moves or deletes them. A track appears once per listen (with
/// consecutive repeats collapsed), which is why rows are keyed by the *entry*
/// and not by the track. Playback continues through the distinct tracks in the
/// list, so a repeat doesn't send `next` backwards.
///
/// Above the log sits the **Pinned** folder: swipe a row right and the track is
/// kept there, at the head of the tab, where the log can't scroll it away. Like
/// everything else on this screen that's a *reference*, not a filing — nothing
/// moves on disk and a pinned track keeps whatever folder it actually lives in
/// — so pinning and unpinning are as free as removing a listen.
struct RecentTracksView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackManager

    let onPlay: () -> Void
    @Binding var share: SharePayload?

    @State private var editingTrack: Track?
    @State private var chapterContext: ChapterContext?
    @State private var confirmingClear = false
    /// The artist a track's **View Discography** asked for.
    @State private var discographyRequest: DiscographyRequest?
    /// Whether the pinned folder is twirled open. Persisted like the Library's
    /// other display choices, so the tab looks the way you left it.
    @AppStorage("recentPinsExpanded") private var pinsExpanded = true

    private var entries: [RecentListenRow] { library.recentListenEntries }
    /// The playback queue for the log: each track once, in the order it was
    /// last heard.
    private var queue: [Track] { library.recentTracks }
    /// What's in the pinned folder — and its own queue, so playing from it
    /// carries on through the folder rather than off into the log.
    private var pinned: [Track] { library.pinnedRecentTracks }

    var body: some View {
        Group {
            if entries.isEmpty && pinned.isEmpty {
                ContentUnavailableViewCompat(
                    title: "Nothing played yet",
                    systemImage: "clock.arrow.circlepath",
                    description: "Tracks appear here as you play them — most recent first. Swipe one right to pin it to the top."
                )
            } else {
                list
            }
        }
        // See InboxView: a tab of the Library, so no title of its own.
        .editMetadataSheet(for: $editingTrack)
        .discographySheet(for: $discographyRequest)
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
            Text("This only empties the list of what you've played. No tracks are deleted, and the pinned folder stays as it is.")
        }
    }

    /// The pinned folder, then the log.
    private var list: some View {
        // Resolved once per render pass rather than once per row: each row is
        // handed its whole list as the playback queue, so reading the computed
        // property inside the loop would rebuild it for every row it built.
        let pins = pinned
        let log = entries
        let logQueue = queue
        return List {
            if !pins.isEmpty {
                Section {
                    if pinsExpanded {
                        ForEach(pins) { track in
                            row(track, in: pins, playsAsFolder: true)
                                .modifier(PinnedFrame(closesBelow: track.id == pins.last?.id))
                        }
                    }
                } header: {
                    // The frame starts here and — with the folder shut, which
                    // is most of the time — ends here too.
                    pinnedFolderRow(count: pins.count)
                        .modifier(PinnedFrame(opensAbove: true, closesBelow: !pinsExpanded))
                }
            }
            Section {
                ForEach(log) { pair in
                    row(pair.track, in: logQueue,
                        detail: relativeDate(pair.entry.date), entry: pair.entry)
                }
            }
        }
        .listStyle(.plain)
        .miniPlayerClearance()
    }

    /// The pinned folder itself: one row at the head of the list, wearing its
    /// count the way a folder row does, that twirls its tracks open and shut.
    /// It's a `Section` **header** rather than an ordinary row so it stays put
    /// at the top while the log scrolls past beneath it — which is most of the
    /// point of pinning something.
    private func pinnedFolderRow(count: Int) -> some View {
        Button {
            withAnimation { pinsExpanded.toggle() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "pin.fill")
                    .foregroundStyle(RecentPin.tint)
                    .frame(width: 24)
                Text("Pinned")
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(pinsExpanded ? 90 : 0))
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A section header upper-cases its text; this one is a folder row, not
        // a caption.
        .textCase(nil)
    }

    /// One row of either list. They differ in four things: which queue a tap
    /// plays within, whether that queue is a *curated* one (only the pinned
    /// folder is), whether the trailing edge has a *listen* to forget (only the
    /// log does), and which way round the pin swipe reads.
    ///
    /// `playsAsFolder` is the pinned folder's half of the Library's autoplay
    /// rule: an **auto-aggregated** list mixes media types together, so
    /// playback stays within the type you started, while a **curated** list —
    /// which the pinned folder is, a track at a time, by hand — plays straight
    /// through in list order whatever the types. Without it a pinned song
    /// followed by a pinned podcast quietly dropped the podcast from the queue,
    /// so the folder ended early and not where the list does.
    private func row(_ track: Track, in queue: [Track],
                     playsAsFolder: Bool = false,
                     detail: String? = nil, entry: RecentListen? = nil) -> some View {
        TrackRow(
            track: track,
            isCurrent: playback.currentTrack?.id == track.id,
            onShowChapters: {
                chapterContext = ChapterContext(track: track, queue: queue)
            },
            trailingDetail: detail,
            // A list of things you've heard: the sleeve is the quickest way to
            // recognise one.
            showsArtwork: true
        )
            .contentShape(Rectangle())
            .onTapGesture {
                playback.play(track, in: queue, restrictToCategory: !playsAsFolder)
                onPlay()
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                // Keeps the track at the top of the tab (or lets it go again).
                // Both directions are the same gesture, so the row you just
                // pinned undoes itself the way you pinned it.
                let isPinned = library.isPinnedInRecent(track.id)
                Button {
                    togglePin(track.id)
                } label: {
                    Label(isPinned ? "Unpin" : "Pin",
                          systemImage: isPinned ? "pin.slash" : "pin")
                }
                .tint(isPinned ? .gray : RecentPin.tint)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if let entry {
                    // Removes the log entry only — the track itself is
                    // untouched, wherever it lives, and a pin of it stays.
                    Button(role: .destructive) {
                        library.removeRecentListen(entry.id)
                    } label: {
                        Label("Remove", systemImage: "clock.badge.xmark")
                    }
                }
                Button {
                    share = SharePayload(urls: [track.fileURL])
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .tint(.blue)
            }
            .contextMenu {
                Button {
                    editingTrack = track
                } label: {
                    Label("Edit Metadata", systemImage: "pencil")
                }
                // The swipe's twin, for the times a menu is already open (and
                // for the Mac, where a swipe is the less obvious gesture).
                let isPinned = library.isPinnedInRecent(track.id)
                Button {
                    togglePin(track.id)
                } label: {
                    Label(isPinned ? "Unpin" : "Pin to Top",
                          systemImage: isPinned ? "pin.slash" : "pin")
                }
                SendToWatchButton(track: track)
                ViewDiscographyButton(track: track, request: $discographyRequest)
                AIOrganizeButton(track: track)
                GetAlbumArtButton(track: track)
                ConvertFormatButton(track: track)
                TrackSourceButtons(track: track)
            }
    }

    /// Pins or unpins, on the **next** main-actor turn.
    ///
    /// The same order `InboxView`'s bulk actions follow, and for the same
    /// reason. A pin moves a row between the two sections of this list, and at
    /// the edges it moves a whole *section*: pinning the first track inserts the
    /// Pinned section (header and all), unpinning the last one removes it.
    /// Landing that in the update the swipe is already animating — the gesture's
    /// own commit — is what the `List` underneath doesn't survive. Doing it a
    /// turn later costs a frame nobody can see and leaves the table one change
    /// to apply at a time.
    private func togglePin(_ trackID: UUID) {
        Task { @MainActor in
            withAnimation { library.toggleRecentPin(trackID) }
        }
    }

    /// "2h ago" / "yesterday" — when this listen happened, on the row's
    /// trailing edge where a library row shows its duration.
    private func relativeDate(_ date: Date) -> String {
        date.formatted(.relative(presentation: .numeric))
    }
}

/// The pin's colour and weight, in one place: the glyph, the swipe action and
/// the border around the folder all draw from here, so the fence reads as
/// belonging to the pin rather than as a stray line.
private enum RecentPin {
    static let tint = Color.orange
    static let line: CGFloat = 1.5
    /// How far the frame stands off the row's content, so text isn't touching
    /// the rails.
    static let inset: CGFloat = 10
}

/// One slice of the border around the Recent tab's **Pinned** folder.
///
/// A `List` draws rows, not boxes, so the frame is assembled a row at a time:
/// every row inside the folder carries the two side rails, the header caps it
/// with a top one, and whichever row is last closes it with a bottom one —
/// which is the header itself while the folder is shut. The separators inside
/// the folder go, so the rails run unbroken from the header down to the last
/// pin instead of being crossed at every row.
private struct PinnedFrame: ViewModifier {
    var opensAbove = false
    var closesBelow = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, RecentPin.inset)
            .overlay(alignment: .leading) { rail.frame(width: RecentPin.line) }
            .overlay(alignment: .trailing) { rail.frame(width: RecentPin.line) }
            .overlay(alignment: .top) {
                if opensAbove { rail.frame(height: RecentPin.line) }
            }
            .overlay(alignment: .bottom) {
                if closesBelow { rail.frame(height: RecentPin.line) }
            }
            .listRowSeparator(.hidden)
    }

    private var rail: some View { Rectangle().fill(RecentPin.tint) }
}
