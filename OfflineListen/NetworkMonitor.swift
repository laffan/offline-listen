import Foundation
import Network

/// Whether the device can reach the network right now — for the few controls
/// that do nothing useful offline and should say so by not being offered (the
/// Player's **Find Similar**, which needs the model and YouTube both).
///
/// One `NWPathMonitor` for the app, started on first use. `isOnline` starts
/// out true: the first path update arrives within moments, and hiding a
/// control for that moment on a phone that *is* online would read as a flicker.
@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published private(set) var isOnline = true

    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.isOnline != online else { return }
                self.isOnline = online
            }
        }
        monitor.start(queue: DispatchQueue(label: "NetworkMonitor"))
    }
}
