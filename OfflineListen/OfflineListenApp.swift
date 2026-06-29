import SwiftUI

@main
struct OfflineListenApp: App {
    @StateObject private var library: LibraryStore
    @StateObject private var downloads: DownloadManager
    @StateObject private var playback: PlaybackManager
    @StateObject private var aiSettings: AISettingsStore
    @StateObject private var aiOrganizer: AIOrganizer

    @Environment(\.scenePhase) private var scenePhase

    init() {
        let library = LibraryStore()
        let aiSettings = AISettingsStore()
        let aiOrganizer = AIOrganizer(library: library, settings: aiSettings)
        _library = StateObject(wrappedValue: library)
        _aiSettings = StateObject(wrappedValue: aiSettings)
        _aiOrganizer = StateObject(wrappedValue: aiOrganizer)
        _downloads = StateObject(wrappedValue: DownloadManager(library: library, aiOrganizer: aiOrganizer))
        _playback = StateObject(wrappedValue: PlaybackManager(library: library))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(downloads)
                .environmentObject(playback)
                .environmentObject(aiSettings)
                .environmentObject(aiOrganizer)
                .environmentObject(LogStore.shared)
                .task { playback.restoreLastSession() }
                .onAppear { importShared() }
                .onOpenURL { _ in importShared() }
                .onChange(of: scenePhase) { phase in
                    if phase == .active {
                        importShared()
                    } else {
                        playback.saveState()
                    }
                }
        }
    }

    /// Drains any URLs handed over by the Share Extension and enqueues them.
    private func importShared() {
        for urlString in SharedInbox.takeAll() {
            appLog("Imported shared URL: \(urlString)", category: "Share")
            downloads.enqueue(urlString: urlString, mode: .audio)
        }
    }
}
