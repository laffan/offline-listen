import Foundation
#if canImport(WebKit)
import WebKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Mints YouTube **proof-of-origin (PO) tokens** on device using a hidden
/// `WKWebView` to run Google's BotGuard attestation program.
///
/// ## Why
///
/// YouTube now enforces PO tokens for its streaming (`gvs`) and `player`
/// contexts across essentially all player clients ([yt-dlp #14404]). A PO token
/// is produced by BotGuard, a JavaScript attestation VM that Google serves at
/// runtime; it runs happily in a real browser environment, which is how every
/// mobile client and the desktop `bgutil` providers solve it. iOS has no Deno or
/// Node, but it has `WKWebView` — a full, out-of-process browser engine — so we
/// run the same program there.
///
/// ## Protocol (as implemented by bgutil / YouTube.js / NewPipe)
///
/// 1. `POST https://www.youtube.com/api/jnn/v1/Create` with the fixed
///    `requestKey` → returns the BotGuard **interpreter URL**, **program**, and
///    the **global VM name**.
/// 2. Load the interpreter (the VM) in the WebView, run the program to obtain a
///    **BotGuard response** bound to `visitorData` (gvs) or `videoId` (player).
/// 3. `POST https://jnn-pa.googleapis.com/$rpc/…/GenerateIT` with that response →
///    an **integrity token** and a TTL.
/// 4. Mint the final websafe PO-token string from the integrity token + the
///    content binding.
///
/// Steps 2 and 4 are the BotGuard VM interaction. The orchestration glue for it
/// (the `BG.BotGuardClient` / `BG.WebPoMinter` logic) is vendored as
/// `botguard.js` in the app bundle — see `OfflineListen/ytdlp/scripts/README.md`.
/// **Until that file is present, `mint(...)` returns nil**: minting is strictly
/// best-effort, so extraction proceeds exactly as before with a single
/// `.warning` in the log and no user-visible change ([JS-RUNTIME-PLAN Phase 1]).
///
/// ## Threading
///
/// `WKWebView` is main-thread-only. `mint(...)` is `async` and hops to the main
/// actor for every WebView touch; the PythonKit bridge that calls it always runs
/// on a background extraction thread, so blocking that thread on the main-actor
/// work can't deadlock the UI or the Python GIL (the WebView JS never re-enters
/// Python).
@MainActor
final class POTokenMinter {
    static let shared = POTokenMinter()

    /// Fixed BotGuard request key for YouTube's web PO-token program. Public,
    /// stable, and identical across every open-source PO-token provider.
    private static let requestKey = "O43z0dpjhgX20SCx4KAo"
    private static let createURL = URL(string: "https://www.youtube.com/api/jnn/v1/Create")!
    private static let generateITURL = URL(string: "https://jnn-pa.googleapis.com/$rpc/google.internal.waa.v1.Waa/GenerateIT")!

    /// A minted token plus the instant it becomes stale. Tokens are good for
    /// hours; we mint lazily and refresh on 403 (handled by the download layer's
    /// re-resolve path) or on expiry.
    private struct CachedToken {
        let token: String
        let expiresAt: Date
    }

    /// Cache keyed by the content binding (visitorData for `gvs`, videoId for
    /// `player`). BotGuard tokens are binding-specific, so two contexts can't
    /// share one entry.
    private var cache: [String: CachedToken] = [:]

    #if canImport(WebKit)
    private var webView: WKWebView?
    private var botguardScript: String?
    private var didLogUnavailable = false
    #endif

    /// The PO-token context, mirroring yt-dlp's `PoTokenContext`.
    enum Context: String {
        case gvs
        case player
    }

    /// Whether the vendored BotGuard orchestration script is bundled. When it
    /// isn't (the default in a sandboxed build), minting can't work, so the
    /// bridge doesn't install the mint callback at all — the PO-token provider
    /// then reports itself unavailable and yt-dlp never invokes it. `nonisolated`
    /// so the background bridge thread can check it without a main-actor hop.
    nonisolated static var isBotguardBundled: Bool {
        Bundle.main.url(forResource: "botguard", withExtension: "js", subdirectory: "ytdlp/scripts") != nil
    }

