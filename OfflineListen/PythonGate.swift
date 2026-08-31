import Foundation

/// App-wide serialization of the embedded Python interpreter.
///
/// The download pipeline runs up to two jobs at once, but the interpreter can
/// only ever execute **one** thing at a time — two concurrent yt-dlp
/// `extract_info` calls (or a plugin import overlapping an extraction, or even
/// traversing a `PythonObject` while another thread runs Python) risk a hard
/// crash. Every Python touchpoint therefore funnels through this gate: the
/// default extraction, the forced-client recovery, mid-download URL
/// refreshers, chapter capture, playlist resolution, and the JS-runtime plugin
/// wiring. Native (YouTubeKit) extractions and the chunked HTTP downloads
/// never touch Python, so they run fully in parallel.
///
/// The gate is FIFO and **cancellation-aware**: a task cancelled while waiting
/// throws `CancellationError` and never holds the gate. Crucially, `run(_:)`
/// executes its body in a detached task that *owns the release* — so when a
/// timeout wrapper abandons a Python call that's still executing (the "zombie
/// extraction" this codebase already knows about), the gate stays held until
/// the interpreter actually returns, and the next Python call waits instead of
/// crashing into it. That's a strictly stronger guarantee than the previous
/// wait-5s-then-proceed-anyway heuristic.
/// A failure from a Python section, flattened to plain text **before the gate
/// that produced it was released**.
///
/// This exists because `PythonError` is a `PythonObject` in a trench coat: it
/// holds the live exception, and asking it for its description — which every
/// catch site here does, to get the real yt-dlp message out of the opaque
/// "PythonError error 0" — calls back into the interpreter. Off the gate, with
/// the other pipeline slot mid-`extract_info`, that is a concurrent access and
/// the process dies inside `_Py_MakeRecCheck`. Even *releasing* the error is an
/// interpreter operation, so it can't simply be carried out and dropped.
///
/// So the text is taken while the gate is still held and only the text travels.
/// `description` returns the detailed form, which is what the diagnostic logs
/// print via `String(describing:)`, so nothing downstream reads differently
/// than it did when a raw `PythonError` reached it.
struct InterpreterError: LocalizedError, CustomStringConvertible {
    let summary: String
    let detail: String
    var errorDescription: String? { summary }
    var description: String { detail }

    /// Flattens `error`, except for the Swift-native signals the pipeline
    /// classifies **by type** rather than by text — cancellation above all,
    /// which every retry and fallback layer tests for and must keep seeing.
    static func flattening(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if error is URLError { return error }
        return InterpreterError(summary: error.localizedDescription,
                                detail: String(describing: error))
    }
}

final class PythonGate: @unchecked Sendable {
    static let shared = PythonGate()

    private let lock = NSLock()
    private var held = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    /// Waiter ids whose cancellation raced ahead of their registration.
    /// (A cancel arriving *after* the gate was granted leaves a stale id here —
    /// harmless, a UUID at most per raced cancel.)
    private var cancelledIDs: Set<UUID> = []

    /// Acquires the gate, waiting (FIFO) while another Python call holds it.
    /// Throws `CancellationError` if the waiting task is cancelled first —
    /// without ever having held the gate, so don't `release()` on that path.
    func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelledIDs.remove(id) != nil {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if held {
                    waiters.append((id, continuation))
                    lock.unlock()
                } else {
                    held = true
                    lock.unlock()
                    continuation.resume()
                }
            }
        } onCancel: {
            lock.lock()
            if let index = waiters.firstIndex(where: { $0.id == id }) {
                let waiter = waiters.remove(at: index)
                lock.unlock()
                waiter.continuation.resume(throwing: CancellationError())
            } else {
                // Raced ahead of registration — flag it so the operation
                // block throws instead of queueing a permanent waiter.
                cancelledIDs.insert(id)
                lock.unlock()
            }
        }
    }

    /// Releases the gate, handing it to the next waiter in FIFO order.
    func release() {
        lock.lock()
        if waiters.isEmpty {
            held = false
            lock.unlock()
        } else {
            let next = waiters.removeFirst()
            lock.unlock()
            next.continuation.resume()
        }
    }

    /// Runs one synchronous Python section under the gate. The body executes
    /// on a detached task that releases the gate in a `defer` — so even if the
    /// *caller* is abandoned by a timeout wrapper mid-await, the gate is held
    /// until the Python work truly finishes, never released out from under a
    /// still-running interpreter call.
    /// A thrown error is flattened to `InterpreterError` *here*, inside the
    /// gated closure, so no `PythonObject` — and no Python refcount — outlives
    /// the gate. See `InterpreterError`.
    func run<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await acquire()
        let task = Task.detached(priority: .userInitiated) { [self] () throws -> T in
            defer { release() }
            do {
                return try body()
            } catch {
                throw InterpreterError.flattening(error)
            }
        }
        return try await task.value
    }
}
