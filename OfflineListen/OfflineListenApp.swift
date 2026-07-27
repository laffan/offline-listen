import SwiftUI

@main
struct OfflineListenApp: App {
    @StateObject private var library: LibraryStore
    @StateObject private var downloads: DownloadManager
    @StateObject private var playback: PlaybackManager
    @StateObject private var aiSettings: AISettingsStore
    @StateObject private var aiOrganizer: AIOrganizer
    @StateObject private var spotifySettings: SpotifySettingsStore
    @StateObject private var browse: BrowseStore
    @StateObject private var localSync: LocalSyncStore

    @Environment(\.scenePhase) private var scenePhase

    init() {
        let library = LibraryStore()
        // Resolves the sync-folder bookmark and kicks the first sync pass
        // (export any journaled changes, then reconcile against the folder).
        _localSync = StateObject(wrappedValue: LocalSyncStore(library: library))
        let aiSettings = AISettingsStore()
        let aiOrganizer = AIOrganizer(library: library, settings: aiSettings)
        let spotifySettings = SpotifySettingsStore()
        _library = StateObject(wrappedValue: library)
        _aiSettings = StateObject(wrappedValue: aiSettings)
        _aiOrganizer = StateObject(wrappedValue: aiOrganizer)
        _spotifySettings = StateObject(wrappedValue: spotifySettings)
        _downloads = StateObject(wrappedValue: DownloadManager(library: library,
                                                              aiOrganizer: aiOrganizer,
                                                              spotifySettings: spotifySettings))
        _browse = StateObject(wrappedValue: BrowseStore(aiSettings: aiSettings))
        let playback = PlaybackManager(library: library)
        _playback = StateObject(wrappedValue: playback)

        // The watch's "Clear all Tracks" empties the phone's Watch folder to match.
        WatchSync.shared.onClearAll = { [weak library] in library?.clearAllFromWatch() }
        // Once the WC session is ready (and whenever the watch state changes),
        // re-push the current set so the watch reconciles.
        WatchSync.shared.onReady = { [weak library] in library?.syncWatch() }
        // A podcast playhead update from the watch keeps the phone in sync.
        WatchSync.shared.onPosition = { [weak library] id, pos in library?.applyWatchPosition(id, pos) }
        // The watch acting as a remote: mirror the phone's now-playing to it, and
        // run the transport commands it sends back.
        playback.onNowPlayingChange = { state in WatchSync.shared.sendNowPlaying(state) }
        WatchSync.shared.onRemoteCommand = { [weak playback] command in
            switch command {
            case RemoteCommand.togglePlayPause: playback?.togglePlayPause()
            case RemoteCommand.next: playback?.next()
            case RemoteCommand.previous: playback?.previous()
            case RemoteCommand.skipForward: playback?.skipForward()
            case RemoteCommand.skipBackward: playback?.skipBackward()
            default: break
            }
        }
        // Best-effort immediate push (no-ops until the session activates).
        library.syncWatch()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(downloads)
                .environmentObject(playback)
                .environmentObject(aiSettings)
                .environmentObject(aiOrganizer)
                .environmentObject(spotifySettings)
                .environmentObject(browse)
                .environmentObject(localSync)
                .environmentObject(LogStore.shared)
                .task { playback.restoreLastSession() }
                .onAppear { importShared() }
                .onOpenURL { _ in importShared() }
                .onChange(of: scenePhase) { phase in
                    if phase == .active {
                        importShared()
                        // Catch anything that changed in the sync folder while
                        // the app was in the background.
                        localSync.scheduleRescan()
                    } else {
                        playback.saveState()
                        // Snapshot the download history so completed rows (with
                        // any AI-cleaned titles) survive being backgrounded/killed.
                        downloads.persistHistory()
                    }
                }
        }
    }

    /// Drains any URLs handed over by the Share Extension and enqueues them.
    /// Routed through `enqueueLinks` rather than `enqueue` so a shared *list* —
    /// a YouTube playlist, a Spotify album — gets the selection popup and its
    /// own folder, exactly as pasting it into the Download field would.
    private func importShared() {
        for urlString in SharedInbox.takeAll() {
            appLog("Imported shared URL: \(urlString)", category: "Share")
            downloads.enqueueLinks(from: urlString, mode: .audio)
        }
    }
}
