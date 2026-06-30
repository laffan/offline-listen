import Foundation
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

/// Phone-side WatchConnectivity bridge. The phone owns the truth about what
/// belongs on the watch; this pushes the desired state (a `WatchManifest`) and
/// the audio files, and listens for the watch's commands and log lines.
///
/// Audio is sent with **`transferFile`** — the system's background file-transfer
/// API for a watch and its companion. It does **not** require the apps to be
/// reachable or foregrounded: the OS queues each transfer and delivers it
/// opportunistically, surviving the watch app backgrounding or being suspended,
/// and resumes large files on its own. A file is marked delivered when its
/// transfer reports `didFinish` with no error, so a failed one retries on the
/// next push. Real per-file progress (`WCSessionFileTransfer.progress`) is
/// published for the Watch folder's sync banner.
@MainActor
final class WatchSync: NSObject, ObservableObject {
    static let shared = WatchSync()

    /// Invoked when the watch asks to clear everything; wired to
    /// `LibraryStore.clearAllFromWatch` at app startup.
    var onClearAll: (() -> Void)?

    /// Invoked when the session becomes usable (activated / watch state changed)
    /// so the current set can be re-pushed; wired to `LibraryStore.syncWatch`.
    var onReady: (() -> Void)?

    /// File names confirmed received by the watch. Published for progress UI;
    /// persisted so it survives relaunch.
    @Published private(set) var deliveredFileNames: Set<String> = []

    /// Live per-file transfer progress (fileName → 0...1) for files in flight.
    @Published private(set) var activeTransfers: [String: Double] = [:]

    private static let deliveredKey = "watchDeliveredFileNames"
    private var progressTimer: Timer?

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

    private func fileName(of transfer: WCSessionFileTransfer) -> String {
        (transfer.file.metadata?[WatchSyncKeys.metaFileName] as? String) ?? transfer.file.fileURL.lastPathComponent
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

    /// Pushes the desired watch set: updates the manifest and queues a background
    /// transfer for any audio the watch hasn't confirmed yet. `tracks` is
    /// `LibraryStore.watchTracks`; `folderNames` maps folder ids to display names.
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

        // Cancel stale transfers left over from earlier runs (files no longer on
        // the watch). These otherwise pile up in the queue and clog it.
        for transfer in session.outstandingFileTransfers where !wantedNames.contains(fileName(of: transfer)) {
            appLog("Cancelling stale transfer \(fileName(of: transfer)).", level: .warning, category: "Watch")
            transfer.cancel()
        }

        // Don't re-queue a file that's already mid-transfer.
        let outstanding = Set(session.outstandingFileTransfers.map { fileName(of: $0) })
        for track in tracks {
            let name = track.fileName
            if deliveredFileNames.contains(name) || outstanding.contains(name) { continue }
            let url = track.fileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                appLog("Skipping \"\(track.title)\" — file missing on phone (\(name)).",
                       level: .error, category: "Watch")
                continue
            }
            session.transferFile(url, metadata: [WatchSyncKeys.metaFileName: name])
            appLog("Queued transfer of \"\(track.title)\" (\(track.fileSizeKB) KB) to watch.", category: "Watch")
        }

        if session.outstandingFileTransfers.isEmpty {
            if wantedNames.subtracting(deliveredFileNames).isEmpty, !tracks.isEmpty {
                appLog("Watch is up to date — \(tracks.count) track(s) delivered.", level: .success, category: "Watch")
            }
        } else {
            logOutstanding("After queueing")
            startProgressTicker()
        }
        #endif
    }

    #if canImport(WatchConnectivity)
    /// One-line description of a transfer's live state.
    private func describe(_ transfer: WCSessionFileTransfer) -> String {
        let p = transfer.progress
        let pct = p.fractionCompleted.isFinite ? Int(p.fractionCompleted * 100) : 0
        return "\(fileName(of: transfer)) — transferring=\(transfer.isTransferring), \(pct)% (\(p.completedUnitCount)/\(p.totalUnitCount) bytes)"
    }

    /// Logs the full outstanding-transfer queue with per-file byte progress.
    private func logOutstanding(_ context: String) {
        let xs = session.outstandingFileTransfers
        guard !xs.isEmpty else {
            appLog("\(context): no outstanding transfers.", category: "Watch")
            return
        }
        appLog("\(context): \(xs.count) outstanding transfer(s):", category: "Watch")
        for transfer in xs {
            appLog("  • \(describe(transfer))", category: "Watch")
        }
    }

    // Stall detection: if the queue's total byte progress doesn't advance for a
    // while, say so — on the Simulator `transferFile` frequently never delivers.
    private var lastProgressBytes: Int64 = -1
    private var lastProgressAt = Date()
    private var stallWarned = false

    /// Polls the system's outstanding transfers for live progress while any run.
    private func startProgressTicker() {
        guard progressTimer == nil else { return }
        lastProgressBytes = -1
        lastProgressAt = Date()
        stallWarned = false
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateProgress() }
        }
        updateProgress()
    }

    private func updateProgress() {
        let outstanding = session.outstandingFileTransfers
        guard !outstanding.isEmpty else {
            progressTimer?.invalidate()
            progressTimer = nil
            if !activeTransfers.isEmpty { activeTransfers = [:] }
            return
        }
        var map: [String: Double] = [:]
        var totalBytes: Int64 = 0
        for transfer in outstanding {
            map[fileName(of: transfer)] = transfer.progress.fractionCompleted
            totalBytes += transfer.progress.completedUnitCount
        }
        activeTransfers = map

        if totalBytes != lastProgressBytes {
            if lastProgressBytes >= 0, totalBytes > lastProgressBytes {
                appLog("Transfer progress: \(totalBytes) bytes delivered across \(outstanding.count) transfer(s).",
                       level: .debug, category: "Watch")
            }
            lastProgressBytes = totalBytes
            lastProgressAt = Date()
            stallWarned = false
        } else if !stallWarned, Date().timeIntervalSince(lastProgressAt) > 20 {
            stallWarned = true
            logOutstanding("Stalled (no byte progress in 20s)")
            appLog("Transfers are queued but not progressing. `transferFile` often never delivers on the watchOS Simulator — try a real iPhone+Watch pair.",
                   level: .warning, category: "Watch")
        }
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
            let pending = session.hasContentPending
            let files = session.outstandingFileTransfers.count
            appLog("Watch session activated (state \(activationState.rawValue), hasContentPending=\(pending), outstandingFiles=\(files)).",
                   category: "Watch")
        }
        if activationState == .activated {
            Task { @MainActor in
                self.logOutstanding("At activation")
                if !WCSession.default.outstandingFileTransfers.isEmpty { self.startProgressTicker() }
                self.onReady?()
            }
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

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let name = (fileTransfer.file.metadata?[WatchSyncKeys.metaFileName] as? String)
            ?? fileTransfer.file.fileURL.lastPathComponent
        Task { @MainActor in
            self.activeTransfers[name] = nil
            if let error {
                appLog("Transfer of \(name) failed: \(error.localizedDescription) — will retry.",
                       level: .error, category: "Watch")
            } else {
                self.deliveredFileNames.insert(name)
                self.persistDelivered()
                appLog("Watch received \(name).", level: .success, category: "Watch")
            }
            self.updateProgress()
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
