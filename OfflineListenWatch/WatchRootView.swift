import SwiftUI

/// The three watch panes — List, Listen, Settings — as swipeable pages. Tapping
/// a track in the List jumps to the Listen pane.
struct WatchRootView: View {
    enum Pane: Hashable { case list, listen, settings }

    @State private var pane: Pane = .list

    var body: some View {
        TabView(selection: $pane) {
            WatchListView(onPlay: { pane = .listen })
                .tag(Pane.list)

            WatchListenView()
                .tag(Pane.listen)

            WatchSettingsView()
                .tag(Pane.settings)
        }
        // watchOS `TabView` is paged (swipeable) by default — exactly the
        // three-pane layout we want; no explicit style needed.
    }
}
