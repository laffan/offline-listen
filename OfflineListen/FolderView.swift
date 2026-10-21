import SwiftUI

/// A user folder: its tracks with tap-to-play and swipe actions, plus
/// drag-to-reorder via the Reorder toolbar toggle. Folders can nest — any
/// subfolders list above the tracks — and a mixtape folder shows its cover
/// banner up top and an Edit Cover button below its tracks.
struct FolderDetailView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackManager
    @EnvironmentObject private var spotifySettings: SpotifySettingsStore

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
    /// The album-art sheets, and the change/reset dialog a tap on the sleeve
    /// opens first: one for a cover of the user's own, one for finding the
    /// record's sleeve in Spotify's catalogue.
    @State private var editingAlbumArt = false
    @State private var findingAlbumArt = false
    @State private var albumArtOptions = false
    /// The artist a track's **View Discography** asked for.
    @State private var discographyRequest: DiscographyRequest?
    /// The track **Find Alternative** was asked for.
    @State private var alternativeRequest: AlternativeRequest?

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
        .findAlternativeSheet(for: $alternativeRequest)
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
        .sheet(isPresented: $findingAlbumArt) {
            if let folder, let client = spotifySettings.client {
                AlbumArtFinder(folder: folder, client: client,
                               suggestion: library.folderArtist(of: folderID) ?? folder.name)
            }
        }
        // No explanatory message: three verbs, each of which says what it
        // does, and a paragraph under them only slows down the reading.
        .confirmationDialog("Album Art", isPresented: $albumArtOptions, titleVisibility: .visible) {
            // The sleeve from the catalogue, chosen rather than guessed: the
            // folder's name is what a one-shot search had to go on, and the
            // person asking for the cover knows the record better than it does.
            if spotifySettings.isConfigured {
                Button("Retrieve Album Art") { findingAlbumArt = true }
            }
            Button("Custom Album Art") { editingAlbumArt = true }
            // Only offered once there's something of the user's to undo.
            if folder?.customArtworkFileName != nil {
                Button("Reset Album Art", role: .destructive) {
                    if let folder { library.resetAlbumArtwork(folder) }
                }
            }
            Button("Cancel", role: .cancel) {}
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
                    ForEach(library.activeFolders.filter { $0.id != folderID }) { other in
                        Button {
                            library.setFolder(track, other.id)
                        } label: {
                            Label(other.name, systemImage: "folder")
                        }
                    }
                    Button(role: .destructive) {
                        library.removeFromFolder(track)
                    } label: {
                        Label("Remove from Folder", systemImage: "folder.badge.minus")
                    }
                } label: {
                    Label("Move to Folder", systemImage: "folder")
                }
                CopyToFolderMenu(track: track)
                SyncToLocalButton(track: track)
                SendToWatchButton(track: track)
                ViewDiscographyButton(track: track, request: $discographyRequest)
                FindAlternativeButton(track: track, request: $alternativeRequest)
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

