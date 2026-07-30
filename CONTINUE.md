# Every Noise integration — handoff notes

Branch: `claude/every-noise-integration-djodwl`. The feature is **complete and
verified on-device**: the bundled genre map (Map/List/Scan/History + Find at
the root, Map/List/Scan + Find inside a genre), similarity sorting, artist
previews, the "+" → Artist source flow, and the live-from-Spotify Browse
Discography with inline YouTube matching have all been exercised on a phone,
end to end (album track → YouTube match → download → AI organize).

The `README.md` section **"The Every Noise browser"** is the authoritative
feature description; `tools/everynoise/README.md` covers the (one-time,
already-run) scraper. What follows is only what a future session benefits
from knowing.

## Architecture in one breath

`tools/everynoise/scrape.py` (Python 3, no deps) scraped everynoise.com into
`OfflineListen/EveryNoiseData/` — a `genres.json` index (6,291 genres, map
positions/colors/sizes/preview URLs) plus one raw-DEFLATE artist shard per
genre (631k artist rows, 57 MB), bundled as an Xcode folder reference.
`EveryNoiseData.swift` loads the index once off-main and inflates shards
lazily behind a small LRU; `NoiseMapView.swift` is a virtualized UIScrollView
(spatial grid, recycled labels) that keeps both maps smooth; the site froze
in late 2024, so the data never needs re-scraping. No Spotify API key is
needed for previews (static p.scdn.co URLs in the data); Browse Discography
does need the Settings ▸ Spotify credentials.

## Sharp edges worth remembering

- **Pushed destinations lose locally-injected environment objects.** The
  browser sits inside Browse's NavigationStack; `navigationDestination`
  content is hosted by that stack, so it inherits app-level environment
  objects but *not* ones injected inside the browser — hand `store`/`player`
  to destinations explicitly (a missed one crashes at first push).
- **Spotify's `/artists/{id}/albums` 400s an explicit `limit`** under a
  client-credentials app. Request the default page size and follow the
  server-minted `next` links.
- **Discography downloads are per-track picks and enqueue *unfiled*** —
  album-folder filing hid them from the Library's root Tracks list, which
  read as a bug.
- The Top 10 / Discography agents log full prompts/responses at debug level
  (Log, category `Browse`); Discography's `maxTokens` is 8192 because 4096
  truncated big catalogues mid-JSON.

## Ideas deliberately left on the table

Pinch-zoom on the maps (the site has none either); a global artist search
(needs a reverse index the shards don't carry); per-release "download all
matched"; scan continuing to play beneath a pushed genre view.
