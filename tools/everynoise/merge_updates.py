#!/usr/bin/env python3
"""Folds the app's harvested dataset updates back into the bundled map.

The Every Noise scrape is frozen (the site lost its Spotify API access in late
2024), but the genre space isn't. With Settings ▸ Every Noise Data ▸ **Collect
updates as I browse** turned on, opening a genre in the app also asks Spotify
— once per genre, heavily throttled — who it currently files under that label,
and records every name the bundled shard is missing. Settings ▸ **Download New
Data** hands that record file off the device; this script merges it in.

    python3 tools/everynoise/merge_updates.py ~/Downloads/everynoise-updates.jsonl

Input is JSONL, one object per line, exactly as the app writes it:

    {"genreKey":"deephouse","genreName":"deep house","artist":"…",
     "spotifyID":"…","popularity":63,"imageURL":null,
     "genres":["deep house","tech house"],"seen":"2026-07-30T12:00:00Z"}

What it does, in place, under OfflineListen/EveryNoiseData/:

1. **New artists.** Each record whose artist isn't already in its genre's
   shard is appended to it — with `preview: null`, because Spotify stopped
   serving `preview_url` to apps created after November 2024 and the app has
   no snippet to record. Everything else about the row is real: the Spotify
   id (so the artist's "+" opens their live discography), and a `size` mapped
   from Spotify's popularity onto the size range the shard already uses,
   which is what the site's font-size cue meant.
2. **New genres.** A label that shows up on harvested artists but has no row
   in `genres.json` is a genre the map never had. With at least
   `--min-artists` artists behind it, it gets a row placed at the centroid of
   the *known* genres those artists were found under — the same "nearby means
   similar" logic the map runs on, since a co-occurring label is by definition
   a neighbour — plus a shard of those artists.
3. **Positions.** Neither Spotify nor anything else can reproduce the site's
   audio-feature layout (the features were withdrawn with the API), so new
   rows are placed *deterministically but arbitrarily*: hashed into the
   existing spread of their genre's map. They sit among their genre's
   artists, not in a meaningful spot within it. That's the honest limit of
   this, and it's noted in `meta.json` as `merged`.

Afterwards, re-run `build_artist_index.py` (the global Find Artist index is
derived from the shards) and commit `OfflineListen/EveryNoiseData/`.

Useful flags: `--dry-run` (report, write nothing), `--min-artists N` (how many
artists a new genre needs before it earns a row, default 3), `--data DIR`.
"""

import argparse
import hashlib
import json
import re
import sys
import unicodedata
import zlib
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

DATA_DIR = Path(__file__).resolve().parents[2] / "OfflineListen" / "EveryNoiseData"

# The size range a shard falls back to when it has too few artists to imply
# one — the site's font-size percent, where 100 is "normal".
DEFAULT_SIZE_RANGE = (60, 160)
# The local map box a brand-new genre's shard is laid out in. The site's own
# artist maps run to a few thousand points on each axis; this matches that
# order of magnitude so the app's virtualized map behaves normally.
NEW_GENRE_CANVAS = (2000, 1400)
# The smallest box new artists are spread across, whatever the shard implies.
# A genre with one artist in it has *no* spread, and without this floor every
# addition would land on that one point, stacking labels on top of each other.
MIN_SPREAD = 400


def fold(text: str) -> str:
    """Mirror the app's folding, so "Beyoncé" and "beyonce" are one artist."""
    decomposed = unicodedata.normalize("NFKD", text)
    stripped = "".join(c for c in decomposed if not unicodedata.combining(c))
    return stripped.casefold().strip()


def compact_json(obj) -> bytes:
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def deflate(data: bytes) -> bytes:
    co = zlib.compressobj(9, zlib.DEFLATED, -15)  # raw DEFLATE, like scrape.py
    return co.compress(data) + co.flush()


def read_shard(path: Path) -> dict:
    return json.loads(zlib.decompress(path.read_bytes(), -15))


def write_shard(path: Path, payload: dict):
    path.write_bytes(deflate(compact_json(payload)))


def jitter(seed: str, span: int) -> int:
    """A stable pseudo-random offset in [0, span), keyed on a name.

    Deterministic on purpose: merging the same export twice must not move
    anybody, and two people merging the same records must get the same map.
    """
    if span <= 0:
        return 0
    digest = hashlib.sha1(seed.encode("utf-8")).digest()
    return int.from_bytes(digest[:4], "big") % span


