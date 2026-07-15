import Foundation

/// A file's identity in a sync folder — enough to detect changes between
/// scans without hashing content.
struct SyncStamp: Codable, Equatable {
    var size: Int64
    var mtime: TimeInterval
}

/// What a scan of one sync folder (a replica) found: every playable file and
/// every directory, with stamps for change detection and any `.mixtapedata`
/// style. Paths are relative to that sync root.
struct SyncSnapshot {
    struct File {
        let relativePath: String
        let stamp: SyncStamp
    }

    struct Directory {
        let relativePath: String
        /// Non-nil when the directory contains `.mixtapedata` — the directory
        /// is a mixtape and this is its banner style.
        let mixtapeStyle: MixtapeStyle?
        /// Stamps of `.mixtapedata/style.json` / `cover.jpg`, when present.
        let styleStamp: SyncStamp?
        let coverStamp: SyncStamp?
    }

    var files: [File] = []
    var directories: [Directory] = []
}

/// A write-through operation queued for a replica. In-app changes apply to
/// the app-local sync store immediately and enqueue one of these; the exporter
/// drains the journal with coordinated file operations, retrying later if the
/// sync folder is unreachable. Ops are self-healing: one whose precondition
/// has been superseded (source vanished, target already gone) drops out
/// instead of blocking the queue.
enum SyncOp: Codable, Equatable {
    /// Copy the file at `rel` from the root's local store into its replica.
    case copyOut(rel: String)
    /// Remove the file or directory at `rel` from the replica.
    case removeRemote(rel: String)
    /// Create the directory `rel` in the replica.
    case createRemoteDir(rel: String)
    /// Rename/move within the replica.
    case moveRemote(from: String, to: String)
    /// (Re)write `dir/.mixtapedata` from the folder's current style + cover.
    case writeMixtapeData(dir: String, folderID: UUID)
    /// Remove `dir/.mixtapedata` from the replica.
    case removeMixtapeData(dir: String)
}

/// A journaled op tagged with the sync root it applies to.
struct PendingSyncOp: Codable, Equatable {
    let rootID: UUID
    let op: SyncOp
}

/// A configured sync folder as persisted: its id, display name, and
/// security-scoped bookmark.
struct SyncRootRecord: Codable, Identifiable {
    let id: UUID
    var name: String
    var bookmark: Data
}

/// A configured sync folder as the UI sees it. `url` is nil while the
/// bookmark can't be resolved (provider offline, folder deleted).
struct SyncRootState: Identifiable, Equatable {
    let id: UUID
    let name: String
    let url: URL?
}

/// Owns the sync folders: persists their security-scoped bookmarks, and keeps
/// each folder (a *replica*) mirroring its app-local sync store
/// (`Documents/Synced/<root-id>/`).
///
/// The library always plays from the local stores — cloud providers (Dropbox,
/// iCloud Drive, …) serve placeholder files that must be downloaded through
/// file coordination before they're readable, and can evict them again, so a
/// replica is never used directly. Per root:
///
/// - The **importer** scans the replica, compares stamps against a persisted
///   manifest, and copies new/changed files in (a coordinated read, which is
///   what makes the provider download a placeholder). Files that vanished
///   from the replica leave the library. Tracks appear as their copies land.
/// - The **exporter** drains a persisted journal of ops produced by in-app
///   changes (Sync to Local, moves, renames, deletes, mixtape edits), so a
///   change made while the folder is unreachable is retried later instead of
///   failing.
///
/// Removing a sync folder removes its synced content from the library (the
/// folder's own files are untouched) — the library only mirrors folders it's
/// still connected to.
@MainActor
final class LocalSyncStore: ObservableObject {
    /// Every configured sync folder, resolved or not, in the order added.
    @Published private(set) var roots: [SyncRootState] = []
    /// True while a sync pass (export drain + scan + import) is running.
    @Published private(set) var isSyncing = false
    /// Journal depth — in-app changes not yet copied to their replicas.
    @Published private(set) var pendingOpCount = 0

    private let library: LibraryStore
    private var records: [SyncRootRecord] = []
    private var resolvedURLs: [UUID: URL] = [:]

