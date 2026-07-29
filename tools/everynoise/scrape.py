#!/usr/bin/env python3
"""One-time scrape of everynoise.com for the app's bundled Every Noise browser.

A modernized descendant of https://github.com/laffan/everynoise-scrape (2016,
Python 2, artist names only). This version captures what the in-app browser
actually needs: every genre's *position on the map* (the site's top/left
pixels), its color, font size (the site's popularity cue), its example-track
preview URL, and — from each genre's own page — the constituent artists with
the same positional/preview data. No Spotify API key is involved anywhere:
the 30-second preview URLs are embedded in the site's HTML.

Output (default: OfflineListen/EveryNoiseData/ so the app bundles it):
  meta.json         scrape date, counts, canvas extents
  genres.json       the genre index, in the site's item order (the map/scan
                    order), uncompressed — read once at startup
  genres/<key>.z    one shard per genre: its artist list as JSON, compressed
                    with raw DEFLATE (zlib wbits=-15), which iOS's
                    Compression framework reads natively — decompressed
                    lazily, one genre at a time, so the app never holds the
                    whole dataset in memory

The site froze in late 2024 (Spotify revoked the API access that fed it), so
this really is a one-time scrape of static data.

Usage:
  python3 scrape.py                 # full scrape (~6,300 pages, 20-60 min)
  python3 scrape.py --limit 5      # smoke test: index + first 5 genre pages
  python3 scrape.py --force        # refetch shards that already exist
Resume is automatic: an interrupted run skips shards already on disk.
"""

import argparse
import html
import json
import re
import sys
import threading
import time
import urllib.error
import urllib.request
import zlib
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path

BASE = "https://everynoise.com/"
INDEX_PAGE = "engenremap.html"
USER_AGENT = "offline-listen-everynoise-scrape/1.0 (one-time archival scrape)"

# ---------------------------------------------------------------------------
# Parsing. The site's HTML is machine-generated and extremely regular, but
# old-school: attributes are quoted only when they contain spaces
# (id=item0, href=engenremap-pop.html, but title="e.g. ...").  Every mapped
# entity — genre on the index, artist on a genre page — is a
# <div id=itemN ... class="genre scanme" ...>label<a ... href=...>» </a></div>
# ---------------------------------------------------------------------------

ITEM_RE = re.compile(r"<div\s+id=(?:\"item(\d+)\"|item(\d+))(.*?)</div>", re.DOTALL)


def _attr(tag: str, name: str):
    """Pull attribute `name` out of an open-tag string, quoted or not."""
    m = re.search(name + r"\s*=\s*\"([^\"]*)\"", tag)
    if not m:
        m = re.search(name + r"\s*=\s*'([^']*)'", tag)
    if not m:
        m = re.search(name + r"\s*=\s*([^\s>]+)", tag)
    return html.unescape(m.group(1)) if m else None


def _style_field(style: str, prop: str):
    m = re.search(prop + r"\s*:\s*([^;]+)", style)
    return m.group(1).strip() if m else None


def parse_items(page_html: str):
    """Every `genre scanme` div on a page → dict. Genres and artists share the
    layout; the embedded link tells them apart (engenremap-*.html vs
    artistprofile.cgi?id=...)."""
    items = []
    for m in ITEM_RE.finditer(page_html):
        item_id = int(m.group(1) or m.group(2))
        rest = m.group(3)
        gt = rest.find(">")
        if gt < 0:
            continue
        open_tag, inner = rest[:gt], rest[gt + 1:]
        if "scanme" not in (_attr(open_tag, "class") or ""):
            continue

        style = _attr(open_tag, "style") or ""
        top = _style_field(style, "top")
        left = _style_field(style, "left")
        if top is None or left is None:
            continue  # not placed on the map (sidebar furniture)

        # Label text = inner up to the nav link; the link's href classifies.
        link = re.search(r"<a\s+([^>]*)>", inner)
        href = _attr(link.group(1), "href") if link else None
        label = inner[:link.start()] if link else inner
        label = html.unescape(re.sub(r"<[^>]*>", "", label)).strip()
        if not label:
            continue

        size = _style_field(style, "font-size") or "100%"
        example = _attr(open_tag, "title")
        if example:
            example = re.sub(r"^e\.g\.\s*", "", example).strip() or None
        preview = _attr(open_tag, "preview_url") or None
        if preview and not preview.startswith("http"):
            preview = None

        items.append({
            "id": item_id,
            "name": label,
            "x": int(re.sub(r"[^0-9-]", "", left) or 0),
            "y": int(re.sub(r"[^0-9-]", "", top) or 0),
            "color": (_style_field(style, "color") or "#ffffff").lower(),
            "size": int(re.sub(r"[^0-9]", "", size) or 100),
            "preview": preview,
            "example": example,
            "href": href,
        })
    items.sort(key=lambda i: i["id"])
    return items


def genre_key(href: str) -> str:
    """engenremap-deephouse.html → deephouse (the shard filename / genre id)."""
    m = re.match(r"engenremap-(.+)\.html$", href or "")
    return m.group(1) if m else ""


def split_genres_artists(items):
    genres, artists = [], []
    for it in items:
        href = it.pop("href") or ""
        if href.startswith("engenremap-"):
            it["key"] = genre_key(href)
            genres.append(it)
        elif "artistprofile" in href:
            m = re.search(r"[?&]id=([A-Za-z0-9]+)", href)
            it["spotify"] = m.group(1) if m else None
            artists.append(it)
    return genres, artists


# ---------------------------------------------------------------------------
# Fetching: polite, retried, rate-limited across worker threads.
# ---------------------------------------------------------------------------

