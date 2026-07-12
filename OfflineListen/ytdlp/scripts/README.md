# On-device JavaScript runtime assets

These files back the on-device JavaScript runtime that closes YouTube's
nsig/PO-token gap (see [`docs/JS-RUNTIME-PLAN.md`](../../../docs/JS-RUNTIME-PLAN.md)).
The whole `ytdlp/` folder is bundled into the app as a **folder reference** so
this layout is preserved at runtime (`Bundle.main/ytdlp/…`).

## `yt.solver.lib.js` / `yt.solver.core.js` — challenge solver (Phase 2, active)

The pinned [`yt-dlp-ejs`](https://github.com/yt-dlp/ejs) challenge-solver
scripts (version in `VERSION`). `JSChallengeSolver` runs them in JavaScriptCore
to solve the `n`/`sig` challenges — the same scripts a desktop Deno/QuickJS
runtime would run. Verified to load and execute `jsc(...)` in a barebones JS
engine exposing only `globalThis`/`JSON`/`console`, which is exactly JSC's
surface.

**Updating:** replace both files from the same `yt-dlp-ejs` release and bump
`VERSION`. Keep `lib` and `core` from the *same* release — they're a matched
pair. (The unminified `.js` variants are used here so JSC's error messages stay
legible; the minified variants work identically.)

## `botguard.js` — PO-token minter glue (Phase 1, **not yet vendored**)

`POTokenMinter` runs BotGuard in a hidden `WKWebView`. It fetches Google's
BotGuard **interpreter (VM)** at runtime and needs a small orchestration script,
`botguard.js`, that exposes two globals:

```js
// Runs the BotGuard program bound to `binding`; returns the BotGuard response.
globalThis.__ol_botguard = async (interpreterUrl, program, globalName, binding) => "...";
// Mints the final websafe PO token from the integrity token + binding.
globalThis.__ol_mint = async (integrityToken, binding) => "...";
```

This is the `BG.BotGuardClient` / `BG.WebPoMinter` logic from
[`bgutils-js`](https://github.com/LuanRT/BgUtils) (Unlicense/MIT). It could not
be vendored in this sandboxed build (no network to GitHub). **Until
`botguard.js` is present, PO-token minting is a clean no-op** — `mint(...)`
returns nil, extraction proceeds exactly as before, and the Log notes it once.
Drop the file here on a networked device build to activate Phase 1, then promote
the web clients to the front of the forced-client order in
`YouTubeExtractor.extractViaForcedClients` (see the comment there).
