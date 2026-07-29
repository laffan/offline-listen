#!/usr/bin/env python3
"""Offline check of scrape.py's parser against fixture HTML that mirrors the
site's real markup quirks: unquoted attributes (id=item0, href=engenremap-...),
quoted ones where values contain spaces, single-quoted titles, unicode names,
entries with no preview_url, and sidebar furniture without map positions.

Run: python3 test_parser.py   (no network, no dependencies)
"""

import json
import zlib
from pathlib import Path

from scrape import parse_items, split_genres_artists, deflate

FIXTURES = Path(__file__).parent / "fixtures"


def test_index():
    items = parse_items((FIXTURES / "engenremap.html").read_text())
    genres, artists = split_genres_artists(items)
    assert artists == [], "index page should classify everything as genres"
    assert [g["name"] for g in genres] == ["pop", "j-pop", "musique concrète", "deep house"]

    pop = genres[0]
    assert pop["key"] == "pop"
    assert (pop["x"], pop["y"]) == (776, 7290)
    assert pop["color"] == "#d05e5a"
    assert pop["size"] == 101
    assert pop["preview"] == "https://p.scdn.co/mp3-preview/97b19fe4b0efc26268cf4d84486cea7c1b0ab0a2"
    assert pop["example"] == 'Dua Lipa "Houdini"'  # "e.g. " prefix stripped

    jpop = genres[1]
    assert jpop["key"] == "jpop"
    assert jpop["example"] == 'YOASOBI "アイドル"'

    concrete = genres[2]
    assert concrete["key"] == "musiqueconcrete"
    assert concrete["preview"] is None, "empty preview_url should read as none"

    deep = genres[3]
    assert deep["size"] == 100, "missing font-size defaults to 100%"


def test_genre_page():
    items = parse_items((FIXTURES / "engenremap-jpop.html").read_text())
    genres, artists = split_genres_artists(items)
    assert [g["name"] for g in genres] == ["city pop"], "sidebar genre link on a genre page stays a genre"
    assert [a["name"] for a in artists] == ["YOASOBI", "Kenshi Yonezu", "Ado & Friends"]

    yoasobi = artists[0]
    assert (yoasobi["x"], yoasobi["y"]) == (337, 240)
    assert yoasobi["spotify"] == "64tJ2EAv1R6UaZqc4iOCyj"
    assert yoasobi["preview"].startswith("https://p.scdn.co/")
    assert yoasobi["example"] == 'YOASOBI "アイドル"'

    assert artists[1]["preview"] is None, "artist without preview_url"
    assert artists[2]["name"] == "Ado & Friends", "entities in labels should unescape"


def test_deflate_roundtrip():
    payload = json.dumps({"name": "jpop", "artists": []}).encode()
    packed = deflate(payload)
    assert zlib.decompress(packed, -15) == payload, "shards must be raw DEFLATE (wbits=-15)"


if __name__ == "__main__":
    test_index()
    test_genre_page()
    test_deflate_roundtrip()
    print("parser fixtures OK")
