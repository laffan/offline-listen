import Foundation
import WatchConnectivity

/// Watch-side WatchConnectivity bridge. Receives the manifest (the phone's
/// desired state) and the audio files, hands them to `WatchLibraryStore`, and
/// sends the "Clear all" command back to the phone when the user clears the watch.
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
        sendClearAllCommand()
    }

    private func sendClearAllCommand() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        let payload = [WatchSyncKeys.command: WatchSyncKeys.clearAllCommand]
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { _ in
                // If the live message fails, fall back to a guaranteed-delivery queue.
                session.transferUserInfo(payload)
            }
        } else {
            session.transferUserInfo(payload)
        }
    }

    /// Decodes and applies a manifest payload from the phone.
    fileprivate func applyManifest(from context: [String: Any]) {
        guard let data = context[WatchSyncKeys.manifest] as? Data,
              let manifest = try? JSONDecoder().decode(WatchManifest.self, from: data) else { return }
        store.apply(manifest)
    }
}

extension WatchConnectivityManager: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        // Apply whatever context was last delivered (it may have arrived before launch).
        let context = session.receivedApplicationContext
        guard !context.isEmpty else { return }
        Task { @MainActor in self.applyManifest(from: context) }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.applyManifest(from: applicationContext) }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // Resolve the destination name from the file's metadata, then move it in.
        // WCSessionFile's URL is in a temp location that's reclaimed once this
        // returns, so the move must happen synchronously here.
        let fileName = (file.metadata?[WatchSyncKeys.metaFileName] as? String)
            ?? file.fileURL.lastPathComponent
        let destination = WatchPaths.documents.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: destination)
        let moved = (try? FileManager.default.moveItem(at: file.fileURL, to: destination)) != nil
        if !moved {
            try? FileManager.default.copyItem(at: file.fileURL, to: destination)
        }
        Task { @MainActor in self.store.objectWillChange.send() }
    }
}
