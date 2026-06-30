import Foundation
import WatchConnectivity

/// Watch-side WatchConnectivity bridge. Receives the manifest (the phone's
/// desired state) and the audio files, hands them to `WatchLibraryStore`, and
/// sends the "Clear all" command back to the phone when the user clears the watch.
///
/// Every notable step is mirrored to the phone's Log tab via `forwardLog` so the
/// whole sync is debuggable from one place.
@MainActor
final class WatchConnectivityManager: NSObject, ObservableObject {
    private let store: WatchLibraryStore

    init(store: WatchLibraryStore) {
        self.store = store
        super.init()
        activate()
    }

    private func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Empties the watch and tells the phone to clear its Watch folder to match.
    func clearAll() {
        store.clearAll()
        forwardLog("Cleared all tracks on watch.")
        send([WatchSyncKeys.command: WatchSyncKeys.clearAllCommand])
    }

    /// Sends a payload to the phone, preferring a live message and falling back
    /// to the guaranteed-delivery queue.
    private func send(_ payload: [String: Any]) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { _ in
                session.transferUserInfo(payload)
            }
        } else {
            session.transferUserInfo(payload)
        }
    }

    /// Mirrors a line to the phone's Log tab (and the watch console).
    private func forwardLog(_ line: String) {
        print("[WatchSync] \(line)")
        send([WatchSyncKeys.log: line])
    }

    private var lastPositionSentAt = Date.distantPast

    /// Forwards a podcast playhead change to the phone (throttled to ~12s).
    func sendPosition(id: UUID, position: Double) {
        guard WCSession.isSupported() else { return }
        guard Date().timeIntervalSince(lastPositionSentAt) > 12 else { return }
        lastPositionSentAt = Date()
        WCSession.default.transferUserInfo([WatchSyncKeys.positionID: id.uuidString,
                                            WatchSyncKeys.positionValue: position])
    }

    /// Decodes and applies a manifest payload from the phone.
    fileprivate func applyManifest(from context: [String: Any]) {
        guard let data = context[WatchSyncKeys.manifest] as? Data,
              let manifest = try? JSONDecoder().decode(WatchManifest.self, from: data) else { return }
        store.apply(manifest)
        let present = manifest.tracks.filter {
            FileManager.default.fileExists(atPath: WatchPaths.documents.appendingPathComponent($0.fileName).path)
        }.count
        let playlists = Set(manifest.tracks.compactMap { $0.folderName }).count
        forwardLog("Applied manifest: \(manifest.tracks.count) track(s), \(present) file(s) present, \(playlists) playlist(s).")
    }

    private func byteSize(of url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
    }

    /// Handles a resumable-stream message from the phone and replies with how many
    /// bytes the watch now holds (so the phone resumes from the right offset).
    fileprivate func handleStreamMessage(_ message: [String: Any], reply: ([String: Any]) -> Void) {
        // Offset query: report how much of the file we already have.
        if let name = message[WatchSyncKeys.fxQuery] as? String {
            let finalURL = WatchPaths.documents.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: finalURL.path) {
                reply([WatchSyncKeys.fxHave: byteSize(of: finalURL), WatchSyncKeys.fxDone: true])
            } else {
                let partURL = WatchPaths.documents.appendingPathComponent(name + ".part")
                reply([WatchSyncKeys.fxHave: byteSize(of: partURL), WatchSyncKeys.fxDone: false])
            }
            return
        }

        guard let name = message[WatchSyncKeys.fxName] as? String,
              let offset = message[WatchSyncKeys.fxOffset] as? Int,
              let data = message[WatchSyncKeys.fxData] as? Data else {
            reply([WatchSyncKeys.fxOk: false, WatchSyncKeys.fxHave: 0, WatchSyncKeys.fxDone: false])
            return
        }
        let eof = message[WatchSyncKeys.fxEof] as? Bool ?? false
        let finalURL = WatchPaths.documents.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: finalURL.path) {
            reply([WatchSyncKeys.fxOk: true, WatchSyncKeys.fxHave: byteSize(of: finalURL), WatchSyncKeys.fxDone: true])
            return
        }

        let partURL = WatchPaths.documents.appendingPathComponent(name + ".part")
        var partSize = byteSize(of: partURL)

        // A chunk for offset 0 restarts the file.
        if offset == 0, partSize > 0 {
            try? FileManager.default.removeItem(at: partURL)
            partSize = 0
        }

        guard offset == partSize else {
            // Out of order — tell the phone our real offset so it resends from there.
            reply([WatchSyncKeys.fxOk: false, WatchSyncKeys.fxHave: partSize, WatchSyncKeys.fxDone: false])
            return
        }

        if partSize == 0, !FileManager.default.fileExists(atPath: partURL.path) {
            FileManager.default.createFile(atPath: partURL.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: partURL) {
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                forwardLog("Error writing \(name) at \(offset): \(error.localizedDescription)")
            }
            try? handle.close()
        }
        let newSize = byteSize(of: partURL)

        if eof {
            try? FileManager.default.removeItem(at: finalURL)
            try? FileManager.default.moveItem(at: partURL, to: finalURL)
            forwardLog("Received \(name) via stream (\(newSize / 1024) KB).")
            store.objectWillChange.send()
            reply([WatchSyncKeys.fxOk: true, WatchSyncKeys.fxHave: byteSize(of: finalURL), WatchSyncKeys.fxDone: true])
        } else {
            // Nudge the List so the row's sync % advances live as bytes arrive.
            store.objectWillChange.send()
            reply([WatchSyncKeys.fxOk: true, WatchSyncKeys.fxHave: newSize, WatchSyncKeys.fxDone: false])
        }
    }
}

extension WatchConnectivityManager: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let context = session.receivedApplicationContext
        Task { @MainActor in
            if let error {
                self.forwardLog("Watch session activation error: \(error.localizedDescription)")
            } else {
                self.forwardLog("Watch session activated (state \(activationState.rawValue)).")
            }
            if !context.isEmpty { self.applyManifest(from: context) }
        }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.applyManifest(from: applicationContext) }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in self.handleStreamMessage(message, reply: replyHandler) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let idString = userInfo[WatchSyncKeys.positionID] as? String,
              let id = UUID(uuidString: idString),
              let pos = userInfo[WatchSyncKeys.positionValue] as? Double else { return }
        Task { @MainActor in self.store.applyRemotePosition(id, pos) }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // WCSessionFile's URL is reclaimed once this returns, so move it now.
        let fileName = (file.metadata?[WatchSyncKeys.metaFileName] as? String)
            ?? file.fileURL.lastPathComponent
        let destination = WatchPaths.documents.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: destination)
        var moveError: String?
        do {
            try FileManager.default.moveItem(at: file.fileURL, to: destination)
        } catch {
            do {
                try FileManager.default.copyItem(at: file.fileURL, to: destination)
            } catch {
                moveError = error.localizedDescription
            }
        }
        Task { @MainActor in
            if let moveError {
                self.forwardLog("Failed to save \(fileName): \(moveError)")
            } else {
                self.forwardLog("Received file \(fileName).")
            }
            self.store.objectWillChange.send()
        }
    }
}
