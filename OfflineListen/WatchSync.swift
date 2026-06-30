import Foundation
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

/// Phone-side WatchConnectivity bridge. The phone owns the truth about what
/// belongs on the watch; this pushes the desired state (a `WatchManifest`) and
/// the audio files, and listens for the watch's commands and log lines.
///
/// File delivery has two paths because the system's `transferFile` channel
/// doesn't establish on every device pair (it accepts the transfer but moves no
/// bytes):
///   - **Reachable** (the watch app is foreground): the phone **streams** the
///     file over the live message channel. It's **resumable** — the watch keeps a
///     `.part` file and reports its current byte offset, so a dropped connection
///     continues from there instead of restarting.
///   - **Not reachable**: a best-effort `transferFile` for background delivery.
/// Whichever path lands the whole file first wins; a file is marked delivered
/// once and the other path is cancelled. `deliveredFileNames`/`activeTransfers`
/// are published for the Watch folder's progress banner.
@MainActor
final class WatchSync: NSObject, ObservableObject {
    static let shared = WatchSync()

    var onClearAll: (() -> Void)?
    var onReady: (() -> Void)?
    /// Invoked with a podcast playhead update received from the watch; wired to
    /// `LibraryStore.applyWatchPosition`.
    var onPosition: ((UUID, Double) -> Void)?

    /// File names confirmed present on the watch (persisted across launches).
    @Published private(set) var deliveredFileNames: Set<String> = []
    /// Live progress (fileName → 0...1) merged from streams and `transferFile`.
    @Published private(set) var activeTransfers: [String: Double] = [:]

    /// Files currently mid-stream, so a re-push doesn't start a second stream.
    private var streamingNames: Set<String> = []
    /// Latest stream progress fraction per file (merged into `activeTransfers`).
    private var streamFractions: [String: Double] = [:]

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

    private var lastPositionSentAt: Date = .distantPast

    /// Sends a podcast playhead update to the watch (best-effort, queued, throttled
    /// to ~12s so a long episode doesn't flood the channel).
    func sendPosition(id: UUID, position: Double) {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported(), session.activationState == .activated, session.isWatchAppInstalled else { return }
        guard Date().timeIntervalSince(lastPositionSentAt) > 12 else { return }
        lastPositionSentAt = Date()
        session.transferUserInfo([WatchSyncKeys.positionID: id.uuidString,
                                  WatchSyncKeys.positionValue: position])
        #endif
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

    private var isOperational: Bool {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return false }
        return session.activationState == .activated && session.isWatchAppInstalled
        #else
        return false
        #endif
    }

    // MARK: - Push

    /// Pushes the desired watch set: updates the manifest, then for each
    /// undelivered file streams it (when reachable) or queues a background
    /// transfer (when not).
    func push(tracks: [Track], folderNames: [UUID: String]) {
        #if canImport(WatchConnectivity)
        let manifestTracks = tracks.enumerated().map { index, track in
            WatchManifestTrack(
                id: track.id, title: track.title, artist: track.artist,
                fileName: track.fileName, duration: track.duration,
                kindRaw: track.kind.rawValue,
                folderName: track.folderID.flatMap { folderNames[$0] },
                order: index,
                byteSize: track.fileSizeBytes,
                lastPosition: track.kind == .podcast ? track.lastPosition : 0)
        }

        let wantedNames = Set(tracks.map { $0.fileName })
        deliveredFileNames.formIntersection(wantedNames)
        streamingNames.formIntersection(wantedNames)
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

        // Drop stale background transfers for files no longer wanted.
        for transfer in session.outstandingFileTransfers where !wantedNames.contains(fileName(of: transfer)) {
            appLog("Cancelling stale transfer \(fileName(of: transfer)).", level: .warning, category: "Watch")
            transfer.cancel()
        }

        let reachable = session.isReachable
        let outstanding = Set(session.outstandingFileTransfers.map { fileName(of: $0) })
        for track in tracks {
            let name = track.fileName
            if deliveredFileNames.contains(name) { continue }
            guard FileManager.default.fileExists(atPath: track.fileURL.path) else {
                appLog("Skipping \"\(track.title)\" — file missing on phone (\(name)).", level: .error, category: "Watch")
                continue
            }
            if reachable {
                startStream(track)
            } else if !outstanding.contains(name) {
                session.transferFile(track.fileURL, metadata: [WatchSyncKeys.metaFileName: name])
                appLog("Queued background transfer of \"\(track.title)\" (\(track.fileSizeKB) KB) — watch unreachable.",
                       category: "Watch")
            }
        }

        if !session.outstandingFileTransfers.isEmpty {
            startProgressTicker()
        }
        if wantedNames.subtracting(deliveredFileNames).isEmpty, !tracks.isEmpty {
            appLog("Watch is up to date — \(tracks.count) track(s) delivered.", level: .success, category: "Watch")
        }
        #endif
    }

    // MARK: - Resumable stream

