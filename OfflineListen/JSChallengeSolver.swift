import Foundation

#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

/// Runs YouTube's player JavaScript on device to solve the `n` (throttling) and
/// `sig` (signature) challenges, using Apple's built-in **JavaScriptCore**.
///
/// ## Why this exists
///
/// YouTube's stream URLs carry an `n` parameter that must be transformed by a
/// function buried in the player's `base.js`, and (for some renditions) a
/// signature that must be descrambled the same way. yt-dlp abandoned its
/// pure-Python JS interpreter for these — they now require running the real
/// player JS — and ships that logic as the **yt-dlp-ejs** script bundle, run
/// through an external JavaScript runtime (Deno by default). On device there is
/// no Deno, but iOS ships JavaScriptCore, which runs the same scripts: they were
/// verified to load and execute `jsc(...)` in an engine exposing only
/// `globalThis` / `JSON` / `console`, which is exactly JSC's surface.
///
/// ## Contract
///
/// The caller (the Python `yt_dlp_plugins` JS-challenge provider, via the
/// PythonKit bridge) hands us the two ejs scripts and a JSON request payload in
/// the shape ejs expects:
///
///     { "type": "player", "player": "<base.js source>",
///       "requests": [ { "type": "n"|"sig", "challenges": ["..."] } ],
///       "output_preprocessed": true }
///
/// We evaluate `lib` → copy its exports onto `globalThis` → evaluate `core` →
/// call `jsc(payload)`, exactly as ejs's own runners do, and return
/// `JSON.stringify` of the result:
///
///     { "type": "result",
///       "responses": [ { "type": "result", "data": { "<challenge>": "<solved>" } } ],
///       "preprocessed_player": "..." }
///
/// or `{ "type": "error", "error": "..." }`. Parsing/dispatch stays in the
/// Python provider so this file is a thin, single-purpose JS host.
enum JSChallengeSolver {
    /// JavaScriptCore lacks the browser globals arbitrary player-JS snippets may
    /// touch. ejs is written for barebones runtimes so the surface is small, but
    /// we install a defensive prelude anyway: a no-op `console`, base64
    /// `atob`/`btoa`, minimal `TextEncoder`/`TextDecoder`, immediate `setTimeout`
    /// (the solve is synchronous, so deferring would just drop work), and
    /// `self`/`window`/`global` aliases for `globalThis`. Anything the ejs core
    /// itself needs (e.g. a stubbed `XMLHttpRequest`) it injects into the player
    /// scope on its own, so we don't duplicate that here.
    private static let polyfillPrelude = """
    (function () {
      var g = globalThis;
      if (typeof g.self === 'undefined') g.self = g;
      if (typeof g.window === 'undefined') g.window = g;
      if (typeof g.global === 'undefined') g.global = g;
      if (typeof g.console === 'undefined') {
        var noop = function () {};
        g.console = { log: noop, debug: noop, info: noop, warn: noop, error: noop, trace: noop };
      }
      if (typeof g.setTimeout === 'undefined') {
        g.setTimeout = function (fn) { if (typeof fn === 'function') { try { fn(); } catch (e) {} } return 0; };
        g.clearTimeout = function () {};
        g.setInterval = function () { return 0; };
        g.clearInterval = function () {};
      }
      if (typeof g.queueMicrotask === 'undefined') {
        g.queueMicrotask = function (fn) { if (typeof fn === 'function') { try { fn(); } catch (e) {} } };
      }
      if (typeof g.atob === 'undefined') {
        var B = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
        g.atob = function (input) {
          var str = String(input).replace(/=+$/, ''); var output = '';
          for (var bc = 0, bs = 0, buffer, i = 0; (buffer = str.charAt(i++));) {
            buffer = B.indexOf(buffer);
            if (~buffer) { bs = bc % 4 ? bs * 64 + buffer : buffer; if (bc++ % 4) output += String.fromCharCode(255 & (bs >> ((-2 * bc) & 6))); }
          }
          return output;
        };
        g.btoa = function (input) {
          var str = String(input); var output = '';
          for (var block = 0, charCode, i = 0, map = B;
               str.charAt(i | 0) || ((map = '='), i % 1);
               output += map.charAt(63 & (block >> (8 - (i % 1) * 8)))) {
            charCode = str.charCodeAt((i += 3 / 4));
            if (charCode > 0xff) throw new Error('btoa: invalid character');
            block = (block << 8) | charCode;
          }
          return output;
        };
      }
      if (typeof g.TextEncoder === 'undefined') {
        g.TextEncoder = function () {};
        g.TextEncoder.prototype.encode = function (s) {
          s = String(s); var utf8 = unescape(encodeURIComponent(s));
          var arr = new Uint8Array(utf8.length);
          for (var i = 0; i < utf8.length; i++) arr[i] = utf8.charCodeAt(i);
          return arr;
        };
      }
      if (typeof g.TextDecoder === 'undefined') {
        g.TextDecoder = function () {};
        g.TextDecoder.prototype.decode = function (buf) {
          var bytes = buf instanceof Uint8Array ? buf : new Uint8Array(buf); var s = '';
          for (var i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
          return decodeURIComponent(escape(s));
        };
      }
    })();
    """

