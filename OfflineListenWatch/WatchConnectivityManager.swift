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
