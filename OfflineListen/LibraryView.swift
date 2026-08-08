import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Identifiable payload so a share sheet can be presented via `.sheet(item:)`.
struct SharePayload: Identifiable {
    let id = UUID()
    let urls: [URL]
}

#if canImport(UIKit)

/// Bridges `UIActivityViewController` (the system share sheet) into SwiftUI so
/// downloaded files can be shared/exported (AirDrop, Files, Messages, …).
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

#else

/// The Mac's answer to the iOS share sheet.
///
/// `NSSharingServicePicker` is a popover that has to hang off a real view, so it
/// can't simply *be* the sheet the way `UIActivityViewController` can. Instead
/// this presents the small sheet a Mac user expects for "here are some files" —
/// the list, then Reveal in Finder (the thing people actually reach for) and
/// Share…, which anchors the system picker to its own button.
struct ActivityView: View {
    let items: [Any]
    @Environment(\.dismiss) private var dismiss

    private var urls: [URL] { items.compactMap { $0 as? URL } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(urls.count == 1 ? "Share File" : "Share \(urls.count) Files")
                .font(.headline)

            if !urls.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(urls, id: \.self) { url in
                        Label(url.lastPathComponent, systemImage: "doc")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .font(.callout)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(urls)
                    dismiss()
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .disabled(urls.isEmpty)

                SharePickerButton(items: items)
                    .disabled(items.isEmpty)

                Spacer()

                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 380)
    }
}

/// A Share… button that opens `NSSharingServicePicker` anchored to itself.
/// It has to be an AppKit button because the picker needs a concrete view and
/// bounds to point its popover at, which SwiftUI won't hand out.
private struct SharePickerButton: NSViewRepresentable {
    let items: [Any]

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "Share…", target: context.coordinator,
                              action: #selector(Coordinator.present(_:)))
        button.bezelStyle = .rounded
        context.coordinator.items = items
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.items = items
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var items: [Any] = []

        @objc func present(_ sender: NSButton) {
            guard !items.isEmpty else { return }
            NSSharingServicePicker(items: items)
                .show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}

#endif

/// Manual metadata editor: edit the track title and artist by hand (handy when
/// AI Organize doesn't get it quite right), with a Reset that restores the
/// original download title.
struct EditMetadataView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    let track: Track
    @State private var title: String
    @State private var artist: String

    init(track: Track) {
        self.track = track
        _title = State(initialValue: track.title)
        // "Unknown" is the placeholder default; show it as empty so the field
        // invites a real artist rather than reading like a value.
        let current = track.artist
        _artist = State(initialValue: current.lowercased() == "unknown" ? "" : current)
    }

    /// The title to reset to: the recorded download title, or the current one if
    /// it was never changed.
    private var original: String { track.originalTitle ?? track.title }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Title", text: $title, axis: .vertical)
                }
                Section("Artist") {
                    TextField("Artist", text: $artist)
                        .textInputAutocapitalization(.words)
                }
                Section {
                    Button("Reset to Original Title") { title = original }
                        .disabled(title == original)
                } footer: {
                    Text("Original: \(original)")
                }
            }
            .navigationTitle("Edit Metadata")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        library.editMetadata(track, title: title, artist: artist)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

/// Presents the metadata editor for the bound track via `.sheet(item:)`.
struct EditMetadataSheet: ViewModifier {
    @Binding var track: Track?

    func body(content: Content) -> some View {
        content.sheet(item: $track) { track in
            EditMetadataView(track: track)
        }
    }
}

extension View {
    func editMetadataSheet(for track: Binding<Track?>) -> some View {
        modifier(EditMetadataSheet(track: track))
    }
}

/// Shared confirmation for "Break Chapters into Playlist": lets the user choose
/// whether to delete the original track once the per-chapter slices are made.
struct BreakChaptersConfirm: ViewModifier {
    @EnvironmentObject private var library: LibraryStore
    @Binding var track: Track?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Break into Playlist",
            isPresented: isPresented,
            titleVisibility: .visible,
            presenting: track
        ) { track in
            Button("Split & Delete Original", role: .destructive) {
                library.breakChaptersIntoPlaylist(track, deleteOriginal: true)
            }
            Button("Split & Keep Original") {
                library.breakChaptersIntoPlaylist(track, deleteOriginal: false)
            }
            Button("Cancel", role: .cancel) {}
        } message: { track in
            Text("Splits “\(track.title)” into \(track.chapters.count) chapter tracks in a new playlist folder.")
        }
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { track != nil },
            set: { if !$0 { track = nil } }
        )
    }
}

