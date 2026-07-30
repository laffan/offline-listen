#!/usr/bin/env python3
"""Builds the global artist-search index from the already-scraped shards.

The app's Every Noise browser searches *artists* across the whole dataset
(the Find field's artist mode), and the per-genre shards can't serve that:
answering one keystroke would mean inflating all 6,291 of them. This script
derives a single flat index from the shards on disk — no network, no
re-scrape — that the app scans as raw bytes (`ENArtistIndex`).

Format (artists.idx.z, raw DEFLATE like the shards; inflated it's UTF-8 text):

    ENAI1\n                                     header line
    folded␟display␟genreKey␟x␟y␟color\n         one line per unique artist

- `folded` is the search key: lowercased, diacritics stripped, width-folded —
  the same folding the app applies to the query, so matching is a plain byte
  search.
- An artist appearing in several genres is kept **once**, in the genre where
  their name is drawn biggest (the site's popularity cue) — that's the page a
  search hit should open.
- Lines are ordered by that size, descending, so the first N matches of a
  scan are the most popular artists matching — ranking for free.
- `display`/`genreKey`/`x`/`y` reproduce the shard row exactly: the genre
  view selects the artist by its `name|x|y` id.

Usage:  python3 build_artist_index.py            # writes next to the shards
Run it again only if the shards themselves are ever regenerated.
"""

import glob
import json
import sys
import unicodedata
import zlib
from pathlib import Path

DATA_DIR = Path(__file__).resolve().parents[2] / "OfflineListen" / "EveryNoiseData"
FIELD_SEP = "\x1f"
HEADER = "ENAI1"


def fold(text: str) -> str:
    """Mirror Swift's .caseInsensitive + .diacriticInsensitive + .widthInsensitive."""
    decomposed = unicodedata.normalize("NFKD", text)
    stripped = "".join(c for c in decomposed if not unicodedata.combining(c))
    return stripped.casefold()


def clean(text: str) -> str:
    """Field separators / newlines can't appear inside a field."""
    return text.replace(FIELD_SEP, " ").replace("\n", " ").replace("\r", " ")


def main() -> int:
    shard_paths = sorted(glob.glob(str(DATA_DIR / "genres" / "*.z")))
    if not shard_paths:
        print(f"No shards under {DATA_DIR}/genres — run scrape.py first.", file=sys.stderr)
        return 1

    # name -> (size, genre_key, x, y, color); keep the biggest-drawn occurrence.
    best = {}
    rows = 0
    for path in shard_paths:
        key = Path(path).name[:-2]  # strip ".z"
        raw = zlib.decompress(open(path, "rb").read(), -15)
        for artist in json.loads(raw)["artists"]:
            rows += 1
            name = clean(artist["name"]).strip()
            if not name:
                continue
            size = artist.get("size", 100)
            prev = best.get(name)
            if prev is None or size > prev[0]:
                best[name] = (size, key, artist["x"], artist["y"], artist.get("color", ""))

    ordered = sorted(best.items(), key=lambda kv: (-kv[1][0], fold(kv[0])))
    lines = [HEADER]
    for name, (size, key, x, y, color) in ordered:
        lines.append(FIELD_SEP.join([fold(name), name, key, str(x), str(y), color]))
    blob = ("\n".join(lines) + "\n").encode("utf-8")

    packer = zlib.compressobj(9, zlib.DEFLATED, -15)  # raw DEFLATE, like the shards
    packed = packer.compress(blob) + packer.flush()
    out = DATA_DIR / "artists.idx.z"
    out.write_bytes(packed)
    print(f"{rows} shard rows -> {len(best)} unique artists")
    print(f"{out}: {len(blob) / 1e6:.1f} MB inflated, {len(packed) / 1e6:.1f} MB on disk")
    return 0


if __name__ == "__main__":
    sys.exit(main())
