# Every Noise at Once — one-time scraper

Feeds the app's in-app **Every Noise browser** (the globe button in Browse).
This is a modernized descendant of
[laffan/everynoise-scrape](https://github.com/laffan/everynoise-scrape): the
original is a set of Python 2 notebooks from 2016 that captured only artist
*names* per genre. This rewrite (plain Python 3, no dependencies) captures what
the in-app map needs — every genre's **map position**, **color**, **font size**
(the site's popularity cue), **example-track preview URL** and the **name of
the track** that URL plays, plus the same fields for the **constituent
artists** on each genre's own page, with each artist's Spotify id.

**No Spotify API key is needed at any point** — the 30-second preview URLs are
embedded in the site's HTML, and the app plays them directly. So are the track
names beside them, in each row's `title` attribute (`Artist "Song"`); Spotify's
API serves neither to apps registered after November 2024, which makes the
site's own markup the only source for either.

> **If your `EveryNoiseData/` predates August 2026**, its artist rows carry no
> track name — the parser read the field from the first version but the shard
> writer dropped it, so only *genres* had one. The app simply leaves the line
> blank where it doesn't have one; re-run the scrape to fill it in.

Every Noise froze in late 2024 when Spotify revoked the API access that fed it,
so the data is static: this scrape is genuinely one-time. The *genre space*
kept moving, though — see
[Topping the dataset up](#topping-the-dataset-up-merge_updatespy) for the
in-app harvest that catches what the frozen page never listed.

## Running the scrape

```sh
python3 tools/everynoise/scrape.py
```

That's the whole thing. It fetches the genre index (~6,300 genres), then every
genre's page (rate-limited, 3 workers, ~20–60 minutes), and writes straight
into `OfflineListen/EveryNoiseData/` — the folder the app bundles:

- `genres.json` — the genre index (name, x/y, color, size, preview, example),
  in the site's map order. Read once when the browser opens.
- `genres/<key>.z` — one shard per genre: its artist list as JSON compressed
  with raw DEFLATE (name, x/y, color, size, preview, example, spotify — the
  per-item `id` is left out, since rows are written in the site's own order).
  The app inflates shards lazily, one genre at a time.
- `meta.json` — scrape date, counts, canvas extents, and a `partial` flag.

Useful flags: `--limit 5` (smoke test), `--force` (refetch existing shards),
`--workers/--interval` (politeness), `--out` (elsewhere). An interrupted run
**resumes automatically** — shards already on disk are skipped — and failed
pages are listed at the end (just re-run to retry only those).

After a full scrape, commit the contents of `OfflineListen/EveryNoiseData/`;
the Xcode project already bundles that folder, so the next build ships it.

## The global artist-search index

```sh
python3 tools/everynoise/build_artist_index.py
```

derives `OfflineListen/EveryNoiseData/artists.idx.z` from the shards already
on disk (no network) — the flat index behind the browser's **Find Artist**
mode. Each unique artist (~470k) is one text line, led by a case/diacritic
folded copy of the name so the app can search it as raw bytes; an artist in
several genres keeps only the genre where they're drawn biggest, and lines are
ordered by that size so the first matches of a scan are the most popular. Run
it again only if the shards are ever regenerated, and commit the result.

> **Network note:** managed Claude Code environments may block everynoise.com
> by egress policy. Run this anywhere with ordinary internet access (a laptop
> with Python 3 is enough), or allow `everynoise.com` in the environment's
> network policy first.

## Topping the dataset up (`merge_updates.py`)

The scrape is frozen; the catalogue isn't. Artists debut, and Spotify files
them under labels the 2024 page never listed. The app can notice that as you
browse — **Settings ▸ Every Noise Data ▸ Collect updates as I browse** (needs
Spotify credentials, off by default). Opening a genre in the Every Noise
browser then also asks Spotify, **once per genre**, which artists it currently
files under that label, and records the names the bundled shard is missing.
**Download New Data** in the same section hands the collected file off the
device; this folds it in:

```sh
python3 tools/everynoise/merge_updates.py ~/Downloads/everynoise-updates.jsonl
python3 tools/everynoise/build_artist_index.py     # the index is derived from the shards
```

It does two things. **New artists** are appended to their genre's shard, with
their Spotify id (so the artist's "+" opens their live discography) and a
`size` mapped from Spotify's popularity onto the range that shard already
uses — the site's font-size cue meant the same thing. **New genres** — a label
carried by harvested artists that `genres.json` has no row for at all — get a
row plus a shard, once at least `--min-artists` (default 3) artists stand
behind them, positioned at the centroid of the known genres those artists were
found under (a co-occurring label is a neighbour, which is precisely what the
map's geometry encodes).

Two honest limits, both recorded in `meta.json` under `merged`:

- **Positions are synthetic.** The site's layout came from Spotify's
  audio-feature API, which was withdrawn along with everything else. New rows
  are hashed deterministically into the spread their genre's map already
  occupies — they sit *among* the right artists, not at a meaningful point
  within them.
- **No preview snippets.** Spotify stopped serving `preview_url` to apps
  created after November 2024, so harvested artists arrive with
  `preview: null` and no 30-second sample — and with no snippet there is no
  track to name either, so `example: null` goes with it. Their discography
  still works.

`--dry-run` reports without writing, and re-merging the same export is a
no-op, so it's safe to run twice. Commit `OfflineListen/EveryNoiseData/`
afterwards, as with a scrape.

**Why it can't get the app rate limited.** The harvest is one request per
genre *visit*, and it is skipped entirely when the genre was harvested in the
last 30 days, when 150 requests have already gone out today, when fewer than
20 seconds have passed since the last one, or when `SpotifyRateLimiter` knows
of *any* live 429 window (sending during one is what makes Spotify extend it).
Practically it costs less than opening a couple of artists in the discography
browser.

## Checking the parser without the network

```sh
python3 tools/everynoise/test_parser.py
```

runs the extraction against fixture HTML in `fixtures/` that mirrors the
site's markup quirks (unquoted attributes, single-quoted titles, entries with
no preview, sidebar entries with no map position). If everynoise.com's markup
ever drifts from these fixtures, `scrape.py` exits with a clear message
instead of writing bad data.
