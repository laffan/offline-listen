import Foundation

/// Shared hand-off point between the Share Extension and the main app, backed by
/// the App Group container. The extension appends a URL; the app drains them.
enum SharedInbox {
    /// Must match the App Group enabled on BOTH targets in Xcode
    /// (Signing & Capabilities → App Groups).
    static let appGroup = "group.com.offlinelisten.app"

    private static let key = "pendingURLs"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroup)
    }

    /// Called from the Share Extension to queue a URL for the app.
    static func add(_ urlString: String) {
        guard let defaults else { return }
        var list = defaults.stringArray(forKey: key) ?? []
        list.append(urlString)
        defaults.set(list, forKey: key)
    }

    /// Called from the app to read and clear all pending URLs.
    static func takeAll() -> [String] {
        guard let defaults else { return [] }
        let list = defaults.stringArray(forKey: key) ?? []
        if !list.isEmpty {
            defaults.removeObject(forKey: key)
        }
        return list
    }
}
