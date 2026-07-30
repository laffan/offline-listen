# Every Noise integration — session handoff

Branch: `claude/every-noise-integration-djodwl`. This file is a snapshot for
whoever (human or agent) picks the work up next. The feature is **functionally
complete and the dataset is committed**; what remains is build verification
and small polish.

## State of play

**Done and pushed:**

- `tools/everynoise/` — working Python 3 scraper (rewrite of the dead
  Python 2 notebooks in laffan/everynoise-scrape). Captures genre + artist
  map positions, colors, sizes, preview URLs, Spotify ids. Offline fixture
  tests: `python3 tools/everynoise/test_parser.py`.
- `OfflineListen/EveryNoiseData/` — the **real scraped dataset** (commit
  `8f780f1`, scraped 2026-07-30): 6,291 genres, 631,768 artist rows, 57 MB.
  Validated in-session: zero missing/empty/duplicate shards, every genre has
  a preview URL, only 4% of artists lack one, all shard keys are `[a-z0-9]`,
  every shard inflates (raw DEFLATE, `wbits=-15`) and decodes against the
  app's models. Largest decoded shard ~0.25 MB (`animecv`).
- App integration, all wired into `project.pbxproj`:
  - `EveryNoiseData.swift` — models (`ENGenre`/`ENArtist`), lazy shard store
    (LRU of 12, `NSData.decompressed(using: .zlib)`), `ENPreviewPlayer`
    (AVPlayer over the p.scdn.co URLs; pauses `PlaybackManager` via the same
    `togglePlayPause()` courtesy the Browse preview modal uses).
  - `NoiseMapView.swift` — virtualized UIScrollView scatter map (spatial
    grid + recycled UILabels; only viewport-adjacent labels exist).
  - `EveryNoiseView.swift` — Map/List/Scan modes + Find at both levels;
    genre tap → artist map; artist tap → preview + "+" → creates an Artist
    source (Top 10/Discography) via `browse.addSource` + first refresh.
  - `BrowseView.swift` — `globe.americas` toolbar button beside "+", opens
    the browser as a `fullScreenCover`.
- README: feature section ("The Every Noise browser"), source-layout rows,
  setup note.

**Pushed via GitHub API at the end of this session** (native `git push` broke
mid-session — see quirks): a docs catch-up commit (README placeholder-era
text updated, real dataset numbers in the `EveryNoiseData.swift` header
comment, `EveryNoiseData/genres/README.txt` keeper deleted) and this file.
If any of that is missing from the branch, the intended contents are in this
session's local checkout at `/home/user/offline-listen` (local commit
"Docs catch up with the bundled Every Noise dataset").

## Not yet verified (the actual next steps)

1. **No Swift compile has ever run** — this environment has no Swift
   toolchain (the repo has always been authored this way). The first Xcode
   build is the syntax gate for the three new files + the `BrowseView` edit.
   Expect at most small fixes (an overload label, an iOS-16 availability
   nit); nothing structural should be wrong.
2. **On-device behavior checklist:**
   - Globe button → map renders ~6,300 genres, pans smoothly both axes.
   - Tap genre → artist map loads (shard inflate ~instant), positions sane.
   - Tap artist → 30s preview plays (needs network — previews stream from
     Spotify's CDN; everything else is offline), main player pauses.
   - "+" on artist bar → Top 10 / Discography → source appears in Browse
     and refreshes.
   - Scan mode: auto-advances on preview end, map follows, resumes position
     (genre level persists via `@AppStorage("everyNoiseScanIndex")`).
   - Find: list filtering, map dropdown + fly-to + 2s highlight flash.
   - Missing-preview artists: bar says so, play button disabled, scan skips.
3. **Perf on iPad**: the map is virtualized specifically for the M1-iPad
   lag complaint; if label churn stutters at high fling speeds, raise
   `Coordinator.margin` (prefetch band) or pool more aggressively.
4. **Possible polish**, deliberately not done: pinch-zoom on the map (site
   has none either); a global artist search (would need a reverse index —
   the scraper's per-genre shards don't carry one); genre "similar genres"
   sidebar links (not scraped).

## Design decisions worth knowing

- **No Spotify API anywhere.** Preview URLs are static p.scdn.co links
  embedded in the site's HTML; the site froze in late 2024, so the data is
  final. Re-scraping is never needed (but `scrape.py` resumes and is
  idempotent if you do).
- **Shards, not one blob**: per-genre raw-DEFLATE files keep git happy
  (no >100 MB file), let the app inflate exactly one genre at a time, and
  make partial scrapes/resumes natural. `genres.json` (1.4 MB) is the only
  thing read eagerly, off-main, on first open.
- **Site coordinates are used as-is** (1500×22648 canvas, top/left pixels →
  points). Genre keys are the site's page slugs — they're the shard
  filenames and the stable ids throughout.
- The dataset folder ships as an Xcode **folder reference** (like `ytdlp/`),
  so replacing/updating data never touches the project file.

## Environment quirks hit this session (for agents, not humans)

- Egress policy allows only GitHub-family hosts: everynoise.com and
  p.scdn.co are blocked here (previews can't be played/tested from the
  container; the scrape ran on the user's laptop).
- After a container resume, the baked-in git-proxy credentials rotated:
  `git pull/push origin` fails with username/password prompts. Workaround
  used: **fetch** via
  `GIT_CONFIG_GLOBAL=/dev/null git -c http.proxy="$HTTPS_PROXY" -c http.sslCAInfo=/root/.ccr/ca-bundle.crt fetch https://github.com/laffan/offline-listen.git <branch>`
  (works because the repo is public); **push** only works through the
  GitHub MCP tools (`push_files`/`delete_file`/`create_or_update_file`) in
  that state. A fresh session should have working git again.
