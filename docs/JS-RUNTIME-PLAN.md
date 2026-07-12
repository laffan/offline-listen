# Plan: on-device JavaScript runtime for extraction (JavaScriptCore / WKWebView)

*Status: **Phases 1 and 2 implemented; Phase 3 still future.** The
download-layer reliability fixes (resume + re-resolve on 403,
truncation-as-failure, download-failure client fallback, playability
verification, auto engine refresh) landed separately and are prerequisites,
not part of this plan.*

## What landed (this session)

| Piece | Status | Where |
|-------|--------|-------|
| JavaScriptCore nsig/sig solver | **Done** | `JSChallengeSolver.swift` |
| yt-dlp provider plugin (JCP + PTP) | **Done** | `ytdlp/plugins/offlinelisten/yt_dlp_plugins/extractor/offlinelisten.py` |
| PythonKit↔Swift bridge + safe plugin registration | **Done** | `PythonBridge.swift` + `wireJSRuntimeIfSafe` |
| Vendored `yt-dlp-ejs` scripts (v0.8.0) | **Done** | `ytdlp/scripts/yt.solver.{lib,core}.js` |
| Failure-class counter line | **Done** | `DownloadManager.failureClass(for:)` |
| PO-token minter (WKWebView + BotGuard) | **Done** | `POTokenMinter.swift` |
| Vendored `botguard.js` (bgutils-js v3.2.0) | **Done** | `ytdlp/scripts/botguard.js` |
| Phase 3 cookie import | **Not started** | — |

**Verification done off-device (no Xcode/live YouTube in the build sandbox):**

- The real `yt-dlp-ejs` v0.8.0 `lib`+`core` scripts load and run `jsc(...)` in a
  barebones JS engine exposing only `globalThis`/`JSON`/`console` — exactly
  JavaScriptCore's surface.
- The Python plugin was driven through the **real** yt-dlp
  `JsChallengeRequestDirector`, solving both an `n` and a `sig` request
  end-to-end (grouping → Swift-bridge call → output mapping → yt-dlp's own
  validators), and the PO-token provider through a `PoTokenRequest`
  (WebPO content binding → bridge → `PoTokenResponse`).
- `botguard.js` (bundled from `bgutils-js`) loads and exposes
  `__ol_generate_pot` in a barebones engine matching WKWebView's surface,
  returning a Promise that rejects cleanly with no network.

What still needs an **on-device** run: a live nsig solve against a real
`base.js`, and the live BotGuard round-trip (Create → VM → GenerateIT → mint) in
the WKWebView.

## Safe registration (why the plugin loads when it does)

`load_all_plugins()` (the plugin import) must never run while another
`extract_info` is executing in the embedded interpreter — that re-entrancy
crashed an early mid-recovery attempt. So the runtime is wired only at a **calm
point**: the start of a job (serial queue) once Python is bootstrapped *and*
`waitForOrphanedExtraction` confirms no extraction is still running
(`wireJSRuntimeIfSafe`). Consequence: the runtime activates from the second
extraction of a session onward (or right after the first successful one). A
first-ever hard video that times out on the default path still falls through to
the forced clients exactly as before — then a retry, with the runtime now
active, solves nsig on device and mints a PO token so the web client works.

## Why this is the structural fix

YouTube's 2025–26 countermeasures changed what "extraction" requires:

