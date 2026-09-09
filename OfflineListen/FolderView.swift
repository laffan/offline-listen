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

/// One day's worth of the **Added** tab: the day it stands for, and what
/// arrived on it, in arrival order.
private struct AddedDay: Identifiable {
    /// The start of the day, which is both the section's identity and what its
    /// heading is written from.
    let id: Date
    let items: [AddedListItem]

    /// Everything under the heading, groups unfolded — the day's contribution
    /// to the playback queue.
    var tracks: [Track] {
        items.flatMap { item -> [Track] in
            switch item {
            case .track(let track): return [track]
            case .album(let group): return group.tracks
            }
        }
    }

    /// **Today** and **Yesterday** by name, because that is how somebody
    /// thinks of them; a weekday and date within the year, and the year too
    /// once it is no longer this one.
    var title: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(id) { return "Today" }
        if calendar.isDateInYesterday(id) { return "Yesterday" }
        if calendar.isDate(id, equalTo: Date(), toGranularity: .year) {
            return id.formatted(.dateTime.weekday(.wide).day().month(.wide))
        }
        return id.formatted(.dateTime.day().month(.wide).year())
    }
}

/// One row under a day's heading: a track on its own, or a whole record —
/// the same two shapes the Download tab's queue has.
private enum AddedListItem: Identifiable {
    case track(Track)
    case album(AddedAlbumGroup)

    var id: String {
        switch self {
        case .track(let track): return track.id.uuidString
        case .album(let group): return group.id
        }
    }
}

/// A record as it arrived on one day: the album folder its tracks are in, and
/// the tracks of it that landed that day. Identified by day *and* folder, so a
/// download that ran past midnight twirls open on each side independently.
private struct AddedAlbumGroup: Identifiable {
    let id: String
    let folder: Folder
    let tracks: [Track]
}

/// The header of a record's group in the **Added** tab: its sleeve, its name,
/// its artist and how much of it landed — the Library's own album row at the
/// size the Download tab's group header uses.
private struct AddedAlbumHeader: View {
    @EnvironmentObject private var library: LibraryStore

    let folder: Folder
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            AlbumCoverArt(folder: folder,
                          image: FolderCover.thumbnail(for: folder,
                                                       tracks: library.tracks(in: folder.id)),
                          cornerRadius: 5)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(folder.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        let tally = "\(count) track\(count == 1 ? "" : "s")"
        guard let artist = library.folderArtist(of: folder.id) else { return tally }
        return "\(artist) · \(tally)"
    }
}

