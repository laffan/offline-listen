import Foundation
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

/// Phone-side WatchConnectivity bridge. The phone owns the truth about what
/// belongs on the watch; this pushes the desired state (a `WatchManifest`) and
/// the audio files, and listens for the watch's commands and log lines.
///
/// File delivery uses two paths:
///   - **Reachable** (both apps active, incl. the Simulator): the file is
///     streamed as a sequence of `sendMessage` chunks the watch reassembles to
///     disk. `transferFile` does not deliver on the watchOS Simulator, so this
///     is what actually works while developing.
///   - **Not reachable**: a best-effort `transferFile` for background delivery on
///     a real device.
/// A file is marked delivered only once a path confirms completion (final chunk
/// acked, or `didFinish` with no error), so a failure is retried on the next
/// push / ready event. `deliveredFileNames` is published for the progress UI.
@MainActor
final class WatchSync: NSObject, ObservableObject {
    static let shared = WatchSync()

    /// Invoked when the watch asks to clear everything; wired to
    /// `LibraryStore.clearAllFromWatch` at app startup.
    var onClearAll: (() -> Void)?

    /// Invoked when the session becomes usable (activated / reachable / watch
    /// state changed) so the current set can be re-pushed; wired to
    /// `LibraryStore.syncWatch` at app startup.
    var onReady: (() -> Void)?

    /// File names confirmed received by the watch. Published for progress UI;
    /// persisted so it survives relaunch.
    @Published private(set) var deliveredFileNames: Set<String> = []

    /// Files currently being chunk-streamed, so a re-push doesn't restart them.
    private var streamingFileNames: Set<String> = []
    /// Files handed to the background `transferFile` path (deduped per session).
    private var backgroundFileNames: Set<String> = []

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

    /// Pushes the desired watch set: updates the manifest and sends any audio the
    /// watch hasn't confirmed yet. `tracks` is `LibraryStore.watchTracks`;
    /// `folderNames` maps folder ids to display names for the playlist grouping.
    func push(tracks: [Track], folderNames: [UUID: String]) {
        #if canImport(WatchConnectivity)
        let manifestTracks = tracks.enumerated().map { index, track in
            WatchManifestTrack(
                id: track.id, title: track.title, artist: track.artist,
                fileName: track.fileName, duration: track.duration,
                kindRaw: track.kind.rawValue,
                folderName: track.folderID.flatMap { folderNames[$0] },
                order: index)
        }

        // Forget bookkeeping for files no longer wanted (removed from the watch).
        let wantedNames = Set(tracks.map { $0.fileName })
        deliveredFileNames.formIntersection(wantedNames)
        streamingFileNames.formIntersection(wantedNames)
        backgroundFileNames.formIntersection(wantedNames)
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

        let reachable = session.isReachable
        for track in tracks {
            let name = track.fileName
            if deliveredFileNames.contains(name) { continue }
            let url = track.fileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                appLog("Skipping \"\(track.title)\" — file missing on phone (\(name)).",
                       level: .error, category: "Watch")
                continue
            }
            if reachable {
                guard !streamingFileNames.contains(name) else { continue }
                startStream(track)
            } else if !backgroundFileNames.contains(name) {
                backgroundFileNames.insert(name)
                session.transferFile(url, metadata: [WatchSyncKeys.metaFileName: name])
                appLog("Queued background transfer of \"\(track.title)\" (watch unreachable).", category: "Watch")
            }
        }

        if wantedNames.subtracting(deliveredFileNames).isEmpty, !tracks.isEmpty {
            appLog("Watch is up to date — \(tracks.count) track(s) delivered.", level: .success, category: "Watch")
        }
        #endif
    }

    #if canImport(WatchConnectivity)
    /// Begins streaming a track's audio file to the watch as ordered chunks.
    private func startStream(_ track: Track) {
        let name = track.fileName
        guard let data = try? Data(contentsOf: track.fileURL) else {
            appLog("Couldn't read \(name) to stream to watch.", level: .error, category: "Watch")
            return
        }
        let total = max(1, (data.count + WatchSyncKeys.fxChunkSize - 1) / WatchSyncKeys.fxChunkSize)
        streamingFileNames.insert(name)
        appLog("Streaming \"\(track.title)\" to watch — \(data.count / 1024) KB in \(total) chunk(s).",
               category: "Watch")
        sendChunk(0, of: data, name: name, total: total, title: track.title)
    }

    private func sendChunk(_ index: Int, of data: Data, name: String, total: Int, title: String) {
        let start = index * WatchSyncKeys.fxChunkSize
        let end = min(start + WatchSyncKeys.fxChunkSize, data.count)
        let chunk = start < end ? data.subdata(in: start..<end) : Data()
        let message: [String: Any] = [
            WatchSyncKeys.fxName: name,
            WatchSyncKeys.fxIndex: index,
            WatchSyncKeys.fxTotal: total,
            WatchSyncKeys.fxData: chunk
        ]
        session.sendMessage(message, replyHandler: { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if index + 1 < total {
                    self.sendChunk(index + 1, of: data, name: name, total: total, title: title)
                } else {
                    self.streamingFileNames.remove(name)
                    self.backgroundFileNames.remove(name)
                    self.deliveredFileNames.insert(name)
                    self.persistDelivered()
                    appLog("Watch received \"\(title)\" (\(data.count / 1024) KB).",
                           level: .success, category: "Watch")
                }
            }
        }, errorHandler: { [weak self] error in
            Task { @MainActor in
                self?.streamingFileNames.remove(name)
                appLog("Streaming \(name) failed at chunk \(index + 1)/\(total): \(error.localizedDescription) — will retry.",
                       level: .error, category: "Watch")
            }
        })
    }
    #endif
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
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        appLog("Watch state changed (installed=\(session.isWatchAppInstalled) paired=\(session.isPaired)).",
               category: "Watch")
        Task { @MainActor in self.onReady?() }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        appLog("Watch reachability changed (reachable=\(session.isReachable)).", category: "Watch")
        if session.isReachable {
            Task { @MainActor in self.onReady?() }
        }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let name = (fileTransfer.file.metadata?[WatchSyncKeys.metaFileName] as? String)
            ?? fileTransfer.file.fileURL.lastPathComponent
        Task { @MainActor in
            self.backgroundFileNames.remove(name)
            if let error {
                appLog("Background transfer of \(name) failed: \(error.localizedDescription) — will retry.",
                       level: .error, category: "Watch")
            } else {
                self.deliveredFileNames.insert(name)
                self.persistDelivered()
                appLog("Watch received \(name) (background).", level: .success, category: "Watch")
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
