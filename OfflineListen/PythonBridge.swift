import Foundation

#if canImport(PythonKit)
import PythonKit
#endif
#if canImport(YoutubeDL)
import YoutubeDL
#endif
// PythonSupport (a transitive dependency of YoutubeDL-iOS) exposes
// `initialize()`, the call that actually starts the embedded interpreter. Being
// able to run it directly is what lets us bootstrap Python *without* a hanging
// extraction. If it doesn't resolve, add it as an explicit package dependency on
// the app target (like PythonKit); guarded by `canImport`, so without it the
// early-bootstrap path compiles out and we fall back to lazy wiring.
#if canImport(PythonSupport)
import PythonSupport
#endif

/// Wires the on-device JavaScript runtime into yt-dlp.
///
/// yt-dlp solves YouTube's `n`/`sig` challenges and mints PO tokens through a
/// *provider* plugin system. On desktop those providers shell out to Deno or a
/// local HTTP service; on iOS there is no subprocess, so we ship a Python plugin
/// (`yt_dlp_plugins.extractor.offlinelisten`) whose providers call back into
/// Swift — JavaScriptCore for challenge solving, a hidden `WKWebView` for PO
/// tokens.
///
/// This type does two one-time setup jobs, both idempotent and both safe to call
/// only *after* the embedded Python has been bootstrapped by a prior
/// `extractInfo` (the same ordering constraint the forced-client recovery
/// already respects):
///
/// 1. **Install the bridge callables** on Python's `builtins` module
///    (`__ol_solve_js`, `__ol_mint_pot`). The plugin looks them up there; if
///    they're absent it reports itself unavailable and yt-dlp behaves as before.
/// 2. **Point yt-dlp's plugin loader at the bundled plugin dir** and force a
///    reload, since the Python-API path (unlike the CLI) never sets
///    `plugin_dirs` from options.
enum PythonBridge {
    private(set) static var isConfigured = false

    /// Whether we've started the embedded Python interpreter ourselves.
    private(set) static var didBootstrapPython = false

    /// Starts the embedded Python interpreter **without** running an extraction,
    /// then registers the providers — so the very first web extraction can solve
    /// nsig on device instead of grinding the pure-Python path (which hangs on
    /// hard videos, orphans a GIL-holding thread, and crashes the forced-client
    /// fallback that then runs a second `extract_info` concurrently).
    ///
    /// This mirrors `YoutubeDL-iOS`'s own `loadPythonModule` sequence step for
    /// step — `PythonSupport.initialize()`, install the fake `Popen` shim, insert
    /// the yt-dlp module dir into `sys.path`, import `yt_dlp` — so the interpreter
    /// ends up in exactly the state the wrapper's first extraction would leave it.
    /// (The earlier version skipped the `Popen` shim and faulted; the log showed
    /// the wrapper relies on it to intercept `ffmpeg`/`deno` subprocess spawns,
    /// which posix_spawn can't do in the iOS sandbox.) Requires the yt-dlp module
    /// on disk (the caller ensures that) and an idle interpreter (the caller gates
    /// on it). No-op without `PythonSupport`, or once already configured.
    ///
    /// Every step writes a breadcrumb to the durable on-disk log *before* it runs,
    /// so if a native fault happens the last persisted line names the exact call.
    /// - Parameter pythonAlreadyInitialized: pass true if a prior extraction has
    ///   already started the interpreter, so we don't call
    ///   `PythonSupport.initialize()` a second time (double-init could fault).
    static func bootstrapAndConfigure(pythonAlreadyInitialized: Bool) {
        #if canImport(PythonKit) && canImport(YoutubeDL) && canImport(PythonSupport)
        guard !isConfigured else { return }
        let category = "JS-runtime"
        do {
            if !didBootstrapPython && !pythonAlreadyInitialized {
                appLog("Early bootstrap: PythonSupport.initialize()…", level: .debug, category: category)
                PythonSupport.initialize()
                didBootstrapPython = true
            }
            appLog("Early bootstrap: import sys…", level: .debug, category: category)
            let sys = try Python.attemptImport("sys")
            let modulePath = YoutubeDL.pythonModuleURL.path
            let paths = (Array(sys.path) ?? []).compactMap { String($0) }
            if !paths.contains(modulePath) {
                // Install the fake Popen shim BEFORE importing yt_dlp — the same
                // thing the wrapper does — so yt-dlp's later subprocess probes
                // (ffmpeg/ffprobe/deno) raise a clean FileNotFoundError instead of
                // a real posix_spawn the iOS sandbox faults on.
                appLog("Early bootstrap: installing fake Popen shim…", level: .debug, category: category)
                installFakePopen()
                appLog("Early bootstrap: inserting module path into sys.path…", level: .debug, category: category)
                sys.path.insert(1, PythonObject(modulePath))
            }
            appLog("Early bootstrap: import yt_dlp…", level: .debug, category: category)
            _ = try Python.attemptImport("yt_dlp")
            appLog("Early bootstrap: registering providers…", level: .debug, category: category)
            configureIfNeeded()
        } catch {
            // Best-effort: fall back to lazy wiring on the normal path.
            appLog("Early Python bootstrap failed (\(error.localizedDescription)) — falling back to lazy wiring.",
                   level: .warning, category: category)
        }
        #endif
    }

