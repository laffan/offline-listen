import Foundation
import Security

/// The Anthropic models the user can pick between for AI-assisted organization.
/// Haiku is cheaper/faster; Sonnet is more capable. Both are plenty for the
/// small classification/metadata task we ask of them.
enum AIModel: String, CaseIterable, Identifiable, Codable {
    case haiku
    case sonnet

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .haiku: return "Haiku"
        case .sonnet: return "Sonnet"
        }
    }

    /// The exact API model identifier passed to the Messages API.
    var apiModelID: String {
        switch self {
        case .haiku: return "claude-haiku-4-5"
        case .sonnet: return "claude-sonnet-4-6"
        }
    }

    var subtitle: String {
        switch self {
        case .haiku: return "Fast and economical"
        case .sonnet: return "More capable, costs a little more"
        }
    }
}

/// Persists the user's AI configuration: which model to use, the API key (stored
/// in the Keychain so it survives between sessions and isn't in plain UserDefaults),
/// and whether the opt-in "AI assist with organization" features are on.
///
/// `isAuthenticated` simply tracks whether a key has been saved — and a key is
/// only ever saved after a successful verification call (see `SettingsView`), so
/// a stored key means a working key the last time it was checked.
@MainActor
final class AISettingsStore: ObservableObject {
    @Published var model: AIModel {
        didSet {
            guard model != oldValue else { return }
            UserDefaults.standard.set(model.rawValue, forKey: Self.modelKey)
        }
    }

    /// The opt-in toggle that turns on automatic AI organization of downloads.
    @Published var assistEnabled: Bool {
        didSet {
            guard assistEnabled != oldValue else { return }
            UserDefaults.standard.set(assistEnabled, forKey: Self.assistKey)
        }
    }

    /// The saved API key (empty when none). Read-only to callers; mutate via
    /// `saveAPIKey`/`clearAPIKey` so the Keychain stays in sync.
    @Published private(set) var apiKey: String

    private static let modelKey = "aiModel"
    private static let assistKey = "aiAssistEnabled"
    private static let keychainAccount = "anthropic-api-key"

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.modelKey),
           let stored = AIModel(rawValue: raw) {
            model = stored
        } else {
            model = .haiku
        }
        assistEnabled = UserDefaults.standard.bool(forKey: Self.assistKey)
        apiKey = Keychain.read(account: Self.keychainAccount) ?? ""
    }

    /// True once a (verified) key is on file. Gates the assist toggle and the
    /// "AI Organize" menu item.
    var isAuthenticated: Bool { !apiKey.isEmpty }

    /// Persists a verified key to the Keychain.
    func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.save(account: Self.keychainAccount, value: trimmed)
        apiKey = trimmed
    }

    /// Forgets the key and turns the assist features back off (they require a key).
    func clearAPIKey() {
        Keychain.delete(account: Self.keychainAccount)
        apiKey = ""
        assistEnabled = false
    }
}

/// Minimal Keychain wrapper for a single string secret per account. Used for the
/// Anthropic API key so it isn't sitting in UserDefaults/plist in the clear.
enum Keychain {
    private static let service = "com.offlinelisten.app.ai"

    static func save(account: String, value: String) {
        delete(account: account)
        guard let data = value.data(using: .utf8), !value.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