/// The Library's **Random** tab: fifty songs picked at random from the whole
/// library, played as a playlist — straight through, top to bottom.
///
/// The hand is dealt afresh on each visit — the Library picked from the tab
/// bar, or this tab picked from the Library's own — and kept while you're
/// here, so the list doesn't reshuffle under your finger as rows redraw. Going
/// back to it from the Player isn't a visit: you land on the hand that's
/// playing. That's why the hand is held by `LibraryView`, which can tell one
/// arrival from the other, rather than here; **Shuffle** deals a new one on
/// demand.
struct RandomTracksView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackManager

    /// The hand, by track id.
    let picks: [UUID]
    /// Deals a new hand.
    let onDeal: () -> Void
    let onPlay: () -> Void
    @Binding var share: SharePayload?

    @State private var editingTrack: Track?
    @State private var chapterContext: ChapterContext?
    @State private var splittingTrack: Track?
    /// The artist a track's **View Discography** asked for.
    @State private var discographyRequest: DiscographyRequest?
    /// The track **Find Alternative** was asked for.
    @State private var alternativeRequest: AlternativeRequest?

    /// The hand, resolved against the live library — a track deleted or
    /// archived since it was dealt simply drops out.
    private var tracks: [Track] {
        let active = Set(library.activeTracks.map(\.id))
        return picks.compactMap { active.contains($0) ? library.track(withID: $0) : nil }
    }

    var body: some View {
        // Resolved once per render pass: every row is handed the whole hand as
        // its playback queue.
        let tracks = self.tracks
        return Group {
            if tracks.isEmpty {
                ContentUnavailableViewCompat(
                    title: "No songs to pick from",
                    systemImage: "shuffle",
                    description: "Once there are songs in your library, fifty of them turn up here at random — a different fifty each time you come back."
                )
            } else {
                List {
                    ForEach(tracks) { track in
                        row(for: track, queue: tracks)
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
        .discographySheet(for: $discographyRequest)
        .findAlternativeSheet(for: $alternativeRequest)
        .sheet(item: $chapterContext) { context in
            ChapterListView(track: context.track, queue: context.queue, onPlay: onPlay)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    withAnimation { onDeal() }
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .accessibilityLabel("Pick another fifty")
            }
        }
        // The first time the tab is shown there's no hand yet.
        .onAppear {
            if picks.isEmpty { onDeal() }
        }
    }

    /// One song's row. A tap plays on through the hand in the order it's
    /// shown — it's a playlist, so it plays the way a folder does.
    private func row(for track: Track, queue: [Track]) -> some View {
        TrackRow(
            track: track,
            isCurrent: playback.currentTrack?.id == track.id,
            onShowChapters: { chapterContext = ChapterContext(track: track, queue: queue) }
        )
            .contentShape(Rectangle())
            .onTapGesture {
                playback.play(track, in: queue, restrictToCategory: false)
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
            }
            .contextMenu {
                Button {
                    editingTrack = track
                } label: {
                    Label("Edit Metadata", systemImage: "pencil")
                }
                if !library.activeFolders.isEmpty {
                    Menu {
                        if track.folderID != nil {
                            Button(role: .destructive) {
                                library.removeFromFolder(track)
                            } label: {
                                Label("Remove from Folder",
                                      systemImage: "folder.badge.minus")
                            }
                        }
                        ForEach(library.activeFolders) { folder in
                            Button {
                                library.setFolder(track, folder.id)
                            } label: {
                                Label(folder.name, systemImage: "folder")
                            }
                        }
                    } label: {
                        Label("Move to Folder", systemImage: "folder")
                    }
                }
                CopyToFolderMenu(track: track)
                SyncToLocalButton(track: track)
                SendToWatchButton(track: track)
                ViewDiscographyButton(track: track, request: $discographyRequest)
                FindAlternativeButton(track: track, request: $alternativeRequest)
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

/// The Recent tab's sections, in the order their tabs sit across its top.
enum RecentTab: String, CaseIterable, Identifiable {
    /// What you've pinned to keep — the default, being what you came back for.
    case pinned
    /// What you've played, newest first.
    case recent
    /// The songs that have gone longest unplayed.
    case ignored

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pinned: return "Pinned"
        case .recent: return "Recent"
        case .ignored: return "Ignored"
        }
    }
}

/// The **Recent** tab — a tab of the app's own, between the Library and the
/// Player: what you've been listening to (and what you haven't) is a place
/// you go as often as the library itself. Divided like the Library, by a strip
/// of tabs across the top: **Pinned** (where it opens), **Recent** and
/// **Ignored**. The lists themselves are `RecentTracksView`.
///
/// No navigation bar: nothing here needs one — Clear sits at the foot of the
/// log, the way History's does in Browse — so the tabs start at the top of the
/// screen.
struct RecentView: View {
    @EnvironmentObject private var library: LibraryStore
    /// Told which tab is showing, so a track starting here can be traced back
    /// to it — and asks for one when the Player is swiped back here.
    @EnvironmentObject private var router: AppRouter

    /// Switches to the player tab after starting playback.
    let onPlay: () -> Void

    @State private var tab: RecentTab = .pinned
    @State private var share: SharePayload?
    /// The **Ignored** list as it stood when you arrived, by track id. A
    /// snapshot, like the Library's Random hand: playing a song takes it off
    /// the live list — it's no longer ignored — and rows vanishing from under
    /// the song you just tapped, its queue going with them, is no way to work
    /// through what you've neglected. Taken afresh on each visit; kept when
    /// the Player is swiped back to it.
    @State private var ignoredPicks: [UUID] = []
    /// Set when going back to the Ignored tab from the Player, so arriving on
    /// it doesn't take a new snapshot over the one that's playing.
    @State private var keepIgnoredPicks = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Section", selection: $tab) {
                    ForEach(RecentTab.allCases) { section in
                        Text(section.displayName).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 4)
                .padding(.bottom, 6)

                RecentTracksView(tab: tab, ignoredPicks: ignoredPicks,
                                 onPlay: onPlay, share: $share)
                    // Greedy so an empty section's placeholder centers in the
                    // room below the tabs rather than clinging to them.
                    .frame(maxHeight: .infinity)
            }
            .navigationBarTitleDisplayMode(.inline)
            #if !os(macOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .sheet(item: $share) { payload in
                ActivityView(items: payload.urls)
            }
        }
        .onAppear {
            router.recentTab = tab
            goBackToPendingTab()
            if ignoredPicks.isEmpty { snapshotIgnored() }
        }
        .onChange(of: tab) { newTab in
            router.recentTab = newTab
            if newTab == .ignored {
                if keepIgnoredPicks { keepIgnoredPicks = false } else { snapshotIgnored() }
            }
        }
        // A visit — the tab picked from the tab bar — takes a fresh snapshot.
        // Going back to it from the Player isn't one.
        .onChange(of: router.recentVisits) { _ in
            if tab == .ignored { snapshotIgnored() }
        }
        .onChange(of: router.pendingRecentTab) { _ in goBackToPendingTab() }
    }

    private func snapshotIgnored() {
        ignoredPicks = library.ignoredSongs(count: LibraryStore.ignoredListSize).map(\.id)
    }

    /// The Player's swipe-down: back to the tab the playing track was started
    /// from.
    private func goBackToPendingTab() {
        guard let pending = router.pendingRecentTab else { return }
        router.pendingRecentTab = nil
        if pending == .ignored && tab != .ignored { keepIgnoredPicks = true }
        tab = pending
    }
}

