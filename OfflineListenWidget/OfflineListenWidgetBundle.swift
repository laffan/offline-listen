import SwiftUI
import WidgetKit

/// The widget extension's entry point. One widget for now — the "pick up where
/// you left off" pair of lists — with the bundle in place so adding a second is
/// a line rather than a target.
@main
struct OfflineListenWidgetBundle: WidgetBundle {
    var body: some Widget {
        RecentsWidget()
    }
}