    private static let legacyBookmarkKey = "localSyncBookmark"
    private static var rootsURL: URL { AppPaths.documents.appendingPathComponent("sync-roots.json") }
    private static var manifestURL: URL { AppPaths.documents.appendingPathComponent("sync-manifest.json") }
    private static var pendingOpsURL: URL { AppPaths.documents.appendingPathComponent("sync-pending.json") }

    /// Per root, the last reconciled remote state: relative path → stamp,
    /// including `.mixtapedata` style/cover entries. What lets a scan tell
    /// "changed remotely" from "already seen".
    private var manifest: [UUID: [String: SyncStamp]] = [:]
    private var pendingOps: [PendingSyncOp] = []

    /// One kqueue-backed source per directory across every replica tree.
    /// Useful for local (On My iPhone) folders; cloud providers don't reliably
    /// signal, so foreground rescans carry those.
    private var monitors: [DispatchSourceFileSystemObject] = []
    private var pendingRescan: Task<Void, Never>?
    private var needsAnotherPass = false

    init(library: LibraryStore) {
        self.library = library
        loadState()
        migrateLegacyRootIfNeeded()
        resolveAll()
        library.syncExporter = { [weak self] op, rootID in self?.enqueue(op, rootID: rootID) }
        if !resolvedURLs.isEmpty {
            rescan()
        }
    }

    var isConfigured: Bool { !resolvedURLs.isEmpty }

    /// The roots whose folders are currently reachable — the ones "Sync to
    /// Local" can target.
    var resolvedRoots: [SyncRootState] { roots.filter { $0.url != nil } }

    // MARK: - Configuration

    /// Adds a folder freshly picked in Settings as a new sync root. The caller
    /// must have opened its security scope (fileImporter grants it) so a
    /// bookmark can be made.
    func addRoot(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        // Already configured? (Compare resolved paths.)
        let path = url.standardizedFileURL.path
        if resolvedURLs.values.contains(where: { $0.standardizedFileURL.path == path }) {
            appLog("\"\(url.lastPathComponent)\" is already a sync folder.",
                   level: .warning, category: "Sync")
            return
        }
        let bookmark: Data
        do {
            bookmark = try url.bookmarkData()
        } catch {
            appLog("Couldn't bookmark the sync folder: \(error.localizedDescription)",
                   level: .error, category: "Sync")
            return
        }
        let record = SyncRootRecord(id: UUID(), name: url.lastPathComponent, bookmark: bookmark)
        records.append(record)
        persistRecords()
        resolveAll()
        appLog("Added sync folder \"\(record.name)\".", level: .success, category: "Sync")
        rescan()
    }

    /// Removes a sync root. Its synced tracks and folders leave the library
    /// and its local store is deleted; the folder's own files are untouched.
    func removeRoot(_ id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        let name = records[index].name
        records.remove(at: index)
        persistRecords()
        if let url = resolvedURLs[id] {
            url.stopAccessingSecurityScopedResource()
        }
        resolvedURLs[id] = nil
        AppPaths.syncRootURLs[id] = nil
        manifest[id] = nil
        persistManifest()
        pendingOps.removeAll { $0.rootID == id }
        persistJournal()
        pendingOpCount = pendingOps.count
        library.removeSynced(rootID: id)
        try? FileManager.default.removeItem(at: AppPaths.syncLocalStore(for: id))
        publishStates()
        stopMonitoring()
        appLog("Removed sync folder \"\(name)\" — its synced items left the library; the folder's files are untouched.",
               category: "Sync")
        if !resolvedURLs.isEmpty {
            scheduleRescan()
        }
    }

    /// Resolves every persisted bookmark, opening each security scope for the
    /// session, and publishes the results (also into `AppPaths.syncRootURLs`,
    /// which gates the Sync to Local actions and resolves nothing else — the
    /// library plays from the local stores).
    private func resolveAll() {
        var map: [UUID: URL] = [:]
        var refreshed = false
        for index in records.indices {
            var stale = false
            do {
                let url = try URL(resolvingBookmarkData: records[index].bookmark,
                                  bookmarkDataIsStale: &stale)
                guard url.startAccessingSecurityScopedResource() else {
                    throw CocoaError(.fileReadNoPermission)
                }
                if stale, let fresh = try? url.bookmarkData() {
                    records[index].bookmark = fresh
                    refreshed = true
                }
                map[records[index].id] = url
            } catch {
                // Leave the record in place — the folder may be temporarily
                // unavailable. The library keeps playing its local copies;
                // only this root's mirroring pauses.
                appLog("Couldn't resolve sync folder \"\(records[index].name)\": \(error.localizedDescription)",
                       level: .warning, category: "Sync")
            }
        }
        if refreshed { persistRecords() }
        resolvedURLs = map
        AppPaths.syncRootURLs = map
        publishStates()
    }

