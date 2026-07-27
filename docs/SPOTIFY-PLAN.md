# Plan: Spotify links in the Download tab

*Status: **implemented**. Paste a Spotify track, album, playlist or artist link
into the Download field and it resolves to Spotify metadata, matches each track
to a YouTube video, and hands the result to the download pipeline that already
exists.*

## What this is not

It isn't a [spotdl](https://github.com/spotDL/spotify-downloader) integration.
spotdl can't run in this app: its converter shells out to an FFmpeg **binary**
(`subprocess.Popen` / `asyncio.create_subprocess_exec` in
`spotdl/utils/ffmpeg.py`, and `Downloader.__init__` raises
`DownloaderError("ffmpeg is not installed")` without one), and an iOS app can't
exec a bundled executable. What landed is the useful ~200 lines of spotdl
reimplemented natively on top of stages the app already has.

Nothing about downloading, conversion, tagging or sync changed. A resolved
Spotify track becomes an ordinary `youtube.com/watch?v=…` URL and inherits the
existing audio/video handling, AVFoundation conversion, chapter capture and AI
organization.

## Constraints it was built under

- **No new Swift package dependencies** — `URLSession`, `Codable`, and the
  helpers already in the project.
- **The Spotify path never touches Python.** `PythonGate`, yt-dlp and
  `PlaylistResolver` are for YouTube. Spotify resolution is plain HTTPS, so a
  pasted Spotify link works on a fresh install, before the yt-dlp module has
  ever been fetched. Only the per-track *downloads* it spawns take the normal
  extractor path.
- **No FFmpeg, no new conversion code.**
- **No regressions.** An http(s) link, a YouTube playlist link, a mixed blob and
  free text all behave exactly as before.

## Deliberate non-goals

- **User OAuth.** Authorization is **Client Credentials** only — the app signs
  in as itself, not as the user — so there are no liked songs, no private
  playlists and no "saved" equivalent. A 404 on a playlist most likely means
  it's private, and the error says so rather than trying to work around it.
- Podcast episodes and audiobooks (skipped in playlists, rejected as a
  reference type).
- Lyrics, `.spotdl` file import, spotdl config compatibility.

## The pieces

| File | Role |
|------|------|
| `SpotifyRef.swift` | Parses `spotify:` URIs and `open.spotify.com` links into a `(kind, id)` pair; resolves `spotify.link` short links by redirect. |
| `SpotifyClient.swift` | Client Credentials token (cached, refreshed on expiry and once on any 401) + the four metadata reads. |
| `SpotifySettings.swift` | `SpotifySettingsStore` — Keychain-backed client id/secret, mirroring `AISettingsStore`. |
| `SpotifyResolver.swift` | Metadata → `ResolvedPlaylist`, including the YouTube matching. |

Everything downstream is reused as-is: `PlaylistEntry` / `ResolvedPlaylist`,
`requestPlaylistSelection` and its popup, `folder(named:fallback:)`,
`enqueue(urlString:mode:folderID:)`, `DownloadJob.isPlaylist`.

## Phase 1 — reference parsing

