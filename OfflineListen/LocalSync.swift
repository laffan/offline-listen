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
        /// The sidecar directory's name as it actually appears on disk, when
        /// the directory has one — normally `.mixtapedata`, but recorded
        /// rather than assumed because a file provider may have renamed it
        /// (see `AppPaths.isMixtapeDataDirectory`).
        let mixtapeDataName: String?
        /// The banner style, when `.mixtapedata/style.json` could actually be
        /// read. Nil when it is absent or unreadable.
        let mixtapeStyle: MixtapeStyle?
        /// Stamps of `.mixtapedata/style.json` / `cover.jpg`, when present.
        let styleStamp: SyncStamp?
        let coverStamp: SyncStamp?
        /// Non-nil when the directory contains `tracks.json` — the running
        /// order of an album *or* a mixtape; the record says which.
        let album: TracklistManifest?
        /// Stamps of `tracks.json` / `cover.jpg` at the directory's top level.
        let albumStamp: SyncStamp?
        let albumCoverStamp: SyncStamp?

        /// The marker that has always said "mixtape". Deliberately separate
        /// from the style below: whether the marker is *there* and whether its
        /// style is *readable* are two different questions, and answering the
        /// first with the second is how an evicted `style.json` used to reset
        /// somebody's font, colours and crop to the defaults.
        var hasMixtapeData: Bool { mixtapeDataName != nil }

        /// Whether this directory is a mixtape. **Two independent witnesses**,
        /// because either can be missing on its own: the hidden
        /// `.mixtapedata` may not have travelled through somebody's cloud
        /// folder, and a `tracks.json` written before records named themselves
        /// doesn't say. What must never happen is the pair being read as an
        /// album merely because the hidden half is out of sight — every
        /// mixtape protection on the import side hangs off this answer.
        var isMixtape: Bool { hasMixtapeData || album?.isMixtape == true }
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
    /// (Re)write `dir/tracks.json` and `dir/cover.jpg` from the album's
    /// current tracklist and sleeve.
    case writeAlbumData(dir: String, folderID: UUID)
    /// Remove both from the replica — the folder is no longer an album.
    case removeAlbumData(dir: String)

    /// True for the ops that copy a track's file out — the unit the sync
    /// progress figure counts (a directory create or a style write isn't one).
    var isFileCopy: Bool {
        if case .copyOut = self { return true }
        return false
    }
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
    /// How many track files the pass in flight has copied so far, and how many
    /// it knows about. The total grows as the pass discovers work (a root's
    /// exports are counted when its journal is drained, its imports when its
    /// replica has been scanned), so Settings can say "Syncing 12 of 133
    /// tracks" instead of a bare spinner. Both are zero between passes — and
    /// while a pass is still scanning, which is what `isSyncing` covers.
    @Published private(set) var syncedFileCount = 0
    @Published private(set) var syncFileTotal = 0
    /// The folder new work is sent **to**: the one sync folder that answers
    /// "where does this album go?" without being asked every time.
    ///
    /// Several sync folders can be mirrored at once, and every one of them is
    /// a *source* — but only one of them is where you put things. Without a
    /// designated upload location "Sync to Local" had to ask which folder on
    /// every single use, which is a question with the same answer every time.
    /// Set by touch-and-hold in Settings; the row wears an arrow to say so.
    @Published private(set) var uploadRootID: UUID?

    private let library: LibraryStore
    private var records: [SyncRootRecord] = []
    private var resolvedURLs: [UUID: URL] = [:]

    private static let legacyBookmarkKey = "localSyncBookmark"
    private static let uploadRootKey = "syncUploadRootID"
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
        loadUploadLocation()
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

    /// The upload location, when it is set *and* reachable — what "Sync to
    /// Local" uses without asking. Nil falls back to asking, which is also
    /// what happens while the chosen folder's provider is offline.
    var uploadRoot: SyncRootState? {
        guard let uploadRootID else { return nil }
        return resolvedRoots.first { $0.id == uploadRootID }
    }

    /// Names one sync folder as the place things are sent to. There is only
    /// ever one; naming a second moves the designation rather than adding to
    /// it. Passing nil clears it and puts the "which folder?" question back.
    func setUploadLocation(_ id: UUID?) {
        guard id == nil || records.contains(where: { $0.id == id }) else { return }
        uploadRootID = id
        if let id {
            UserDefaults.standard.set(id.uuidString, forKey: Self.uploadRootKey)
            appLog("Uploads now go to \"\(records.first { $0.id == id }?.name ?? "the sync folder")\".",
                   category: "Sync")
        } else {
            UserDefaults.standard.removeObject(forKey: Self.uploadRootKey)
            appLog("No sync folder is the upload location any more.", category: "Sync")
        }
    }

    /// Reads the saved upload location, and — the first time a sync folder
    /// exists at all — makes it the upload location. One configured folder
    /// with nothing designated is a distinction without a difference, and
    /// leaving it undesignated only means asking a question with one answer.
    private func loadUploadLocation() {
        if let saved = UserDefaults.standard.string(forKey: Self.uploadRootKey),
           let id = UUID(uuidString: saved), records.contains(where: { $0.id == id }) {
            uploadRootID = id
            return
        }
        uploadRootID = nil
        if let only = records.first, records.count == 1 {
            setUploadLocation(only.id)
        }
    }

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
        // The first folder configured is the upload location by default —
        // see `loadUploadLocation`.
        if uploadRootID == nil { setUploadLocation(record.id) }
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
        if uploadRootID == id {
            // Hand the designation to whatever is left rather than leaving
            // uploads homeless; with nothing left it simply clears.
            setUploadLocation(records.count == 1 ? records.first?.id : nil)
        }
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
        syncedFileCount = 0
        syncFileTotal = 0

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
        syncedFileCount = 0
        syncFileTotal = 0

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
        // Only the file copies count towards the progress figure — a directory
        // create or a `.mixtapedata` write isn't a track.
        syncFileTotal += pendingOps.filter { $0.rootID == rootID && $0.op.isFileCopy }.count
        while let index = pendingOps.firstIndex(where: { $0.rootID == rootID }) {
            let entry = pendingOps[index]
            let succeeded = await execute(entry.op, rootID: rootID, root: rootURL)
            guard succeeded else { break }
            if case .copyOut = entry.op { syncedFileCount += 1 }
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
            let dirURL = root.appendingPathComponent(dir, isDirectory: true)
            return await Task.detached { () -> Bool in
                // Into the sidecar that is already there, whatever it is
                // called — writing to the canonical name beside a renamed one
                // would leave two, and the provider would rename the new one
                // too, and so on.
                let dataDir = Self.existingMixtapeData(in: dirURL)
                    ?? dirURL.appendingPathComponent(AppPaths.mixtapeDataDirName, isDirectory: true)
                return Self.coordinatedWriteMixtapeData(into: dataDir, style: styleData, cover: coverData)
            }.value

        case .removeMixtapeData(let dir):
            let dirURL = root.appendingPathComponent(dir, isDirectory: true)
            return await Task.detached { () -> Bool in
                // Nothing there under any name is the op's own success: the
                // point is that no marker remains.
                guard let dataDir = Self.existingMixtapeData(in: dirURL) else { return true }
                return Self.coordinatedDelete(at: dataDir)
            }.value

        case .writeAlbumData(let dir, let folderID):
            // Snapshot the album on the main actor; obsolete if it is no
            // longer a synced album, in which case the op simply drops.
            guard let manifest = library.tracklistManifest(forFolder: folderID) else { return true }
            guard let manifestData = try? JSONEncoder().encode(manifest) else { return true }
            let coverData = library.sidecarCoverData(forFolder: folderID)
            let dirURL = root.appendingPathComponent(dir, isDirectory: true)
            return await Task.detached {
                Self.coordinatedWriteAlbumData(into: dirURL, manifest: manifestData, cover: coverData)
            }.value

        case .removeAlbumData(let dir):
            let dirURL = root.appendingPathComponent(dir, isDirectory: true)
            let manifest = dirURL.appendingPathComponent(TracklistManifest.fileName)
            let cover = dirURL.appendingPathComponent(TracklistManifest.coverFileName)
            return await Task.detached {
                let a = Self.coordinatedDelete(at: manifest)
                let b = Self.coordinatedDelete(at: cover)
                return a && b
            }.value
        }
    }

    // MARK: - Importer

    private func styleKey(_ dir: String) -> String { "\(dir)/\(AppPaths.mixtapeDataDirName)/style.json" }
    private func coverKey(_ dir: String) -> String { "\(dir)/\(AppPaths.mixtapeDataDirName)/cover.jpg" }
    private func albumKey(_ dir: String) -> String { "\(dir)/\(TracklistManifest.fileName)" }
    private func albumCoverKey(_ dir: String) -> String { "\(dir)/\(TracklistManifest.coverFileName)" }

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
        // Album records are adopted on the same terms: only when `tracks.json`
        // changed remotely, so a local reordering isn't undone by a pass that
        // read the same file it wrote.
        var adoptAlbum: Set<String> = []
        for dir in snapshot.directories where rootManifest[albumKey(dir.relativePath)] != dir.albumStamp {
            adoptAlbum.insert(dir.relativePath)
        }
        let folderIDs = library.reconcileSyncedFolders(snapshot.directories,
                                                       adoptStyleFor: adoptStyle,
                                                       adoptAlbumFor: adoptAlbum,
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
        syncFileTotal += imports.count
        var failures = 0
        /// Directories this pass actually put files into. Their album record
        /// is applied whatever its stamp says: tracks that only just landed
        /// have never been ordered, and on a fresh install that is every one
        /// of them.
        var filled: Set<String> = []
        for (index, file) in imports.enumerated() {
            let src = rootURL.appendingPathComponent(file.relativePath)
            let dst = localStore.appendingPathComponent(file.relativePath)
            let ok = await Task.detached(priority: .utility) {
                Self.coordinatedCopy(from: src, to: dst)
            }.value
            syncedFileCount += 1
            if ok {
                newManifest[file.relativePath] = file.stamp
                let dirPath = (file.relativePath as NSString).deletingLastPathComponent
                if !dirPath.isEmpty { filled.insert(dirPath) }
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

        // The album records, once their tracks are on disk: order, titles and
        // artists come back from `tracks.json`, which is the whole point of
        // writing it — a record that went out whole comes back whole instead
        // of as an alphabetical folder of filenames.
        for dir in snapshot.directories {
            guard let album = dir.album,
                  adoptAlbum.contains(dir.relativePath) || filled.contains(dir.relativePath),
                  let folderID = folderIDs[dir.relativePath] else { continue }
            library.applyTracklistManifest(album, toFolder: folderID)
        }

        // A mixtape whose record was written before records named themselves
        // still leans on `.mixtapedata` alone to say what it is. Restate it
        // now, while the marker is in sight, so the folder keeps its identity
        // the next time the hidden directory isn't — one rewrite per folder,
        // since the condition stops holding once `kind` is in the file.
        for dir in snapshot.directories where dir.hasMixtapeData && dir.album != nil && dir.album?.kind == nil {
            guard let folderID = folderIDs[dir.relativePath],
                  library.folder(withID: folderID)?.isMixtape == true else { continue }
            library.refreshTracklistSidecar(folderID)
        }

        // And their sleeves, on the same "changed remotely" terms as a
        // mixtape's.
        // A mixtape's top-level `cover.jpg` is a copy for the outside world;
        // its own cover is imported below. Reading this one in as well would
        // hand a mixtape an album's cover — and, through `setFolderArtwork`,
        // an album's flag with it.
        for dir in snapshot.directories where !dir.isMixtape {
            guard dir.album != nil, let stamp = dir.albumCoverStamp,
                  let folderID = folderIDs[dir.relativePath] else { continue }
            let key = albumCoverKey(dir.relativePath)
            if rootManifest[key] == stamp, library.folder(withID: folderID)?.artworkFileName != nil {
                newManifest[key] = stamp
                continue
            }
            let src = rootURL.appendingPathComponent(dir.relativePath, isDirectory: true)
                .appendingPathComponent(TracklistManifest.coverFileName)
            let dst = AppPaths.folderArtwork.appendingPathComponent("\(folderID.uuidString).jpg")
            let ok = await Task.detached { Self.coordinatedCopy(from: src, to: dst) }.value
            if ok {
                newManifest[key] = stamp
                library.adoptSyncedAlbumCover(folderID: folderID)
            }
        }
        for dir in snapshot.directories {
            if let stamp = dir.albumStamp { newManifest[albumKey(dir.relativePath)] = stamp }
        }

        // Mixtape covers: copy in when new or changed remotely.
        //
        // `.mixtapedata/cover.jpg` is the authoritative one — it travels with
        // the crop that frames it. The `cover.jpg` beside the tracks is the
        // fallback, and it is only reached by a mixtape whose hidden directory
        // didn't arrive: a picture is better than the gradient placeholder,
        // and reading it here (rather than through the album path above) is
        // what keeps it from bringing an album's flag with it.
        for dir in snapshot.directories where dir.isMixtape {
            guard let folderID = folderIDs[dir.relativePath] else { continue }
            let ownCover = dir.coverStamp != nil
            guard let stamp = ownCover ? dir.coverStamp : dir.albumCoverStamp else { continue }
            let key = ownCover ? coverKey(dir.relativePath) : albumCoverKey(dir.relativePath)
            if rootManifest[key] == stamp {
                newManifest[key] = stamp
                continue
            }
            let dirURL = rootURL.appendingPathComponent(dir.relativePath, isDirectory: true)
            let src = ownCover
                ? dirURL.appendingPathComponent(dir.mixtapeDataName ?? AppPaths.mixtapeDataDirName,
                                                isDirectory: true)
                        .appendingPathComponent("cover.jpg")
                : dirURL.appendingPathComponent(TracklistManifest.coverFileName)
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
    /// block on the network while listing).
    ///
    /// **What is not library content**: hidden entries, anything that isn't a
    /// playable file, and the app's own `.mixtapedata` sidecar — which is the
    /// *marker* for the directory holding it (contributing its style and
    /// stamps) and never a folder in its own right. It is recognised by name
    /// rather than by its leading dot, because a file provider that won't
    /// store a name with no base gives it one, and a directory called
    /// "Unknown file.mixtapedata" is not hidden at all: it was walking
    /// straight into the library as a subfolder of the mixtape, which then
    /// stopped being convertible (mixtapes can't contain folders) and lost
    /// its marker in the same stroke.
    nonisolated private static func scan(root: URL) -> SyncSnapshot {
        var snapshot = SyncSnapshot()
        // The root mirrors the sync folder itself, not a library folder, so it
        // records no directory of its own — hence the nil relative path.
        scanDirectory(root, relative: nil, root: root, into: &snapshot)
        return snapshot
    }

    /// Records `dir`'s playable files and — unless it is the root — `dir`
    /// itself, then walks its subdirectories.
    ///
    /// A directory records *itself* rather than being recorded by its parent,
    /// because its sidecar is found in the listing it already pays for: having
    /// the parent look for it would mean listing every directory in the tree
    /// twice on every pass, over a folder that can be somebody's Dropbox.
    nonisolated private static func scanDirectory(_ dir: URL, relative: String?, root: URL,
                                                  into snapshot: inout SyncSnapshot) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey],
            options: []) else { return }
        var dataDir: URL?
        var children: [URL] = []
        for entry in entries.sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }) {
            let name = entry.lastPathComponent
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if AppPaths.isMixtapeDataDirectory(name) {
                // This directory's own bookkeeping: its marker, and nothing
                // the library should ever see or walk into.
                if isDir { dataDir = entry }
                continue
            }
            if name.hasPrefix(".") { continue }
            if isDir {
                children.append(entry)
            } else if PlayableMedia.isPlayable(extension: entry.pathExtension) {
                guard let stamp = stamp(of: entry) else { continue }
                snapshot.files.append(SyncSnapshot.File(relativePath: relativePath(of: entry, from: root),
                                                       stamp: stamp))
            }
        }
        if let relative {
            snapshot.directories.append(record(at: dir, relative: relative, dataDir: dataDir))
        }
        for child in children {
            scanDirectory(child, relative: relativePath(of: child, from: root), root: root, into: &snapshot)
        }
    }

    /// One directory's record: its two sidecars, read and stamped.
    nonisolated private static func record(at dir: URL, relative: String,
                                           dataDir: URL?) -> SyncSnapshot.Directory {
        let styleURL = dataDir?.appendingPathComponent("style.json")
        let coverURL = dataDir?.appendingPathComponent("cover.jpg")
        let manifestURL = dir.appendingPathComponent(TracklistManifest.fileName)
        let albumCoverURL = dir.appendingPathComponent(TracklistManifest.coverFileName)
        return SyncSnapshot.Directory(
            relativePath: relative,
            mixtapeDataName: dataDir?.lastPathComponent,
            mixtapeStyle: styleURL.flatMap { mixtapeStyle(at: $0) },
            styleStamp: styleURL.flatMap { stamp(of: $0) },
            coverStamp: coverURL.flatMap { stamp(of: $0) },
            album: tracklist(at: manifestURL),
            albumStamp: stamp(of: manifestURL),
            albumCoverStamp: stamp(of: albumCoverURL))
    }

    /// The album record beside a directory's audio, when there is one. A
    /// `tracks.json` that won't parse is treated as absent rather than as an
    /// empty album: a truncated or half-written file (a sync provider caught
    /// mid-copy) must not be read as "this record has no songs".
    nonisolated private static func tracklist(at url: URL) -> TracklistManifest? {
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(TracklistManifest.self, from: data),
              !manifest.tracks.isEmpty else { return nil }
        return manifest
    }

    nonisolated private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// The mixtape sidecar inside a replica directory, whatever name it is
    /// wearing — the canonical one first (one `stat`, and the answer almost
    /// every time), and only failing that a listing to find a renamed one.
    nonisolated private static func existingMixtapeData(in dir: URL) -> URL? {
        let canonical = dir.appendingPathComponent(AppPaths.mixtapeDataDirName, isDirectory: true)
        if isDirectory(canonical) { return canonical }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return nil }
        return entries.first {
            AppPaths.isMixtapeDataDirectory($0.lastPathComponent) && isDirectory($0)
        }
    }

    /// The banner style, or nil when there isn't one to read.
    ///
    /// Nil means *unknown*, never "the default". A missing or half-written
    /// `style.json` — a cloud provider that evicted it, or was caught
    /// mid-copy — used to come back as a fresh `MixtapeStyle()`, which the
    /// importer then adopted over the crop, font and colours the user had
    /// chosen. An answer of nil leaves them alone.
    nonisolated private static func mixtapeStyle(at styleURL: URL) -> MixtapeStyle? {
        guard let data = try? Data(contentsOf: styleURL) else { return nil }
        return try? JSONDecoder().decode(MixtapeStyle.self, from: data)
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

    /// Writes an album's `tracks.json` (and `cover.jpg`, when it has one)
    /// into the album's own directory in the replica. The tracklist is
    /// written even when the cover isn't: order and titles are the part that
    /// can't be recovered from the files themselves.
    nonisolated private static func coordinatedWriteAlbumData(into dir: URL, manifest: Data, cover: Data?) -> Bool {
        var coordinationError: NSError?
        var wrote = false
        NSFileCoordinator().coordinate(writingItemAt: dir, options: [], error: &coordinationError) { writeURL in
            do {
                try FileManager.default.createDirectory(at: writeURL, withIntermediateDirectories: true)
                try manifest.write(to: writeURL.appendingPathComponent(TracklistManifest.fileName),
                                   options: .atomic)
                if let cover {
                    try cover.write(to: writeURL.appendingPathComponent(TracklistManifest.coverFileName),
                                    options: .atomic)
                }
                wrote = true
            } catch {
                appLog("Couldn't write \(TracklistManifest.fileName): \(error.localizedDescription)",
                       level: .warning, category: "Sync")
            }
        }
        if let coordinationError {
            appLog("Couldn't write the album record: \(coordinationError.localizedDescription)",
                   level: .warning, category: "Sync")
        }
        return wrote
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