    enum SolverError: LocalizedError {
        case unavailable
        case scriptsMissing
        case evaluationThrew(String)
        case timedOut(Int)
        case noResult

        var errorDescription: String? {
            switch self {
            case .unavailable: return "JavaScriptCore is not available."
            case .scriptsMissing: return "The bundled yt-dlp-ejs solver scripts are missing."
            case .evaluationThrew(let m): return "JS challenge evaluation failed: \(m)"
            case .timedOut(let s): return "JS challenge evaluation timed out after \(s)s."
            case .noResult: return "JS challenge evaluation returned no value."
            }
        }
    }

    /// The vendored `yt-dlp-ejs` `lib` + `core` scripts, read from the app bundle
    /// once and cached. These are the pinned challenge-solver scripts (their
    /// version is recorded in `ytdlp/scripts/VERSION`); refreshing them travels
    /// with the "Refresh yt-dlp engine" flow.
    private static let scriptCache = ScriptCache()

    static func bundledScripts() throws -> (lib: String, core: String) {
        if let cached = scriptCache.get() { return cached }
        guard let libURL = Bundle.main.url(forResource: "yt.solver.lib", withExtension: "js", subdirectory: "ytdlp/scripts"),
              let coreURL = Bundle.main.url(forResource: "yt.solver.core", withExtension: "js", subdirectory: "ytdlp/scripts"),
              let lib = try? String(contentsOf: libURL, encoding: .utf8),
              let core = try? String(contentsOf: coreURL, encoding: .utf8) else {
            throw SolverError.scriptsMissing
        }
        scriptCache.set((lib, core))
        return (lib, core)
    }

    private final class ScriptCache: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (lib: String, core: String)?
        func get() -> (lib: String, core: String)? { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ v: (lib: String, core: String)) { lock.lock(); value = v; lock.unlock() }
    }

    /// Whether on-device JS solving can run at all — used so the Python provider
    /// (and, transitively, yt-dlp's client selection) only advertises the web
    /// client when a runtime really exists.
    static var isAvailable: Bool {
        #if canImport(JavaScriptCore)
        return true
        #else
        return false
        #endif
    }

    /// Evaluates `lib` + `core` + `jsc(payload)` and returns the stringified
    /// result. Runs on a dedicated queue with a hard wall-clock deadline: JSC has
    /// no public preemption API, so on timeout we stop *waiting* and return an
    /// error while the abandoned context finishes and deallocates on its own —
    /// the same "orphan and move on" shape the Python timeouts already use. A
    /// fresh `JSContext` per call keeps state from leaking between challenges.
    static func solve(libScript: String,
                      coreScript: String,
                      payloadJSON: String,
                      timeout: TimeInterval = 20) throws -> String {
        #if canImport(JavaScriptCore)
        let box = ResultBox()
        let queue = DispatchQueue(label: "JSChallengeSolver")
        let semaphore = DispatchSemaphore(value: 0)

        queue.async {
            autoreleasepool {
                guard let context = JSContext() else {
                    box.set(.failure(SolverError.unavailable)); semaphore.signal(); return
                }
                var thrown: String?
                context.exceptionHandler = { _, exception in
                    thrown = exception?.toString() ?? "unknown JS exception"
                }

                context.evaluateScript(polyfillPrelude)
                context.evaluateScript(libScript)
                context.evaluateScript("Object.assign(globalThis, lib);")
                context.evaluateScript(coreScript)
                if let thrown {
                    box.set(.failure(SolverError.evaluationThrew(thrown))); semaphore.signal(); return
                }

                // `jsc` returns an object; stringify inside JS so we hand back a
                // plain string and never marshal a live JSValue across threads.
                let invocation = "JSON.stringify(jsc(\(payloadJSON)))"
                let value = context.evaluateScript(invocation)
                if let thrown {
                    box.set(.failure(SolverError.evaluationThrew(thrown))); semaphore.signal(); return
                }
                guard let string = value?.toString(), string != "undefined", !string.isEmpty else {
                    box.set(.failure(SolverError.noResult)); semaphore.signal(); return
                }
                box.set(.success(string)); semaphore.signal()
            }
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            throw SolverError.timedOut(Int(timeout))
        }
        switch box.get() {
        case .success(let s): return s
        case .failure(let e): throw e
        case .none: throw SolverError.noResult
        }
        #else
        throw SolverError.unavailable
        #endif
    }

    /// Thread-safe one-shot slot for the worker's result.
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<String, Error>?
        func set(_ v: Result<String, Error>) { lock.lock(); if value == nil { value = v }; lock.unlock() }
        func get() -> Result<String, Error>? { lock.lock(); defer { lock.unlock() }; return value }
    }
}
