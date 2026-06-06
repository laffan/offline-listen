import Foundation

enum LogLevel: String, Sendable {
    case debug
    case info
    case success
    case warning
    case error

    var symbol: String {
        switch self {
        case .debug: return "•"
        case .info: return "›"
        case .success: return "✓"
        case .warning: return "!"
        case .error: return "✕"
        }
    }
}

struct LogEntry: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let level: LogLevel
    let category: String
    let message: String
}

/// App-wide, thread-safe log sink. Components call `LogStore.shared.log(...)`
/// (or the `appLog` helper) from any thread; entries are published on the main
/// actor for the Log screen to observe.
@MainActor
final class LogStore: ObservableObject {
    static let shared = LogStore()

    @Published private(set) var entries: [LogEntry] = []

    private let maxEntries = 2000

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    nonisolated func log(_ message: String, level: LogLevel = .info, category: String = "App") {
        let entry = LogEntry(date: Date(), level: level, category: category, message: message)
        #if DEBUG
        print("[\(category)] \(level.rawValue.uppercased()): \(message)")
        #endif
        Task { @MainActor in
            self.entries.append(entry)
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
        }
    }

    func clear() {
        entries.removeAll()
    }

    func time(for entry: LogEntry) -> String {
        Self.timeFormatter.string(from: entry.date)
    }

    /// Plain-text rendering of the whole log, suitable for the clipboard.
    var plainText: String {
        entries.map { entry in
            "\(Self.timeFormatter.string(from: entry.date)) [\(entry.level.rawValue.uppercased())] \(entry.category): \(entry.message)"
        }
        .joined(separator: "\n")
    }
}

/// Convenience free function so non-UI code can log without importing SwiftUI.
func appLog(_ message: String, level: LogLevel = .info, category: String = "App") {
    LogStore.shared.log(message, level: level, category: category)
}