- **nsig/sig challenges now require running YouTube's actual player JS.**
  yt-dlp abandoned its pure-Python JS interpreter for these and now requires an
  external JavaScript runtime (Deno by default) plus its `yt-dlp-ejs` script
  bundle ([yt-dlp #15012](https://github.com/yt-dlp/yt-dlp/issues/15012)).
  Without a runtime, the web-family player clients — the renditions Safari
  plays, and the most reliable tier — are effectively dead on device.
- **PO (proof-of-origin) tokens are being enforced for all player clients**
  ([yt-dlp #14404](https://github.com/yt-dlp/yt-dlp/issues/14404)). The app's
  forced-client roulette (`tv`/`ios`/`android`/…) worked when those clients
  were pre-signed and untokened; each is progressively being gated. Tokens are
  minted by BotGuard, a JS attestation program — again, a JS runtime problem.

Desktop tools (4K Video Downloader, yt-dlp+Deno) are reliable because they run
this JavaScript. iOS ships two first-party JS engines — **JavaScriptCore**
(headless, fast to instantiate) and **WKWebView** (full browser environment,
out-of-process) — so the capability gap is self-imposed. Closing it removes
the app's dependence on whichever unauthenticated client YouTube hasn't gated
yet.

## Current architecture (for orientation)

```
CompositeExtractor
├─ YouTubeKitExtractor (native Swift, YouTube only)      ← no nsig solving, no PO tokens
└─ YoutubeDLExtractor  (yt-dlp via kewlbear/YoutubeDL-iOS + PythonKit)
   ├─ default extractInfo (web client)                   ← 15s grace; nsig usually unsolvable on device
   └─ extractViaForcedClients (tv/ios/android/web_*)     ← pre-signed URLs; increasingly PO-gated
```

Constraint to keep in mind everywhere: `kewlbear/YoutubeDL-iOS` (last commit
Jan 2024) is abandoned; it bootstraps an embedded Python and downloads the
yt-dlp module from the official yt-dlp releases. We drive yt-dlp's Python API
directly via PythonKit in the forced-client path, so we can pass arbitrary
options (`extractor_args`, plugin dirs, `po_token`) without touching the
wrapper.

## Phase 1 — PO-token minting in a hidden WKWebView (highest value / effort ratio)

BotGuard runs happily in a real WebView; this is how other mobile clients
solve it. The bgutil-style providers
([bgutil-ytdlp-pot-provider](https://github.com/Brainicism/bgutil-ytdlp-pot-provider))
show the exact protocol: load the BotGuard program, run it against a
`visitorData` / datasync-id binding, produce `poToken` strings for
`gvs` (googlevideo streaming) and `player` contexts.

Work items:

1. **`POTokenMinter.swift`** — an off-screen `WKWebView` (must be in the view
   hierarchy on iOS to run JS reliably; add it 1×1pt, hidden, to the key
   window) that loads a minimal local HTML shell, injects the BotGuard
   bootstrap (fetched from YouTube's `/js` endpoints the way bgutil does), and
   exposes `mint(visitorData:) async throws -> String` via
   `evaluateJavaScript`/message handlers.
2. **Visitor-data plumbing.** Extract `visitorData` from the same innertube
   response the extraction already makes (yt-dlp exposes it; YouTubeKit's
   response carries it too). Cache token + visitorData pairs; tokens are good
   for hours, so mint lazily and refresh on 403.
3. **Feed tokens to yt-dlp** via `extractor_args`:
   `youtube: { po_token: ["web.gvs+<TOKEN>", "web.player+<TOKEN>"], player_client: [...] }`
   in `forcedClientResolve` (it already passes `extractor_args`). Also feed the
   fetch-refresher path so a mid-download re-resolve gets a fresh token.
4. **Feed tokens to YouTubeKit** if its API grows support; otherwise append
   the `pot=` query parameter to resolved googlevideo URLs (that is how gvs
   tokens are transmitted).
5. **Failure isolation.** Minting is best-effort: on any failure, extraction
   proceeds exactly as today (log a `.warning`, no user-visible change).

Acceptance: a video that currently fails all clients with "missing a PO
token" / 403-on-first-chunk downloads successfully; the Log shows
`PO token minted (gvs, cached Xh)`.

## Phase 2 — nsig/sig solving via JavaScriptCore (restores the web client)

yt-dlp's EJS layer externalizes the challenge scripts; its runtime contract is
small (feed script + input, read JSON result). Two implementation options,
in order of preference:

1. **JSC-backed runtime plugin.** Write a tiny yt-dlp plugin (Python, shipped
   in the app bundle and added to yt-dlp's plugin path) that implements the
   JS-runtime interface by calling back into Swift. The bridge: plugin writes
   the script+input to a temp file / calls a registered Python function that
   PythonKit maps to a Swift closure running `JSContext.evaluateScript`.
   JavaScriptCore lacks browser globals the player JS may touch
   (`setTimeout`, `TextEncoder`, `console`, `atob`) — ship a small polyfill
   prelude; yt-dlp-ejs targets barebones runtimes, so the surface is small and
   versioned with the ejs release we vendor.
2. **WKWebView fallback.** If a challenge needs DOM-ish APIs JSC + polyfills
   can't satisfy, evaluate in the Phase-1 WKWebView instead (slower, but
   complete). Same Swift interface, so the two are interchangeable per call.

Work items:

1. Vendor a pinned **yt-dlp-ejs** release in the app bundle; record its
   version; add it to the "Refresh yt-dlp engine" flow so engine + ejs update
   together.
2. **`JSChallengeSolver.swift`** — `solve(script:input:) async throws ->
   String` over a `JSContext` with the polyfill prelude; hard timeout (JSC has
   no preemption — run on a worker thread and abandon on deadline, mirroring
   `withTimeout`).
3. The **plugin bridge** (PythonKit-registered callback) + wiring it into both
   `extractInfo` (structured) and `forcedClientResolve` (direct) paths.
4. Re-order clients once web works: web/web_safari move to the *front* for
   both modes (highest quality, least gated when properly tokened + solved);
   tv/ios/android become the fallbacks.

Acceptance: with the module fresh, the default web-client extraction resolves
a video that today logs an nsig failure, within the 15s grace window on an
A15-class device.

## Phase 3 — optional cookie import (age-gated / members-only content)

A `WKWebView`-hosted Google sign-in (shown modally from Settings, user-
initiated) whose cookies are exported from `WKHTTPCookieStore` into a
Netscape-format jar handed to yt-dlp (`cookiefile`) and to YouTubeKit
(`useCookies`). Store nothing but the cookie jar, in the Keychain. This is
explicitly opt-in and last in priority: Phases 1–2 fix the mainstream failure
mode; cookies fix the long tail.

## Testing & metrics

- Build a small **test-matrix note** (10–15 URLs: plain video, music, age-
  gated, chaptered, 4K/AV1-only, Shorts, non-YouTube) and record per-phase
  pass/fail in the Log before/after each phase.
- Add a **failure-class counter line** to the end of each failed job's log
  (`Failure class: http-403 | bot-check | nsig | timeout | hls-only | other`)
  so diagnostics logs can be tallied across a week of real use.

## Risks / notes

- **Maintenance treadmill.** BotGuard and the player JS change continuously;
  pin ejs + bgutil-equivalent scripts to versions and expose "refresh engine"
  as the recovery lever. Expect periodic breakage regardless — the goal is
  matching the desktop tools' ceiling, not exceeding it.
- **Memory.** Python + WKWebView + JSC concurrently is heavy on older phones;
  instantiate the WebView lazily, drop it after idling, and never run two
  Python extractions at once (already enforced by the serial queue).
- **App Review.** This app is a personal-use side-load (see README header);
  none of this is App Store-safe, which is unchanged from today.
- **PythonKit callback re-entrancy.** The Python→Swift→JSC bridge must not
  block the main actor and must marshal strings only (no PythonObject capture
  across threads) — the existing `withTimeout`/GCD patterns in
  `YouTubeExtractor.swift` are the template.
