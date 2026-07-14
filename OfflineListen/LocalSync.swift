import Foundation

/// What a scan of the local sync folder found: every playable file and every
/// directory (with the mixtape style read from a directory's `.mixtapedata`,
/// when it has one). Paths are relative to the sync root.
struct SyncSnapshot {
    struct File {
        let relativePath: String
    }

    struct Directory {
        let relativePath: String
        /// Non-nil when the directory contains `.mixtapedata` — the directory
        /// is a mixtape and this is its banner style.
        let mixtapeStyle: MixtapeStyle?
    }

    var files: [File] = []
    var directories: [Directory] = []
}

/// Owns the user-chosen local sync folder: persists its security-scoped
/// bookmark, watches the directory tree for external changes, and reconciles
/// what's on disk into the library (as synced tracks/folders) via
/// `LibraryStore.applySyncSnapshot`.
///
/// The sync folder is a mirror of the synced part of the library: files added
/// to it (from the Files app, another device, …) appear in the library
/// immediately, and files removed from it disappear immediately.
@MainActor
final class LocalSyncStore: ObservableObject {
    /// The resolved sync root, nil until a folder is chosen (or while its
    /// bookmark can't be resolved — e.g. the folder was deleted externally).
    @Published private(set) var rootURL: URL?

    private let library: LibraryStore
    private static let bookmarkKey = "localSyncBookmark"

    /// One kqueue-backed source per directory in the tree (the root and every
    /// subdirectory) — a single source only reports writes to its own
    /// directory, not to nested ones.
    private var monitors: [DispatchSourceFileSystemObject] = []
    private var pendingRescan: Task<Void, Never>?

    init(library: LibraryStore) {
        self.library = library
        resolveBookmark()
        // rescan() itself defers the walk and the reconcile off the current
        // turn, so kicking it from init (inside a view update) is safe.
        if rootURL != nil {
            rescan()
        }
    }

    var isConfigured: Bool { rootURL != nil }

    /// Adopts a folder freshly picked in Settings. The caller must have opened
    /// its security scope (fileImporter grants it) so a bookmark can be made.
    func setRoot(_ url: URL) {
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

    /// Un-configures local sync. Synced tracks/folders leave the library; the
    /// files themselves are untouched.
    func clearRoot() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        stopMonitoring()
        rootURL = nil
        AppPaths.syncRoot = nil
        library.removeAllSynced()
        appLog("Local sync folder removed.", category: "Sync")
    }

    /// Resolves the persisted bookmark, opens its security scope for the
    /// session, and publishes the root (also into `AppPaths.syncRoot`, which
    /// synced tracks resolve their file URLs against).
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
            // unavailable. Synced items stay in the library; their files just
            // don't resolve until the folder is back.
            rootURL = nil
            AppPaths.syncRoot = nil
            appLog("Couldn't resolve the sync folder bookmark: \(error.localizedDescription)",
                   level: .warning, category: "Sync")
        }
    }

    // MARK: - Scanning

    /// Debounced rescan entry point: called on any filesystem event, on app
    /// foreground, and after our own sync operations. Coalesces bursts (a copy
    /// of many files fires many events) into one scan.
    func scheduleRescan() {
        pendingRescan?.cancel()
        pendingRescan = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.rescan()
        }
    }

    /// Scans the tree and reconciles the library, then rebuilds the directory
    /// monitors (new subdirectories need watching too). The walk runs off the
    /// main actor: a cloud-backed file-provider directory (Dropbox, iCloud
    /// Drive, …) can block on the network while listing, and that must never
    /// freeze the UI.
    func rescan() {
        guard let root = rootURL else { return }
        Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                Self.scan(root: root)
            }.value
            guard let self, self.rootURL == root else { return }
            self.library.applySyncSnapshot(snapshot)
            self.startMonitoring(root: root, directories: snapshot.directories.map { $0.relativePath })
        }
    }

    /// Walks the sync tree. Hidden files and directories are skipped, except
    /// that a `.mixtapedata` directory marks its *parent* as a mixtape and
    /// contributes its style. `nonisolated` so the walk really runs on the
    /// detached task, not the main actor.
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
                snapshot.directories.append(
                    SyncSnapshot.Directory(relativePath: relative,
                                           mixtapeStyle: mixtapeStyle(inDirectory: entry)))
                scanDirectory(entry, root: root, into: &snapshot)
            } else if PlayableMedia.isPlayable(extension: entry.pathExtension) {
                snapshot.files.append(SyncSnapshot.File(relativePath: relative))
            }
        }
    }

    /// Reads a directory's `.mixtapedata/style.json`, if the hidden mixtape
    /// data folder exists. A present `.mixtapedata` with an unreadable style
    /// still counts as a mixtape (default style) — the marker is the folder.
    nonisolated private static func mixtapeStyle(inDirectory dir: URL) -> MixtapeStyle? {
        let dataDir = dir.appendingPathComponent(AppPaths.mixtapeDataDirName, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dataDir.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        let styleURL = dataDir.appendingPathComponent("style.json")
        if let data = try? Data(contentsOf: styleURL),
           let style = try? JSONDecoder().decode(MixtapeStyle.self, from: data) {
            return style
        }
        return MixtapeStyle()
    }

    nonisolated private static func relativePath(of url: URL, from root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count + 1))
    }

    // MARK: - Monitoring

    /// Watches the root and every subdirectory for writes (files/directories
    /// added, removed, or renamed) and schedules a rescan on any event.
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
