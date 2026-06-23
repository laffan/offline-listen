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

    init() {
        // Touch the disk mirror so the previous session's file is rolled aside
        // for crash forensics before this session writes its first line.
        _ = DiagnosticLogFile.shared
    }

    nonisolated func log(_ message: String, level: LogLevel = .info, category: String = "App") {
        let date = Date()
        let entry = LogEntry(date: date, level: level, category: category, message: message)
        #if DEBUG
        print("[\(category)] \(level.rawValue.uppercased()): \(message)")
        #endif
        // Mirror to disk *synchronously* (on the file's serial queue) before we
        // return. The in-memory append below is deferred onto the main actor, so
        // a hard native crash (e.g. a PythonKit fault) right after this call
        // would lose it — but the disk write has already completed, leaving a
        // durable trail whose last line names the step that died.
        DiagnosticLogFile.shared.append(date: date, level: level, category: category, message: message)
        Task { @MainActor in
            self.entries.append(entry)
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
        }
    }

    /// On-disk diagnostics for sharing: the current session's log and, if it
    /// exists, the previous session's (preserved across launches/crashes).
    nonisolated var persistedLogURLs: [URL] {
        let f = DiagnosticLogFile.shared
        return [f.currentURL, f.previousURL].filter { FileManager.default.fileExists(atPath: $0.path) }
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

/// Crash-durable, append-only mirror of the log to a file in Documents.
///
/// The in-memory `LogStore` is published onto the main actor, so a hard native
/// crash — the most likely cause of a log that simply stops mid-step, e.g. a
/// PythonKit fault during a forced-client `extract_info` — takes its buffered
/// tail down with it: the very lines that would say *where* it died are exactly
/// the ones lost. This writes each line out via a synchronous `write()` syscall
/// on a private serial queue, so it survives a process crash (the kernel keeps
/// the written bytes), and on launch it rolls the prior file aside as
/// `diagnostics-previous.log` so that trail is there to read next time.
final class DiagnosticLogFile: @unchecked Sendable {
    static let shared = DiagnosticLogFile()

    private let queue = DispatchQueue(label: "DiagnosticLogFile")
    private var handle: FileHandle?
    private var bytesWritten = 0
    /// Roll the file once it passes this size so it can't grow without bound.
    private let maxBytes = 2_000_000

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var currentURL: URL { AppPaths.documents.appendingPathComponent("diagnostics.log") }
    var previousURL: URL { AppPaths.documents.appendingPathComponent("diagnostics-previous.log") }

    private init() {
        queue.sync { rollAndOpen() }
    }

    /// Preserve the previous file as `*-previous.log` (a crash trail to read on
    /// the next run) and start a fresh current file. Always runs on `queue`.
    private func rollAndOpen() {
        let fm = FileManager.default
        try? handle?.close()
        try? fm.removeItem(at: previousURL)
        if fm.fileExists(atPath: currentURL.path) {
            try? fm.moveItem(at: currentURL, to: previousURL)
        }
        fm.createFile(atPath: currentURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: currentURL)
        bytesWritten = 0
    }

    func append(date: Date, level: LogLevel, category: String, message: String) {
        // Synchronous so the write completes before the caller proceeds to a
        // step that might crash — that's what makes the last line trustworthy.
        queue.sync {
            let line = "\(formatter.string(from: date)) [\(level.rawValue.uppercased())] \(category): \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if bytesWritten + data.count > maxBytes { rollAndOpen() }
            guard let handle else { return }
            handle.write(data)
            bytesWritten += data.count
        }
    }
}

/// Thrown by `withTimeout` when an operation overruns its deadline.
struct OperationTimeout: LocalizedError {
    let label: String
    let seconds: Int
    var errorDescription: String? { "\(label) timed out after \(seconds)s." }
}

/// Races `operation` against a hard deadline enforced by a GCD timer rather than
/// `Task.sleep`. A synchronous, pool-starving call — yt-dlp's Python
/// `extract_info`, which blocks its thread and can starve the cooperative pool —
/// would never let a `Task.sleep`-based timeout fire, so the timer runs on its
/// own dispatch queue. On timeout we stop *waiting* and throw, but deliberately
/// let the operation keep running: cancellation can't interrupt blocking Python
/// work anyway, and abandoning the wait is what lets the caller move on (e.g. try
/// the next forced player client) instead of hanging forever. Mirrors the
/// default extraction path's `resolveInfo` timeout for the forced-client path,
/// which previously had only a heartbeat and no cap.
func withTimeout<T>(_ label: String,
                    category: String,
                    seconds: TimeInterval,
                    operation: @escaping () async throws -> T) async throws -> T {
    let work = Task { try await operation() }
    let lock = NSLock()
    var finished = false
    // Returns true if *this* call settled the continuation, so the loser can
    // tell it raced in after the deadline already fired.
    func finish(_ body: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        body()
        return true
    }

    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler {
            _ = finish { continuation.resume(throwing: OperationTimeout(label: label, seconds: Int(seconds))) }
            timer.cancel()
        }
        timer.resume()

        Task {
            do {
                let value = try await work.value
                if !finish({ timer.cancel(); continuation.resume(returning: value) }) {
                    appLog("\(label): finished after the \(Int(seconds))s timeout had already fired — result discarded.",
                           level: .debug, category: category)
                }
            } catch {
                if !finish({ timer.cancel(); continuation.resume(throwing: error) }) {
                    appLog("\(label): failed after the \(Int(seconds))s timeout had already fired: \(error.localizedDescription)",
                           level: .debug, category: category)
                }
            }
        }
    }
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