    /// Returns a PO token for `binding` in `context`, minting one if the cache is
    /// empty or stale. Never throws: any failure logs a `.warning` and returns
    /// nil so the caller falls back to today's behaviour.
    /// - Parameter forceRefresh: skip the cache (used when a 403 says the cached
    ///   token was rejected).
    func mint(binding: String, context: Context, forceRefresh: Bool = false) async -> String? {
        let category = "PO-token"
        guard !binding.isEmpty else { return nil }
        let cacheKey = "\(context.rawValue):\(binding)"

        if !forceRefresh, let cached = cache[cacheKey], cached.expiresAt > Date() {
            let hours = Int(cached.expiresAt.timeIntervalSinceNow / 3600)
            appLog("PO token served from cache (\(context.rawValue), valid ~\(max(0, hours))h).",
                   level: .debug, category: category)
            return cached.token
        }

        #if canImport(WebKit)
        guard let script = loadBotguardScript() else {
            if !didLogUnavailable {
                didLogUnavailable = true
                appLog("PO-token minting disabled: botguard.js not bundled — extraction continues without a PO token (see ytdlp/scripts/README.md).",
                       level: .warning, category: category)
            }
            return nil
        }

        do {
            appLog("Minting PO token (\(context.rawValue))…", category: category)
            let result = try await runBotguard(script: script, binding: binding, context: context, category: category)
            let ttl = result.ttlSeconds ?? 6 * 3600
            cache[cacheKey] = CachedToken(token: result.token, expiresAt: Date().addingTimeInterval(TimeInterval(ttl)))
            appLog("PO token minted (\(context.rawValue), cached \(ttl / 3600)h).", level: .success, category: category)
            return result.token
        } catch {
            appLog("PO-token minting failed (\(error.localizedDescription)) — continuing without one.",
                   level: .warning, category: category)
            return nil
        }
        #else
        return nil
        #endif
    }

    #if canImport(WebKit)
    private struct MintResult { let token: String; let ttlSeconds: Int? }

    /// Loads the vendored BotGuard orchestration script from the bundle once.
    /// Absent by default (it's the one piece that can't be fetched in a
    /// sandboxed build) — its absence is what keeps minting a clean no-op.
    private func loadBotguardScript() -> String? {
        if let botguardScript { return botguardScript }
        guard let url = Bundle.main.url(forResource: "botguard", withExtension: "js",
                                        subdirectory: "ytdlp/scripts"),
              let code = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        botguardScript = code
        return code
    }

