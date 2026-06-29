import Foundation
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

/// Phone-side WatchConnectivity bridge. The phone owns the truth about what
/// belongs on the watch; this pushes the desired state (a `WatchManifest`) and
/// the audio files, and listens for the watch's "Clear all" command.
///
/// Guarded so it degrades gracefully when there is no paired watch or the
/// framework isn't available (Simulator without a paired watch, etc.): every
/// entry point checks `isOperational` first and otherwise no-ops.
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

    /// File names we've already handed to `transferFile`, so re-pushing the
    /// manifest (which happens on many library edits) doesn't resend megabytes.
    private var transferredFileNames: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.transferredKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.transferredKey) }
    }
    private static let transferredKey = "watchTransferredFileNames"

    private override init() {
        super.init()
        activate()
    }

    private func activate() {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        #endif
    }

    /// True when a session is active and a watch app is installed to receive data.
    private var isOperational: Bool {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return false }
        let session = WCSession.default
        return session.activationState == .activated && session.isWatchAppInstalled
        #else
        return false
        #endif
    }

    /// Pushes the desired watch set: updates the manifest and transfers any audio
    /// file not yet sent. `tracks` is `LibraryStore.watchTracks`; `folderNames`
    /// maps folder ids to display names so each track can carry its playlist name.
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

        // Prune the "already transferred" bookkeeping down to the current set so
        // a file removed and later re-added gets sent again.
        let wantedNames = Set(tracks.map { $0.fileName })
        transferredFileNames = transferredFileNames.intersection(wantedNames)

        guard isOperational else { return }
        let session = WCSession.default

        if let data = try? JSONEncoder().encode(WatchManifest(tracks: manifestTracks)) {
            try? session.updateApplicationContext([WatchSyncKeys.manifest: data])
        }

        var sent = transferredFileNames
        for track in tracks where !sent.contains(track.fileName) {
            let url = track.fileURL
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            // Metadata must be a valid property list, so only include the folder
            // name when there is one (a boxed nil isn't plist-serializable).
            var metadata: [String: Any] = [
                WatchSyncKeys.metaID: track.id.uuidString,
                WatchSyncKeys.metaTitle: track.title,
                WatchSyncKeys.metaArtist: track.artist,
                WatchSyncKeys.metaFileName: track.fileName,
                WatchSyncKeys.metaDuration: track.duration,
                WatchSyncKeys.metaKind: track.kind.rawValue,
                WatchSyncKeys.metaOrder: 0
            ]
            if let folderID = track.folderID, let name = folderNames[folderID] {
                metadata[WatchSyncKeys.metaFolderName] = name
            }
            session.transferFile(url, metadata: metadata)
            sent.insert(track.fileName)
        }
        transferredFileNames = sent
        #endif
    }
}

#if canImport(WatchConnectivity)
extension WatchSync: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
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
        // The watch app was (un)installed or a different watch was paired —
        // re-push so the new watch reconciles to the current set.
        Task { @MainActor in self.onReady?() }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handle(command: message[WatchSyncKeys.command] as? String)
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        handle(command: userInfo[WatchSyncKeys.command] as? String)
    }

    private nonisolated func handle(command: String?) {
        guard command == WatchSyncKeys.clearAllCommand else { return }
        Task { @MainActor in self.onClearAll?() }
    }
}
#endif