/// The Recent tab's lists — **Pinned**, the **Recent** log, and **Ignored** —
/// one at a time, as its tab strip picks.
///
/// The log is a log rather than a place — the tracks live wherever they
/// normally do, and nothing here moves or deletes them. A track appears once
/// per listen (with consecutive repeats collapsed), which is why rows are
/// keyed by the *entry* and not by the track. Playback continues through the
/// distinct tracks in the list, so a repeat doesn't send `next` backwards.
///
/// **Pinned** is what a swipe right keeps — anywhere on this screen — where
/// the log can't scroll it away. Like everything else here that's a
/// *reference*, not a filing: nothing moves on disk and a pinned track keeps
/// whatever folder it actually lives in, so pinning and unpinning are as free
/// as removing a listen.
///
/// **Ignored** is the songs that have gone longest without a play (see
/// `LibraryStore.ignoredSongs`), as `RecentView` snapshotted them on arrival.
struct RecentTracksView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackManager

    let tab: RecentTab
    /// The Ignored list's snapshot, by track id.
    let ignoredPicks: [UUID]
    let onPlay: () -> Void
    @Binding var share: SharePayload?

    @State private var editingTrack: Track?
    @State private var chapterContext: ChapterContext?
    @State private var confirmingClear = false
    /// The artist a track's **View Discography** asked for.
    @State private var discographyRequest: DiscographyRequest?
    /// The track **Find Alternative** was asked for.
    @State private var alternativeRequest: AlternativeRequest?

    private var entries: [RecentListenRow] { library.recentListenEntries }
    /// The playback queue for the log: each track once, in the order it was
    /// last heard.
    private var queue: [Track] { library.recentTracks }
    /// What's pinned — and its own queue, so playing from it carries on
    /// through the pins rather than off into the log.
    private var pinned: [Track] { library.pinnedRecentTracks }
    /// The snapshot, resolved against the live library — a song deleted or
    /// archived since simply drops out.
    private var ignored: [Track] {
        let active = Set(library.activeTracks.map(\.id))
        return ignoredPicks.compactMap { active.contains($0) ? library.track(withID: $0) : nil }
    }

    var body: some View {
        Group {
            switch tab {
            case .pinned: pinnedList
            case .recent: logList
            case .ignored: ignoredList
            }
        }
        // No title: the tab bar names it.
        .editMetadataSheet(for: $editingTrack)
        .discographySheet(for: $discographyRequest)
        .findAlternativeSheet(for: $alternativeRequest)
        .sheet(item: $chapterContext) { context in
            ChapterListView(track: context.track, queue: context.queue, onPlay: onPlay)
        }
        .confirmationDialog("Clear the Recent list?",
                            isPresented: $confirmingClear,
                            titleVisibility: .visible) {
            Button("Clear", role: .destructive) { library.clearRecentListens() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This only empties the list of what you've played. No tracks are deleted, pinned tracks stay pinned, and the Ignored list still knows when each song was last played.")
        }
    }

    // Each list is resolved once per render pass rather than once per row:
    // every row is handed its whole list as the playback queue, so reading the
    // computed property inside the loop would rebuild it for every row built.

    @ViewBuilder
    private var pinnedList: some View {
        let pins = pinned
        if pins.isEmpty {
            ContentUnavailableViewCompat(
                title: "Nothing pinned",
                systemImage: "pin",
                description: "Swipe a track right in Recent or Ignored — or tap the sleeve in the Player — to keep it here, where the log can't scroll it away."
            )
        } else {
            List {
                ForEach(pins) { track in
                    row(track, in: pins, playsAsFolder: true)
                }
            }
            .listStyle(.plain)
            .miniPlayerClearance()
        }
    }

    @ViewBuilder
    private var logList: some View {
        let log = entries
        let logQueue = queue
        if log.isEmpty {
            ContentUnavailableViewCompat(
                title: "Nothing played yet",
                systemImage: "clock.arrow.circlepath",
                description: "Tracks appear here as you play them — most recent first. Swipe one right to pin it."
            )
        } else {
            List {
                ForEach(log) { pair in
                    row(pair.track, in: logQueue,
                        detail: relativeDate(pair.entry.date), entry: pair.entry)
                }
                // At the foot of the log rather than in a navigation bar,
                // the way History's Clear sits in Browse: it's the last thing
                // you'd do here, and a bar kept for one button is a bar's
                // height lost from every tab.
                Button(role: .destructive) {
                    confirmingClear = true
                } label: {
                    Text("Clear Recent")
                        .frame(maxWidth: .infinity)
                }
                .padding(.vertical, 6)
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .miniPlayerClearance()
        }
    }

    @ViewBuilder
    private var ignoredList: some View {
        let songs = ignored
        if songs.isEmpty {
            ContentUnavailableViewCompat(
                title: "Nothing ignored",
                systemImage: "moon.zzz",
                description: "The songs you've gone longest without playing turn up here — longest first."
            )
        } else {
            List {
                ForEach(songs) { track in
                    row(track, in: songs, playsAsFolder: true,
                        detail: unplayedDetail(for: track))
                }
            }
            .listStyle(.plain)
            .miniPlayerClearance()
        }
    }

    /// One row of any of the lists. They differ in four things: which queue a
    /// tap plays within, whether that queue is a *curated* one (Pinned and
    /// Ignored are), whether the trailing edge has a *listen* to forget (only
    /// the log does), and which way round the pin swipe reads.
    ///
    /// `playsAsFolder` is the Library's autoplay rule: an **auto-aggregated**
    /// list mixes media types together, so playback stays within the type you
    /// started, while a **curated** list — which the pins are, a track at a
    /// time, by hand — plays straight through in list order whatever the
    /// types. Without it a pinned song followed by a pinned podcast quietly
    /// dropped the podcast from the queue, so the list ended early and not
    /// where it does on screen.
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
                // Pins the track (or lets it go again). Both directions are
                // the same gesture, so the row you just pinned undoes itself
                // the way you pinned it.
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
                    Label(isPinned ? "Unpin" : "Pin",
                          systemImage: isPinned ? "pin.slash" : "pin")
                }
                CopyToFolderMenu(track: track)
                SendToWatchButton(track: track)
                ViewDiscographyButton(track: track, request: $discographyRequest)
                // Recent is where a bad copy announces itself — you have just
                // listened to it.
                FindAlternativeButton(track: track, request: $alternativeRequest)
                AIOrganizeButton(track: track)
                GetAlbumArtButton(track: track)
                ConvertFormatButton(track: track)
                TrackSourceButtons(track: track)
            }
    }

    /// Pins or unpins, on the **next** main-actor turn.
    ///
    /// The same order the Library's bulk actions follow, and for the same
    /// reason. In the Pinned tab, unpinning removes the very row the swipe is
    /// still animating — and unpinning the last one swaps the whole list for
    /// the placeholder. Landing that in the update the swipe is already
    /// animating — the gesture's own commit — is what the `List` underneath
    /// doesn't survive. Doing it a turn later costs a frame nobody can see and
    /// leaves the table one change to apply at a time.
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

    /// What an Ignored row says on its trailing edge: when it was last played,
    /// "Never played" for a song that hasn't been, and — for one played too
    /// long ago for anything to have recorded the date — nothing, so the row
    /// shows its length the way a library row does.
    private func unplayedDetail(for track: Track) -> String? {
        if let date = library.lastPlayed(track.id) { return relativeDate(date) }
        return track.hasBeenPlayed ? nil : "Never played"
    }
}

/// The pin's colour: the glyph and the swipe action both draw from here.
private enum RecentPin {
    static let tint = Color.orange
}
