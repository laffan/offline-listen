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

/// Shared rename-track alert: prefills the current title and, once a track has
/// ever been renamed, offers "Reset to Original" to restore the download title.
struct RenameTrackAlert: ViewModifier {
    @EnvironmentObject private var library: LibraryStore
    @Binding var track: Track?
    @State private var title = ""

    func body(content: Content) -> some View {
        content
            .onChange(of: track) { newValue in
                if let newValue { title = newValue.title }
            }
            .alert("Rename Track", isPresented: isPresented, presenting: track) { track in
                TextField("Title", text: $title)
                Button("Rename") { library.rename(track, to: title) }
                if let original = track.originalTitle, original != track.title {
                    Button("Reset to Original") { library.resetTitle(track) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { track in
                if let original = track.originalTitle, original != track.title {
                    Text("Original: \(original)")
                }
            }
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { track != nil },
            set: { if !$0 { track = nil } }
        )
    }
}

extension View {
    func renameTrackAlert(for track: Binding<Track?>) -> some View {
        modifier(RenameTrackAlert(track: track))
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

extension View {
    func breakChaptersConfirm(for track: Binding<Track?>) -> some View {
        modifier(BreakChaptersConfirm(track: track))
    }
}

/// Navigation targets reachable from the library list.
enum LibraryRoute: Hashable {
    case inbox
    case folder(UUID)
    case archived
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

    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renamingFolder: Folder?
    @State private var renameText = ""
    @State private var renamingTrack: Track?
    @State private var chapterContext: ChapterContext?
    @State private var splittingTrack: Track?

    private var filteredTracks: [Track] {
        library.unfiledActiveTracks.filter { filter.matches($0) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                if library.tracks.isEmpty && library.folders.isEmpty {
                    ContentUnavailableViewCompat(
                        title: "Your library is empty",
                        systemImage: "music.note.list",
                        description: "Downloaded tracks appear here, ready to play offline."
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    libraryList
                }
            }
            .navigationTitle("Library")
            .toolbar { toolbarContent }
            .environment(\.editMode, $editMode)
            .sheet(item: $share) { payload in
                ActivityView(items: payload.urls)
            }
            .sheet(item: $chapterContext) { context in
                ChapterListView(track: context.track, queue: context.queue, onPlay: onPlay)
            }
            .navigationDestination(for: LibraryRoute.self) { route in
                switch route {
                case .inbox:
                    InboxView(onPlay: onPlay, share: $share)
                case .folder(let id):
                    FolderDetailView(folderID: id, onPlay: onPlay, share: $share)
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
            .renameTrackAlert(for: $renamingTrack)
            .breakChaptersConfirm(for: $splittingTrack)
        }
    }

    private var renameAlertPresented: Binding<Bool> {
        Binding(
            get: { renamingFolder != nil },
            set: { if !$0 { renamingFolder = nil } }
        )
    }

    private var libraryList: some View {
        List(selection: $selection) {
            // Folders are hidden while selecting tracks for bulk actions.
            if !editMode.isEditing {
                Section {
                    inboxRow
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
                    if !library.archivedTracks.isEmpty || !library.archivedFolders.isEmpty {
                        archiveRow
                    }
                } header: {
                    foldersHeader
                }
            }

            Section {
                ForEach(filteredTracks) { track in
                    row(for: track)
                }
                if filteredTracks.isEmpty && !library.unfiledActiveTracks.isEmpty {
                    Text("Nothing in \(filter.displayName)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                if !editMode.isEditing {
                    tracksHeader
                }
            }
        }
        .listStyle(.plain)
    }

    /// "Folders" label with a trailing toggle to sort by name or User Order.
    private var foldersHeader: some View {
        HStack {
            Text("Folders")
            Spacer()
            Menu {
                Picker("Sort Folders", selection: $library.folderSort) {
                    ForEach(FolderSort.allCases) { sort in
                        Text(sort.displayName).tag(sort)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down")
                    Text(library.folderSort.displayName)
                }
                .font(.caption)
                .textCase(nil)
            }
        }
    }

    /// "Tracks" label with the media-type filter directly beneath it.
    private var tracksHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tracks")
            if !library.activeTracks.isEmpty {
                Picker("Filter", selection: $filter) {
                    ForEach(LibraryFilter.allCases) { f in
                        Text(f.displayName).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .textCase(nil)
                .padding(.bottom, 4)
            }
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

    /// The Inbox is a virtual folder pinned above user folders: every active
    /// track that hasn't been listened to yet, regardless of folder.
    private var inboxRow: some View {
        NavigationLink(value: LibraryRoute.inbox) {
            HStack(spacing: 12) {
                // Red is reserved for the currently-playing location, so the
                // Inbox uses the same neutral icon tint as user folders.
                Image(systemName: "tray.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                Text("Inbox")
                    .font(.body)
                Spacer()
                Text("\(library.inboxTracks.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.vertical, 4)
        }
    }

    /// True when the currently-playing track lives in this folder, so its row
    /// can light up red like the playing track itself.
    private func isPlaying(in folder: Folder) -> Bool {
        guard let id = playback.currentTrack?.id else { return false }
        return library.tracks(in: folder.id).contains { $0.id == id }
    }

    private func folderRow(_ folder: Folder) -> some View {
        let playingHere = isPlaying(in: folder)
        return NavigationLink(value: LibraryRoute.folder(folder.id)) {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(playingHere ? Color.accentColor : .secondary)
                    .frame(width: 24)
                Text(folder.name)
                    .font(.body)
                    .lineLimit(1)
                Spacer()
                Text("\(library.tracks(in: folder.id).count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.vertical, 4)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                library.deleteFolder(folder)
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
    }

    // MARK: - Track rows

    @ViewBuilder
    private func row(for track: Track) -> some View {
        let base = TrackRow(
            track: track,
            isCurrent: playback.currentTrack?.id == track.id,
            onShowChapters: { chapterContext = ChapterContext(track: track, queue: filteredTracks) }
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
                playback.play(track, in: filteredTracks)
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

        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if !editMode.isEditing {
                Button {
                    newFolderName = ""
                    showNewFolder = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
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
            .disabled(library.unfiledActiveTracks.isEmpty && !editMode.isEditing)
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

/// The Archive: archived folders (each openable to play its tracks) above
/// individually-archived tracks. Swipe to unarchive, share, or delete.
struct ArchivedTracksView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackManager

    let onPlay: () -> Void
    @Binding var share: SharePayload?

    @State private var chapterContext: ChapterContext?

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
            }
        }
        .navigationTitle("Archive")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $chapterContext) { context in
            ChapterListView(track: context.track, queue: context.queue, onPlay: onPlay)
        }
    }

    private func archivedFolderRow(_ folder: Folder) -> some View {
        NavigationLink(value: LibraryRoute.folder(folder.id)) {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                Text(folder.name)
                    .font(.body)
                    .lineLimit(1)
                Spacer()
                Text("\(library.tracks(in: folder.id).count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.vertical, 4)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                library.deleteFolder(folder)
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
                Text(track.title)
                    .font(.body)
                    .lineLimit(1)

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

            if !showsProgress, track.duration > 0 {
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
