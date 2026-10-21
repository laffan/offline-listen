import SwiftUI

/// The tabs, in the order they sit in the tab bar.
enum Tab: Hashable {
    /// Browse, Download, Sources and Bookmarks — finding things to listen to.
    case search
    case library
    case recent
    case player
    case settings
}

struct RootView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackManager
    @EnvironmentObject private var router: AppRouter
    /// The "which resolution?" question a video download raises once it knows
    /// what the source offers. Presented here rather than in the Download tab
    /// because the download that asks may well have been started from Browse —
    /// and a question nobody can see is a download that waits for nothing.
    @EnvironmentObject private var videoQuality: VideoQualityChooser
    @State private var selection: Tab = .library
    /// Set while the Player's swipe-down is switching tabs, so arriving back in
    /// the Library or Recent reads as going back rather than as a visit (see
    /// `AppRouter.libraryVisits`).
    @State private var returning = false

    /// Downloads still working or waiting — the number shown on the Search
    /// tab's badge (finished/failed/cancelled history doesn't count). The queue
    /// lives one of that tab's buttons in, so the badge is how it's seen from
    /// everywhere else.
    private var pendingDownloads: Int {
        downloads.jobs.filter { $0.state.isActive || $0.state == .queued }.count
    }

    var body: some View {
        // Every tab but the Player carries the mini player above the tab bar,
        // so a track stays controllable wherever you are. It's attached per tab
        // (outside each screen's own NavigationStack) rather than to the
        // TabView, which is what lets a screen's own bottom bar — the Every
        // Noise scan/artist bars — stack neatly above it.
        // Left to right: where you find things, the library they land in, what
        // you've been playing out of it, the player they all feed, then the
        // settings behind them.
        TabView(selection: $selection) {
            SearchView(onPlay: { selection = .player })
                .miniPlayerBar { selection = .player }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .badge(pendingDownloads == 0 ? nil : Text("\(pendingDownloads)"))
                .tag(Tab.search)

            LibraryView(onPlay: { selection = .player })
                .miniPlayerBar { selection = .player }
                .tabItem { Label("Library", systemImage: "music.note.list") }
                .tag(Tab.library)

            RecentView(onPlay: { selection = .player })
                .miniPlayerBar { selection = .player }
                .tabItem { Label("Recent", systemImage: "clock.arrow.circlepath") }
                .tag(Tab.recent)

            // Swiping the player down puts it away — back to wherever the
            // playing track was started from.
            PlayerView(onSwipeDown: returnToPlayContext)
                .tabItem { Label("Player", systemImage: "play.circle") }
                .tag(Tab.player)

            SettingsView()
                .miniPlayerBar { selection = .player }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        // A widget tap can land before this view exists (a cold launch from the
        // home screen), in which case the link is already parked and no change
        // fires — so both routes are checked on appear as well.
        .sheet(item: $videoQuality.pending) { pending in
            VideoQualityPickerView(pending: pending)
        }
        .onAppear {
            notePlayStarts()
            routeBrowse()
            routeTrack()
        }
        .onChange(of: selection) { tab in
            if !returning { router.noteVisit(to: tab) }
            returning = false
        }
        .onChange(of: router.pendingBrowse) { _ in routeBrowse() }
        .onChange(of: router.pendingTrackID) { _ in routeTrack() }
    }

    /// Has every track that starts note the tab it was started on. `play` is
    /// called from the screen being looked at, before that screen's `onPlay`
    /// switches to the Player — so at that moment the selected tab *is* where
    /// the track came from, whichever shared screen (a discography, the
    /// preview modal) did the starting.
    private func notePlayStarts() {
        let router = self.router
        let tab = $selection
        playback.onStart = { router.notePlayStarted(on: tab.wrappedValue) }
    }

    /// The Player's swipe-down: back to the screen the playing track was
    /// started from — the album, the Recent tab's Pinned, Recent or Ignored
    /// list, the Random hand it was dealt from — rather than to the Library
    /// regardless.
    private func returnToPlayContext() {
        returning = true
        switch router.playContext {
        case .search(let section)?:
            router.pendingSearchSection = section
            selection = .search
        case .library(let place)?:
            router.pendingLibraryPlace = place
            selection = .library
        case .recent(let tab)?:
            router.pendingRecentTab = tab
            selection = .recent
        case nil:
            // Nothing started this session — the track restored at launch.
            // The Library is where it most likely came from.
            selection = .library
        }
    }

    /// The tab is all this level does for a browse row — resolving it against
    /// the genre index and pushing it belongs to the browser, which owns the
    /// navigation stack and knows when that index has finished loading.
    private func routeBrowse() {
        guard router.pendingBrowse != nil else { return }
        selection = .search
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
        router.notePlayStarted(in: .recent(.recent))
        selection = .player
    }
}
