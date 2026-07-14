import Foundation
import AVFoundation

/// Persists the list of downloaded tracks to a JSON index in Documents and owns
/// the lifecycle of the underlying audio files.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var folders: [Folder] = []
    /// Bumped whenever a mixtape cover image is (re)written, so views that
    /// render covers from disk know to reload even when the style is unchanged.
    @Published private(set) var coverRevision = 0
    /// How the library's folder list is ordered. Persisted so the choice sticks
    /// across launches.
    @Published var folderSort: FolderSort = .userOrder {
        didSet {
            guard folderSort != oldValue else { return }
            UserDefaults.standard.set(folderSort.rawValue, forKey: Self.folderSortKey)
        }
    }

    private static let folderSortKey = "folderSort"

    /// Set by `LocalSyncStore`: receives a `SyncOp` for every in-app change to
    /// synced content, so the change is written through to the sync folder
    /// (immediately, or later if it's unreachable). Local file operations
    /// never wait on it — the replica catches up.
    var syncExporter: ((SyncOp) -> Void)?

    private func exportOp(_ op: SyncOp) {
        syncExporter?(op)
    }

    /// True when a folder — or any of its ancestors — has been archived, so the
    /// whole subtree hides from the main library.
    func folderArchived(_ folderID: UUID?) -> Bool {
        var currentID = folderID
        var hops = 0
        while let id = currentID, hops < 64 {
            guard let folder = folders.first(where: { $0.id == id }) else { return false }
            if folder.isArchived { return true }
            currentID = folder.parentID
            hops += 1
        }
        return false
    }

    /// Folders the user has archived (directly or via an ancestor) are hidden
    /// from the main library.
    var activeFolders: [Folder] { folders.filter { !folderArchived($0.id) } }
    /// Directly-archived folders, surfaced inside the Archive. (Their
    /// descendants ride along and are reached by opening them there.)
    var archivedFolders: [Folder] { folders.filter { $0.isArchived } }

    /// Active folders in the order the library should display them: the user's
    /// hand-set drag order, or alphabetically by name.
    var displayedFolders: [Folder] {
        sorted(activeFolders.filter { $0.parentID == nil })
    }

    /// A folder's active subfolders, in display order.
    func childFolders(of folderID: UUID) -> [Folder] {
        sorted(activeFolders.filter { $0.parentID == folderID })
    }

    /// True when the folder contains subfolders (which bars it from becoming a
    /// mixtape — mixtapes can't contain folders).
    func hasSubfolders(_ folderID: UUID) -> Bool {
        folders.contains { $0.parentID == folderID }
    }

    func folder(withID id: UUID) -> Folder? {
        folders.first { $0.id == id }
    }

    private func sorted(_ list: [Folder]) -> [Folder] {
        switch folderSort {
        case .userOrder:
            return list
        case .name:
            return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    var activeTracks: [Track] { tracks.filter { !$0.isArchived && !folderArchived($0.folderID) } }
    /// Individually-archived loose tracks (not those merely living in an
    /// archived folder, which are reached by opening the folder in the Archive).
    var archivedTracks: [Track] { tracks.filter { $0.isArchived } }
    /// Active tracks not assigned to any folder — the main library list.
    var unfiledActiveTracks: [Track] { activeTracks.filter { $0.folderID == nil } }
    /// Active tracks that haven't been listened to yet — the Inbox.
    var inboxTracks: [Track] { activeTracks.filter { !$0.hasBeenPlayed } }
    /// Tracks pushed to the Apple Watch — the "Watch" virtual folder. Like the
    /// Inbox, these still live wherever they normally do in the library; this is
    /// just a filtered view for managing what's on the watch.
    var watchTracks: [Track] { activeTracks.filter { $0.sentToWatch } }

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
    func createFolder(named name: String, parent parentID: UUID? = nil) -> Folder? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var newFolder = Folder(name: trimmed, parentID: parentID)
        // A folder created inside a synced folder mirrors a real directory.
        if let parentID, let parent = folder(withID: parentID), parent.isSynced,
           let parentDir = parent.syncedDirectoryURL, let parentPath = parent.syncedPath {
            let dirName = AppPaths.uniqueName(base: trimmed.sanitizedFileName(), ext: "", in: parentDir)
            do {
                try FileManager.default.createDirectory(
                    at: parentDir.appendingPathComponent(dirName, isDirectory: true),
                    withIntermediateDirectories: true)
            } catch {
                appLog("Couldn't create synced folder: \(error.localizedDescription)",
                       level: .error, category: "Sync")
                return nil
            }
            newFolder.name = dirName
            newFolder.isSynced = true
            newFolder.syncedPath = "\(parentPath)/\(dirName)"
            exportOp(.createRemoteDir(rel: "\(parentPath)/\(dirName)"))
        }
        folders.append(newFolder)
        saveFolders()
        return newFolder
    }

    func renameFolder(_ folder: Folder, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        // A synced folder mirrors a directory in the local sync store, so
        // renaming renames it there (rewriting every path recorded under it)
        // and queues the same rename for the replica.
        if folders[index].isSynced, let oldPath = folders[index].syncedPath {
            let local = AppPaths.syncLocalStore
            let parentPath = (oldPath as NSString).deletingLastPathComponent
            let parentDir = parentPath.isEmpty
                ? local
                : local.appendingPathComponent(parentPath, isDirectory: true)
            let newDirName = AppPaths.uniqueName(base: trimmed.sanitizedFileName(), ext: "", in: parentDir)
            do {
                try FileManager.default.moveItem(
                    at: local.appendingPathComponent(oldPath, isDirectory: true),
                    to: parentDir.appendingPathComponent(newDirName, isDirectory: true))
            } catch {
                appLog("Couldn't rename synced folder: \(error.localizedDescription)",
                       level: .error, category: "Sync")
                return
            }
            let newPath = parentPath.isEmpty ? newDirName : "\(parentPath)/\(newDirName)"
            rewriteSyncedPaths(from: oldPath, to: newPath)
            folders[index].name = newDirName
            saveFolders()
            save()
            exportOp(.moveRemote(from: oldPath, to: newPath))
            return
        }
        folders[index].name = trimmed
        saveFolders()
    }

    /// Rewrites the recorded sync paths of everything at or under `oldPrefix`
    /// after its directory moved to `newPrefix`.
    private func rewriteSyncedPaths(from oldPrefix: String, to newPrefix: String) {
        for index in folders.indices where folders[index].isSynced {
            guard let path = folders[index].syncedPath else { continue }
            if path == oldPrefix {
                folders[index].syncedPath = newPrefix
            } else if path.hasPrefix(oldPrefix + "/") {
                folders[index].syncedPath = newPrefix + path.dropFirst(oldPrefix.count)
            }
        }
        for index in tracks.indices where tracks[index].isSynced {
            if tracks[index].fileName.hasPrefix(oldPrefix + "/") {
                tracks[index].fileName = newPrefix + tracks[index].fileName.dropFirst(oldPrefix.count)
            }
        }
    }

    /// Removes the folder only; its tracks keep their files and return to the
    /// main library list, and any subfolders move up to the deleted folder's
    /// parent. A synced folder additionally moves its files back to Documents
    /// (recursively) before its directory is removed — deleting a folder never
    /// deletes tracks.
    func deleteFolder(_ folder: Folder) {
        guard let current = folders.first(where: { $0.id == folder.id }) else { return }
        var doomed: Set<UUID> = [current.id]
        if current.isSynced {
            unsyncSubtree(of: current.id)
            doomed.formUnion(descendantFolderIDs(of: current.id))
            // Drop the doomed mixtapes' local covers.
            for target in folders where doomed.contains(target.id) && target.isMixtape {
                if let cover = target.coverURL {
                    try? FileManager.default.removeItem(at: cover)
                }
            }
            // Only remove the local directory once nothing playable is left
            // inside — removeItem is recursive, and a file whose move failed
            // must not be deleted with it.
            if let dir = current.syncedDirectoryURL, let path = current.syncedPath {
                let stillInside = tracks.contains {
                    $0.isSynced && $0.fileName.hasPrefix(path + "/")
                }
                if stillInside {
                    appLog("Left \"\(current.name)\" in place — some files couldn't be moved out.",
                           level: .warning, category: "Sync")
                } else {
                    try? FileManager.default.removeItem(at: dir)
                    // Mirror the removal to the replica (its copies go too).
                    exportOp(.removeRemote(rel: path))
                }
            }
            folders.removeAll { doomed.contains($0.id) }
        } else {
            if let cover = current.coverURL {
                try? FileManager.default.removeItem(at: cover)
            }
            for index in folders.indices where folders[index].parentID == current.id {
                folders[index].parentID = current.parentID
            }
            folders.removeAll { $0.id == current.id }
        }
        saveFolders()
        var changed = false
        for index in tracks.indices {
            guard let folderID = tracks[index].folderID, doomed.contains(folderID) else { continue }
            tracks[index].folderID = nil
            changed = true
        }
        if changed { save() }
    }

    /// Every folder id nested (at any depth) under `folderID`.
    private func descendantFolderIDs(of folderID: UUID) -> [UUID] {
        var result: [UUID] = []
        var frontier = [folderID]
        while let current = frontier.popLast() {
            let children = folders.filter { $0.parentID == current }.map { $0.id }
            result.append(contentsOf: children)
            frontier.append(contentsOf: children)
        }
        return result
    }

    /// Moves every synced file at or under `folderID` out of the local sync
    /// store into Documents and unfiles the tracks, bottom-up, so the
    /// directory tree can be removed without deleting anything playable. Each
    /// move queues the matching removal for the replica (else the next import
    /// would copy the file straight back in).
    private func unsyncSubtree(of folderID: UUID) {
        for child in folders where child.parentID == folderID {
            unsyncSubtree(of: child.id)
        }
        for index in tracks.indices where tracks[index].folderID == folderID && tracks[index].isSynced {
            let source = tracks[index].fileURL
            let oldRel = tracks[index].fileName
            let last = (oldRel as NSString).lastPathComponent
            let newName = AppPaths.uniqueDocumentName(
                base: (last as NSString).deletingPathExtension,
                ext: (last as NSString).pathExtension)
            do {
                try FileManager.default.moveItem(
                    at: source, to: AppPaths.documents.appendingPathComponent(newName))
                tracks[index].fileName = newName
                tracks[index].isSynced = false
                tracks[index].folderID = nil
                exportOp(.removeRemote(rel: oldRel))
            } catch {
                appLog("Couldn't move \"\(tracks[index].title)\" out of the sync folder: \(error.localizedDescription)",
                       level: .error, category: "Sync")
            }
        }
    }

    /// Archives or unarchives a folder. The folder's tracks ride along — they
    /// stay assigned to it and reappear in the library when it's unarchived.
    func setFolderArchived(_ folder: Folder, _ archived: Bool) {
        guard let index = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        folders[index].isArchived = archived
        saveFolders()
    }

    /// Reorders the active root folders, setting the persisted "User Order".
    /// The root folders are permuted among the slots they occupy in the full
    /// folders array, so archived and nested folders keep their positions.
    func moveFolders(fromOffsets source: IndexSet, toOffset destination: Int) {
        let slots = folders.indices.filter {
            folders[$0].parentID == nil && !folderArchived(folders[$0].id)
        }
        var active = slots.map { folders[$0] }
        active.move(fromOffsets: source, toOffset: destination)
        for (slot, folder) in zip(slots, active) {
            folders[slot] = folder
        }
        saveFolders()
    }

    /// Moves a track into a folder (or out of all folders with nil). When the
    /// move crosses the local-sync boundary the file is physically relocated
    /// too — the sync folder mirrors the library, so a track's file must live
    /// where the library says it does. A failed relocation aborts the move.
    func setFolder(_ track: Track, _ folderID: UUID?) {
        guard let index = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        guard relocateFile(at: index, toFolder: folderID) else { return }
        tracks[index].folderID = folderID
        save()
    }

    /// Physically moves a track's file to match a folder assignment: into the
    /// destination's directory in the local sync store when that folder is
    /// synced, back to Documents when a synced track leaves the synced tree —
    /// queueing the matching replica op either way. Returns false (after
    /// logging) when a required move failed; pure library moves return true
    /// untouched.
    private func relocateFile(at index: Int, toFolder folderID: UUID?) -> Bool {
        let track = tracks[index]
        let destFolder = folderID.flatMap { folder(withID: $0) }
        let last = (track.fileName as NSString).lastPathComponent
        let base = (last as NSString).deletingPathExtension
        let ext = (last as NSString).pathExtension

        if let destFolder, destFolder.isSynced, let dirPath = destFolder.syncedPath,
           let dir = destFolder.syncedDirectoryURL {
            // Already in exactly that directory — nothing to move.
            if track.isSynced, (track.fileName as NSString).deletingLastPathComponent == dirPath {
                return true
            }
            let newName = AppPaths.uniqueName(base: base, ext: ext, in: dir)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: track.fileURL, to: dir.appendingPathComponent(newName))
            } catch {
                appLog("Couldn't move \"\(track.title)\" into the synced folder: \(error.localizedDescription)",
                       level: .error, category: "Sync")
                return false
            }
            let oldRel = track.fileName
            let newRel = "\(dirPath)/\(newName)"
            tracks[index].fileName = newRel
            let wasSynced = tracks[index].isSynced
            tracks[index].isSynced = true
            exportOp(wasSynced ? .moveRemote(from: oldRel, to: newRel) : .copyOut(rel: newRel))
            return true
        }

        // Destination is the plain library (or an unsynced folder): a synced
        // file returns to Documents and its replica copy is removed.
        guard track.isSynced else { return true }
        let newName = AppPaths.uniqueDocumentName(base: base, ext: ext)
        do {
            try FileManager.default.moveItem(at: track.fileURL,
                                             to: AppPaths.documents.appendingPathComponent(newName))
        } catch {
            appLog("Couldn't move \"\(track.title)\" out of the sync folder: \(error.localizedDescription)",
                   level: .error, category: "Sync")
            return false
        }
        exportOp(.removeRemote(rel: track.fileName))
        tracks[index].fileName = newName
        tracks[index].isSynced = false
        return true
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
    /// folder (the Inbox is its own location in the UI). A synced track leaves
    /// the sync folder in the process, like any move out of the synced tree.
    func moveToInbox(_ track: Track) {
        guard let index = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        guard relocateFile(at: index, toFolder: nil) else { return }
        tracks[index].folderID = nil
        tracks[index].hasBeenPlayed = false
        save()
    }

    // MARK: - Local sync

    /// True once a sync folder has been configured and resolved, gating the
    /// "Sync to Local" actions.
    var isSyncAvailable: Bool { AppPaths.syncRoot != nil }

    /// Moves a track's file into the local sync store (at its top level),
    /// marks it synced, and queues the copy-out to the replica. It behaves
    /// like any other track afterwards — it just wears the sync icon and
    /// mirrors to the sync folder.
    func syncToLocal(_ track: Track) {
        guard isSyncAvailable,
              let index = tracks.firstIndex(where: { $0.id == track.id }),
              !tracks[index].isSynced else { return }
        let local = AppPaths.syncLocalStore
        let last = (tracks[index].fileName as NSString).lastPathComponent
        let newName = AppPaths.uniqueName(
            base: (last as NSString).deletingPathExtension,
            ext: (last as NSString).pathExtension,
            in: local)
        do {
            try FileManager.default.moveItem(at: tracks[index].fileURL,
                                             to: local.appendingPathComponent(newName))
        } catch {
            appLog("Couldn't sync \"\(track.title)\" to local: \(error.localizedDescription)",
                   level: .error, category: "Sync")
            return
        }
        tracks[index].fileName = newName
        tracks[index].isSynced = true
        tracks[index].folderID = nil
        save()
        exportOp(.copyOut(rel: newName))
        appLog("Synced \"\(track.title)\" to local.", level: .success, category: "Sync")
    }

    /// Moves a folder — tracks, subfolders and all — into the local sync
    /// store as a directory tree at its top level and queues the exports. A
    /// mixtape brings its style and cover along as a `.mixtapedata` write.
    func syncToLocal(_ folder: Folder) {
        guard isSyncAvailable,
              let index = folders.firstIndex(where: { $0.id == folder.id }),
              !folders[index].isSynced else { return }
        let local = AppPaths.syncLocalStore
        let dirName = AppPaths.uniqueName(base: folder.name.sanitizedFileName(), ext: "", in: local)
        do {
            try FileManager.default.createDirectory(
                at: local.appendingPathComponent(dirName, isDirectory: true),
                withIntermediateDirectories: true)
        } catch {
            appLog("Couldn't create \"\(dirName)\" in the sync store: \(error.localizedDescription)",
                   level: .error, category: "Sync")
            return
        }
        markSynced(at: index, path: dirName, name: dirName)
        // The synced tree mirrors the sync folder, so a synced folder always
        // sits at the root of the library's folder list.
        folders[index].parentID = nil
        syncContents(of: folder.id)
        saveFolders()
        save()
        appLog("Synced folder \"\(folders[index].name)\" to local.", level: .success, category: "Sync")
    }

    /// Marks a folder synced at `path` and queues its replica directory (and,
    /// for a mixtape, its `.mixtapedata`). The cover image stays app-local.
    private func markSynced(at index: Int, path: String, name: String) {
        folders[index].name = name
        folders[index].isSynced = true
        folders[index].syncedPath = path
        exportOp(.createRemoteDir(rel: path))
        if folders[index].isMixtape {
            exportOp(.writeMixtapeData(dir: path, folderID: folders[index].id))
        }
    }

    /// Recursively moves a folder's tracks and subfolders into its (already
    /// created) directory in the local sync store, queueing each export.
    private func syncContents(of folderID: UUID) {
        guard let parent = folder(withID: folderID),
              let parentPath = parent.syncedPath,
              let parentDir = parent.syncedDirectoryURL else { return }
        for index in tracks.indices where tracks[index].folderID == folderID && !tracks[index].isSynced {
            let last = (tracks[index].fileName as NSString).lastPathComponent
            let newName = AppPaths.uniqueName(
                base: (last as NSString).deletingPathExtension,
                ext: (last as NSString).pathExtension,
                in: parentDir)
            do {
                try FileManager.default.moveItem(at: tracks[index].fileURL,
                                                 to: parentDir.appendingPathComponent(newName))
                tracks[index].fileName = "\(parentPath)/\(newName)"
                tracks[index].isSynced = true
                exportOp(.copyOut(rel: "\(parentPath)/\(newName)"))
            } catch {
                appLog("Couldn't sync \"\(tracks[index].title)\": \(error.localizedDescription)",
                       level: .error, category: "Sync")
            }
        }
        for index in folders.indices where folders[index].parentID == folderID && !folders[index].isSynced {
            let dirName = AppPaths.uniqueName(
                base: folders[index].name.sanitizedFileName(), ext: "", in: parentDir)
            do {
                try FileManager.default.createDirectory(
                    at: parentDir.appendingPathComponent(dirName, isDirectory: true),
                    withIntermediateDirectories: true)
            } catch {
                appLog("Couldn't sync folder \"\(folders[index].name)\": \(error.localizedDescription)",
                       level: .error, category: "Sync")
                continue
            }
            markSynced(at: index, path: "\(parentPath)/\(dirName)", name: dirName)
            syncContents(of: folders[index].id)
        }
    }

    // MARK: - Local sync: importer primitives (driven by LocalSyncStore)

    /// Reconciles synced folders against the replica's directory list: new
    /// directories appear as folders (parents before children), vanished ones
    /// disappear, and mixtape styles are adopted for the paths the importer
    /// says actually changed remotely. Returns the path → folder-id map and
    /// re-derives every synced track's folder membership from its path.
    func reconcileSyncedFolders(_ dirs: [SyncSnapshot.Directory],
                                adoptStyleFor adopt: Set<String>) -> [String: UUID] {
        var foldersChanged = false
        var tracksChanged = false

        var byPath: [String: UUID] = [:]
        for folder in folders where folder.isSynced {
            if let path = folder.syncedPath { byPath[path] = folder.id }
        }

        for dir in dirs.sorted(by: {
            $0.relativePath.components(separatedBy: "/").count <
                $1.relativePath.components(separatedBy: "/").count
        }) {
            if let id = byPath[dir.relativePath],
               let index = folders.firstIndex(where: { $0.id == id }) {
                guard adopt.contains(dir.relativePath) else { continue }
                if let style = dir.mixtapeStyle {
                    if !folders[index].isMixtape || folders[index].mixtape != style {
                        folders[index].isMixtape = true
                        folders[index].mixtape = style
                        foldersChanged = true
                    }
                } else if folders[index].isMixtape {
                    // .mixtapedata was removed remotely — plain folder again.
                    if let cover = folders[index].coverURL {
                        try? FileManager.default.removeItem(at: cover)
                    }
                    folders[index].isMixtape = false
                    folders[index].mixtape = MixtapeStyle()
                    foldersChanged = true
                }
            } else {
                let parentPath = (dir.relativePath as NSString).deletingLastPathComponent
                let newFolder = Folder(
                    name: (dir.relativePath as NSString).lastPathComponent,
                    parentID: parentPath.isEmpty ? nil : byPath[parentPath],
                    isSynced: true,
                    syncedPath: dir.relativePath,
                    isMixtape: dir.mixtapeStyle != nil,
                    mixtape: dir.mixtapeStyle ?? MixtapeStyle())
                folders.append(newFolder)
                byPath[dir.relativePath] = newFolder.id
                foldersChanged = true
            }
        }

        let livePaths = Set(dirs.map { $0.relativePath })
        let vanished = folders.filter { $0.isSynced && !livePaths.contains($0.syncedPath ?? "") }
        if !vanished.isEmpty {
            let doomed = Set(vanished.map { $0.id })
            for gone in vanished where gone.isMixtape {
                if let cover = gone.coverURL {
                    try? FileManager.default.removeItem(at: cover)
                }
            }
            folders.removeAll { doomed.contains($0.id) }
            for path in vanished.compactMap({ $0.syncedPath }) { byPath[path] = nil }
            foldersChanged = true
        }

        // Membership follows the path (covers a directory that was recreated
        // and got a fresh folder id).
        for index in tracks.indices where tracks[index].isSynced {
            let dirPath = (tracks[index].fileName as NSString).deletingLastPathComponent
            let expected = dirPath.isEmpty ? nil : byPath[dirPath]
            if tracks[index].folderID != expected {
                tracks[index].folderID = expected
                tracksChanged = true
            }
        }

        if foldersChanged { saveFolders() }
        if tracksChanged { save() }
        return byPath
    }

    /// Removes every synced track whose replica file is gone, deleting its
    /// local copy too. Non-synced tracks are never touched.
    func removeSyncedTracks(notIn remotePaths: Set<String>) {
        let victims = tracks.filter { $0.isSynced && !remotePaths.contains($0.fileName) }
        guard !victims.isEmpty else { return }
        let wasOnWatch = victims.contains { $0.sentToWatch }
        for victim in victims {
            try? FileManager.default.removeItem(at: victim.fileURL)
        }
        let ids = Set(victims.map { $0.id })
        tracks.removeAll { ids.contains($0.id) }
        save()
        if wasOnWatch { syncWatch() }
    }

    func hasSyncedTrack(at relativePath: String) -> Bool {
        tracks.contains { $0.isSynced && $0.fileName == relativePath }
    }

    /// Registers a synced track for a file the importer just copied in (or
    /// refreshes an existing one's folder/duration).
    func ensureSyncedTrack(at relativePath: String, folderID: UUID?) {
        if let index = tracks.firstIndex(where: { $0.isSynced && $0.fileName == relativePath }) {
            if tracks[index].folderID != folderID {
                tracks[index].folderID = folderID
                save()
            }
            if tracks[index].duration <= 0 {
                loadDurations(for: [tracks[index].id])
            }
            return
        }
        let last = (relativePath as NSString).lastPathComponent
        let track = Track(
            title: (last as NSString).deletingPathExtension,
            fileName: relativePath,
            sourceURL: "",
            isVideo: PlayableMedia.isVideo(extension: (last as NSString).pathExtension),
            folderID: folderID,
            isSynced: true)
        tracks.append(track)
        save()
        loadDurations(for: [track.id])
    }

    /// Lets the importer signal that a cover image file changed on disk.
    func bumpCoverRevision() {
        coverRevision += 1
    }

    /// Un-configuring the sync folder: synced tracks become regular local
    /// tracks (their files move from the local sync store into Documents),
    /// folders stay but stop being synced, and the replica is left untouched.
    /// Tracks whose files were never imported have nothing to keep and are
    /// dropped.
    func unsyncEverything() {
        var dropIDs: Set<UUID> = []
        var changedTracks = false
        for index in tracks.indices where tracks[index].isSynced {
            changedTracks = true
            let source = tracks[index].fileURL
            guard FileManager.default.fileExists(atPath: source.path) else {
                dropIDs.insert(tracks[index].id)
                continue
            }
            let last = (tracks[index].fileName as NSString).lastPathComponent
            let newName = AppPaths.uniqueDocumentName(
                base: (last as NSString).deletingPathExtension,
                ext: (last as NSString).pathExtension)
            do {
                try FileManager.default.moveItem(
                    at: source, to: AppPaths.documents.appendingPathComponent(newName))
                tracks[index].fileName = newName
                tracks[index].isSynced = false
            } catch {
                appLog("Couldn't keep \"\(tracks[index].title)\" locally: \(error.localizedDescription)",
                       level: .error, category: "Sync")
            }
        }
        if !dropIDs.isEmpty {
            tracks.removeAll { dropIDs.contains($0.id) }
        }
        var changedFolders = false
        for index in folders.indices where folders[index].isSynced {
            folders[index].isSynced = false
            folders[index].syncedPath = nil
            changedFolders = true
        }
        // Clear the emptied local store — but never while a failed move left
        // a playable file inside (removeItem is recursive).
        if !tracks.contains(where: { $0.isSynced }) {
            try? FileManager.default.removeItem(at: AppPaths.syncLocalStore)
        }
        if changedTracks {
            save()
            syncWatch()
        }
        if changedFolders { saveFolders() }
    }

    /// Best-effort duration probe for tracks that appeared via a sync scan
    /// (downloads know their duration; external files don't until read).
    private func loadDurations(for ids: [UUID]) {
        Task {
            var changed = false
            for id in ids {
                guard let index = tracks.firstIndex(where: { $0.id == id }) else { continue }
                let asset = AVURLAsset(url: tracks[index].fileURL)
                guard let duration = try? await asset.load(.duration).seconds,
                      duration.isFinite, duration > 0,
                      let liveIndex = tracks.firstIndex(where: { $0.id == id }) else { continue }
                tracks[liveIndex].duration = duration
                changed = true
            }
            if changed { save() }
        }
    }

    // MARK: - Mixtapes

    /// Turns a folder into a mixtape. Only childless folders qualify —
    /// mixtapes can't contain folders. A synced folder queues its
    /// `.mixtapedata` for the replica.
    func convertToMixtape(_ folder: Folder) {
        guard let index = folders.firstIndex(where: { $0.id == folder.id }),
              !folders[index].isMixtape,
              !hasSubfolders(folder.id) else { return }
        folders[index].isMixtape = true
        if folders[index].isSynced, let path = folders[index].syncedPath {
            exportOp(.writeMixtapeData(dir: path, folderID: folders[index].id))
        }
        saveFolders()
    }

    /// Turns a mixtape back into a plain folder, discarding its cover image
    /// and style (and queueing removal of a synced mixtape's `.mixtapedata`).
    func convertToFolder(_ folder: Folder) {
        guard let index = folders.firstIndex(where: { $0.id == folder.id }),
              folders[index].isMixtape else { return }
        if let cover = folders[index].coverURL {
            try? FileManager.default.removeItem(at: cover)
        }
        folders[index].isMixtape = false
        folders[index].mixtape = MixtapeStyle()
        if folders[index].isSynced, let path = folders[index].syncedPath {
            exportOp(.removeMixtapeData(dir: path))
        }
        saveFolders()
    }

    /// Applies the cover editor's result: the banner style and, when the user
    /// picked a new image, the cover JPEG itself. A synced mixtape queues the
    /// `.mixtapedata` rewrite for the replica.
    func setMixtapeStyle(_ folder: Folder, _ style: MixtapeStyle, coverImageData: Data? = nil) {
        guard let index = folders.firstIndex(where: { $0.id == folder.id }),
              folders[index].isMixtape else { return }
        folders[index].mixtape = style
        if let coverImageData, let cover = folders[index].coverURL {
            do {
                try FileManager.default.createDirectory(
                    at: cover.deletingLastPathComponent(), withIntermediateDirectories: true)
                try coverImageData.write(to: cover, options: .atomic)
                coverRevision += 1
            } catch {
                appLog("Couldn't save mixtape cover: \(error.localizedDescription)",
                       level: .error, category: "Library")
            }
        }
        if folders[index].isSynced, let path = folders[index].syncedPath {
            exportOp(.writeMixtapeData(dir: path, folderID: folders[index].id))
        }
        saveFolders()
    }

    // MARK: - Apple Watch

    /// Whether a track is currently pushed to the watch.
    func isOnWatch(_ track: Track) -> Bool {
        tracks.first(where: { $0.id == track.id })?.sentToWatch ?? false
    }

    /// Pushes a single track to the watch. Video isn't supported on the watch, so
    /// it's a no-op for video tracks. Sending never changes the track's place in
    /// the library — only the `sentToWatch` flag.
    func sendToWatch(_ track: Track) {
        guard let index = tracks.firstIndex(where: { $0.id == track.id }),
              !tracks[index].isVideo,
              !tracks[index].sentToWatch else { return }
        tracks[index].sentToWatch = true
        save()
        syncWatch()
    }

    /// Pushes every audio track in a folder to the watch, tagged (via the
    /// manifest) with the folder's name so they group as a playlist on the watch.
    func sendFolderToWatch(_ folder: Folder) {
        var changed = false
        for index in tracks.indices
        where tracks[index].folderID == folder.id && !tracks[index].isVideo && !tracks[index].sentToWatch {
            tracks[index].sentToWatch = true
            changed = true
        }
        if changed {
            save()
            syncWatch()
        }
    }

    /// Removes a single track from the watch (the file is deleted on the watch by
    /// the next manifest prune). The track itself is untouched in the library.
    func removeFromWatch(_ track: Track) {
        guard let index = tracks.firstIndex(where: { $0.id == track.id }),
              tracks[index].sentToWatch else { return }
        tracks[index].sentToWatch = false
        save()
        syncWatch()
    }

    /// Clears the whole Watch folder — used both by the phone and in response to
    /// the watch's "Clear all Tracks".
    func clearAllFromWatch() {
        var changed = false
        for index in tracks.indices where tracks[index].sentToWatch {
            tracks[index].sentToWatch = false
            changed = true
        }
        if changed {
            save()
            syncWatch()
        }
    }

    /// Pushes the current watch set over to the paired watch.
    func syncWatch() {
        let folderNames = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.name) })
        WatchSync.shared.push(tracks: watchTracks, folderNames: folderNames)
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
        if tracks[index].sentToWatch { syncWatch() }
    }

    /// Restores a renamed track's original (download) title.
    func resetTitle(_ track: Track) {
        guard let index = tracks.firstIndex(where: { $0.id == track.id }),
              let original = tracks[index].originalTitle else { return }
        tracks[index].title = original
        save()
    }

    /// Manual metadata edit (title + artist) from the "Edit Metadata" sheet. A
    /// title change records `originalTitle` on first edit (like a rename) so it
    /// can still be reset to the download title; an empty artist falls back to
    /// "Unknown". A blank title is ignored so a track can't lose its name.
    func editMetadata(_ track: Track, title: String, artist: String) {
        guard let index = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedTitle.isEmpty, tracks[index].title != trimmedTitle {
            if tracks[index].originalTitle == nil {
                tracks[index].originalTitle = tracks[index].title
            }
            tracks[index].title = trimmedTitle
        }

        let newArtist = trimmedArtist.isEmpty ? "Unknown" : trimmedArtist
        if tracks[index].artist != newArtist {
            tracks[index].artist = newArtist
        }
        save()
        if tracks[index].sentToWatch { syncWatch() }
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
    /// Forwards the new position to the watch when the track is a podcast that's
    /// been sent there, so the two stay in sync.
    func updatePosition(for id: UUID, to position: Double) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        guard abs(tracks[index].lastPosition - position) >= 1 else { return }
        tracks[index].lastPosition = position
        save()
        if tracks[index].kind == .podcast, tracks[index].sentToWatch {
            WatchSync.shared.sendPosition(id: id, position: position)
        }
    }

    /// Applies a podcast playhead update received *from* the watch. Updates the
    /// saved position only (active phone playback is untouched) and does not echo
    /// it back to the watch.
    func applyWatchPosition(_ id: UUID, _ position: Double) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        guard abs(tracks[index].lastPosition - position) >= 1 else { return }
        tracks[index].lastPosition = position
        save()
    }

    /// Removes a track from the library and deletes its audio file from disk.
    /// A synced track's replica copy is queued for removal too.
    func delete(_ track: Track) {
        guard let current = tracks.first(where: { $0.id == track.id }) else { return }
        try? FileManager.default.removeItem(at: current.fileURL)
        if current.isSynced {
            exportOp(.removeRemote(rel: current.fileName))
        }
        tracks.removeAll { $0.id == track.id }
        save()
        if current.sentToWatch { syncWatch() }
    }

    func delete(at offsets: IndexSet) {
        let wasOnWatch = offsets.contains { tracks[$0].sentToWatch }
        for index in offsets {
            try? FileManager.default.removeItem(at: tracks[index].fileURL)
            if tracks[index].isSynced {
                exportOp(.removeRemote(rel: tracks[index].fileName))
            }
        }
        tracks.remove(atOffsets: offsets)
        save()
        if wasOnWatch { syncWatch() }
    }
}
