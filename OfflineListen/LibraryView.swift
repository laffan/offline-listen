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

/// Navigation targets reachable from the library list.
enum LibraryRoute: Hashable {
    case inbox
    case folder(UUID)
    /// Same destination as `.folder`, but lands with reordering already active.
    case folderReorder(UUID)
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
    @State private var filter: LibraryFilter = .all
    @State private var path: [LibraryRoute] = []

    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renamingFolder: Folder?
    @State private var renameText = ""
    @State private var renamingTrack: Track?

    private var filteredTracks: [Track] {
        library.unfiledActiveTracks.filter { filter.matches($0) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                if !library.activeTracks.isEmpty {
                    Picker("Filter", selection: $filter) {
                        ForEach(LibraryFilter.allCases) { f in
                            Text(f.displayName).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
                }

                if library.activeTracks.isEmpty && library.folders.isEmpty {
                    ContentUnavailableViewCompat(
                        title: library.tracks.isEmpty ? "Your library is empty" : "No active tracks",
                        systemImage: "music.note.list",
                        description: library.tracks.isEmpty
                            ? "Downloaded tracks appear here, ready to play offline."
                            : "Everything is archived — open the Archived folder above."
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
            .navigationDestination(isPresented: $showArchived) {
                ArchivedTracksView(onPlay: onPlay, share: $share)
            }
            .navigationDestination(for: LibraryRoute.self) { route in
                switch route {
                case .inbox:
                    InboxView(onPlay: onPlay, share: $share)
                case .folder(let id):
                    FolderDetailView(folderID: id, startReordering: false, onPlay: onPlay, share: $share)
                case .folderReorder(let id):
                    FolderDetailView(folderID: id, startReordering: true, onPlay: onPlay, share: $share)
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
                    ForEach(library.folders) { folder in
                        folderRow(folder)
                    }
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
                    Text("Tracks")
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Folder rows

    /// The Inbox is a virtual folder pinned above user folders: every active
    /// track that hasn't been listened to yet, regardless of folder.
    private var inboxRow: some View {
        NavigationLink(value: LibraryRoute.inbox) {
            HStack(spacing: 12) {
                Image(systemName: "tray.fill")
                    .foregroundStyle(Color.accentColor)
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

    private func folderRow(_ folder: Folder) -> some View {
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
                renameText = folder.name
                renamingFolder = folder
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.orange)
            Button {
                path.append(.folderReorder(folder.id))
            } label: {
                Label("Reorder", systemImage: "arrow.up.arrow.down")
            }
            .tint(.blue)
        }
    }

    // MARK: - Track rows

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
                    ForEach(library.folders) { folder in
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
                        ForEach(library.folders) { folder in
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
        } else if !library.archivedTracks.isEmpty {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    showArchived = true
                } label: {
                    Label("Archived (\(library.archivedTracks.count))", systemImage: "archivebox")
                }
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

struct TrackRow: View {
    let track: Track
    let isCurrent: Bool

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

    /// Podcasts (audio only) show a resume progress bar.
    private var showsProgress: Bool {
        track.kind == .podcast && !track.isVideo
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
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
}