    /// Replaces `subprocess.Popen` with a stub that raises `FileNotFoundError`
    /// for every command. yt-dlp treats `ffmpeg`/`ffprobe`/`deno` as optional and
    /// degrades gracefully when they're "missing"; this app never uses yt-dlp's
    /// ffmpeg path (it does its own chunked download + AVFoundation), so a
    /// reject-all shim is sufficient — and it prevents a real `posix_spawn` in the
    /// iOS sandbox, which is what the wrapper's own shim exists to avoid.
    private static func installFakePopen() {
        let code = """
        import errno, os, subprocess
        class _OLFakePopen:
            def __init__(self, *args, **kwargs):
                cmd = args[0] if args else ''
                raise FileNotFoundError(errno.ENOENT, os.strerror(errno.ENOENT), cmd)
        subprocess.Popen = _OLFakePopen
        """
        let builtins = Python.import("builtins")
        let namespace = builtins.dict()
        builtins.exec(PythonObject(code), namespace)
    }

    /// Installs the callbacks and registers the plugin. Call at the top of the
    /// forced-client path. No-op after the first successful run.
    static func configureIfNeeded() {
        #if canImport(PythonKit) && canImport(YoutubeDL)
        guard !isConfigured else { return }
        let category = "JS-runtime"
        do {
            // Breadcrumbs written to the durable on-disk log before each step, so
            // if a native fault happens inside these Python/PythonKit calls the
            // last persisted line names exactly which one died.
            appLog("Wiring JS runtime: installing bridge callables…", level: .debug, category: category)
            try installBridgeCallables()
            appLog("Wiring JS runtime: registering plugin…", level: .debug, category: category)
            try registerPlugin(category: category)
            isConfigured = true
            appLog("On-device JS runtime wired into yt-dlp (JavaScriptCore + WKWebView).",
                   level: .success, category: category)
        } catch {
            // Best-effort: a wiring failure just means yt-dlp runs as it did
            // before (JS-less clients). Log and move on — never fatal.
            appLog("Could not wire on-device JS runtime (\(error.localizedDescription)) — continuing without it.",
                   level: .warning, category: category)
        }
        #endif
    }

    #if canImport(PythonKit) && canImport(YoutubeDL)
    /// The bundled plugin package's parent dir — the value yt-dlp's plugin
    /// loader scans (it iterates the dir's children looking for `yt_dlp_plugins`
    /// packages). Nil if the resources weren't bundled.
    private static var pluginDir: String? {
        Bundle.main.url(forResource: "plugins", withExtension: nil, subdirectory: "ytdlp")?.path
    }

