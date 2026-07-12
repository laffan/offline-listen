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

## `botguard.js` — PO-token minter glue (Phase 1, active)

`POTokenMinter` runs BotGuard in a hidden `WKWebView` to mint PO tokens. The
whole flow is vendored here as `botguard.js`, bundled from
[`bgutils-js`](https://github.com/LuanRT/BgUtils) v3.2.0 (MIT, © 2024 LuanRT)
plus a thin entry (`ol-entry.ts`, kept in the commit history) that exposes one
global:

```js
globalThis.__ol_generate_pot(requestKey, identifier)
    // -> Promise<JSON string { poToken, ttl }>
```

It runs the full protocol — Create → load the interpreter VM → snapshot →
GenerateIT → mint — inside the WebView. Because the WebView document sits in the
`youtube.com` origin, the Create/GenerateIT `fetch`es are **same-origin** (no
CORS), so Swift makes no HTTP calls and parses no challenge itself.

**Regenerating** (after a bgutils-js update):

```sh
bun build ol-entry.ts --target=browser --format=iife --minify
```

then prepend the provenance header and save as `botguard.js`. If `botguard.js`
is ever removed, `POTokenMinter.isBotguardBundled` is false, the bridge doesn't
install the mint callback, and the PO-token provider reports itself unavailable
— minting becomes a clean no-op with extraction unchanged.