/// The Library's **Added** tab: the most recently added tracks, newest first,
/// capped at `LibraryStore.recentlyAddedLimit`.
///
/// It used to be an **Inbox** — everything not yet listened to, emptying itself
/// as you played it and offering Mark Played and Mark All Played to empty it
/// faster. An inbox is a thing you are meant to clear, and that turned out not
/// to be what this list was wanted for: "what did I add lately?" is the
/// question, and playing a track is no answer to it. So nothing leaves for
/// having been played, and the unplayed-green the rows carried has gone with
/// the idea (see `TrackRow.iconColor`).
struct RecentlyAddedView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackManager

    let onPlay: () -> Void
    @Binding var share: SharePayload?

    @State private var editingTrack: Track?
    @State private var chapterContext: ChapterContext?
    @State private var splittingTrack: Track?
    /// The artist a track's **View Discography** asked for.
    @State private var discographyRequest: DiscographyRequest?
    /// The track **Find Alternative** was asked for.
    @State private var alternativeRequest: AlternativeRequest?
    /// Multi-select, the same shape the **All** tab has: a batch download
    /// lands here in a batch and is usually filed in one too.
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<Track.ID>()
    /// Which album groups are twirled open, by group id. Empty by default, for
    /// the reason the Download tab's are: a record that arrived whole is *one*
    /// thing that happened, and a dozen rows of it burying the rest of the day
    /// is what the grouping is for.
    @State private var expandedAlbums: Set<String> = []

    private var tracks: [Track] {
        library.recentlyAddedTracks
    }

    var body: some View {
        let days = self.days
        let queue = days.flatMap(\.tracks)
        return Group {
            if days.isEmpty {
                ContentUnavailableViewCompat(
                    title: "Nothing added yet",
                    systemImage: "tray.and.arrow.down",
                    description: "Downloads and synced files show up here, newest first."
                )
            } else {
                List(selection: $selection) {
                    ForEach(days) { day in
                        Section(day.title) {
                            ForEach(day.items) { item in
                                switch item {
                                case .track(let track):
                                    row(for: track, queue: queue)
                                case .album(let group):
                                    DisclosureGroup(isExpanded: expansion(of: group.id)) {
                                        ForEach(group.tracks) { track in
                                            row(for: track, queue: queue)
                                        }
                                    } label: {
                                        AddedAlbumHeader(folder: group.folder,
                                                         count: group.tracks.count)
                                    }
                                }
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
        .findAlternativeSheet(for: $alternativeRequest)
        .sheet(item: $chapterContext) { context in
            ChapterListView(track: context.track, queue: context.queue, onPlay: onPlay)
        }
        // The list emptying from under an open selection would leave a Done
        // button over nothing.
        .onChange(of: tracks.isEmpty) { empty in
            if empty, editMode.isEditing { endEditing() }
        }
        .toolbar { toolbarContent }
    }

    /// One track's row, wherever it sits — loose under its day, or inside the
    /// record it arrived with. `queue` is the whole list in the order the
    /// screen shows it, so playing a track carries on down what you can see.
    @ViewBuilder
    private func row(for track: Track, queue: [Track]) -> some View {
        let base = TrackRow(
            track: track,
            isCurrent: playback.currentTrack?.id == track.id,
            onShowChapters: { chapterContext = ChapterContext(track: track, queue: queue) }
        )
            .contentShape(Rectangle())
            // The list is a `ForEach` over days and items, not over tracks, so
            // the selection value has to be said out loud.
            .tag(track.id)
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
        // Selecting is a mode you're in *instead* of playing: a tap ticks the
        // row rather than starting the track.
        if editMode.isEditing {
            base
        } else {
            base.onTapGesture {
                playback.play(track, in: queue)
                onPlay()
            }
        }
    }

    /// The list as it is shown: **a section per day**, and within a day, a
    /// record that arrived that day folded into one collapsible group.
    ///
    /// The day is the outer division because that is the question the tab
    /// answers — what arrived, and when — and it means everything under a
    /// heading really did arrive on that date. A record whose downloads
    /// straddled midnight therefore appears under both, each with the tracks
    /// that landed then, rather than picking one day and lying about the rest.
    ///
    /// Grouping needs **two** tracks to be worth doing: a group exists to
    /// collapse a crowd, and putting a lone arrival behind a twirl only hides
    /// it. Albums only — a mixtape or a plain folder is a place you file
    /// things over time rather than a thing that arrives, and its cover isn't
    /// a sleeve.
    private var days: [AddedDay] {
        let calendar = Calendar.current
        var albums: [UUID: Folder] = [:]
        for folder in library.folders where library.isAlbumFolder(folder) {
            albums[folder.id] = folder
        }

        var result: [AddedDay] = []
        // `recentlyAddedTracks` is already newest-first, so a day ends exactly
        // where the next one starts and no sorting is needed here.
        for (start, arrivals) in consecutiveDays(of: tracks, calendar: calendar) {
            var members: [UUID: [Track]] = [:]
            for track in arrivals {
                guard let id = track.folderID, albums[id] != nil else { continue }
                members[id, default: []].append(track)
            }
            var items: [AddedListItem] = []
            var placed: Set<UUID> = []
            for track in arrivals {
                guard let id = track.folderID, let folder = albums[id],
                      let group = members[id], group.count > 1 else {
                    items.append(.track(track))
                    continue
                }
                guard placed.insert(id).inserted else { continue }
                items.append(.album(AddedAlbumGroup(
                    id: "\(start.timeIntervalSinceReferenceDate)|\(id.uuidString)",
                    folder: folder, tracks: group)))
            }
            result.append(AddedDay(id: start, items: items))
        }
        return result
    }

    /// Splits an already newest-first list into runs that share a calendar day.
    private func consecutiveDays(of list: [Track],
                                 calendar: Calendar) -> [(Date, [Track])] {
        var runs: [(Date, [Track])] = []
        for track in list {
            let start = calendar.startOfDay(for: track.dateAdded)
            if runs.last?.0 == start {
                runs[runs.count - 1].1.append(track)
            } else {
                runs.append((start, [track]))
            }
        }
        return runs
    }

    private func expansion(of id: String) -> Binding<Bool> {
        Binding(get: { expandedAlbums.contains(id) },
                set: { open in
                    if open { expandedAlbums.insert(id) } else { expandedAlbums.remove(id) }
                })
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
            for track in picks { library.setFolder(track, folderID) }
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
    /// The track **Find Alternative** was asked for.
    @State private var alternativeRequest: AlternativeRequest?
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
        // See RecentlyAddedView: a tab of the Library, so no title of its own.
        .editMetadataSheet(for: $editingTrack)
        .discographySheet(for: $discographyRequest)
        .findAlternativeSheet(for: $alternativeRequest)
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
                    // The frame starts here; the last pin closes it. Shut,
                    // the folder is a plain row with no border at all.
                    pinnedFolderRow(count: pins.count)
                        .modifier(PinnedFrame(isDrawn: pinsExpanded, opensAbove: true))
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
    /// The same order `RecentlyAddedView`'s bulk actions follow, and for the same
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
    /// Where the rails stand relative to the screen edge — the margin the
    /// list's own rows keep, so the box lines up with the log beneath it.
    static let gutter: CGFloat = 16
    /// The breathing room above and below a row inside the frame. The frame
    /// takes the list's row insets to zero (see `PinnedFrame`), so it has to
    /// put back the vertical padding those insets were providing.
    static let rowPad: CGFloat = 11
    /// Extra room inside the top and bottom of the box, so the first and last
    /// rows aren't sitting on the rails.
    static let endPad: CGFloat = 10
}

/// One slice of the border around the Recent tab's **Pinned** folder.
///
/// A `List` draws rows, not boxes, so the frame is assembled a row at a time:
/// every row inside the folder carries the two side rails, the header caps it
/// with a top one, and the last pin closes it with a bottom one. The
/// separators inside the folder go, so the rails run unbroken from the header
/// down to the last pin instead of being crossed at every row.
///
/// The row's own padding is the frame's, not the list's: a `List` puts its row
/// insets *outside* the row's content, so an overlay drawn on that content
/// stopped short of the row above and below and the side rails came out as a
/// dashed line with a gap at every boundary. Zeroing `listRowInsets` and
/// re-padding inside the frame lets each row's rails meet its neighbour's.
///
/// With the folder shut there's nothing inside to fence off, so no frame is
/// drawn at all — a box around the one closed row reads as a stray rectangle
/// rather than as a folder holding something.
private struct PinnedFrame: ViewModifier {
    var isDrawn = true
    var opensAbove = false
    var closesBelow = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, isDrawn ? RecentPin.inset : 0)
            .padding(.top, isDrawn && opensAbove ? RecentPin.endPad : 0)
            .padding(.bottom, isDrawn && closesBelow ? RecentPin.endPad : 0)
            .padding(.vertical, RecentPin.rowPad)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) { rail(width: RecentPin.line) }
            .overlay(alignment: .trailing) { rail(width: RecentPin.line) }
            .overlay(alignment: .top) {
                if opensAbove { rail(height: RecentPin.line) }
            }
            .overlay(alignment: .bottom) {
                if closesBelow { rail(height: RecentPin.line) }
            }
            .padding(.horizontal, RecentPin.gutter)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
    }

    /// A length of rail — or nothing at all, with the folder shut, which is
    /// what keeps the padding and the alignment while the border goes away.
    @ViewBuilder
    private func rail(width: CGFloat? = nil, height: CGFloat? = nil) -> some View {
        if isDrawn {
            Rectangle()
                .fill(RecentPin.tint)
                .frame(width: width, height: height)
        }
    }
}