    private static func installBridgeCallables() throws {
        let builtins = Python.import("builtins")

        // JS-challenge solve: (dataJSON) -> resultJSON. The ejs `data` payload
        // comes from the Python provider; JavaScriptCore holds the lib/core
        // scripts and runs `jsc(data)`. Runs synchronously on the calling
        // (Python extraction) thread — JSC solving is fast.
        builtins.__ol_solve_js = PythonObject(PythonFunction { (arg: PythonObject) throws -> PythonConvertible in
            let payload = String(arg) ?? ""
            do {
                let (lib, core) = try JSChallengeSolver.bundledScripts()
                return try JSChallengeSolver.solve(libScript: lib, coreScript: core, payloadJSON: payload)
            } catch {
                // Turn the Swift error into a Python exception the provider
                // catches and reports per-request.
                throw PythonError.exception(
                    Python.RuntimeError("JSC solve failed: \(error.localizedDescription)"), traceback: nil)
            }
        })

        // PO-token mint: (binding, context, forceRefresh) -> token | None. The
        // WKWebView is main-thread-only, so this blocks the calling background
        // thread on a main-actor hop (safe: the caller is never the main actor,
        // and the WebView JS never re-enters Python).
        //
        // Installed ONLY when `botguard.js` is bundled. Without it minting can't
        // work, and leaving the callback out means the PO-token provider reports
        // itself unavailable — so yt-dlp never calls it and the main-actor hop
        // never happens. This keeps the dormant Phase-1 path completely inert
        // until its one missing script is vendored.
        guard POTokenMinter.isBotguardBundled else {
            appLog("PO-token bridge not installed (botguard.js absent) — provider stays dormant.",
                   level: .debug, category: "JS-runtime")
            return
        }
        builtins.__ol_mint_pot = PythonObject(PythonFunction { (args: [PythonObject]) -> PythonConvertible in
            guard args.count >= 2,
                  let binding = String(args[0]),
                  let contextRaw = String(args[1]),
                  let context = POTokenMinter.Context(rawValue: contextRaw) else {
                return Python.None
            }
            let forceRefresh = args.count >= 3 ? (Bool(args[2]) ?? false) : false
            let token = blockingMintPOToken(binding: binding, context: context, forceRefresh: forceRefresh)
            return token.map { PythonObject($0) } ?? Python.None
        })
    }

    /// Sets `plugin_dirs` to include the bundled dir and forces a reload so the
    /// providers register even though the wrapper already created a `YoutubeDL`
    /// (which loaded plugins once, with our dir absent).
    private static func registerPlugin(category: String) throws {
        guard let pluginDir else {
            appLog("Plugin dir not bundled — on-device providers won't register.",
                   level: .warning, category: category)
            return
        }
        // Make sure the plugin specs (extractor/postprocessor) are registered by
        // importing the packages, then repoint plugin_dirs and reload.
        appLog("Plugin: importing yt_dlp.extractor…", level: .debug, category: category)
        _ = Python.import("yt_dlp.extractor")
        _ = Python.import("yt_dlp.postprocessor")
        let globals = Python.import("yt_dlp.globals")
        let plugins = Python.import("yt_dlp.plugins")
        globals.plugin_dirs.value = PythonObject(["default", pluginDir])
        globals.all_plugins_loaded.value = false
        appLog("Plugin: running load_all_plugins…", level: .debug, category: category)
        plugins.load_all_plugins()
        appLog("Registered on-device yt-dlp plugin from \(pluginDir).", level: .debug, category: category)
    }

    /// Blocks the current (background) thread until the main-actor minter
    /// returns, with a hard cap so a stuck WebView can't hang extraction forever.
    private static func blockingMintPOToken(binding: String, context: POTokenMinter.Context, forceRefresh: Bool) -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = TokenBox()
        Task { @MainActor in
            let token = await POTokenMinter.shared.mint(binding: binding, context: context, forceRefresh: forceRefresh)
            box.set(token)
            semaphore.signal()
        }
        // 45s is comfortably above a healthy BotGuard round-trip; a timeout just
        // yields no token (extraction proceeds without one).
        if semaphore.wait(timeout: .now() + 45) == .timedOut { return nil }
        return box.get()
    }

    private final class TokenBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        func set(_ v: String?) { lock.lock(); value = v; lock.unlock() }
        func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
    }
    #endif
}
