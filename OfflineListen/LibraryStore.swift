import Foundation

/// Persists the list of downloaded tracks to a JSON index in Documents and owns
/// the lifecycle of the underlying audio files.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var folders: [Folder] = []
    /// How the library's folder list is ordered. Persisted so the choice sticks
    /// across launches.
    @Published var folderSort: FolderSort = .userOrder {
        didSet {
            guard folderSort != oldValue else { return }
            UserDefaults.standard.set(folderSort.rawValue, forKey: Self.folderSortKey)
        }
    }

    private static let folderSortKey = "folderSort"

    /// Folders the user has archived are hidden from the main library.
    var activeFolders: [Folder] { folders.filter { !$0.isArchived } }
    /// Archived folders, surfaced inside the Archive.
    var archivedFolders: [Folder] { folders.filter { $0.isArchived } }

    /// Active folders in the order the library should display them: the user's
    /// hand-set drag order, or alphabetically by name.
    var displayedFolders: [Folder] {
        switch folderSort {
        case .userOrder:
            return activeFolders
        case .name:
            return activeFolders.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    /// True when a track's folder has itself been archived (so the track is
    /// effectively archived along with it).
    private func folderArchived(_ folderID: UUID?) -> Bool {
        guard let folderID else { return false }
        return folders.first(where: { $0.id == folderID })?.isArchived ?? false
    }

    var activeTracks: [Track] { tracks.filter { !$0.isArchived && !folderArchived($0.folderID) } }
    /// Individually-archived loose tracks (not those merely living in an
    /// archived folder, which are reached by opening the folder in the Archive).
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
        if let raw = UserDefaults.standard.string(forKey: Self.folderSortKey),
           let sort = FolderSort(rawValue: raw) {
            folderSort = sort
        }
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

    @discardableResult
    func createFolder(named name: String) -> Folder? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let folder = Folder(name: trimmed)
        folders.append(folder)
        saveFolders()
        return folder
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

    /// Archives or unarchives a folder. The folder's tracks ride along — they
    /// stay assigned to it and reappear in the library when it's unarchived.
    func setFolderArchived(_ folder: Folder, _ archived: Bool) {
        guard let index = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        folders[index].isArchived = archived
        saveFolders()
    }

    /// Reorders the active folders, setting the persisted "User Order". The
    /// active folders are permuted among the slots they occupy in the full
    /// folders array, so archived folders keep their positions.
    func moveFolders(fromOffsets source: IndexSet, toOffset destination: Int) {
        let slots = folders.indices.filter { !folders[$0].isArchived }
        var active = slots.map { folders[$0] }
        active.move(fromOffsets: source, toOffset: destination)
        for (slot, folder) in zip(slots, active) {
            folders[slot] = folder
        }
        saveFolders()
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

    /// Inserts several tracks at the top of the library, keeping their order.
    func addTracks(_ newTracks: [Track]) {
        guard !newTracks.isEmpty else { return }
        tracks.insert(contentsOf: newTracks, at: 0)
        save()
    }

    // MARK: - Chapters → playlist

    /// Breaks a track that has chapter markers into a folder of one track per
    /// chapter, exporting a slice of the original file for each. The new folder
    /// is named after the original track. When `deleteOriginal` is true the
    /// source track is removed once the slices are in place; otherwise it stays
    /// in the library alongside the new playlist. Runs the exports off the main
    /// actor; library mutation stays on the main actor.
    func breakChaptersIntoPlaylist(_ track: Track, deleteOriginal: Bool) {
        guard track.hasChapters else { return }
        guard let current = tracks.first(where: { $0.id == track.id }) else { return }
        let chapters = current.chapters
        let sourceURL = current.fileURL
        let isVideo = current.isVideo
        let kind = current.kind
        let sourceURLString = current.sourceURL
        // The original's known duration bounds the final chapter when yt-dlp's
        // end_time is missing or runs past the file.
        let totalDuration = current.duration

        appLog("Breaking \"\(current.title)\" into \(chapters.count) chapters…",
               level: .warning, category: "Chapters")

        guard let folder = createFolder(named: current.title) else { return }

        Task { [weak self] in
            var newTracks: [Track] = []
            for (offset, chapter) in chapters.enumerated() {
                let start = chapter.start
                // Prefer the chapter's own end; fall back to the next chapter's
                // start, then the file duration.
                var end = chapter.end
                if end <= start {
                    end = offset + 1 < chapters.count ? chapters[offset + 1].start : totalDuration
                }
                if totalDuration > 0 { end = min(end, totalDuration) }
                guard end > start else {
                    appLog("Skipping zero-length chapter \(offset + 1) (\(chapter.title)).",
                           level: .warning, category: "Chapters")
                    continue
                }
                do {
                    let prefix = String(offset + 1).leftPadded(to: 2, with: "0")
                    let fileName = try await ChapterSplitter.exportSlice(
                        from: sourceURL, start: start, end: end, isVideo: isVideo,
                        baseName: "\(prefix) \(chapter.title)")
                    let chapterTrack = Track(
                        title: chapter.title,
                        fileName: fileName,
                        sourceURL: sourceURLString,
                        duration: end - start,
                        kind: kind,
                        isVideo: isVideo,
                        folderID: folder.id,
                        hasBeenPlayed: true)
                    newTracks.append(chapterTrack)
                    appLog("Exported chapter \(offset + 1)/\(chapters.count): \(chapter.title)",
                           category: "Chapters")
                } catch {
                    appLog("Chapter \(offset + 1) (\(chapter.title)) failed: \(error.localizedDescription)",
                           level: .error, category: "Chapters")
                }
            }

            await MainActor.run {
                guard let self else { return }
                guard !newTracks.isEmpty else {
                    // Nothing exported — undo the empty folder we created.
                    self.deleteFolder(folder)
                    appLog("Breaking into playlist produced no files — leaving the original in place.",
                           level: .error, category: "Chapters")
                    return
                }
                self.addTracks(newTracks)
                if deleteOriginal {
                    self.delete(track)
                }
                appLog("Created playlist \"\(folder.name)\" with \(newTracks.count) chapter track(s)\(deleteOriginal ? "; removed the original." : "; kept the original.")",
                       level: .success, category: "Chapters")
            }
        }
    }

    /// Renames a track. The first rename records the download title so
    /// `resetTitle` can restore it later.
    func rename(_ track: Track, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = tracks.firstIndex(where: { $0.id == track.id }),
              tracks[index].title != trimmed else { return }
        if tracks[index].originalTitle == nil {
            tracks[index].originalTitle = tracks[index].title
        }
        tracks[index].title = trimmed
        save()
    }

    /// Restores a renamed track's original (download) title.
    func resetTitle(_ track: Track) {
        guard let index = tracks.firstIndex(where: { $0.id == track.id }),
              let original = tracks[index].originalTitle else { return }
        tracks[index].title = original
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

    /// Applies an AI organization result to a track in one save: sets the
    /// music/podcast kind and, for music, a clean title and artist when the model
    /// supplied them. A title change records `originalTitle` (like a manual
    /// rename) so "Reset to Original" can still restore the download title.
    func applyAIOrganization(to id: UUID, kind: TrackKind, cleanTitle: String?, artist: String?) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }

        tracks[index].kind = kind
        if kind == .song { tracks[index].lastPosition = 0 }

        if let cleanTitle, !cleanTitle.isEmpty, tracks[index].title != cleanTitle {
            if tracks[index].originalTitle == nil {
                tracks[index].originalTitle = tracks[index].title
            }
            tracks[index].title = cleanTitle
        }

        if let artist, !artist.isEmpty {
            tracks[index].artist = artist
        }

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
