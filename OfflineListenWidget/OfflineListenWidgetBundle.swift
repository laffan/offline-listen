import SwiftUI
import WidgetKit

/// The widget extension's entry point: the "pick up where you left off" pair
/// of lists, and the lock screen player's Live Activity — which lives here
/// because a Live Activity's views are always drawn by the app's widget
/// extension.
@main
struct OfflineListenWidgetBundle: WidgetBundle {
    var body: some Widget {
        RecentsWidget()
        LockScreenPlayerActivity()
    }
}