class RateLimiter:
    def __init__(self, min_interval: float):
        self.min_interval = min_interval
        self.lock = threading.Lock()
        self.next_at = 0.0

    def wait(self):
        with self.lock:
            now = time.monotonic()
            delay = max(0.0, self.next_at - now)
            self.next_at = max(now, self.next_at) + self.min_interval
        if delay > 0:
            time.sleep(delay)


def fetch(url: str, limiter: RateLimiter, retries: int = 4) -> str:
    last = None
    for attempt in range(retries):
        limiter.wait()
        try:
            req = urllib.request.Request(url, headers={
                "User-Agent": USER_AGENT,
                "Accept-Encoding": "identity",
            })
            with urllib.request.urlopen(req, timeout=60) as resp:
                return resp.read().decode("utf-8", errors="replace")
        except (urllib.error.URLError, OSError) as exc:
            last = exc
            time.sleep(2 ** attempt)
    raise RuntimeError(f"failed after {retries} tries: {url}: {last}")


# ---------------------------------------------------------------------------
# Output.
# ---------------------------------------------------------------------------

def compact_json(obj) -> bytes:
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def deflate(data: bytes) -> bytes:
    co = zlib.compressobj(9, zlib.DEFLATED, -15)  # raw DEFLATE, no zlib header
    return co.compress(data) + co.flush()


def write_shard(path: Path, genre: dict, artists: list):
    payload = {
        "name": genre["name"],
        "artists": [{k: a[k] for k in ("name", "x", "y", "color", "size", "preview", "spotify")}
                    for a in artists],
    }
    path.write_bytes(deflate(compact_json(payload)))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    default_out = Path(__file__).resolve().parents[2] / "OfflineListen" / "EveryNoiseData"
    ap.add_argument("--out", type=Path, default=default_out, help=f"output dir (default {default_out})")
    ap.add_argument("--base", default=BASE, help="site base URL")
    ap.add_argument("--limit", type=int, default=0, help="scrape only the first N genre pages (smoke test)")
    ap.add_argument("--workers", type=int, default=3, help="concurrent fetches (default 3)")
    ap.add_argument("--interval", type=float, default=0.25, help="min seconds between request starts (default 0.25)")
    ap.add_argument("--force", action="store_true", help="refetch shards that already exist")
    args = ap.parse_args()

    out: Path = args.out
    shards = out / "genres"
    shards.mkdir(parents=True, exist_ok=True)
    limiter = RateLimiter(args.interval)

    print(f"Fetching genre index {args.base}{INDEX_PAGE} …", flush=True)
    index_html = fetch(args.base + INDEX_PAGE, limiter)
    genres, _ = split_genres_artists(parse_items(index_html))
    if not genres:
        sys.exit("No genres found on the index page — the site's HTML may have "
                 "changed. Inspect it and adjust parse_items().")

    # De-collide keys defensively (the site itself never collides).
    seen = {}
    for g in genres:
        base_key = g["key"] or re.sub(r"[^a-z0-9]", "", g["name"].lower()) or "genre"
        n = seen.get(base_key, 0)
        seen[base_key] = n + 1
        g["key"] = base_key if n == 0 else f"{base_key}-{n + 1}"

    print(f"  {len(genres)} genres on the map")
    todo = genres[: args.limit] if args.limit else genres

    stats = {"artists": 0, "empty": 0, "skipped": 0, "failed": []}
    lock = threading.Lock()

    def scrape_genre(g):
        shard = shards / (g["key"] + ".z")
        if shard.exists() and not args.force:
            with lock:
                stats["skipped"] += 1
            return
        page = fetch(args.base + f"engenremap-{g['key']}.html", limiter)
        _, artists = split_genres_artists(parse_items(page))
        write_shard(shard, g, artists)
        with lock:
            stats["artists"] += len(artists)
            if not artists:
                stats["empty"] += 1

    done = 0
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = {pool.submit(scrape_genre, g): g for g in todo}
        for fut in as_completed(futures):
            g = futures[fut]
            done += 1
            try:
                fut.result()
            except Exception as exc:
                stats["failed"].append(g["key"])
                print(f"  ! {g['name']}: {exc}", flush=True)
            if done % 100 == 0 or done == len(todo):
                print(f"  {done}/{len(todo)} genre pages", flush=True)

    # The bundled index drops the per-item id (array order carries it) and
    # keeps only genres whose shard exists, so the app never 404s on a tap.
    index = [{k: g[k] for k in ("name", "key", "x", "y", "color", "size", "preview", "example")}
             for g in genres if (shards / (g["key"] + ".z")).exists()]
    (out / "genres.json").write_bytes(compact_json(index))

    meta = {
        "version": 1,
        "source": args.base,
        "scraped": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        "genres": len(index),
        "canvas": {"w": max((g["x"] for g in index), default=0),
                   "h": max((g["y"] for g in index), default=0)},
        "partial": bool(args.limit) or bool(stats["failed"]),
    }
    (out / "meta.json").write_bytes(json.dumps(meta, indent=2).encode())

    size = sum(f.stat().st_size for f in shards.glob("*.z"))
    print(f"\nDone. {len(index)} genres indexed, {stats['artists']} artist rows "
          f"({stats['skipped']} shards already present, {stats['empty']} empty), "
          f"shards total {size / 1e6:.1f} MB → {out}")
    if stats["failed"]:
        print(f"FAILED ({len(stats['failed'])}): {', '.join(stats['failed'][:20])}"
              + (" …" if len(stats["failed"]) > 20 else "")
              + "\nRe-run to retry just these (existing shards are skipped).")


if __name__ == "__main__":
    main()