    private func publishStates() {
        roots = records.map { SyncRootState(id: $0.id, name: $0.name, url: resolvedURLs[$0.id]) }
    }

    // MARK: - Legacy migration (single sync folder → roots list)

    /// Adopts a pre-multi-root configuration: the single legacy bookmark
    /// becomes the first root, the flat local store moves under the new
    /// root-id directory, the old manifest/journal formats are re-keyed, and
    /// legacy synced items (no root id) are assigned to it.
    private func migrateLegacyRootIfNeeded() {
        guard let bookmark = UserDefaults.standard.data(forKey: Self.legacyBookmarkKey) else { return }
        UserDefaults.standard.removeObject(forKey: Self.legacyBookmarkKey)
        var name = "Sync Folder"
        var stale = false
        if let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) {
            name = url.lastPathComponent
        }
        let record = SyncRootRecord(id: UUID(), name: name, bookmark: bookmark)
        records.append(record)
        persistRecords()

        // Move the flat local store's contents under the new root directory.
        let fm = FileManager.default
        let parent = AppPaths.syncLocalStore
        let target = AppPaths.syncLocalStore(for: record.id)
        if let entries = try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) {
            for entry in entries where entry.lastPathComponent != record.id.uuidString {
                try? fm.moveItem(at: entry,
                                 to: target.appendingPathComponent(entry.lastPathComponent))
            }
        }

        // Re-key the old single-root manifest, if one decoded as legacy.
        if let data = try? Data(contentsOf: Self.manifestURL),
           let legacy = try? JSONDecoder().decode([String: SyncStamp].self, from: data) {
            manifest[record.id] = legacy
            persistManifest()
        }
        // Wrap old-format journal entries with the migrated root's id.
        if let data = try? Data(contentsOf: Self.pendingOpsURL),
           let legacy = try? JSONDecoder().decode([SyncOp].self, from: data), !legacy.isEmpty {
            pendingOps = legacy.map { PendingSyncOp(rootID: record.id, op: $0) }
            pendingOpCount = pendingOps.count
            persistJournal()
        }

        library.assignLegacyRoot(record.id)
        appLog("Migrated sync folder \"\(name)\" to the multi-folder format.", category: "Sync")
    }

    // MARK: - Journal

    /// Queues a replica operation from an in-app change and kicks a sync pass.
    func enqueue(_ op: SyncOp, rootID: UUID) {
        pendingOps.append(PendingSyncOp(rootID: rootID, op: op))
        pendingOpCount = pendingOps.count
        persistJournal()
        scheduleRescan()
    }

    private func loadState() {
        if let data = try? Data(contentsOf: Self.rootsURL),
           let decoded = try? JSONDecoder().decode([SyncRootRecord].self, from: data) {
            records = decoded
        }
        if let data = try? Data(contentsOf: Self.manifestURL),
           let decoded = try? JSONDecoder().decode([UUID: [String: SyncStamp]].self, from: data) {
            manifest = decoded
        }
        if let data = try? Data(contentsOf: Self.pendingOpsURL),
           let decoded = try? JSONDecoder().decode([PendingSyncOp].self, from: data) {
            pendingOps = decoded
            pendingOpCount = decoded.count
        }
    }

    private func persistRecords() {
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: Self.rootsURL, options: .atomic)
        }
    }

    private func persistManifest() {
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: Self.manifestURL, options: .atomic)
        }
    }

    private func persistJournal() {
        if let data = try? JSONEncoder().encode(pendingOps) {
            try? data.write(to: Self.pendingOpsURL, options: .atomic)
        }
    }

    // MARK: - Sync passes

    /// Debounced entry point: called on filesystem events, on app foreground,
    /// and after in-app changes. Coalesces bursts into one pass.
    func scheduleRescan() {
        pendingRescan?.cancel()
        pendingRescan = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await self?.performSync()
        }
    }

    /// An immediate pass (used at launch and after adding a folder).
    func rescan() {
        Task { [weak self] in await self?.performSync() }
    }

    /// One full pass over every reachable root: drain its journal, then scan
    /// its replica and reconcile the library against it. A root's
    /// reconciliation is skipped while its exports are still pending — the
    /// replica is stale until they land, and reconciling against it could
    /// undo the very changes waiting to be written.
    private func performSync() async {
        if isSyncing {
            needsAnotherPass = true
            return
        }
        isSyncing = true

        var monitorTargets: [(root: URL, dirs: [String])] = []
        for state in roots {
            guard let rootURL = state.url else { continue }
            await drainJournal(rootID: state.id, rootURL: rootURL)
            if pendingOps.contains(where: { $0.rootID == state.id }) {
                appLog("Changes for \"\(state.name)\" couldn't reach the folder — will retry.",
                       level: .warning, category: "Sync")
                continue
            }
            let snapshot = await Task.detached(priority: .utility) {
                Self.scan(root: rootURL)
            }.value
            await reconcile(snapshot, rootID: state.id, rootURL: rootURL)
            monitorTargets.append((rootURL, snapshot.directories.map { $0.relativePath }))
        }
        startMonitoring(targets: monitorTargets)
        pendingOpCount = pendingOps.count

        isSyncing = false
        if needsAnotherPass {
            needsAnotherPass = false
            scheduleRescan()
        }
    }

    // MARK: - Exporter

    /// Runs one root's journaled ops in order. Stops at the first hard
    /// failure (usually the folder being unreachable) to preserve causal
    /// order; superseded ops drop out. Ops only ever append while this runs,
    /// so indices into the array stay valid across awaits.
    private func drainJournal(rootID: UUID, rootURL: URL) async {
        while let index = pendingOps.firstIndex(where: { $0.rootID == rootID }) {
            let entry = pendingOps[index]
            let succeeded = await execute(entry.op, rootID: rootID, root: rootURL)
            guard succeeded else { break }
            pendingOps.remove(at: index)
            persistJournal()
        }
        pendingOpCount = pendingOps.count
    }

    /// Returns true when the op finished or is obsolete; false to retry later.
    private func execute(_ op: SyncOp, rootID: UUID, root: URL) async -> Bool {
        let local = AppPaths.syncLocalStore(for: rootID)
        switch op {
        case .copyOut(let rel):
            let src = local.appendingPathComponent(rel)
            // Superseded: the local file moved on before we could export it.
            guard FileManager.default.fileExists(atPath: src.path) else { return true }
            let dst = root.appendingPathComponent(rel)
            return await Task.detached { Self.coordinatedCopy(from: src, to: dst) }.value

        case .removeRemote(let rel):
            let target = root.appendingPathComponent(rel)
            return await Task.detached { Self.coordinatedDelete(at: target) }.value

        case .createRemoteDir(let rel):
            let target = root.appendingPathComponent(rel, isDirectory: true)
            return await Task.detached { Self.coordinatedCreateDir(at: target) }.value

        case .moveRemote(let from, let to):
            let src = root.appendingPathComponent(from)
            let dst = root.appendingPathComponent(to)
            let localDst = local.appendingPathComponent(to)
            return await Task.detached { () -> Bool in
                if FileManager.default.fileExists(atPath: src.path) {
                    return Self.coordinatedMove(from: src, to: dst)
                }
                // The remote source never landed; export the local file
                // directly to the new location instead (or drop the op if
                // that's gone too).
                if FileManager.default.fileExists(atPath: localDst.path) {
                    return Self.coordinatedCopy(from: localDst, to: dst)
                }
                return true
            }.value

        case .writeMixtapeData(let dir, let folderID):
            // Snapshot the folder's current style/cover on the main actor;
            // obsolete if it's no longer a synced mixtape.
            guard let folder = library.folder(withID: folderID),
                  folder.isMixtape, folder.isSynced else { return true }
            guard let styleData = try? JSONEncoder().encode(folder.mixtape) else { return true }
            let coverData = folder.coverURL.flatMap { try? Data(contentsOf: $0) }
            let dataDir = root.appendingPathComponent(dir, isDirectory: true)
                .appendingPathComponent(AppPaths.mixtapeDataDirName, isDirectory: true)
            return await Task.detached {
                Self.coordinatedWriteMixtapeData(into: dataDir, style: styleData, cover: coverData)
            }.value

        case .removeMixtapeData(let dir):
            let dataDir = root.appendingPathComponent(dir, isDirectory: true)
                .appendingPathComponent(AppPaths.mixtapeDataDirName, isDirectory: true)
            return await Task.detached { Self.coordinatedDelete(at: dataDir) }.value
        }
    }

    // MARK: - Importer

    private func styleKey(_ dir: String) -> String { "\(dir)/\(AppPaths.mixtapeDataDirName)/style.json" }
    private func coverKey(_ dir: String) -> String { "\(dir)/\(AppPaths.mixtapeDataDirName)/cover.jpg" }

    /// Reconciles the library against one root's replica scan: folders first,
    /// then removals, then copy-ins (each track appears as its file lands),
    /// then mixtape covers — and finally the root's manifest records what was
    /// seen.
    private func reconcile(_ snapshot: SyncSnapshot, rootID: UUID, rootURL: URL) async {
        let rootManifest = manifest[rootID] ?? [:]
        let localStore = AppPaths.syncLocalStore(for: rootID)

        // Mixtape styles are adopted only when .mixtapedata actually changed
        // remotely (stamp vs manifest) — never merely because it differs from
        // the library, which would undo local edits.
        var adoptStyle: Set<String> = []
        for dir in snapshot.directories where rootManifest[styleKey(dir.relativePath)] != dir.styleStamp {
            adoptStyle.insert(dir.relativePath)
        }
        let folderIDs = library.reconcileSyncedFolders(snapshot.directories,
                                                       adoptStyleFor: adoptStyle,
                                                       rootID: rootID)

        // Files that vanished from the replica leave the library (and the
        // local store).
        let remotePaths = Set(snapshot.files.map { $0.relativePath })
        library.removeSyncedTracks(notIn: remotePaths, rootID: rootID)

        // What needs copying in: unknown files, changed files, or known files
        // whose local copy is missing (e.g. a fresh install, or an import that
        // failed half-way).
        var imports: [SyncSnapshot.File] = []
        var newManifest: [String: SyncStamp] = [:]
        for file in snapshot.files {
            let localPath = localStore.appendingPathComponent(file.relativePath).path
            if rootManifest[file.relativePath] == file.stamp,
               FileManager.default.fileExists(atPath: localPath),
               library.hasSyncedTrack(at: file.relativePath, rootID: rootID) {
                newManifest[file.relativePath] = file.stamp
            } else {
                imports.append(file)
            }
        }

        if !imports.isEmpty {
            appLog("Importing \(imports.count) file(s) from the sync folder…", category: "Sync")
        }
        var failures = 0
        for (index, file) in imports.enumerated() {
            let src = rootURL.appendingPathComponent(file.relativePath)
            let dst = localStore.appendingPathComponent(file.relativePath)
            let ok = await Task.detached(priority: .utility) {
                Self.coordinatedCopy(from: src, to: dst)
            }.value
            if ok {
                newManifest[file.relativePath] = file.stamp
                let dirPath = (file.relativePath as NSString).deletingLastPathComponent
                library.ensureSyncedTrack(at: file.relativePath,
                                          folderID: dirPath.isEmpty ? nil : folderIDs[dirPath],
                                          rootID: rootID)
                if imports.count > 3 {
                    appLog("Imported \(index + 1)/\(imports.count): \((file.relativePath as NSString).lastPathComponent)",
                           level: .debug, category: "Sync")
                }
            } else {
                failures += 1
            }
        }
        if failures > 0 {
            appLog("\(failures) file(s) couldn't be imported (still downloading or unreachable) — will retry on the next pass.",
                   level: .warning, category: "Sync")
        }

        // Mixtape covers: copy in when new or changed remotely.
        for dir in snapshot.directories {
            let key = coverKey(dir.relativePath)
            guard let stamp = dir.coverStamp else { continue }
            guard let folderID = folderIDs[dir.relativePath] else { continue }
            if rootManifest[key] == stamp {
                newManifest[key] = stamp
                continue
            }
            let src = rootURL.appendingPathComponent(dir.relativePath, isDirectory: true)
                .appendingPathComponent(AppPaths.mixtapeDataDirName, isDirectory: true)
                .appendingPathComponent("cover.jpg")
            let dst = AppPaths.mixtapeCovers.appendingPathComponent("\(folderID.uuidString).jpg")
            let ok = await Task.detached { Self.coordinatedCopy(from: src, to: dst) }.value
            if ok {
                newManifest[key] = stamp
                library.bumpCoverRevision()
            }
        }
        // Style stamps for everything seen (styles were adopted above).
        for dir in snapshot.directories {
            if let stamp = dir.styleStamp { newManifest[styleKey(dir.relativePath)] = stamp }
        }

        manifest[rootID] = newManifest
        persistManifest()

        // Sweep local-store leftovers (files/dirs whose remote counterpart is
        // gone). Safe because reconcile only runs with this root's journal
        // empty.
        let dirPaths = Set(snapshot.directories.map { $0.relativePath })
        await Task.detached(priority: .utility) {
            Self.sweepLocalStore(root: localStore, validFiles: remotePaths, validDirs: dirPaths)
        }.value
    }

    // MARK: - Scanning (replica)

    /// Walks a replica tree off the main actor (a cloud-backed directory can
    /// block on the network while listing). Hidden entries are skipped, except
    /// that `.mixtapedata` marks its parent as a mixtape and contributes its
    /// style + stamps.
    nonisolated private static func scan(root: URL) -> SyncSnapshot {
        var snapshot = SyncSnapshot()
        scanDirectory(root, root: root, into: &snapshot)
        return snapshot
    }

    nonisolated private static func scanDirectory(_ dir: URL, root: URL, into snapshot: inout SyncSnapshot) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey],
            options: []) else { return }
        for entry in entries.sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }) {
            let name = entry.lastPathComponent
            if name.hasPrefix(".") { continue }
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let relative = relativePath(of: entry, from: root)
            if isDirectory {
                let dataDir = entry.appendingPathComponent(AppPaths.mixtapeDataDirName, isDirectory: true)
                let styleURL = dataDir.appendingPathComponent("style.json")
                let coverURL = dataDir.appendingPathComponent("cover.jpg")
                snapshot.directories.append(SyncSnapshot.Directory(
                    relativePath: relative,
                    mixtapeStyle: mixtapeStyle(at: styleURL, dataDir: dataDir),
                    styleStamp: stamp(of: styleURL),
                    coverStamp: stamp(of: coverURL)))
                scanDirectory(entry, root: root, into: &snapshot)
            } else if PlayableMedia.isPlayable(extension: entry.pathExtension) {
                guard let stamp = stamp(of: entry) else { continue }
                snapshot.files.append(SyncSnapshot.File(relativePath: relative, stamp: stamp))
            }
        }
    }

    /// A present `.mixtapedata` with an unreadable style still counts as a
    /// mixtape (default style) — the marker is the folder.
    nonisolated private static func mixtapeStyle(at styleURL: URL, dataDir: URL) -> MixtapeStyle? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dataDir.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        if let data = try? Data(contentsOf: styleURL),
           let style = try? JSONDecoder().decode(MixtapeStyle.self, from: data) {
            return style
        }
        return MixtapeStyle()
    }

    nonisolated private static func stamp(of url: URL) -> SyncStamp? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attrs[.size] as? Int64) ?? Int64((attrs[.size] as? Int) ?? 0)
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return SyncStamp(size: size, mtime: mtime)
    }

    nonisolated private static func relativePath(of url: URL, from root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count + 1))
    }

    // MARK: - Coordinated file operations

    /// Coordinated read + copy. For a cloud placeholder the coordinator makes
    /// the provider download the file first, which is exactly why imports run
    /// through here (and off the main actor — this call can take a while).
    nonisolated private static func coordinatedCopy(from src: URL, to dst: URL) -> Bool {
        var coordinationError: NSError?
        var copied = false
        NSFileCoordinator().coordinate(readingItemAt: src, options: [], error: &coordinationError) { readURL in
            do {
                try FileManager.default.createDirectory(
                    at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: dst.path) {
                    try FileManager.default.removeItem(at: dst)
                }
                try FileManager.default.copyItem(at: readURL, to: dst)
                copied = true
            } catch {
                appLog("Copy failed for \(src.lastPathComponent): \(error.localizedDescription)",
                       level: .warning, category: "Sync")
            }
        }
        if let coordinationError {
            appLog("Couldn't read \(src.lastPathComponent): \(coordinationError.localizedDescription)",
                   level: .warning, category: "Sync")
        }
        return copied
    }

    nonisolated private static func coordinatedDelete(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        var coordinationError: NSError?
        var deleted = false
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { writeURL in
            do {
                try FileManager.default.removeItem(at: writeURL)
                deleted = true
            } catch {
                appLog("Delete failed for \(url.lastPathComponent): \(error.localizedDescription)",
                       level: .warning, category: "Sync")
            }
        }
        return deleted && coordinationError == nil
    }

    nonisolated private static func coordinatedCreateDir(at url: URL) -> Bool {
        var coordinationError: NSError?
        var created = false
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { writeURL in
            do {
                try FileManager.default.createDirectory(at: writeURL, withIntermediateDirectories: true)
                created = true
            } catch {
                appLog("Couldn't create \(url.lastPathComponent) in the sync folder: \(error.localizedDescription)",
                       level: .warning, category: "Sync")
            }
        }
        return created && coordinationError == nil
    }

    nonisolated private static func coordinatedMove(from src: URL, to dst: URL) -> Bool {
        var coordinationError: NSError?
        var moved = false
        NSFileCoordinator().coordinate(writingItemAt: src, options: .forMoving,
                                       writingItemAt: dst, options: .forReplacing,
                                       error: &coordinationError) { srcURL, dstURL in
            do {
                try FileManager.default.createDirectory(
                    at: dstURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: dstURL.path) {
                    try FileManager.default.removeItem(at: dstURL)
                }
                try FileManager.default.moveItem(at: srcURL, to: dstURL)
                moved = true
            } catch {
                appLog("Move failed for \(src.lastPathComponent): \(error.localizedDescription)",
                       level: .warning, category: "Sync")
            }
        }
        return moved && coordinationError == nil
    }

    nonisolated private static func coordinatedWriteMixtapeData(into dataDir: URL, style: Data, cover: Data?) -> Bool {
        var coordinationError: NSError?
        var written = false
        NSFileCoordinator().coordinate(writingItemAt: dataDir, options: [], error: &coordinationError) { dirURL in
            do {
                try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
                try style.write(to: dirURL.appendingPathComponent("style.json"), options: .atomic)
                if let cover {
                    try cover.write(to: dirURL.appendingPathComponent("cover.jpg"), options: .atomic)
                }
                written = true
            } catch {
                appLog("Couldn't write .mixtapedata: \(error.localizedDescription)",
                       level: .warning, category: "Sync")
            }
        }
        return written && coordinationError == nil
    }

    /// Deletes anything in a root's local store whose remote counterpart no
    /// longer exists.
    nonisolated private static func sweepLocalStore(root: URL, validFiles: Set<String>, validDirs: Set<String>) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        var doomed: [URL] = []
        for case let url as URL in enumerator {
            let rel = relativePath(of: url, from: root)
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                if !validDirs.contains(rel) {
                    doomed.append(url)
                    enumerator.skipDescendants()
                }
            } else if !validFiles.contains(rel) {
                doomed.append(url)
            }
        }
        for url in doomed {
            try? fm.removeItem(at: url)
        }
    }

    // MARK: - Monitoring

    /// Watches every replica's root and subdirectories for writes and
    /// schedules a pass on any event.
    private func startMonitoring(targets: [(root: URL, dirs: [String])]) {
        stopMonitoring()
        for target in targets {
            var urls = [target.root]
            urls.append(contentsOf: target.dirs.map {
                target.root.appendingPathComponent($0, isDirectory: true)
            })
            for url in urls {
                let fd = open(url.path, O_EVTONLY)
                guard fd >= 0 else { continue }
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: fd,
                    eventMask: [.write, .delete, .rename],
                    queue: .main)
                source.setEventHandler { [weak self] in
                    self?.scheduleRescan()
                }
                source.setCancelHandler {
                    close(fd)
                }
                source.resume()
                monitors.append(source)
            }
        }
    }

    private func stopMonitoring() {
        for monitor in monitors {
            monitor.cancel()
        }
        monitors.removeAll()
    }
}
