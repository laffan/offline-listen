# Every Noise at Once — one-time scraper

Feeds the app's in-app **Every Noise browser** (the globe button in Browse).
This is a modernized descendant of
[laffan/everynoise-scrape](https://github.com/laffan/everynoise-scrape): the
original is a set of Python 2 notebooks from 2016 that captured only artist
*names* per genre. This rewrite (plain Python 3, no dependencies) captures what
the in-app map needs — every genre's **map position**, **color**, **font size**
(the site's popularity cue), and **example-track preview URL**, plus the same
fields for the **constituent artists** on each genre's own page, with each
artist's Spotify id.

**No Spotify API key is needed at any point** — the 30-second preview URLs are
embedded in the site's HTML, and the app plays them directly.

Every Noise froze in late 2024 when Spotify revoked the API access that fed it,
so the data is static: this scrape is genuinely one-time.

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
  with raw DEFLATE. The app inflates shards lazily, one genre at a time.
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

## Checking the parser without the network

```sh
python3 tools/everynoise/test_parser.py
```

runs the extraction against fixture HTML in `fixtures/` that mirrors the
site's markup quirks (unquoted attributes, single-quoted titles, entries with
no preview, sidebar entries with no map position). If everynoise.com's markup
ever drifts from these fixtures, `scrape.py` exits with a clear message
instead of writing bad data.
