import SwiftUI

/// The tabs, in the order they sit in the tab bar.
enum Tab: Hashable {
    case browse
    case library
    case player
    case download
    case settings
}

struct RootView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackManager
    @EnvironmentObject private var router: AppRouter
    @State private var selection: Tab = .library

    /// Downloads still working or waiting — the number shown on the Download
    /// tab's badge (finished/failed/cancelled history doesn't count).
    private var pendingDownloads: Int {
        downloads.jobs.filter { $0.state.isActive || $0.state == .queued }.count
    }

    var body: some View {
        // Every tab but the Player carries the mini player above the tab bar,
        // so a track stays controllable wherever you are. It's attached per tab
        // (outside each screen's own NavigationStack) rather than to the
        // TabView, which is what lets a screen's own bottom bar — the Every
        // Noise scan/artist bars — stack neatly above it.
        // Left to right: the two screens you browse with, the player they feed,
        // then the queue and the settings behind them.
        TabView(selection: $selection) {
            BrowseView()
                .miniPlayerBar { selection = .player }
                .tabItem { Label("Browse", systemImage: "safari") }
                .tag(Tab.browse)

            LibraryView(onPlay: { selection = .player })
                .miniPlayerBar { selection = .player }
                .tabItem { Label("Library", systemImage: "music.note.list") }
                .tag(Tab.library)

            PlayerView()
                .tabItem { Label("Player", systemImage: "play.circle") }
                .tag(Tab.player)

            DownloadView(onPlay: { selection = .player })
                .miniPlayerBar { selection = .player }
                .tabItem { Label("Download", systemImage: "arrow.down.circle") }
                .badge(pendingDownloads == 0 ? nil : Text("\(pendingDownloads)"))
                .tag(Tab.download)

            SettingsView()
                .miniPlayerBar { selection = .player }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        // A widget tap can land before this view exists (a cold launch from the
        // home screen), in which case the link is already parked and no change
        // fires — so both routes are checked on appear as well.
        .onAppear { routeGenre(); routeTrack() }
        .onChange(of: router.pendingGenreKey) { _ in routeGenre() }
        .onChange(of: router.pendingTrackID) { _ in routeTrack() }
    }

    /// The tab is all this level does for a genre — finding it in the index and
    /// pushing it belongs to the browser, which owns the navigation stack and
    /// knows when the index has finished loading.
    private func routeGenre() {
        guard router.pendingGenreKey != nil else { return }
        selection = .browse
    }

    /// Starts a track tapped in the widget, with the Recent list as its queue —
    /// the same queue tapping that row inside the app would have given it.
    private func routeTrack() {
        guard let id = router.pendingTrackID else { return }
        router.pendingTrackID = nil
        guard let track = library.track(withID: id) else {
            appLog("Widget asked for a track that's no longer in the library.",
                   level: .warning, category: "Widget")
            return
        }
        playback.play(track, in: library.recentTracks)
        selection = .player
    }
}
