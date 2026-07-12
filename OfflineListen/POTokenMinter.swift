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
/// is produced by BotGuard, a JavaScript attestation VM Google serves at
/// runtime; it runs happily in a real browser environment — which is how every
/// mobile client and the desktop `bgutil` providers solve it. iOS has no Deno or
/// Node, but it has `WKWebView`, a full out-of-process browser engine, so we run
/// the same program there.
///
/// ## How
///
/// The whole flow is vendored as `botguard.js` (bundled from `bgutils-js`), which
/// exposes one global:
///
///     globalThis.__ol_generate_pot(requestKey, identifier)
///         -> Promise<JSON string { poToken, ttl }>
///
/// It runs Create → load the interpreter VM → snapshot → GenerateIT → mint, all
/// inside the WebView. Because the WebView document sits in the `youtube.com`
/// origin, the Create/GenerateIT `fetch`es are **same-origin** — no CORS, and no
/// native HTTP or challenge parsing needed on the Swift side. We just hand it the
/// request key and the content binding (`visitorData` for `gvs`, `videoId` for
/// `player`) and read back the token.
///
/// ## Threading & failure isolation
///
/// `WKWebView` is main-thread-only, so `mint(...)` is `@MainActor`; the PythonKit
/// bridge that calls it always runs on a background extraction thread and blocks
/// on the hop (safe — the WebView JS never re-enters Python). Minting is strictly
/// best-effort: any failure logs a `.warning` and returns nil, so extraction
/// proceeds exactly as it would without a token.
@MainActor
final class POTokenMinter {
    static let shared = POTokenMinter()

    /// Fixed BotGuard request key for YouTube's web PO-token program. Public,
    /// stable, and identical across every open-source PO-token provider.
    private static let requestKey = "O43z0dpjhgX20SCx4KAo"

    /// A minted token plus the instant it becomes stale. Tokens are good for
    /// hours; we mint lazily and refresh on 403 (driven by the download layer's
    /// re-resolve path passing `forceRefresh`) or on expiry.
    private struct CachedToken {
        let token: String
        let expiresAt: Date
    }

    /// Cache keyed by context + content binding. BotGuard tokens are
    /// binding-specific, so two contexts (or two videos) can't share one entry.
    private var cache: [String: CachedToken] = [:]

    /// The PO-token context, mirroring yt-dlp's `PoTokenContext`.
    enum Context: String {
        case gvs
        case player
    }

    /// Whether the vendored BotGuard bundle is present. When it isn't, minting
    /// can't work, so `PythonBridge` doesn't install the mint callback at all —
    /// the PO-token provider then reports itself unavailable and yt-dlp never
    /// invokes it. `nonisolated` so the background bridge thread can check it
    /// without a main-actor hop.
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
                appLog("PO-token minting disabled: botguard.js not bundled — extraction continues without a PO token.",
                       level: .warning, category: category)
            }
            return nil
        }

        do {
            appLog("Minting PO token (\(context.rawValue))…", category: category)
            let webView = ensureWebView()
            try await waitForDocument(webView)
            injectScriptIfNeeded(webView, script: script)

            let raw = try await webView.callAsyncJavaScript(
                "return await __ol_generate_pot(requestKey, identifier);",
                arguments: ["requestKey": Self.requestKey, "identifier": binding],
                contentWorld: .page)

            guard let json = raw as? String,
                  let data = json.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = object["poToken"] as? String, !token.isEmpty else {
                throw MinterError.noToken
            }
            let ttl = (object["ttl"] as? Int) ?? (object["ttl"] as? Double).map(Int.init) ?? 6 * 3600
            cache[cacheKey] = CachedToken(token: token, expiresAt: Date().addingTimeInterval(TimeInterval(ttl)))
            appLog("PO token minted (\(context.rawValue), cached \(max(1, ttl / 3600))h).", level: .success, category: category)
            return token
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
    private var webView: WKWebView?
    private var botguardScript: String?
    private var scriptInjectedInto: WKWebView?
    private var didLogUnavailable = false

    private enum MinterError: LocalizedError {
        case noToken
        var errorDescription: String? {
            switch self {
            case .noToken: return "BotGuard produced no usable token"
            }
        }
    }

    /// Loads the vendored BotGuard bundle from the app bundle once.
    private func loadBotguardScript() -> String? {
        if let botguardScript { return botguardScript }
        guard let url = Bundle.main.url(forResource: "botguard", withExtension: "js", subdirectory: "ytdlp/scripts"),
              let code = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        botguardScript = code
        return code
    }

    /// Ensures an off-screen 1×1 `WKWebView` exists in the key window's view
    /// hierarchy — iOS only runs a WebView's JS reliably when it's actually in
    /// the tree, so a detached view would silently never execute. The document is
    /// loaded with a `youtube.com` base URL so the BotGuard `fetch`es are
    /// same-origin.
    private func ensureWebView() -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        view.isHidden = true
        if let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) {
            window.addSubview(view)
        }
        view.loadHTMLString("<!doctype html><html><head></head><body></body></html>",
                            baseURL: URL(string: "https://www.youtube.com"))
        webView = view
        scriptInjectedInto = nil
        return view
    }

    /// Evaluates the BotGuard bundle in the page once per WebView, defining
    /// `__ol_generate_pot`.
    private func injectScriptIfNeeded(_ webView: WKWebView, script: String) {
        guard scriptInjectedInto !== webView else { return }
        webView.evaluateJavaScript(script, completionHandler: nil)
        scriptInjectedInto = webView
    }

    private func waitForDocument(_ webView: WKWebView, tries: Int = 50) async throws {
        for _ in 0..<tries {
            if webView.url != nil, !webView.isLoading { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
    #endif
}