/// Shared confirmation for deleting a folder. A folder has always been just a
/// grouping — deleting one left its tracks in the library — but a folder that
/// *is* an album is usually meant to go with its songs, and quietly picking
/// either reading is wrong half the time. So it asks, naming the count, and
/// the destructive option is never the one you get by accident.
struct DeleteFolderConfirm: ViewModifier {
    @EnvironmentObject private var library: LibraryStore
    @Binding var folder: Folder?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Delete Folder",
            isPresented: isPresented,
            titleVisibility: .visible,
            presenting: folder
        ) { folder in
            let count = library.containedTrackCount(of: folder.id)
            if count > 0 {
                // Only this one is red: it's the one that loses files.
                Button("Delete Folder & \(count) Track\(count == 1 ? "" : "s")", role: .destructive) {
                    library.deleteFolder(folder, deletingTracks: true)
                }
                Button("Delete Folder Only") {
                    library.deleteFolder(folder)
                }
            } else {
                Button("Delete Folder", role: .destructive) {
                    library.deleteFolder(folder)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { folder in
            let count = library.containedTrackCount(of: folder.id)
            if count == 0 {
                Text("“\(folder.name)” is empty.")
            } else {
                Text("“\(folder.name)” holds \(count) track\(count == 1 ? "" : "s"). Deleting the folder on its own leaves them in your library; deleting them too removes the files for good.")
            }
        }
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { folder != nil },
            set: { if !$0 { folder = nil } }
        )
    }
}

extension View {
    func breakChaptersConfirm(for track: Binding<Track?>) -> some View {
        modifier(BreakChaptersConfirm(track: track))
    }

    func deleteFolderConfirm(for folder: Binding<Folder?>) -> some View {
        modifier(DeleteFolderConfirm(folder: folder))
    }
}

/// Navigation targets reachable from the library list.
enum LibraryRoute: Hashable {
    case folder(UUID)
    /// The optional "Synced" grouping row (Settings ▸ Local Sync): every
    /// folder mirroring a sync folder, collected in one place.
    case synced
    case archived
}

/// The Library's top-level sections, in the order their tabs sit across the
/// top of the screen. Each one used to be a row you pushed into (or, for
/// **All**, the flat list that sat under the folders) — as tabs they're all
/// one tap from each other instead of one tap and a back button.
enum LibraryTab: String, CaseIterable, Identifiable {
    /// What you've played, newest first.
    case recent
    case folders
    /// What you haven't listened to yet.
    case inbox
    /// What's been pushed to the Apple Watch.
    case watch
    /// Every active track, filed or not — the full flat view of the library.
    case all

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .recent: return "Recent"
        case .folders: return "Folders"
        case .inbox: return "Inbox"
        case .watch: return "Watch"
        case .all: return "All"
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackManager
    @Environment(\.openURL) private var openURL

    /// Called after a track starts playing so the parent can switch to the player tab.
    let onPlay: () -> Void

    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<Track.ID>()
    @State private var share: SharePayload?
    @State private var filter: LibraryFilter = .all
    @State private var path: [LibraryRoute] = []
    /// Which section is showing. Recent leads: what you were just listening to
    /// is the likeliest reason to open the library at all.
    @State private var tab: LibraryTab = .recent

    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renamingFolder: Folder?
    @State private var renameText = ""
    /// The folder a swipe-Delete is asking about (see `DeleteFolderConfirm`).
    @State private var deletingFolder: Folder?
    @State private var editingTrack: Track?
    @State private var chapterContext: ChapterContext?
    @State private var splittingTrack: Track?

    /// What's in the search field.
    @State private var searchText = ""
    /// What the list is actually showing results for — `searchText` after a
    /// short debounce, so a burst of typing rebuilds the list once instead of
    /// once per keystroke.
    @State private var query = ""

