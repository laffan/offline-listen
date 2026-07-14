import Foundation

/// A file's identity in the sync folder — enough to detect changes between
/// scans without hashing content.
struct SyncStamp: Codable, Equatable {
    var size: Int64
    var mtime: TimeInterval
}

/// What a scan of the sync folder (the replica) found: every playable file and
/// every directory, with stamps for change detection and any `.mixtapedata`
/// style. Paths are relative to the sync root.
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

/// A write-through operation queued for the replica. In-app changes apply to
/// the app-local sync store immediately and enqueue one of these; the exporter
/// drains the journal with coordinated file operations, retrying later if the
/// sync folder is unreachable. Ops are self-healing: one whose precondition
/// has been superseded (source vanished, target already gone) drops out
/// instead of blocking the queue.
enum SyncOp: Codable, Equatable {
    /// Copy `Synced/rel` from the local store into the replica at `rel`.
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

/// Owns the sync folder: persists its security-scoped bookmark, and keeps the
/// app-local sync store (`Documents/Synced/`) and the user's folder (the
/// *replica*) mirroring each other.
///
/// The library always plays from the local store — cloud providers (Dropbox,
/// iCloud Drive, …) serve placeholder files that must be downloaded through
/// file coordination before they're readable, and can evict them again, so
/// the replica is never used directly. Instead:
///
/// - The **importer** scans the replica, compares stamps against a persisted
///   manifest, and copies new/changed files in (a coordinated read, which is
///   what makes the provider download a placeholder). Files that vanished
///   from the replica leave the library. Tracks appear as their copies land.
/// - The **exporter** drains a persisted journal of `SyncOp`s produced by
///   in-app changes (Sync to Local, moves, renames, deletes, mixtape edits),
///   so a change made while the folder is unreachable is retried later
///   instead of failing.
@MainActor
final class LocalSyncStore: ObservableObject {
    /// The resolved sync root, nil until a folder is chosen (or while its
    /// bookmark can't be resolved — e.g. the provider is unavailable).
    @Published private(set) var rootURL: URL?
    /// True while a sync pass (export drain + scan + import) is running.
    @Published private(set) var isSyncing = false
    /// Journal depth — in-app changes not yet copied to the replica.
    @Published private(set) var pendingOpCount = 0

    private let library: LibraryStore
    private static let bookmarkKey = "localSyncBookmark"
    private static var manifestURL: URL { AppPaths.documents.appendingPathComponent("sync-manifest.json") }
    private static var pendingOpsURL: URL { AppPaths.documents.appendingPathComponent("sync-pending.json") }

    /// The last reconciled remote state: relative path → stamp, including
    /// `.mixtapedata` style/cover entries. What lets a scan tell "changed
    /// remotely" from "already seen".
    private var manifest: [String: SyncStamp] = [:]
    private var pendingOps: [SyncOp] = []

    /// One kqueue-backed source per directory in the replica tree. Useful for
    /// local (On My iPhone) folders; cloud providers don't reliably signal, so
    /// foreground rescans carry those.
    private var monitors: [DispatchSourceFileSystemObject] = []
    private var pendingRescan: Task<Void, Never>?
    private var needsAnotherPass = false

    init(library: LibraryStore) {
        self.library = library
        loadJournal()
        resolveBookmark()
        library.syncExporter = { [weak self] op in self?.enqueue(op) }
        if rootURL != nil {
            rescan()
        }
    }

    var isConfigured: Bool { rootURL != nil }

    // MARK: - Configuration

    /// Adopts a folder freshly picked in Settings. The caller must have opened
    /// its security scope (fileImporter grants it) so a bookmark can be made.
    /// Choosing a different folder first releases the current one (synced
    /// items stay in the library as regular local tracks).
    func setRoot(_ url: URL) {
        if rootURL != nil || UserDefaults.standard.data(forKey: Self.bookmarkKey) != nil {
            detachCurrentRoot()
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData()
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        } catch {
            appLog("Couldn't bookmark the sync folder: \(error.localizedDescription)",
                   level: .error, category: "Sync")
            return
        }
        // Re-resolve from the bookmark so the retained URL carries its own
        // security scope for the rest of the session.
        resolveBookmark()
        if rootURL != nil {
            appLog("Local sync folder set to \"\(url.lastPathComponent)\".",
                   level: .success, category: "Sync")
            rescan()
        }
    }

