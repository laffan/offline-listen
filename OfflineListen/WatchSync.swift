import Foundation
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

/// Phone-side WatchConnectivity bridge. The phone owns the truth about what
/// belongs on the watch; this pushes the desired state (a `WatchManifest`) and
/// the audio files, and listens for the watch's commands and log lines.
///
/// Delivery is tracked **per file** and only confirmed once `transferFile`
/// reports it finished (`didFinish` with no error), so a transfer that fails or
/// never lands is retried on the next push instead of being lost. `deliveredFileNames`
/// is published so the Watch folder can show sync progress.
@MainActor
final class WatchSync: NSObject, ObservableObject {
    static let shared = WatchSync()

    /// Invoked when the watch asks to clear everything; wired to
    /// `LibraryStore.clearAllFromWatch` at app startup.
    var onClearAll: (() -> Void)?

    /// Invoked when the session becomes usable (activated, or the watch state
    /// changes) so the current set can be re-pushed; wired to
    /// `LibraryStore.syncWatch` at app startup. A push attempted before the
    /// session is ready no-ops, so this is what actually delivers the first sync.
    var onReady: (() -> Void)?

    /// File names confirmed received by the watch (transfer finished cleanly).
    /// Published so progress UI updates; persisted so it survives relaunch.
    @Published private(set) var deliveredFileNames: Set<String> = []

    /// Files currently mid-transfer, so a re-push doesn't queue them twice.
    private var inFlightFileNames: Set<String> = []

    private static let deliveredKey = "watchDeliveredFileNames"

    private override init() {
        super.init()
        deliveredFileNames = Set(UserDefaults.standard.stringArray(forKey: Self.deliveredKey) ?? [])
        activate()
    }

    private func activate() {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else {
            appLog("WatchConnectivity unsupported on this device.", level: .warning, category: "Watch")
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        #endif
    }

    private func persistDelivered() {
        UserDefaults.standard.set(Array(deliveredFileNames), forKey: Self.deliveredKey)
    }

    #if canImport(WatchConnectivity)
    private var session: WCSession { WCSession.default }

    /// Human-readable session state for the log.
    private var stateDescription: String {
        guard WCSession.isSupported() else { return "unsupported" }
        let s = session
        return "activated=\(s.activationState == .activated) installed=\(s.isWatchAppInstalled) reachable=\(s.isReachable) paired=\(s.isPaired)"
    }
    #endif

    /// True when a session is active and a watch app is installed to receive data.
    private var isOperational: Bool {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return false }
        return session.activationState == .activated && session.isWatchAppInstalled
        #else
        return false
        #endif
    }

    /// Pushes the desired watch set: updates the manifest and transfers any audio
    /// file the watch hasn't confirmed yet. `tracks` is `LibraryStore.watchTracks`;
    /// `folderNames` maps folder ids to display names so each track can carry its
    /// playlist name.
    func push(tracks: [Track], folderNames: [UUID: String]) {
        #if canImport(WatchConnectivity)
        let manifestTracks = tracks.enumerated().map { index, track in
            WatchManifestTrack(
                id: track.id,
                title: track.title,
                artist: track.artist,
                fileName: track.fileName,
                duration: track.duration,
                kindRaw: track.kind.rawValue,
                folderName: track.folderID.flatMap { folderNames[$0] },
                order: index)
        }

        // Forget bookkeeping for files no longer wanted (removed from the watch),
        // so re-adding one later transfers it again.
        let wantedNames = Set(tracks.map { $0.fileName })
        deliveredFileNames.formIntersection(wantedNames)
        inFlightFileNames.formIntersection(wantedNames)
        persistDelivered()

        guard isOperational else {
            appLog("Watch sync deferred — session not ready (\(stateDescription)). \(tracks.count) track(s) queued.",
                   level: .warning, category: "Watch")
            return
        }

        appLog("Syncing \(tracks.count) track(s) to watch [\(stateDescription)].", category: "Watch")

        do {
            let data = try JSONEncoder().encode(WatchManifest(tracks: manifestTracks))
            try session.updateApplicationContext([WatchSyncKeys.manifest: data])
            let grouped = manifestTracks.filter { $0.folderName != nil }.count
            appLog("Sent manifest: \(manifestTracks.count) track(s), \(grouped) in playlists.", category: "Watch")
        } catch {
            appLog("Failed to send manifest: \(error.localizedDescription)", level: .error, category: "Watch")
        }

        for track in tracks {
            let name = track.fileName
            if deliveredFileNames.contains(name) || inFlightFileNames.contains(name) { continue }
            let url = track.fileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                appLog("Skipping \"\(track.title)\" — file missing on phone (\(name)).",
                       level: .error, category: "Watch")
                continue
            }
            var metadata: [String: Any] = [
                WatchSyncKeys.metaID: track.id.uuidString,
                WatchSyncKeys.metaTitle: track.title,
                WatchSyncKeys.metaArtist: track.artist,
                WatchSyncKeys.metaFileName: name,
                WatchSyncKeys.metaDuration: track.duration,
                WatchSyncKeys.metaKind: track.kind.rawValue,
                WatchSyncKeys.metaOrder: 0
            ]
            if let folderID = track.folderID, let folder = folderNames[folderID] {
                metadata[WatchSyncKeys.metaFolderName] = folder
            }
            session.transferFile(url, metadata: metadata)
            inFlightFileNames.insert(name)
            appLog("Transferring \"\(track.title)\" → watch (\(name)).", category: "Watch")
        }

        let outstanding = wantedNames.subtracting(deliveredFileNames)
        if outstanding.isEmpty {
            appLog("Watch is up to date — \(tracks.count) track(s) delivered.", level: .success, category: "Watch")
        }
        #endif
    }
}

#if canImport(WatchConnectivity)
extension WatchSync: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        if let error {
            appLog("Watch session activation error: \(error.localizedDescription)", level: .error, category: "Watch")
        } else {
            appLog("Watch session activated (state \(activationState.rawValue)).", category: "Watch")
        }
        if activationState == .activated {
            Task { @MainActor in self.onReady?() }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate so a switched watch keeps syncing.
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        appLog("Watch state changed (installed=\(session.isWatchAppInstalled) paired=\(session.isPaired)).",
               category: "Watch")
        Task { @MainActor in self.onReady?() }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        if session.isReachable {
            Task { @MainActor in self.onReady?() }
        }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let name = (fileTransfer.file.metadata?[WatchSyncKeys.metaFileName] as? String)
            ?? fileTransfer.file.fileURL.lastPathComponent
        Task { @MainActor in
            self.inFlightFileNames.remove(name)
            if let error {
                appLog("Transfer of \(name) failed: \(error.localizedDescription) — will retry.",
                       level: .error, category: "Watch")
            } else {
                self.deliveredFileNames.insert(name)
                self.persistDelivered()
                appLog("Watch received \(name).", level: .success, category: "Watch")
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handle(message)
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        handle(userInfo)
    }

    private nonisolated func handle(_ payload: [String: Any]) {
        if let line = payload[WatchSyncKeys.log] as? String {
            appLog("⌚ \(line)", category: "Watch")
        }
        if payload[WatchSyncKeys.command] as? String == WatchSyncKeys.clearAllCommand {
            appLog("Watch requested Clear All.", level: .warning, category: "Watch")
            Task { @MainActor in self.onClearAll?() }
        }
    }
}
#endif
