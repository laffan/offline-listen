import SwiftUI
#if os(macOS)
import AppKit
#endif

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
    /// App-level so both the Every Noise browser (which feeds it) and Settings
    /// (which exports it) see the same store — a browser-local one would be
    /// invisible to Settings.
    @StateObject private var everyNoiseUpdates: ENUpdateStore
    /// Also app-level: the browser fills it, its own button shows it, and an
    /// artist's (pushed) discography page saves into it — a store injected
    /// inside the browser would be invisible to the last of those.
    @StateObject private var savedForLater = SavedForLaterStore()
    /// Where a tapped home-screen widget row is parked until the screen that
    /// can act on it is up.
    @StateObject private var router = AppRouter()

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
        _everyNoiseUpdates = StateObject(wrappedValue: ENUpdateStore())
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
        // Routed through the `remote…` transport, not the library player's own,
        // so the watch drives whatever is actually making sound — a Browse
        // preview included.
        WatchSync.shared.onRemoteCommand = { [weak playback] command in
            switch command {
            case RemoteCommand.togglePlayPause: playback?.remoteTogglePlayPause()
            case RemoteCommand.next: playback?.remoteNext()
            case RemoteCommand.previous: playback?.remotePrevious()
            case RemoteCommand.skipForward: playback?.remoteSkipForward()
            case RemoteCommand.skipBackward: playback?.remoteSkipBackward()
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
                .environmentObject(everyNoiseUpdates)
                .environmentObject(savedForLater)
                .environmentObject(router)
                // Shared rather than owned here: the extractors reach it as a
                // singleton (they have no view context), and this is what puts
                // its question on screen.
                .environmentObject(VideoQualityChooser.shared)
                .environmentObject(LogStore.shared)
                #if os(macOS)
                // Dark, whatever the system is set to. `preferredColorScheme`
                // covers the app's own views; the `NSApp` appearance is what
                // takes the AppKit chrome with it — title bar, scrollers, the
                // open panel — which would otherwise stay light around a dark
                // window.
                .preferredColorScheme(.dark)
                .onAppear {
                    NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
                }
                #endif
                .task { playback.restoreLastSession() }
                // The copy of the harvest's records in its chosen folder,
                // brought up to date at launch (it may have been collecting on
                // another device, or the folder may have been offline last
                // time). Skipped outright when no folder is configured.
                .task { everyNoiseUpdates.writeToDataFolder() }
                // The widget's browse rows come from a log the browser only
                // reads when the Browse tab is opened, so they're refreshed
                // from disk at launch instead of waiting on a visit.
                .task { WidgetBridge.publishBrowseFromHistory() }
                #if os(macOS)
                // Whether the Mac has a yt-dlp binary behind the native
                // extractors is the single biggest thing separating one install
                // from another, so the log says which it is at launch.
                .task { await MacYtDlp.logStartupState() }
                #endif
                .onAppear { importShared() }
                // A widget row's link is handled by the router; anything else
                // on the scheme is the Share Extension bringing us forward with
                // a URL waiting in the App Group. (Foregrounding drains the
                // inbox too, so a widget tap loses nothing by not doing it.)
                .onOpenURL { url in
                    if !router.handle(url) { importShared() }
                }
                .onChange(of: scenePhase) { phase in
                    if phase == .active {
                        importShared()
                        // Catch anything that changed in the sync folder while
                        // the app was in the background.
                        localSync.scheduleRescan()
                        // And catch a data folder that was unreachable last
                        // time we tried to leave the harvest's records in it.
                        // The write is skipped when the copy is already
                        // current, so this costs nothing in the ordinary case.
                        everyNoiseUpdates.writeToDataFolder()
                    } else {
                        playback.saveState()
                        // Snapshot the download history so completed rows (with
                        // any AI-cleaned titles) survive being backgrounded/killed.
                        downloads.persistHistory()
                    }
                }
        }
        #if os(macOS)
        // The five-tab layout wants roughly an iPad's worth of room; without a
        // default the Mac opens it at SwiftUI's small standard size, where the
        // noise map and the library grid both arrive cramped.
        .defaultSize(width: 1180, height: 800)
        #endif
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