`SpotifyRef.parse` is synchronous and network-free (the Download field asks "is
this a link?" on every keystroke) and handles:

```
spotify:track:0V3wPSX9ygBnCm8psDIegu
https://open.spotify.com/track/0V3wPSX9ygBnCm8psDIegu
https://open.spotify.com/track/0V3wPSX9ygBnCm8psDIegu?si=abc123
https://open.spotify.com/intl-de/track/0V3wPSX9ygBnCm8psDIegu
https://spotify.link/xxxxxx                     (redirect resolved later)
spotify:user:someone:playlist:37i9dQZF1DXcBWIGoYBM5M
```

- `/intl-xx/` segments are dropped; the query string is ignored entirely (`si`
  is a share token).
- Ids are validated **loosely** — ASCII alphanumeric, 20–24 characters — so a
  future change of length doesn't break parsing while "playlists" or "search"
  are still rejected.
- `spotify.link` can only be read by following its redirect, so it parses as
  `.shortLink` and is resolved on the job's async path, never in the
  synchronous predicate.
- `show`, `episode`, `audiobook`, `user`, … parse as `.unsupported` rather than
  nil, so they read as a *link* and fail with "unsupported reference type"
  instead of silently becoming a YouTube search.

### Wiring the input field

`isQueueableURL` was left alone — `enqueue(urlString:)` relies on it meaning "a
real http(s) URL", and a `spotify:` URI reaching `enqueue` would fail every
download with `invalidURL`. Instead:

1. `DownloadManager.isDownloadableToken(_:)` = `isQueueableURL || parses as Spotify`.
2. `DownloadView.isSearch` tests that, so a pasted URI reads as a link and the
   button says **Download**.
3. `enqueueLinks(from:mode:)` checks `SpotifyRef.parse` **before**
   `PlaylistURL.isPlaylistURL` (an `open.spotify.com` link is also a well-formed
   http(s) URL). Everything else falls through unchanged.

## Phase 2 — credentials

Settings ▸ **Spotify**: client id + secret, **Verify & Save**, stored in the
Keychain on success only — the same shape as the AI section. `verify()` mints a
token and makes one cheap metadata call; a wrong secret is reported as
"credentials rejected", not a network error. The bearer token is cached with its
`expires_in` (keyed by client id) and refreshed on expiry and once on any 401.
Until credentials are saved, a pasted Spotify link produces a visible **failed**
job pointing at Settings — never a silent no-op.

## Phase 3 — metadata

| Kind | Endpoints |
|------|-----------|
| track | `/tracks/{id}` |
| album | `/albums/{id}` → paged `next`, then `/tracks?ids=` in batches of 50 |
| playlist | `/playlists/{id}` → paged `next` |
| artist | `/artists/{id}` + `/artists/{id}/top-tracks?market=…` |

Only the needed fields are modelled, with explicit `CodingKeys`. The gotchas
that were handled:

- **Pagination.** Album tracks page at 50, playlist tracks at 100; `next` is
  followed to nil. (A 200-track playlist silently truncating to 100 was the
  most likely bug here.)
- **Playlist items are wrapped** and can be null, an episode, or a local file.
  Every wire field is optional so one odd item can't fail the whole page's
  decode; items are then filtered on `type == "track"` and a non-null id, and
  the skipped counts are logged.
- **Album tracks are simplified objects** — no album name, no `external_ids.isrc`
  — so the ids are re-read through `/tracks?ids=` (one extra request per 50) to
  recover the ISRC. If that batch call fails, the simplified objects are used
  with the album name carried down.
- **`market` is required** on top-tracks: the device region, US fallback.

## Phase 4 — matching tracks to YouTube

Per track, mirroring spotdl's strategy (`spotdl/providers/audio/base.py`)
without its `rapidfuzz` scoring:

1. **ISRC first.** An ISRC identifies a specific *recording*, so a hit is almost
   always the right master — including where a title search would land on a live
   take, a remix or a lyric-video re-upload.
2. **Fall back to `"{primary artist} - {title}"`** through
   `YouTubeSearchResolver`, the same scraper the AI Discovery and Discography
   sources use, taking the first result whose length is within **15s** of
   Spotify's `duration_ms`.

One deviation from the brief, in the same spirit: the ISRC hit is *also*
duration-checked when the results page exposes a length. A YouTube search always
returns something, so an ISRC that nothing has tagged would otherwise hand back
an unrelated video with full confidence. A true ISRC match is the same recording
and therefore the same length, so the gate can only reject false positives.
Feeding it needed one small addition — `YouTubeSearchResult.durationSeconds`,
parsed from the renderer's `lengthText`; results with no exposed length pass the
gate rather than being rejected on missing information.

Every resolution logs at `.debug` — the Spotify title, whether ISRC or title
search matched it, and the chosen video's title — because a wrong track in the
library is the failure mode users actually hit, and the Log is how they'll
diagnose it.

**Cost is bounded** the way a Discography refresh is: at most **200** tracks per
paste (the remainder dropped and logged), resolved **5 at a time** — serial is
far too slow for a long playlist, and 200 at once gets throttled.

## Phase 5 — job flow

- A **single track** resolves and enqueues one ordinary download: no popup, no
  folder. The job's title becomes `"{artist} - {title}"` as soon as metadata
  lands, so the queue row is readable while the search runs.
- An **album, playlist or artist** builds a `ResolvedPlaylist` and goes through
  the *existing* flow — `requestPlaylistSelection` → popup →
  `folder(named:fallback:)` → one `enqueue(…, folderID:)` per pick, in Spotify
  order — including the "queued N of M into a folder" success log and the
  reuse-an-existing-folder behaviour on re-paste.
- The resolver branch is chosen by **reference kind**, never by calling
  `PlaylistResolver.resolve` (which would drive yt-dlp through the Python gate).
- The queue row counts the matching off (`Resolving 42 of 137…`) via
  `DownloadJob.progressNote`, so a large playlist doesn't look hung.
- Cancellation is honoured mid-resolution: the matching loop checks
  `Task.isCancelled` and the job goes to `.cancelled` with nothing queued.

Resolution is best-effort by nature: a track with no YouTube match drops out
with a warning and the rest of the playlist still comes through — it never
fails the whole job.

## Phase 6 — share extension

`ShareViewController` already filters attachments to http(s) URLs, so a link
shared from the Spotify app passes untouched. The one change was on the app
side: `importShared()` drained into `enqueue(urlString:)`, which would have
downloaded a shared album as a single item. It now goes through
`enqueueLinks(from:)`, so a shared *list* — Spotify album or YouTube playlist —
gets the selection popup and its own folder, exactly as pasting it would.

## Where to be careful

- The single most likely regression is `isSearch` / `isQueueableURL`. Changing
  the wrong one makes `enqueue` accept a `spotify:` URI and fail every download
  with `invalidURL`.
- The second is taking the Python gate on the Spotify path, which would make
  Spotify links depend on the yt-dlp module having been fetched. They don't.
