import Foundation

/// Persists the list of downloaded tracks to a JSON index in Documents and owns
/// the lifecycle of the underlying audio files.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var folders: [Folder] = []

    var activeTracks: [Track] { tracks.filter { !$0.isArchived } }
    var archivedTracks: [Track] { tracks.filter { $0.isArchived } }
    /// Active tracks not assigned to any folder — the main library list.
    var unfiledActiveTracks: [Track] { activeTracks.filter { $0.folderID == nil } }
    /// Active tracks that haven't been listened to yet — the Inbox.
    var inboxTracks: [Track] { activeTracks.filter { !$0.hasBeenPlayed } }

    /// Active tracks in a folder, in library order (which doubles as the
    /// folder's user-set order; see `moveTracks(in:fromOffsets:toOffset:)`).
    func tracks(in folderID: UUID) -> [Track] {
        tracks.filter { $0.folderID == folderID && !$0.isArchived }
    }

    init() {
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: AppPaths.libraryIndex) else {
            tracks = []
            loadFolders()
            return
        }
        do {
            tracks = try JSONDecoder().decode([Track].self, from: data)
        } catch {
            print("[LibraryStore] failed to decode index: \(error)")
            tracks = []
        }
        loadFolders()
    }

    private func loadFolders() {
        guard let data = try? Data(contentsOf: AppPaths.foldersIndex) else {
            folders = []
            return
        }
        do {
            folders = try JSONDecoder().decode([Folder].self, from: data)
        } catch {
            print("[LibraryStore] failed to decode folders: \(error)")
            folders = []
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(tracks)
            try data.write(to: AppPaths.libraryIndex, options: .atomic)
        } catch {
            print("[LibraryStore] failed to save index: \(error)")
        }
    }

    private func saveFolders() {
        do {
            let data = try JSONEncoder().encode(folders)
            try data.write(to: AppPaths.foldersIndex, options: .atomic)
        } catch {
            print("[LibraryStore] failed to save folders: \(error)")
        }
    }

    // MARK: - Folders

    func createFolder(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        folders.append(Folder(name: trimmed))
        saveFolders()
    }

    func renameFolder(_ folder: Folder, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        folders[index].name = trimmed
        saveFolders()
    }

    /// Removes the folder only; its tracks keep their files and return to the
    /// main library list.
    func deleteFolder(_ folder: Folder) {
        folders.removeAll { $0.id == folder.id }
        saveFolders()
        var changed = false
        for index in tracks.indices where tracks[index].folderID == folder.id {
            tracks[index].folderID = nil
            changed = true
        }
        if changed { save() }
    }

    /// Moves a track into a folder (or out of all folders with nil).
    func setFolder(_ track: Track, _ folderID: UUID?) {
        guard let index = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        tracks[index].folderID = folderID
        save()
    }

    /// Reorders a folder's tracks. The folder's members are permuted among the
    /// array slots they already occupy, so every other track keeps its position.
    func moveTracks(in folderID: UUID, fromOffsets source: IndexSet, toOffset destination: Int) {
        let slots = tracks.indices.filter { tracks[$0].folderID == folderID && !tracks[$0].isArchived }
        var folderTracks = slots.map { tracks[$0] }
        folderTracks.move(fromOffsets: source, toOffset: destination)
        for (slot, track) in zip(slots, folderTracks) {
            tracks[slot] = track
        }
        save()
    }

    /// "Moves" a track to the Inbox: back to not-yet-listened and out of any
    /// folder (the Inbox is its own location in the UI).
    func moveToInbox(_ track: Track) {
        guard let index = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        tracks[index].folderID = nil
        tracks[index].hasBeenPlayed = false
        save()
    }

    // MARK: - Played state (Inbox)

    /// Marks a track as listened-to (or not), moving it out of (or into) the Inbox.
    func markPlayed(_ id: UUID, _ played: Bool = true) {
        guard let index = tracks.firstIndex(where: { $0.id == id }),
              tracks[index].hasBeenPlayed != played else { return }
        tracks[index].hasBeenPlayed = played
        save()
    }

    /// Empties the Inbox in one go.
    func markAllPlayed() {
        var changed = false
        for index in tracks.indices where !tracks[index].hasBeenPlayed {
            tracks[index].hasBeenPlayed = true
            changed = true
        }
        if changed { save() }
    }

    /// Adds a freshly downloaded track to the top of the library.
    func add(_ track: Track) {
        tracks.insert(track, at: 0)
        save()
    }

    /// Archives or unarchives a track.
    func setArchived(_ track: Track, _ archived: Bool) {
        guard let index = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        tracks[index].isArchived = archived
        save()
    }

    /// Classifies a track as a song or podcast. Switching to song clears any
    /// saved playhead (songs always start from the beginning).
    func setKind(_ track: Track, _ kind: TrackKind) {
        guard let index = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        tracks[index].kind = kind
        if kind == .song { tracks[index].lastPosition = 0 }
        save()
    }

    /// Records a podcast's playhead. No-ops for tiny changes to limit churn.
    func updatePosition(for id: UUID, to position: Double) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        guard abs(tracks[index].lastPosition - position) >= 1 else { return }
        tracks[index].lastPosition = position
        save()
    }

    /// Removes a track from the library and deletes its audio file from disk.
    func delete(_ track: Track) {
        try? FileManager.default.removeItem(at: track.fileURL)
        tracks.removeAll { $0.id == track.id }
        save()
    }

    func delete(at offsets: IndexSet) {
        for index in offsets {
            try? FileManager.default.removeItem(at: tracks[index].fileURL)
        }
        tracks.remove(atOffsets: offsets)
        save()
    }
}