    /// Un-configures local sync. Synced items stay in the library as regular
    /// local tracks; the replica's files are untouched.
    func clearRoot() {
        detachCurrentRoot()
        appLog("Local sync folder removed — synced items kept as local tracks.",
               category: "Sync")
    }

    private func detachCurrentRoot() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        stopMonitoring()
        pendingRescan?.cancel()
        rootURL = nil
        AppPaths.syncRoot = nil
        manifest = [:]
        pendingOps = []
        pendingOpCount = 0
        persistManifest()
        persistJournal()
        library.unsyncEverything()
    }

    /// Resolves the persisted bookmark, opens its security scope for the
    /// session, and publishes the root (also into `AppPaths.syncRoot` for
    /// anything that needs to know sync is configured).
    private func resolveBookmark() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else {
            rootURL = nil
            AppPaths.syncRoot = nil
            return
        }
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
            guard url.startAccessingSecurityScopedResource() else {
                throw CocoaError(.fileReadNoPermission)
            }
            if stale, let refreshed = try? url.bookmarkData() {
                UserDefaults.standard.set(refreshed, forKey: Self.bookmarkKey)
            }
            rootURL = url
            AppPaths.syncRoot = url
        } catch {
            // Leave the bookmark in place — the folder may be temporarily
            // unavailable. The library keeps playing its local copies; only
            // the mirroring pauses.
            rootURL = nil
            AppPaths.syncRoot = nil
            appLog("Couldn't resolve the sync folder bookmark: \(error.localizedDescription)",
                   level: .warning, category: "Sync")
        }
    }

    // MARK: - Journal

    /// Queues a replica operation from an in-app change and kicks a sync pass.
    func enqueue(_ op: SyncOp) {
        pendingOps.append(op)
        pendingOpCount = pendingOps.count
        persistJournal()
        scheduleRescan()
    }

    private func loadJournal() {
        if let data = try? Data(contentsOf: Self.manifestURL),
           let decoded = try? JSONDecoder().decode([String: SyncStamp].self, from: data) {
            manifest = decoded
        }
        if let data = try? Data(contentsOf: Self.pendingOpsURL),
           let decoded = try? JSONDecoder().decode([SyncOp].self, from: data) {
            pendingOps = decoded
            pendingOpCount = decoded.count
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

    /// An immediate pass (used at launch and after picking a folder).
    func rescan() {
        Task { [weak self] in await self?.performSync() }
    }

    /// One full pass: drain the export journal, then scan the replica and
    /// reconcile the library against it. Reconciliation is skipped while
    /// exports are still pending — the replica is stale until they land, and
    /// reconciling against it could undo the very changes waiting to be
    /// written.
    private func performSync() async {
        guard let root = rootURL else { return }
        if isSyncing {
            needsAnotherPass = true
            return
        }
        isSyncing = true

        await drainJournal(root: root)

        if pendingOps.isEmpty {
            let snapshot = await Task.detached(priority: .utility) {
                Self.scan(root: root)
            }.value
            await reconcile(snapshot, root: root)
            startMonitoring(root: root, directories: snapshot.directories.map { $0.relativePath })
        } else {
            appLog("\(pendingOps.count) sync change(s) couldn't reach the folder — will retry.",
                   level: .warning, category: "Sync")
        }

        isSyncing = false
        if needsAnotherPass {
            needsAnotherPass = false
            scheduleRescan()
        }
    }

    // MARK: - Exporter

    /// Runs journaled ops in order. Stops at the first hard failure (usually
    /// the folder being unreachable) to preserve causal order; superseded ops
    /// drop out.
    private func drainJournal(root: URL) async {
        while let op = pendingOps.first {
            let succeeded = await execute(op, root: root)
            guard succeeded else { break }
            pendingOps.removeFirst()
            persistJournal()
        }
        pendingOpCount = pendingOps.count
    }

    /// Returns true when the op finished or is obsolete; false to retry later.
    private func execute(_ op: SyncOp, root: URL) async -> Bool {
        let local = AppPaths.syncLocalStore
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

    /// Reconciles the library against a replica scan: folders first, then
    /// removals, then copy-ins (each track appears as its file lands), then
    /// mixtape covers — and finally the manifest records what was seen.
    private func reconcile(_ snapshot: SyncSnapshot, root: URL) async {
        // Mixtape styles are adopted only when .mixtapedata actually changed
        // remotely (stamp vs manifest) — never merely because it differs from
        // the library, which would undo local edits.
        var adoptStyle: Set<String> = []
        for dir in snapshot.directories where manifest[styleKey(dir.relativePath)] != dir.styleStamp {
            adoptStyle.insert(dir.relativePath)
        }
        let folderIDs = library.reconcileSyncedFolders(snapshot.directories, adoptStyleFor: adoptStyle)

        // Files that vanished from the replica leave the library (and the
        // local store).
        let remotePaths = Set(snapshot.files.map { $0.relativePath })
        library.removeSyncedTracks(notIn: remotePaths)

        // What needs copying in: unknown files, changed files, or known files
        // whose local copy is missing (e.g. a fresh install, or an import that
        // failed half-way).
        var imports: [SyncSnapshot.File] = []
        var newManifest: [String: SyncStamp] = [:]
        for file in snapshot.files {
            let localPath = AppPaths.syncLocalStore.appendingPathComponent(file.relativePath).path
            if manifest[file.relativePath] == file.stamp,
               FileManager.default.fileExists(atPath: localPath),
               library.hasSyncedTrack(at: file.relativePath) {
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
            let src = root.appendingPathComponent(file.relativePath)
            let dst = AppPaths.syncLocalStore.appendingPathComponent(file.relativePath)
            let ok = await Task.detached(priority: .utility) {
                Self.coordinatedCopy(from: src, to: dst)
            }.value
            if ok {
                newManifest[file.relativePath] = file.stamp
                let dirPath = (file.relativePath as NSString).deletingLastPathComponent
                library.ensureSyncedTrack(at: file.relativePath,
                                          folderID: dirPath.isEmpty ? nil : folderIDs[dirPath])
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
            if manifest[key] == stamp {
                newManifest[key] = stamp
                continue
            }
            let src = root.appendingPathComponent(dir.relativePath, isDirectory: true)
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

        manifest = newManifest
        persistManifest()

        // Sweep local-store leftovers (files/dirs whose remote counterpart is
        // gone). Safe because reconcile only runs with an empty journal.
        let dirPaths = Set(snapshot.directories.map { $0.relativePath })
        let localRoot = AppPaths.syncLocalStore
        await Task.detached(priority: .utility) {
            Self.sweepLocalStore(root: localRoot, validFiles: remotePaths, validDirs: dirPaths)
        }.value
    }

    // MARK: - Scanning (replica)

    /// Walks the replica tree off the main actor (a cloud-backed directory can
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

    /// Deletes anything in the local store whose remote counterpart no longer
    /// exists, bottom-up, then prunes empty directories.
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

    /// Watches the replica's root and every subdirectory for writes and
    /// schedules a pass on any event.
    private func startMonitoring(root: URL, directories: [String]) {
        stopMonitoring()
        var urls = [root]
        urls.append(contentsOf: directories.map { root.appendingPathComponent($0, isDirectory: true) })
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

    private func stopMonitoring() {
        for monitor in monitors {
            monitor.cancel()
        }
        monitors.removeAll()
    }
}