    /// Ensures an off-screen 1×1 `WKWebView` exists in the key window's view
    /// hierarchy — iOS only runs a WebView's JS reliably when it's actually in
    /// the tree, so a detached view would silently never execute.
    private func ensureWebView() -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        view.isHidden = true
        if let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) {
            window.addSubview(view)
        }
        // A minimal about:blank document so evaluateJavaScript has a page.
        view.loadHTMLString("<!doctype html><html><head></head><body></body></html>",
                            baseURL: URL(string: "https://www.youtube.com"))
        webView = view
        return view
    }

    /// Drives the four-step BotGuard flow. The two HTTPS calls are made from
    /// Swift (`URLSession`), and the VM interaction runs in the WebView via the
    /// vendored `botguard.js`, which exposes
    /// `globalThis.__ol_botguard(interpreterUrl, program, globalName, binding)` →
    /// a BotGuard response string, and `globalThis.__ol_mint(integrityToken)` →
    /// the final websafe token.
    private func runBotguard(script: String, binding: String, context: Context, category: String) async throws -> MintResult {
        let webView = ensureWebView()
        try await waitForDocument(webView)
        _ = try await evaluate(webView, script)  // define the orchestration helpers

        // 1. Create — discover the interpreter + program for this session.
        let create = try await postJSON(Self.createURL, body: [Self.requestKey])
        let challenge = try BotguardChallenge(createResponse: create)

        // 2. Run the BotGuard program in the WebView, bound to the content id.
        let bgCall = "__ol_botguard(\(jsString(challenge.interpreterURL)), \(jsString(challenge.program)), \(jsString(challenge.globalName)), \(jsString(binding)))"
        guard let bgResponse = try await evaluate(webView, bgCall) as? String, !bgResponse.isEmpty else {
            throw MinterError.botguardFailed
        }

        // 3. GenerateIT — exchange the BotGuard response for an integrity token.
        let itResponse = try await postJSON(Self.generateITURL, body: [Self.requestKey, bgResponse])
        guard let integrityToken = (itResponse as? [Any])?.first as? String else {
            throw MinterError.noIntegrityToken
        }
        let ttl = (itResponse as? [Any]).flatMap { $0.count > 1 ? $0[1] as? Int : nil }

        // 4. Mint the final PO token from the integrity token + binding.
        let mintCall = "__ol_mint(\(jsString(integrityToken)), \(jsString(binding)))"
        guard let token = try await evaluate(webView, mintCall) as? String, !token.isEmpty else {
            throw MinterError.mintFailed
        }
        return MintResult(token: token, ttlSeconds: ttl)
    }

    // MARK: - WebView helpers

    private func waitForDocument(_ webView: WKWebView, tries: Int = 50) async throws {
        for _ in 0..<tries {
            if webView.url != nil, !webView.isLoading { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func evaluate(_ webView: WKWebView, _ js: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(js) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value) }
            }
        }
    }

    private func postJSON(_ url: URL, body: [Any]) async throws -> Any {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json+protobuf", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MinterError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// JSON-encodes a Swift string as a JS string literal (quotes + escaping) so
    /// it can be interpolated safely into an `evaluateJavaScript` call.
    private func jsString(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let array = String(data: data, encoding: .utf8) else { return "\"\"" }
        // Strip the surrounding [ ] to get just the quoted element.
        return String(array.dropFirst().dropLast())
    }

    /// Parses the fields we need out of the `Create` response array. The response
    /// is a nested JSON array; the interpreter URL, program, and global VM name
    /// sit at known positions (mirrors bgutil's descrambler).
    private struct BotguardChallenge {
        let interpreterURL: String
        let program: String
        let globalName: String

        init(createResponse: Any) throws {
            guard let outer = createResponse as? [Any], outer.count > 1,
                  let inner = outer[1] as? [Any] else {
                throw MinterError.malformedChallenge
            }
            // Layout: inner[0]=messageId, inner[1]=[interpreterUrl,...],
            // inner[2]=interpreterHash, inner[3]=program, inner[4]=globalName.
            let interpreter = (inner.count > 1 ? inner[1] : nil)
            let urlString: String?
            if let arr = interpreter as? [Any] { urlString = arr.first as? String }
            else { urlString = interpreter as? String }
            guard let url = urlString,
                  let program = (inner.count > 3 ? inner[3] as? String : nil),
                  let globalName = (inner.count > 4 ? inner[4] as? String : nil) else {
                throw MinterError.malformedChallenge
            }
            // The interpreter URL may arrive scheme-relative (//www.gstatic.com/…).
            self.interpreterURL = url.hasPrefix("//") ? "https:\(url)" : url
            self.program = program
            self.globalName = globalName
        }
    }

    private enum MinterError: LocalizedError {
        case httpError(Int)
        case malformedChallenge
        case botguardFailed
        case noIntegrityToken
        case mintFailed

        var errorDescription: String? {
            switch self {
            case .httpError(let code): return "BotGuard HTTP \(code)"
            case .malformedChallenge: return "unexpected Create response shape"
            case .botguardFailed: return "BotGuard program produced no response"
            case .noIntegrityToken: return "GenerateIT returned no integrity token"
            case .mintFailed: return "token minting produced no value"
            }
        }
    }
    #endif
}