    /// The **All** tab shows every active track, filed or not — the Folders
    /// tab is one way in, this list is the full flat view.
    private var filteredTracks: [Track] {
        library.activeTracks.filter { filter.matches($0) }
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Nothing downloaded and nothing filed: the one state that replaces the
    /// tabs with a welcome rather than showing five empty sections.
    private var isEmptyLibrary: Bool {
        library.tracks.isEmpty && library.folders.isEmpty
    }

    /// Search results honour the media-type filter, so a search inside
    /// "Podcasts" stays inside podcasts.
    private var trackResults: [Track] {
        library.searchTracks(matching: query).filter { filter.matches($0) }
    }

    private var folderResults: [Folder] {
        library.searchFolders(matching: query)
    }

    /// Wraps `path` to reject a consecutive-duplicate push synchronously, before
    /// the stack animates a second copy of the same screen. (Some destinations
    /// trigger a spurious double-append; none of these routes is ever
    /// legitimately pushed twice in a row.)
    private var dedupedPath: Binding<[LibraryRoute]> {
        Binding(
            get: { path },
            set: { newValue in
                if newValue.count >= 2, newValue[newValue.count - 1] == newValue[newValue.count - 2] {
                    path = Array(newValue.dropLast())
                } else {
                    path = newValue
                }
            }
        )
    }

    var body: some View {
        NavigationStack(path: dedupedPath) {
            VStack(spacing: 0) {
                if isEmptyLibrary {
                    ContentUnavailableViewCompat(
                        title: "Your library is empty",
                        systemImage: "music.note.list",
                        description: "Downloaded tracks appear here, ready to play offline."
                    )
                    .frame(maxHeight: .infinity)
                } else if isSearching {
                    // Search answers across the whole library, so the tabs step
                    // aside rather than claim the results belong to one of them.
                    searchList
                } else {
                    tabBar
                    // Greedy so an empty section's placeholder centers in the
                    // room below the tabs rather than clinging to them.
                    tabContent
                        .frame(maxHeight: .infinity)
                }
            }
            // No title — the tabs say where you are, and the height they'd
            // otherwise share goes to the list.
            .navigationBarTitleDisplayMode(.inline)
            #if os(macOS)
            .searchable(text: $searchText, prompt: "Search titles and artists")
            #else
            .searchable(text: $searchText,
                        placement: .navigationBarDrawer(displayMode: .automatic),
                        prompt: "Search titles and artists")
            #endif
            // Debounce: each keystroke cancels the pending pass, so the list is
            // rebuilt once the typing pauses rather than mid-word. Clearing the
            // field takes effect at once — there's nothing to wait for.
            .task(id: searchText) {
                if !searchText.isEmpty {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard !Task.isCancelled else { return }
                }
                query = searchText
            }
            .toolbar { toolbarContent }
            .editModeEnvironment($editMode)
            // Selection belongs to the tracks in All (and in a search's
            // results); carrying it anywhere else would leave a Done button
            // over a list it can't act on — or no Done button at all.
            .onChange(of: tab) { _ in
                if editMode.isEditing { endEditing() }
            }
            .onChange(of: isSearching) { _ in
                if editMode.isEditing { endEditing() }
            }
            .sheet(item: $share) { payload in
                ActivityView(items: payload.urls)
            }
            .sheet(item: $chapterContext) { context in
                ChapterListView(track: context.track, queue: context.queue, onPlay: onPlay)
            }
            .navigationDestination(for: LibraryRoute.self) { route in
                switch route {
                case .folder(let id):
                    FolderDetailView(folderID: id, onPlay: onPlay, share: $share)
                case .synced:
                    SyncedFoldersView()
                case .archived:
                    ArchivedTracksView(onPlay: onPlay, share: $share)
                }
            }
            .alert("New Folder", isPresented: $showNewFolder) {
                TextField("Folder name", text: $newFolderName)
                Button("Create") {
                    library.createFolder(named: newFolderName)
                    newFolderName = ""
                }
                Button("Cancel", role: .cancel) { newFolderName = "" }
            }
            .alert("Rename Folder", isPresented: renameAlertPresented, presenting: renamingFolder) { folder in
                TextField("Folder name", text: $renameText)
                Button("Rename") { library.renameFolder(folder, to: renameText) }
                Button("Cancel", role: .cancel) {}
            }
            .editMetadataSheet(for: $editingTrack)
            .breakChaptersConfirm(for: $splittingTrack)
            .deleteFolderConfirm(for: $deletingFolder)
        }
    }

    private var renameAlertPresented: Binding<Bool> {
        Binding(
            get: { renamingFolder != nil },
            set: { if !$0 { renamingFolder = nil } }
        )
    }

    /// Search replaces the whole list rather than filtering it in place, so
    /// matching *folders* can lead the results before the matching tracks.
    private var searchList: some View {
        // Resolved once per render pass, not once per row: `row(for:in:)` takes
        // the whole result list as the playback queue, and recomputing the
        // search for every row it built made the list quadratic in its own size.
        let matchedTracks = trackResults
        let matchedFolders = folderResults
        return List(selection: $selection) {
            if !matchedFolders.isEmpty && !editMode.isEditing {
                Section {
                    ForEach(matchedFolders) { folder in
                        folderRow(folder)
                    }
                } header: {
                    Text("Folders")
                }
            }
            Section {
                ForEach(matchedTracks) { track in
                    row(for: track, in: matchedTracks)
                }
                if matchedTracks.isEmpty {
                    Text("No tracks match “\(query)”")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Tracks")
            }
        }
        .listStyle(.plain)
        .miniPlayerClearance()
    }

    /// The section tabs across the top. Hidden while selecting tracks for bulk
    /// actions — that's a mode you leave by finishing it, not by wandering off
    /// into another section.
    @ViewBuilder
    private var tabBar: some View {
        if !editMode.isEditing {
            Picker("Section", selection: $tab) {
                ForEach(LibraryTab.allCases) { section in
                    Text(section.displayName).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 4)
            .padding(.bottom, 6)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .recent:
            RecentTracksView(onPlay: onPlay, share: $share)
        case .folders:
            folderList
        case .inbox:
            InboxView(onPlay: onPlay, share: $share)
        case .watch:
            WatchFolderView(onPlay: onPlay)
        case .all:
            trackList
        }
    }

    /// The **Folders** tab: user folders, then the optional "Synced" grouping
    /// and the Archive pinned beneath them.
    @ViewBuilder
    private var folderList: some View {
        let showsSynced = library.groupSyncedFolders && !library.syncedRootFolders.isEmpty
        let showsArchive = !library.archivedTracks.isEmpty || !library.archivedFolders.isEmpty
        if library.displayedFolders.isEmpty && !showsSynced && !showsArchive {
            ContentUnavailableViewCompat(
                title: "No folders yet",
                systemImage: "folder",
                description: "Make one with the folder button above, then touch and hold a track and choose Move to Folder."
            )
            .frame(maxHeight: .infinity)
        } else {
            List {
                // Drag-to-reorder (touch and hold a row) only makes sense in
                // User Order; by-name order is computed and can't be permuted.
                if library.folderSort == .userOrder {
                    ForEach(library.displayedFolders) { folder in
                        folderRow(folder)
                    }
                    .onMove { source, destination in
                        library.moveFolders(fromOffsets: source, toOffset: destination)
                    }
                } else {
                    ForEach(library.displayedFolders) { folder in
                        folderRow(folder)
                    }
                }
                // With the grouping on, the synced folders come out of the
                // list above and live behind this one row instead.
                if showsSynced {
                    syncedRow
                }
                if showsArchive {
                    archiveRow
                }
            }
            .listStyle(.plain)
            .miniPlayerClearance()
        }
    }

    /// The **All** tab: every active track, filed or not — the full flat view
    /// of the library, with the media-type filter pinned above it.
    @ViewBuilder
    private var trackList: some View {
        if library.activeTracks.isEmpty {
            ContentUnavailableViewCompat(
                title: "No tracks yet",
                systemImage: "music.note",
                description: "Everything you download lands here, whether or not it's filed in a folder."
            )
            .frame(maxHeight: .infinity)
        } else {
            // Same reason as `searchList`: one evaluation, shared by every row.
            let listed = filteredTracks
            List(selection: $selection) {
                Section {
                    ForEach(listed) { track in
                        row(for: track, in: listed)
                    }
                    if listed.isEmpty {
                        Text("Nothing in \(filter.displayName)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    if !editMode.isEditing {
                        filterHeader
                    }
                }
            }
            .listStyle(.plain)
            .miniPlayerClearance()
        }
    }

    /// The media-type filter, sitting where the "Tracks" header used to.
    private var filterHeader: some View {
        Picker("Filter", selection: $filter) {
            ForEach(LibraryFilter.allCases) { f in
                Text(f.displayName).tag(f)
            }
        }
        .pickerStyle(.segmented)
        .textCase(nil)
        .padding(.vertical, 4)
    }

    /// Sort the folder list by name or by User Order — the control the
    /// "Folders" header used to carry, now in the toolbar beside New Folder.
    private var folderSortMenu: some View {
        Menu {
            Picker("Sort Folders", selection: $library.folderSort) {
                ForEach(FolderSort.allCases) { sort in
                    Text(sort.displayName).tag(sort)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort folders — \(library.folderSort.displayName)")
    }

    /// The optional "Synced" grouping row: a tidier home for the folders that
    /// mirror a sync folder, sitting just above the Archive. Purely visual —
    /// the folders behave exactly as they do when listed inline.
    private var syncedRow: some View {
        NavigationLink(value: LibraryRoute.synced) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                Text("Synced")
                    .font(.body)
                Spacer()
                Text("\(library.syncedRootFolders.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.vertical, 4)
        }
    }

    /// The Archive: pinned to the bottom of the folder list, with its own icon.
    /// Holds both individually-archived tracks and archived folders.
    private var archiveRow: some View {
        let count = library.archivedTracks.count + library.archivedFolders.count
        return NavigationLink(value: LibraryRoute.archived) {
            HStack(spacing: 12) {
                Image(systemName: "archivebox.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                Text("Archive")
                    .font(.body)
                Spacer()
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Folder rows

    /// True when the currently-playing track lives in this folder, so its row
    /// can light up red like the playing track itself.
    private func isPlaying(in folder: Folder) -> Bool {
        guard let id = playback.currentTrack?.id else { return false }
        return library.folder(folder.id, contains: id)
    }

    private func folderRow(_ folder: Folder) -> some View {
        NavigationLink(value: LibraryRoute.folder(folder.id)) {
            FolderRowLabel(folder: folder,
                           count: library.trackCount(in: folder.id),
                           playingHere: isPlaying(in: folder))
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deletingFolder = folder
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                renameText = folder.name
                renamingFolder = folder
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.orange)
            Button {
                library.setFolderArchived(folder, true)
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .tint(.indigo)
        }
        .contextMenu {
            FolderContextMenu(folder: folder)
        }
    }

    // MARK: - Track rows

    /// One track row. `queue` is the list the row belongs to — what playback
    /// continues through after it, and what the chapter sheet advances within.
    @ViewBuilder
    private func row(for track: Track, in queue: [Track]) -> some View {
        let base = TrackRow(
            track: track,
            isCurrent: playback.currentTrack?.id == track.id,
            onShowChapters: { chapterContext = ChapterContext(track: track, queue: queue) }
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
                    library.setArchived(track, true)
                } label: {
                    Label("Archive", systemImage: "archivebox")
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
                playback.play(track, in: queue)
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
                    Menu {
                        Button {
                            moveSelectedToInbox()
                        } label: {
                            Label("Inbox", systemImage: "tray")
                        }
                        ForEach(library.activeFolders) { folder in
                            Button(folder.name) {
                                moveSelected(to: folder.id)
                            }
                        }
                    } label: {
                        Label("Move to Folder", systemImage: "folder")
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

        // Each tab brings its own actions: the folder controls where the folders
        // are, Select where the tracks are — in the All tab, and in a search's
        // results, which are tracks too. (Inbox and Recent carry their own —
        // Mark All Played and Clear — from the views themselves.)
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            // New Folder also has to survive the empty-library welcome, which
            // stands in for the tabs — otherwise a fresh install has no way to
            // make its first folder at all.
            if (tab == .folders || isEmptyLibrary) && !isSearching && !editMode.isEditing {
                if !isEmptyLibrary {
                    folderSortMenu
                }
                Button {
                    newFolderName = ""
                    showNewFolder = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
            }
            // `editMode.isEditing` is in the condition rather than implied by
            // the other two: leaving All (or clearing a search) drops Done for
            // the render before `onChange` closes edit mode, and a Done button
            // that blinks out is worse than one that lingers a frame.
            if tab == .all || isSearching || editMode.isEditing {
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

    private func moveSelected(to folderID: UUID) {
        for track in selectedTracks() {
            library.setFolder(track, folderID)
        }
        endEditing()
    }

    private func moveSelectedToInbox() {
        for track in selectedTracks() {
            library.moveToInbox(track)
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

/// The "Synced" grouping screen (Settings ▸ Local Sync ▸ Group synced folders):
/// the folders that mirror a sync folder, gathered out of the main folder list
/// so it reads as the user's own. Nothing here is a different kind of folder —
/// the rows carry the same swipe actions and touch-and-hold menu they'd have
/// inline — and turning the grouping off puts them straight back.
struct SyncedFoldersView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackManager

    @State private var renamingFolder: Folder?
    @State private var renameText = ""
    /// The folder a swipe-Delete is asking about (see `DeleteFolderConfirm`).
    @State private var deletingFolder: Folder?

    private var folders: [Folder] { library.syncedRootFolders }

    var body: some View {
        Group {
            if folders.isEmpty {
                ContentUnavailableViewCompat(
                    title: "Nothing synced",
                    systemImage: "arrow.triangle.2.circlepath",
                    description: "Folders that mirror a sync folder appear here. Touch and hold a folder and choose Sync to Local to add one."
                )
            } else {
                List {
                    ForEach(folders) { folder in
                        folderRow(folder)
                    }
                }
                .listStyle(.plain)
                .miniPlayerClearance()
            }
        }
        .navigationTitle("Synced")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Rename Folder", isPresented: renameAlertPresented, presenting: renamingFolder) { folder in
            TextField("Folder name", text: $renameText)
            Button("Rename") { library.renameFolder(folder, to: renameText) }
            Button("Cancel", role: .cancel) {}
        }
        .deleteFolderConfirm(for: $deletingFolder)
    }

    private var renameAlertPresented: Binding<Bool> {
        Binding(
            get: { renamingFolder != nil },
            set: { if !$0 { renamingFolder = nil } }
        )
    }

    private func isPlaying(in folder: Folder) -> Bool {
        guard let id = playback.currentTrack?.id else { return false }
        return library.folder(folder.id, contains: id)
    }

    private func folderRow(_ folder: Folder) -> some View {
        NavigationLink(value: LibraryRoute.folder(folder.id)) {
            FolderRowLabel(folder: folder,
                           count: library.trackCount(in: folder.id),
                           playingHere: isPlaying(in: folder))
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deletingFolder = folder
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                renameText = folder.name
                renamingFolder = folder
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.orange)
            Button {
                library.setFolderArchived(folder, true)
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .tint(.indigo)
        }
        .contextMenu {
            FolderContextMenu(folder: folder)
        }
    }
}

/// The Archive: archived folders (each openable to play its tracks) above
/// individually-archived tracks. Swipe to unarchive, share, or delete.
struct ArchivedTracksView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackManager

    let onPlay: () -> Void
    @Binding var share: SharePayload?

    @State private var chapterContext: ChapterContext?
    /// The folder a swipe-Delete is asking about (see `DeleteFolderConfirm`).
    @State private var deletingFolder: Folder?

    private var isEmpty: Bool {
        library.archivedTracks.isEmpty && library.archivedFolders.isEmpty
    }

    var body: some View {
        Group {
            if isEmpty {
                ContentUnavailableViewCompat(
                    title: "Nothing archived",
                    systemImage: "archivebox",
                    description: "Swipe a track or folder in your library and tap Archive to move it here."
                )
            } else {
                List {
                    if !library.archivedFolders.isEmpty {
                        Section("Folders") {
                            ForEach(library.archivedFolders) { folder in
                                archivedFolderRow(folder)
                            }
                        }
                    }
                    if !library.archivedTracks.isEmpty {
                        Section("Tracks") {
                            ForEach(library.archivedTracks) { track in
                                trackRow(track)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .miniPlayerClearance()
            }
        }
        .navigationTitle("Archive")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $chapterContext) { context in
            ChapterListView(track: context.track, queue: context.queue, onPlay: onPlay)
        }
        .deleteFolderConfirm(for: $deletingFolder)
    }

    private func archivedFolderRow(_ folder: Folder) -> some View {
        NavigationLink(value: LibraryRoute.folder(folder.id)) {
            FolderRowLabel(folder: folder, count: library.trackCount(in: folder.id))
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deletingFolder = folder
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                library.setFolderArchived(folder, false)
            } label: {
                Label("Unarchive", systemImage: "tray.and.arrow.up")
            }
            .tint(.indigo)
        }
    }

    private func trackRow(_ track: Track) -> some View {
        TrackRow(
            track: track,
            isCurrent: playback.currentTrack?.id == track.id,
            onShowChapters: { chapterContext = ChapterContext(track: track, queue: library.archivedTracks) }
        )
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

struct TrackRow: View {
    let track: Track
    let isCurrent: Bool
    /// When set and the track has chapters, a tappable arrow appears after the
    /// title that opens the chapter list (instead of playing the track).
    var onShowChapters: (() -> Void)? = nil
    /// Replaces the trailing duration with something list-specific — the
    /// Recent folder shows when the track was played there instead.
    var trailingDetail: String? = nil

    private var hasArtist: Bool {
        !track.artist.isEmpty && track.artist.lowercased() != "unknown"
    }

    private var progress: Double {
        track.duration > 0 ? min(track.lastPosition / track.duration, 1) : 0
    }

    private var iconName: String {
        if track.isVideo { return "film" }
        return track.kind == .podcast ? "mic.fill" : "music.note"
    }

    /// Red marks the currently-playing track; green flags a track that hasn't
    /// been listened to yet (the Inbox set); everything else is neutral.
    private var iconColor: Color {
        if isCurrent { return .accentColor }
        if !track.hasBeenPlayed { return .green }
        return .secondary
    }

    /// Podcasts and videos resume, so they show a progress bar; songs don't.
    private var showsProgress: Bool {
        track.remembersPosition
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(track.title)
                        .font(.body)
                        .lineLimit(1)
                    // Synced tracks live in the local sync folder; the badge
                    // marks them wherever they're listed.
                    if track.isSynced {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                if showsProgress {
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

            if let onShowChapters, track.hasChapters {
                chapterButton(onShowChapters)
            }

            Spacer()

            if let trailingDetail {
                Text(trailingDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !showsProgress, track.duration > 0 {
                Text(track.duration.asPlaybackTime)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 4)
    }

    /// The chapter-list affordance: a chevron set off by a left border so it
    /// reads as a button distinct from the row's tap-to-play, echoing the
    /// disclosure arrow folders show.
    private func chapterButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.leading, 12)
                .padding(.vertical, 2)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: 1)
                        .padding(.vertical, 2)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A sheet listing a track's chapters; tapping one starts the track at that
/// marker. Carries the queue the track would normally play within so autoplay
/// continues correctly afterwards.
struct ChapterListView: View {
    @EnvironmentObject private var playback: PlaybackManager
    @Environment(\.dismiss) private var dismiss

    let track: Track
    let queue: [Track]
    let onPlay: () -> Void

    private var isCurrentTrack: Bool {
        playback.currentTrack?.id == track.id
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(track.chapters.enumerated()), id: \.element.id) { index, chapter in
                    ChapterRow(
                        progress: playback.progress,
                        chapter: chapter,
                        chapters: track.chapters,
                        index: index,
                        isCurrentTrack: isCurrentTrack
                    ) {
                        playback.play(track, in: queue, startAt: chapter.start)
                        dismiss()
                        onPlay()
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle(track.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// A row in the chapter list. Observes the playback ticker so the chapter the
/// playhead is currently in lights up red (and only while *this* track plays).
private struct ChapterRow: View {
    @ObservedObject var progress: PlaybackProgress
    let chapter: Chapter
    let chapters: [Chapter]
    let index: Int
    let isCurrentTrack: Bool
    let action: () -> Void

    private var isCurrentChapter: Bool {
        isCurrentTrack && chapters.index(at: progress.currentTime) == index
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isCurrentChapter ? "speaker.wave.2.fill" : "play.circle")
                    .font(.callout)
                    .foregroundStyle(isCurrentChapter ? Color.accentColor : .secondary)
                    .frame(width: 22)
                Text(chapter.title)
                    .font(.body)
                    .foregroundStyle(isCurrentChapter ? Color.accentColor : .primary)
                    .lineLimit(2)
                Spacer()
                Text(chapter.start.asPlaybackTime)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Identifiable bundle so a chapter sheet can be presented via `.sheet(item:)`,
/// carrying both the track and the queue it should play within.
struct ChapterContext: Identifiable {
    let id = UUID()
    let track: Track
    let queue: [Track]
}

/// The shared touch-and-hold menu for a folder row: Send to Watch, Sync to
/// Local (when a sync folder is configured), and the mixtape conversion pair —
/// Convert to Mixtape for childless plain folders, Convert to Folder for
/// mixtapes.
struct FolderContextMenu: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var localSync: LocalSyncStore

    let folder: Folder

    var body: some View {
        Button {
            library.sendFolderToWatch(folder)
        } label: {
            Label("Send to Watch", systemImage: "applewatch")
        }
        if !folder.isSynced {
            SyncToLocalMenu { rootID in
                library.syncToLocal(folder, rootID: rootID)
            }
        }
        if folder.isMixtape {
            Button {
                library.convertToFolder(folder)
            } label: {
                Label("Convert to Folder", systemImage: "folder")
            }
        } else if !library.hasSubfolders(folder.id) {
            // Mixtapes can't contain folders, so only childless folders convert.
            Button {
                library.convertToMixtape(folder)
            } label: {
                Label("Convert to Mixtape", systemImage: "recordingtape")
            }
        }
    }
}

/// The "Sync to Local" context-menu entry, root-aware: with one reachable
/// sync folder it's a plain button; with several it becomes a submenu naming
/// each folder. Renders nothing while no sync folder is reachable.
struct SyncToLocalMenu: View {
    @EnvironmentObject private var localSync: LocalSyncStore

    let action: (UUID) -> Void

    var body: some View {
        let roots = localSync.resolvedRoots
        if roots.count == 1, let only = roots.first {
            Button {
                action(only.id)
            } label: {
                Label("Sync to Local", systemImage: "arrow.triangle.2.circlepath")
            }
        } else if roots.count > 1 {
            Menu {
                ForEach(roots) { root in
                    Button(root.name) { action(root.id) }
                }
            } label: {
                Label("Sync to Local", systemImage: "arrow.triangle.2.circlepath")
            }
        }
    }
}

/// A context-menu entry that moves a track's file into a sync folder. Shows
/// itself only when a sync folder is reachable and the track isn't already
/// synced. Safe to drop into any track's `contextMenu`.
struct SyncToLocalButton: View {
    @EnvironmentObject private var library: LibraryStore

    let track: Track

    var body: some View {
        if !track.isSynced {
            SyncToLocalMenu { rootID in
                library.syncToLocal(track, rootID: rootID)
            }
        }
    }
}

/// A context-menu button that pushes a track to (or pulls it from) the Apple
/// Watch. Audio only — video isn't supported on the watch. The label toggles
/// with the track's current state. Safe to drop into any track's `contextMenu`.
struct SendToWatchButton: View {
    @EnvironmentObject private var library: LibraryStore
    let track: Track

    var body: some View {
        if !track.isVideo {
            if library.isOnWatch(track) {
                Button {
                    library.removeFromWatch(track)
                } label: {
                    Label("Remove from Watch", systemImage: "applewatch.slash")
                }
            } else {
                Button {
                    library.sendToWatch(track)
                } label: {
                    Label("Send to Watch", systemImage: "applewatch")
                }
            }
        }
    }
}

/// A context-menu button that re-runs AI organization on a single track. Shows
/// itself only when AI has been set up in Settings; for audio tracks only
/// (videos aren't music/podcasts). Safe to drop into any track's `contextMenu`.
struct AIOrganizeButton: View {
    @EnvironmentObject private var ai: AIOrganizer
    let track: Track

    var body: some View {
        if ai.isAvailable, !track.isVideo {
            Button {
                let id = track.id
                Task { await ai.organize(id) }
            } label: {
                Label("AI Organize", systemImage: "sparkles")
            }
            .disabled(ai.inFlight.contains(track.id))
        }
    }
}

/// A context-menu button that re-downloads a track from its source in the
/// **other** format — audio becomes video, video becomes audio. The fresh
/// download files into the same folder, and the original is replaced only
/// once it has fully landed (a failed conversion costs nothing — check the
/// Download tab's row). Needs the original's source link, so tracks without
/// one (local-sync imports) don't offer it. Safe to drop into any track's
/// `contextMenu`.
struct ConvertFormatButton: View {
    @EnvironmentObject private var downloads: DownloadManager
    let track: Track

    var body: some View {
        if track.sourceURL.lowercased().hasPrefix("http") {
            Button {
                downloads.enqueue(urlString: track.sourceURL,
                                  mode: track.isVideo ? .audio : .video,
                                  folderID: track.folderID,
                                  replacesTrackID: track.id)
            } label: {
                Label(track.isVideo ? "Convert to Audio" : "Convert to Video",
                      systemImage: track.isVideo ? "music.note" : "film")
            }
        }
    }
}

/// A context-menu button that finds a track's album cover on Spotify and
/// attaches it — the same app-local artwork every Spotify-sourced download
/// wears (Player, lock screen, mini player). Shows itself only when Spotify
/// credentials are saved; best-effort like every artwork fetch, so a miss
/// logs and changes nothing. Safe to drop into any track's `contextMenu`.
struct GetAlbumArtButton: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var spotifySettings: SpotifySettingsStore
    let track: Track

    var body: some View {
        if let client = spotifySettings.client {
            Button {
                fetch(with: client)
            } label: {
                Label("Get Album Art", systemImage: "photo.on.rectangle")
            }
        }
    }

    /// Search Spotify by the track's (AI-cleaned when available) artist +
    /// title, take the first hit that carries a cover, and hang it on the
    /// track through the same fetcher downloads use.
    private func fetch(with client: SpotifyClient) {
        let hasArtist = !track.artist.isEmpty && track.artist.lowercased() != "unknown"
        let query = hasArtist ? "\(track.artist) \(track.title)" : track.title
        let trackID = track.id
        let library = library
        Task {
            do {
                let hits = try await client.searchTracks(query: query)
                guard let cover = hits.first(where: { $0.albumImageURL != nil })?.albumImageURL else {
                    appLog("Get Album Art: Spotify found no match for \"\(query)\".",
                           level: .warning, category: "Spotify")
                    return
                }
                await MainActor.run {
                    ArtworkFetcher.attach(cover, to: trackID, library: library)
                }
            } catch {
                if isCancellation(error) { return }
                appLog("Get Album Art failed for \"\(query)\": \(error.localizedDescription)",
                       level: .warning, category: "Spotify")
            }
        }
    }
}