def size_range(artists: list) -> tuple:
    sizes = [a.get("size") for a in artists if isinstance(a.get("size"), int)]
    if len(sizes) < 2:
        return DEFAULT_SIZE_RANGE
    return min(sizes), max(sizes)


def size_for(popularity: int, span: tuple) -> int:
    low, high = span
    popularity = max(0, min(100, int(popularity or 0)))
    return int(round(low + (high - low) * popularity / 100))


def place(seed: str, artists: list) -> tuple:
    """A position for a new artist inside a genre's own map.

    Inside the spread the genre's existing artists occupy, so the new row
    lands among them rather than off in empty canvas. An empty shard falls
    back to the standard new-genre box.
    """
    xs = [a["x"] for a in artists if isinstance(a.get("x"), int)]
    ys = [a["y"] for a in artists if isinstance(a.get("y"), int)]
    if xs and ys:
        width = max(max(xs) - min(xs), MIN_SPREAD)
        height = max(max(ys) - min(ys), MIN_SPREAD)
        cx = (min(xs) + max(xs)) // 2
        cy = (min(ys) + max(ys)) // 2
    else:
        width, height = NEW_GENRE_CANVAS
        cx, cy = width // 2, height // 2
    return (max(0, cx - width // 2 + jitter(seed + "|x", width)),
            max(0, cy - height // 2 + jitter(seed + "|y", height)))


def slugify(name: str, taken: set) -> str:
    """The site's own key shape: lowercase, alphanumerics only."""
    base = re.sub(r"[^a-z0-9]", "", name.lower()) or "genre"
    key, n = base, 1
    while key in taken:
        n += 1
        key = f"{base}-{n}"
    return key


def load_records(path: Path) -> list:
    records = []
    bad = 0
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            bad += 1
            continue
        if record.get("artist") and record.get("genreKey"):
            records.append(record)
        else:
            bad += 1
    if bad:
        print(f"  ! skipped {bad} unreadable line(s)")
    return records


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("updates", type=Path, help="the exported everynoise-updates.jsonl")
    ap.add_argument("--data", type=Path, default=DATA_DIR,
                    help=f"dataset directory (default {DATA_DIR})")
    ap.add_argument("--min-artists", type=int, default=3,
                    help="artists a genre new to the map needs before it earns a row (default 3)")
    ap.add_argument("--dry-run", action="store_true", help="report what would change, write nothing")
    args = ap.parse_args()

    data: Path = args.data
    shards = data / "genres"
    index_path = data / "genres.json"
    if not index_path.exists() or not shards.is_dir():
        print(f"No dataset under {data} — run scrape.py first.", file=sys.stderr)
        return 1
    if not args.updates.exists():
        print(f"No such file: {args.updates}", file=sys.stderr)
        return 1

    records = load_records(args.updates)
    if not records:
        print("Nothing to merge.")
        return 0
    print(f"{len(records)} record(s) from {args.updates}")

    index = json.loads(index_path.read_bytes())
    by_key = {g["key"]: g for g in index}
    known_labels = {fold(g["name"]) for g in index}

    # ---- 1. New artists, grouped by the genre they were found under. -------
    per_genre = defaultdict(list)
    for record in records:
        per_genre[record["genreKey"]].append(record)

    added_artists = 0
    touched_shards = 0
    missing_shards = []
    pending_writes = {}

    for key, group in sorted(per_genre.items()):
        shard_path = shards / f"{key}.z"
        if not shard_path.exists():
            missing_shards.append(key)
            continue
        shard = read_shard(shard_path)
        artists = shard.get("artists", [])
        present = {fold(a["name"]) for a in artists}
        genre_color = by_key.get(key, {}).get("color", "")
        span = size_range(artists)
        fresh = []
        for record in group:
            name = record["artist"].strip()
            if not name or fold(name) in present:
                continue
            present.add(fold(name))
            x, y = place(f"{key}|{name}", artists)
            fresh.append({
                "name": name,
                "x": x,
                "y": y,
                # Artists on a genre page share the genre's hue on the site;
                # a harvested row has no colour of its own to copy.
                "color": genre_color,
                "size": size_for(record.get("popularity", 0), span),
                # Spotify serves no preview_url to apps created after
                # November 2024, so there is genuinely no snippet to record —
                # and with no snippet there is no track to name either.
                "preview": None,
                "example": None,
                "spotify": record.get("spotifyID"),
            })
        if not fresh:
            continue
        shard["artists"] = artists + fresh
        pending_writes[shard_path] = shard
        added_artists += len(fresh)
        touched_shards += 1

    # ---- 2. Genres the map doesn't have at all. ----------------------------
    # A label carried by harvested artists but absent from genres.json. Its
    # position comes from the genres those artists *were* found under: a
    # co-occurring label is a neighbour, which is exactly what the map's
    # geometry encodes.
    new_labels = defaultdict(lambda: {"artists": {}, "hosts": defaultdict(int), "display": ""})
    for record in records:
        for label in record.get("genres", []):
            folded = fold(label)
            if not folded or folded in known_labels:
                continue
            entry = new_labels[folded]
            entry["display"] = entry["display"] or label
            entry["artists"][fold(record["artist"])] = record
            if record["genreKey"] in by_key:
                entry["hosts"][record["genreKey"]] += 1

    taken_keys = set(by_key)
    new_genres = []
    for folded, entry in sorted(new_labels.items()):
        artists = list(entry["artists"].values())
        if len(artists) < args.min_artists or not entry["hosts"]:
            continue
        hosts = sorted(entry["hosts"].items(), key=lambda kv: (-kv[1], kv[0]))
        total = sum(count for _, count in hosts)
        x = round(sum(by_key[k]["x"] * c for k, c in hosts) / total)
        y = round(sum(by_key[k]["y"] * c for k, c in hosts) / total)
        popularity = sum(a.get("popularity", 0) for a in artists) / len(artists)
        key = slugify(entry["display"], taken_keys)
        taken_keys.add(key)

        rows = []
        for artist in artists:
            name = artist["artist"].strip()
            ax, ay = place(f"{key}|{name}", [])
            rows.append({
                "name": name,
                "x": ax,
                "y": ay,
                "color": by_key[hosts[0][0]].get("color", ""),
                "size": size_for(artist.get("popularity", 0), DEFAULT_SIZE_RANGE),
                "preview": None,
                "example": None,
                "spotify": artist.get("spotifyID"),
            })
        new_genres.append({
            "row": {
                "name": entry["display"],
                "key": key,
                "x": x,
                "y": y,
                "color": by_key[hosts[0][0]].get("color", ""),
                "size": size_for(popularity, DEFAULT_SIZE_RANGE),
                "preview": None,
                "example": None,
            },
            "artists": rows,
        })

    # ---- 3. Report, then write. -------------------------------------------
    print(f"  {added_artists} artist(s) into {touched_shards} existing genre(s)")
    below_cut = len(new_labels) - len(new_genres)
    print(f"  {len(new_genres)} genre(s) new to the map"
          + (f" ({below_cut} more unknown label(s) under --min-artists {args.min_artists})"
             if below_cut > 0 else ""))
    if missing_shards:
        print(f"  ! {len(missing_shards)} record group(s) name a genre with no shard "
              f"({', '.join(missing_shards[:5])}…) — skipped")
    if args.dry_run:
        print("\nDry run — nothing written.")
        return 0
    if not added_artists and not new_genres:
        print("\nNothing to write.")
        return 0

    for path, payload in pending_writes.items():
        write_shard(path, payload)
    for entry in new_genres:
        write_shard(shards / f"{entry['row']['key']}.z",
                    {"name": entry["row"]["name"], "artists": entry["artists"]})
        index.append(entry["row"])
    index_path.write_bytes(compact_json(index))

    meta_path = data / "meta.json"
    meta = json.loads(meta_path.read_bytes()) if meta_path.exists() else {"version": 1}
    merged = meta.get("merged", [])
    merged.append({
        "date": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        "artistsAdded": added_artists,
        "genresAdded": len(new_genres),
        "source": "in-app Spotify harvest (positions are synthetic)",
    })
    meta["merged"] = merged
    meta["genres"] = len(index)
    meta_path.write_bytes(json.dumps(meta, indent=2).encode())

    print(f"\nWrote {len(pending_writes) + len(new_genres)} shard(s), genres.json ({len(index)} genres), meta.json.")
    print("Now re-run:  python3 tools/everynoise/build_artist_index.py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
