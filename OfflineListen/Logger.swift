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

/// Runs `operation` while a detached watchdog logs a heartbeat line every
/// `interval` seconds. Wrap any opaque, potentially slow step (info
/// resolution, a single chunk request, an AVFoundation export) so that when it
/// stalls, the Log screen shows *which* step is stuck and for how long instead
/// of going silent. Heartbeats only appear if the step outlives `interval`,
/// so fast steps add no noise.
///
/// The watchdog runs detached so it keeps ticking even if `operation` starves
/// the cooperative pool. `progress` (0…1), when provided, is sampled into each
/// heartbeat line.
func withHeartbeat<T>(_ label: String,
                      category: String,
                      interval: TimeInterval = 10,
                      level: LogLevel = .info,
                      progress: (@Sendable () -> Double?)? = nil,
                      operation: () async throws -> T) async rethrows -> T {
    let started = Date()
    let heartbeat = Task.detached {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            if Task.isCancelled { return }
            let elapsed = Int(Date().timeIntervalSince(started))
            if let fraction = progress?() {
                appLog("\(label)… \(Int(fraction * 100))% · \(elapsed)s elapsed", level: level, category: category)
            } else {
                appLog("\(label)… \(elapsed)s elapsed", level: level, category: category)
            }
        }
    }
    defer { heartbeat.cancel() }
    return try await operation()
}