    #if canImport(WatchConnectivity)
    /// Asks the watch how much of `track` it already has, then streams the rest.
    private func startStream(_ track: Track) {
        let name = track.fileName
        guard session.isReachable, !streamingNames.contains(name) else { return }
        streamingNames.insert(name)
        session.sendMessage([WatchSyncKeys.fxQuery: name], replyHandler: { [weak self] reply in
            Task { @MainActor in
                guard let self else { return }
                let have = reply[WatchSyncKeys.fxHave] as? Int ?? 0
                let done = reply[WatchSyncKeys.fxDone] as? Bool ?? false
                if done {
                    self.markDelivered(name, via: "stream")
                    return
                }
                guard let data = try? Data(contentsOf: track.fileURL) else {
                    self.streamingNames.remove(name)
                    appLog("Couldn't read \(name) to stream.", level: .error, category: "Watch")
                    return
                }
                appLog("Streaming \"\(track.title)\" to watch from \(have / 1024) KB / \(data.count / 1024) KB.",
                       category: "Watch")
                self.sendStreamChunk(name: name, data: data, offset: have, title: track.title)
            }
        }, errorHandler: { [weak self] error in
            Task { @MainActor in
                self?.streamingNames.remove(name)
                appLog("Stream query for \(name) failed: \(error.localizedDescription) — will resume when reachable.",
                       level: .warning, category: "Watch")
            }
        })
    }

    private func sendStreamChunk(name: String, data: Data, offset: Int, title: String) {
        let total = data.count
        let end = min(offset + WatchSyncKeys.fxChunkSize, total)
        let chunk = offset < end ? data.subdata(in: offset..<end) : Data()
        let eof = end >= total
        let message: [String: Any] = [
            WatchSyncKeys.fxName: name,
            WatchSyncKeys.fxOffset: offset,
            WatchSyncKeys.fxData: chunk,
            WatchSyncKeys.fxEof: eof
        ]
        session.sendMessage(message, replyHandler: { [weak self] reply in
            Task { @MainActor in
                guard let self else { return }
                let have = reply[WatchSyncKeys.fxHave] as? Int ?? offset
                let done = reply[WatchSyncKeys.fxDone] as? Bool ?? false
                self.streamFractions[name] = total > 0 ? min(Double(have) / Double(total), 1) : 1
                self.publishActiveTransfers()
                if done || have >= total {
                    self.markDelivered(name, via: "stream")
                    return
                }
                // Always continue from the watch's confirmed offset (self-corrects
                // if a chunk was rejected for arriving at the wrong offset).
                self.sendStreamChunk(name: name, data: data, offset: have, title: title)
            }
        }, errorHandler: { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.streamingNames.remove(name)
                appLog("Stream of \"\(title)\" paused at \(offset / 1024) KB: \(error.localizedDescription) — resumes when reachable.",
                       level: .warning, category: "Watch")
            }
        })
    }

    /// Marks a file delivered, cleans up its stream/transfer state, and cancels
    /// the other (background) path if it's still queued.
    private func markDelivered(_ name: String, via: String) {
        streamingNames.remove(name)
        streamFractions[name] = nil
        deliveredFileNames.insert(name)
        persistDelivered()
        for transfer in session.outstandingFileTransfers where fileName(of: transfer) == name {
            transfer.cancel()
        }
        publishActiveTransfers()
        appLog("Watch received \(name) (via \(via)).", level: .success, category: "Watch")
    }
    #endif

    // MARK: - Progress

    #if canImport(WatchConnectivity)
    private func publishActiveTransfers() {
        var map = streamFractions
        for transfer in session.outstandingFileTransfers {
            let name = fileName(of: transfer)
            // A stuck background transfer (0%) must not mask live stream progress.
            map[name] = max(map[name] ?? 0, transfer.progress.fractionCompleted)
        }
        activeTransfers = map
    }

    private func describe(_ transfer: WCSessionFileTransfer) -> String {
        let p = transfer.progress
        let pct = p.fractionCompleted.isFinite ? Int(p.fractionCompleted * 100) : 0
        return "\(fileName(of: transfer)) — transferring=\(transfer.isTransferring), \(pct)% (\(p.completedUnitCount)/\(p.totalUnitCount) bytes)"
    }

    private var stallWarned = false
    private var lastBackgroundBytes: Int64 = -1
    private var lastBackgroundAt = Date()

    private func startProgressTicker() {
        guard progressTimer == nil else { return }
        stallWarned = false
        lastBackgroundBytes = -1
        lastBackgroundAt = Date()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickBackgroundTransfers() }
        }
    }

    private func tickBackgroundTransfers() {
        let outstanding = session.outstandingFileTransfers
        guard !outstanding.isEmpty else {
            progressTimer?.invalidate()
            progressTimer = nil
            publishActiveTransfers()
            return
        }
        publishActiveTransfers()
        let bytes = outstanding.reduce(Int64(0)) { $0 + $1.progress.completedUnitCount }
        if bytes != lastBackgroundBytes {
            lastBackgroundBytes = bytes
            lastBackgroundAt = Date()
            stallWarned = false
        } else if !stallWarned, Date().timeIntervalSince(lastBackgroundAt) > 20 {
            stallWarned = true
            appLog("Background transfer(s) not progressing; open the watch app to deliver over the live channel instead.",
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
            appLog("Watch session activated (state \(activationState.rawValue), reachable=\(session.isReachable)).",
                   category: "Watch")
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
        Task { @MainActor in self.onReady?() }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let name = (fileTransfer.file.metadata?[WatchSyncKeys.metaFileName] as? String)
            ?? fileTransfer.file.fileURL.lastPathComponent
        Task { @MainActor in
            if let error {
                appLog("Background transfer of \(name) ended: \(error.localizedDescription).", category: "Watch")
            } else {
                self.markDelivered(name, via: "background")
            }
            self.publishActiveTransfers()
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
        if let idString = payload[WatchSyncKeys.positionID] as? String,
           let id = UUID(uuidString: idString),
           let pos = payload[WatchSyncKeys.positionValue] as? Double {
            Task { @MainActor in self.onPosition?(id, pos) }
        }
    }
}
#endif
