# Offline Listen

A SwiftUI iPhone app that downloads the audio from a video URL, saves it to the
device, and plays it back offline — including in the background with the phone
locked.

> **Personal-use tool.** Downloading from sites like YouTube may conflict with
> their Terms of Service and with copyright. Only download content you own or
> have the right to, and use this responsibly.

## What's here

Three screens (tabs):

1. **Download** — paste one or more URLs (whitespace/line-break separated; any
   http(s) link is queued and the rest of a pasted blob is skipped), choose
   **Audio** or **Video** (default Audio), watch the queue. Links from **any site
   yt-dlp supports** work — YouTube, Vimeo, SoundCloud and ~hundreds more — not
   just YouTube. Swipe a row for **Cancel** (active/queued), **Restart**, or
   **Clear**; tap a finished row to play it.

   **Playlists.** Paste a **YouTube playlist** link — either the dedicated
   `…/playlist?list=…` page or a `watch?v=…&list=…` link opened from inside a
   playlist — and the app resolves its entries and shows a **selection popup**
   listing every video. Everything is checked by default, so **Download** grabs
   the whole list in one tap; or check off just the ones you want (a
   **Select All / Deselect All** toggle is in the header). Confirming creates a
   **folder named after the playlist** and queues the chosen entries into it (in
   playlist order, using the same Audio/Video mode); cancelling — or dismissing
   the popup — downloads nothing. A playlist row sits in the queue while it
   resolves and while the popup is open, then reports how many downloads it
   spawned. Auto-generated **mixes/radios** (`RD…` list ids) and the auth-only
   **Watch Later** / **Liked** lists are treated as ordinary single-video links,
   not playlists. Resolving the entry list uses the on-device yt-dlp module, so —
   like chapter capture — it works only once that module has been fetched by a
   prior download.
2. **Library** — downloaded tracks; tap to play. A **filter** (All / Music /
   Podcasts / Video) sits directly beneath the **Tracks** header. Swipe **left**
   for Delete/Share/Archive (and bulk versions via **Select**); swipe **right**
   on an audio track to classify it **Song** or **Podcast**. Songs start from the
   beginning; podcasts (mic icon) and videos (film icon) resume where you left
   off and show a progress bar. A track you haven't listened to yet shows a
   **green** icon. Video tracks play with picture on the Player screen. Archived
   tracks (and archived folders) live in the **Archive**, pinned to the bottom of
   the folder list.

   **Autoplay.** When a track finishes, playback advances to the next track in
   the same list and keeps going to the end — it doesn't loop. In the
   **auto-aggregated** lists (the unfiled root and the Inbox), where media types
   are mixed together, autoplay **stays within the media type** you started: pick
   a song and only songs play on (podcasts and videos are skipped until the next
   song or the list ends), and likewise for podcasts and videos. A **folder is a
   curated playlist**, though, so it **plays straight through in list order**
   regardless of type — tap any track and the whole folder plays in sequence.

   **Chapters.** Tracks that carry YouTube chapter markers show an **arrow**
   after the title, set off by a left border so it reads as a button distinct
   from the row: tapping the **title** plays the track normally, tapping the
   **arrow** opens a list of chapters to jump to. Touch-and-hold such a track
   for **Break Chapters into Playlist**, which exports one file per chapter into
   a new folder named after the track and then asks whether to delete the
   original — turning a chaptered recording into a proper playlist. The
   chapter list also highlights the chapter currently playing.

   **Folders** organize the library, under a **Folders** header (mirroring the
   Tracks one): an **Inbox** pinned to the top collects every track you haven't
   listened to yet (starting playback — or a **Mark Played** swipe — clears it
   from the Inbox), user folders sit below it, and the **Archive** is pinned to
   the bottom. Create folders with the toolbar's folder button; move tracks in
   via touch-and-hold → **Move to Folder** (or the bulk Select menu). The Inbox
   is itself a move target — moving a track there returns it to unlistened.
   Touch-and-hold also offers **Edit Metadata**, a modal for hand-editing the
   track **title and artist** (handy when AI Organize doesn't get it quite
   right), with **Reset to Original Title** to restore the download title. Swipe
   a folder row for its slide menu: **Delete** (the folder only — its tracks
   return to the library),
   **Rename**, and **Archive** (move the whole folder, tracks and all, into the
   Archive). To **reorder** the tracks inside a folder, use the **Reorder**
   button in the folder's own screen.

   The folder list itself sorts two ways, chosen with the toggle on the right of
   the **Folders** header: **Name** (alphabetical) or **User Order**. In User
   Order you set the sequence by hand — **touch and hold a folder and drag** it
   into place; the order persists to `folders.json`. Folders persist to
   `Documents/folders.json`.
3. **Player** — artwork, scrubber, play/pause, skip, next/previous — the same
   control suite for audio and video. Video is edge-to-edge in portrait and
   goes fullscreen automatically when the phone rotates to landscape (tap the
   picture to toggle the floating controls). Drives the lock screen and
   Control Center. For a chaptered track, small **dots** sit along the scrubber
   at each chapter's start and the **current chapter title** shows on its own
   line beneath the title/artist, updating as playback crosses a marker.
4. **Settings** — AI configuration on top, the **Log** as a section beneath it.
   - **AI model & API key.** Pick **Haiku** (fast/cheap) or **Sonnet** (more
     capable), paste an Anthropic API key, and **Verify & Save** — the key is
     checked against the API and, on success, stored in the device **Keychain**
     so it persists between sessions. Once a key is saved, an **AI assist with
     organization** toggle appears.
   - **Log** — a row that opens the timestamped, copyable stream of every
     pipeline step (queue, yt-dlp, conversion, AI) with light colour coding, for
     diagnosing downloads.

### AI-assisted organization

With a verified key and **AI assist** turned on, the AI lightweight-organizes
your library via Anthropic's Messages API:

- **On download**, each finished audio track is sent to the chosen model with its
  **title and duration**. The model decides **music vs. podcast** (auto-setting
  the track's kind, so the Library filter and resume/lock-screen behaviour follow
  suit) and, for music, extracts a **clean track title and artist** from the noisy
  YouTube title (dropping "Official Video", channel names, brackets, view counts,
  …). Library rows already show the title prominently with the artist in smaller,
  lower-opacity text beneath it — now that line is populated.
- **On demand**, any already-downloaded audio track gets an **AI Organize** entry
  in its touch-and-hold menu (shown only when a key is configured), so older
  tracks can be tidied up too.

A title the AI rewrites records the original, so **Edit Metadata → Reset to
Original Title** still restores the download title. AI work is best-effort and runs off the
download queue — failures are logged, never fatal. No key, no AI: everything else
is unchanged.

### Pipeline

```
URL  ──►  extractor (native / yt-dlp)  ──►  chunked download  ──►  Documents/  ──►  AVPlayer
         best audio-only or muxed mp4       (+ audio extract       local file       audio/video
                                             for audio mode)                         playback
```

### Source layout (`OfflineListen/`)

| File | Role |
|------|------|
| `OfflineListenApp.swift` | App entry; wires up the shared stores. |
| `Models.swift` | `Track`, `Folder`, `DownloadMode`, `LibraryFilter`, `FolderSort`, paths, helpers. |
| `LibraryStore.swift` | Persists the library to `Documents/library.json` and folders to `Documents/folders.json`. |
| `DownloadManager.swift` | Serial download queue + `DownloadJob`. |
| `YouTubeExtractor.swift` | `MediaExtractor` protocol + YoutubeDL-iOS impl + a mock. |
| `YouTubeKitExtractor.swift` | Native-Swift (b5i/YouTubeKit) primary extractor. |
| `CompositeExtractor.swift` | Tries the native extractor, falls back to yt-dlp. |
| `AudioStreamDownloader.swift` | Shared chunked byte-range stream downloader. |
| `VideoAudioExtractor.swift` | Extracts audio from a muxed video via AVFoundation. |
| `ChapterFetcher.swift` | Best-effort capture of YouTube chapter markers via the on-device yt-dlp module. |
| `PlaylistResolver.swift` | Detects playlist links and flat-resolves their entries (on-device yt-dlp) so a playlist downloads into a folder. |
| `ChapterSplitter.swift` | Exports one file per chapter (AVFoundation) for "Break Chapters into Playlist". |
| `VideoMerger.swift` | Muxes a video-only + audio-only stream into one MP4. |
| `PlaybackManager.swift` | `AVPlayer` engine (audio + video), audio session, lock screen. |
| `Logger.swift` | `LogStore` — thread-safe, app-wide log sink. |
| `AISettings.swift` | `AISettingsStore` (model/key/assist, Keychain-backed), `AIModel`, `Keychain` helper. |
| `AnthropicClient.swift` | Minimal Anthropic Messages API client (verify + single-shot completion) over URLSession. |
| `AIOrganizer.swift` | Builds the prompt, calls the API, writes music/podcast + clean metadata back to the library. |
| `*View.swift` | The four SwiftUI screens (Download, Library, Player, Settings — which embeds the Log). |
| `FolderView.swift` | Folder detail (tap-to-play, reorder) and Inbox screens. |
| `WatchFolderView.swift` | The phone's **Watch** virtual-folder screen (manage what's been sent to the watch). |
| `WatchManifest.swift` | Wire format shared by the iPhone and watch targets (the sync manifest, the remote-control `RemoteNowPlaying`/`RemoteCommand` types, + WC keys). |
| `WatchSync.swift` | Phone-side WatchConnectivity bridge: pushes the manifest + audio files, handles the watch's "Clear all". |

The companion watch app lives under `OfflineListenWatch/` (see
[Companion Apple Watch app](#companion-apple-watch-app)).

The extraction step is isolated behind a `MediaExtractor` seam (a mock
implementation is included), so adapting to a library API change touches one
file and the UI can be exercised with no native dependency.

## Companion Apple Watch app

A bundled **watchOS app** (`OfflineListenWatch/`) lets you push Music and Podcast
tracks to your Apple Watch and listen **offline** — on a run, away from the phone.
It's **audio only** (video isn't sent to the watch).

**Three panes** (swipe between them):

1. **List** — the tracks and playlists that have been pushed to the watch.
   Playlists you sent as a folder stay grouped; loose tracks sit below. A row
   that's still transferring shows its live **Syncing… N%** and isn't tappable
   yet; once the file lands it becomes playable. Tap a track to play it (and jump
   to Listen).
2. **Listen** — now-playing title/artist, a progress bar, and transport buttons:
   **previous / play-pause / next** for songs, **jump-back-15 / play-pause /
   jump-forward-30** for podcasts (mirroring the lock screen). The **Digital Crown
   adjusts volume** while this pane is showing. Podcasts resume where you left
   off, and their playhead **syncs both ways** with the phone — listen on one,
   pick up where you stopped on the other.

   **Remote for the phone.** When the **phone** is playing a track and the watch
   isn't playing its own audio, this same pane repurposes itself into a remote
   control: a **"Controlling iPhone"** banner above the phone's now-playing
   title/artist and progress, with the identical transport buttons now driving
   the phone instead of the watch. The progress bar advances on the watch between
   updates, play/pause responds instantly, and podcasts get the 15s/30s jumps
   just as on the lock screen. The moment you start a track from the watch's own
   List, local playback takes over and the remote steps aside.
3. **Settings** — an **Output** preference (**Bluetooth** / **Speaker**) and a
   **Clear all Tracks** button (with a confirmation step) that deletes every
   saved file on the watch. (watchOS routes audio at the system level — Bluetooth
   when connected, otherwise the built-in speaker — so the preference steers the
   system route rather than forcing a port.)

### Sending from the phone

Touch-and-hold a **track** (or a **playlist/folder**) in the library and choose
**Send to Watch**. Sending **never changes the item's place** in your phone
library — it only flags it for the watch. A **Watch** folder appears directly
below the **Inbox**: a *virtual* folder (its tracks really live wherever they
normally do) for managing what's on the watch. There it's deliberately spare —
tap to play, and a single swipe-left action, **Remove from Watch** (no
song/podcast swipe). Touch-and-hold a track already on the watch and the menu
shows **Remove from Watch** instead.

The phone is the **source of truth**, and the link runs both ways: tapping
**Clear all Tracks** on the watch empties the phone's **Watch** folder to match,
and removing a track from the Watch folder deletes it from the watch on the next
sync.

### How the sync works

Transport is **WatchConnectivity** (`WCSession`). The phone pushes the
authoritative set as a JSON **manifest** via `updateApplicationContext` (the watch
renders its List from it and **prunes** any local file no longer listed). Audio
files travel one of two ways:

- **`transferFile`** — the system's background file-transfer API — when the watch
  isn't reachable (so a queued track keeps delivering after you pocket the phone).
- A **resumable stream** over the live message channel when the watch app *is*
  reachable. The phone asks the watch how many bytes of the file it already has
  (the watch keeps a `.part` file) and sends the rest in chunks; if the
  connection drops the next attempt **resumes from that offset** instead of
  restarting. This exists because the system file-transfer channel doesn't
  establish on every device pair (it accepts the transfer but moves no bytes) —
  the resumable stream delivers regardless, as long as the watch app is open.

Whichever path lands the whole file first wins; the other is cancelled. The Watch
folder shows real byte-level progress.

The same channel carries the **remote-control** traffic: while the phone is
playing, it pushes a small now-playing snapshot (`RemoteNowPlaying`) to the watch
on every transition (start / pause / resume / seek / track change), throttling
the playhead-only updates since the watch interpolates locally; the watch sends
back a transport command (`RemoteCommand`) when you tap a button on the remote.
Both ride the live message channel and require no extra setup.

The watch sends a small `clearAll` message
back when you clear it, and mirrors each sync step to the phone's **Log** tab
(`⌚`-prefixed) so the whole exchange is debuggable from one place. The wire format
(`WatchManifest.swift`) is compiled into **both** targets so encode and decode
can't drift — the same trick the Share Extension uses with `SharedInbox.swift`.

> **Tip:** for the fastest, most reliable delivery, **keep the watch app open**
> (the List pane) while syncing — that keeps the watch reachable so the resumable
> stream runs.

### Watch source layout (`OfflineListenWatch/`)

| File | Role |
|------|------|
| `OfflineListenWatchApp.swift` | App entry; wires up the watch stores. |
| `WatchModels.swift` | `WatchTrack` + paths (the watch's own lightweight library). |
| `WatchLibraryStore.swift` | Persists `watch-library.json`; applies the manifest, prunes/ingests files. |
| `WatchConnectivityManager.swift` | Watch-side WC delegate: receives the manifest + files, sends "Clear all". |
| `WatchPlaybackManager.swift` | `AVPlayer` audio engine + Now Playing (the iPhone player's core, audio only); also holds the phone's now-playing for remote mode. |
| `WatchRootView.swift` | The three swipeable panes. |
| `WatchListView.swift` / `WatchListenView.swift` / `WatchSettingsView.swift` | The List / Listen / Settings panes. The Listen pane doubles as the phone **remote** when the phone is playing. |

## Share from other apps

A **Share Extension** lets you send a link straight from Safari, the YouTube
app, etc. into Offline Listen:

1. In another app, tap Share → **Offline Listen**.
2. The extension stashes the URL in the shared App Group container and opens the
   app via the `offlinelisten://` URL scheme.
3. On launch/foreground the app drains the shared URLs and auto-enqueues them as
   M4A downloads (see `SharedInbox` + `importShared()` in `OfflineListenApp`).

The extension does no downloading itself (extensions have a tight memory budget);
it just hands the URL to the app.

### Required Xcode setup for the extension

The project wires up the second target, entitlements, and URL scheme, but
**signing and the App Group must be configured in Xcode** (they can't be set
from source alone):

1. Select each target (**OfflineListen** and **ShareExtension**) →
   *Signing & Capabilities* → set your **Team**.
2. Confirm both targets have the **App Groups** capability with the same group,
   `group.com.offlinelisten.app` (the `.entitlements` files declare it; let
   Xcode register/provision it). If you change the group id, update it in both
   entitlements files and in `SharedInbox.appGroup`.
3. Bundle IDs default to `com.offlinelisten.app` and
   `com.offlinelisten.app.ShareExtension` — change both (keep the extension a
   child of the app id) if those are taken.

### Required Xcode setup for the watch app

The project wires up the **OfflineListenWatch** target, embeds it in the iOS app,
and sets `WKCompanionAppBundleIdentifier`, but **signing must be set in Xcode**:

1. Select the **OfflineListenWatch** target → *Signing & Capabilities* → set your
   **Team** (a watch app needs its own provisioning).
2. The watch bundle id defaults to `com.offlinelisten.app.watchkitapp` (a child
   of the app id). If you changed the app's bundle id, update the watch's to
   match and keep `WKCompanionAppBundleIdentifier` (in `OfflineListenWatch/Info.plist`)
   equal to the **iOS app's** id.
3. The watch target needs **no extra capabilities** — WatchConnectivity requires
   no entitlement, and the watch keeps its library in its own container (so the
   watch entitlements file is intentionally empty).
4. Run the **OfflineListenWatch** scheme on a paired watch (or a paired
   iPhone + Watch Simulator pair) to test the sync end-to-end.

## Setup

Requires **Xcode 15+** and an Apple developer account (free is fine for running
on your own device).

1. Open `OfflineListen.xcodeproj`.
2. Xcode resolves two Swift packages on first open (needs a network connection):
   - **YouTubeKit** — `https://github.com/b5i/YouTubeKit.git` — the native-Swift
     primary extractor.
   - **YoutubeDL-iOS** — `https://github.com/kewlbear/YoutubeDL-iOS.git` — the
     yt-dlp fallback extractor.

   YouTubeKit is pinned **up-to-next-major from 2.8.0** (it's actively
   maintained and tracks YouTube's changes — use Xcode's *Update Package*
   to pull new releases deliberately); YoutubeDL-iOS is pinned to `main`
   (the repo is dormant — the yt-dlp *engine* it downloads at runtime is
   what actually updates). Playback uses Apple's AVFoundation — no
   media-player package.
3. Select the **OfflineListen** scheme and your device (or a Simulator — note
   the on-device yt-dlp download needs network).
4. Set your **Signing Team** under *Signing & Capabilities* and adjust
   `PRODUCT_BUNDLE_IDENTIFIER` (default `com.offlinelisten.app`) if needed.
5. Build & run.

> **First download is slow:** YoutubeDL-iOS fetches the `yt-dlp` Python module
> (tens of MB) on first use, then caches it. A network connection is required
> for that step and for every download; playback is fully offline.

## Background / lock-screen playback (the success criterion)

Three pieces make this work, already configured:

- `UIBackgroundModes = [audio]` in `Info.plist`.
- `AVAudioSession` set to the `.playback` category in `PlaybackManager`.
- `MPNowPlayingInfoCenter` (now-playing metadata **and** an explicit
  `playbackState`, which iOS 13+ needs to reliably surface the controls) +
  `MPRemoteCommandCenter` for the lock-screen transport buttons.

Start a track, lock the phone — audio keeps playing and the controls appear on
the lock screen.

The lock screen / Control Center renders only **three** transport buttons (a
centre play/pause plus two side buttons), and iOS shows *either* the
next/previous-track commands *or* the skip-forward/backward commands — never
both (enabling both makes them conflict and the skip buttons silently fail to
appear). So `PlaybackManager` chooses the side pair **per track** in
`updateTransportButtons()`: **songs and videos** get **next/previous-track**,
while **podcasts** get **jump ahead 30s / back 15s** (more useful for long
episodes). Whichever pair isn't shown stays available from the in-app Player,
whose controls call `next()` / `previous()` / `skipForward()` directly.

## Audio vs. Video

- **Audio** (default) saves an AAC `.m4a` — the best audio-only stream, or, if a
  video has none, the audio extracted from a muxed MP4. No transcoding.
- **Video** saves an `.mp4`. Modern YouTube usually serves **separate**
  video-only and audio-only (DASH) streams, so we download the best video plus
  the best audio and **mux them natively** with `AVMutableComposition`
  (`VideoMerger`, no FFmpeg) — auto-detecting whether the video already has audio
  so it's never doubled. Video renders through `AVPlayerViewController` (for
  the picture and PiP) but is driven by the app's own transport controls — the
  same suite audio gets — and keeps its audio in the background.

  Video selection is **codec-aware** (`PlayableVideoCodec`): only **H.264**
  (`avc1`/`avc3`) and **HEVC** (`hvc1`/`hev1`) are chosen, because AVFoundation
  can't decode the **AV1** (`av01`) or **VP9** streams YouTube increasingly
  serves — an AV1 file plays its timeline but shows a blank QuickTime
  placeholder with no picture or sound. When *only* such codecs are on offer (it
  happens when the on-device player JS can't be resolved and every H.264 URL,
  which needs nsig descrambling, gets dropped), the yt-dlp path runs a
  **recovery**: it re-resolves forcing alternate **player clients** (`tv`,
  `ios`, `android`, `web_safari`, `mweb`, `web`) one at a time, whose H.264 URLs
  need no descrambling — the same renditions Safari plays — and takes the first
  that yields a decodable stream. The order matters for quality: it accepts the
  first client that works, so the no-token, **higher-resolution** source (`tv`,
  up to 1080p H.264) leads — it's also the most reliable on device under
  YouTube's 2024–25 SABR / PO-token tightening, whereas `ios` is increasingly
  gated or slow — and `android`, whose formats SABR frequently caps low (360p),
  follows; the web-family clients come last because on device they usually fail
  the n-challenge (no JS runtime). When the
  recovered H.264 is much lower than what was offered, the log says so — a 360p
  save from a 2160p AV1-only source reads as a codec ceiling, not a bug. Only if
  every client still yields nothing decodable does the download fail with a clear
  `unplayableVideoCodec` message.

## Extraction: native primary + yt-dlp fallback

Extraction sits behind the `MediaExtractor` protocol, and `CompositeExtractor`
tries a primary then a fallback (cancellation is never treated as a failure, so
Cancel doesn't trigger the fallback). Each extractor advertises which URLs it can
handle via `canHandle(_:)`, so the composite **skips** a primary that doesn't
apply (the YouTube-only native extractor on a Vimeo/SoundCloud link) and goes
straight to yt-dlp, instead of logging a guaranteed failure:

1. **`YouTubeKitExtractor` (primary, YouTube only)** — b5i/YouTubeKit resolves
   the audio-only stream URL natively in Swift (no Python, no engine download,
   fast). Pure `VideoInfosWithDownloadFormatsResponse.sendThrowingRequest` → best
   `AudioOnlyFormat`. `canHandle` returns true only when a YouTube video id can be
   parsed, so non-YouTube links bypass it.
2. **`YoutubeDLExtractor` (fallback)** — the yt-dlp path, used when the native
   extractor fails. `extractInfo(url:)` resolves the video; the Download tab's
   "⋯" menu has **Refresh yt-dlp engine** to re-pull a stale module. The URL is
   first **canonicalised** to `https://www.youtube.com/watch?v=ID` — the mobile
   host (`m.youtube.com`) and tracking/autoplay params (`pp`, `ra`, …) are
   stripped, since a parameterised mobile URL can push on-device extraction down
   a slower path.

   The default `extractInfo` call runs first — it's also what bootstraps the
   embedded Python runtime (PYTHONHOME, the unpacked stdlib, PythonKit's module
   search path), so the forced-client recovery, which drives Python directly,
   **must** run after it (calling it first crashes with `No module named
   'encodings'`).

   **For YouTube, that first attempt gets only a short grace period (15s), not
   the full 90s.** yt-dlp's default *web* client has to run YouTube's nsig
   descrambling through the slow pure-Python JS interpreter on device; easy
   videos resolve in a few seconds, but a video that needs descrambling would
   otherwise stall the whole 90s. The short window lets easy videos (and the
   Python bootstrap) through, then **falls to the forced fast player clients**,
   one at a time, whose stream URLs need no descrambling — the same renditions
   Safari plays — so the videos that hang the web path download quickly. The
   client order is **mode-aware**: **audio** leads with the pre-signed
   `ios`/`android` clients (resolution is irrelevant and they dodge YouTube's
   `tv`-client DRM experiment, [yt-dlp #12563](https://github.com/yt-dlp/yt-dlp/issues/12563)),
   while **video** leads with `tv` for its higher-resolution H.264; the
   web-family clients (`web_safari`/`mweb`/`web`) come last in both. Non-YouTube sites (Vimeo,
   SoundCloud, …) have no such fast fallback and can legitimately be slow, so
   they keep the full 90s timeout and only **retry with the forced clients** if
   the default extraction stalls or fails. This forced-client recovery handles
   **both audio and video** downloads (see below).

If a video exposes **no dedicated audio-only stream**, both extractors fall back
to downloading the smallest muxed (video+audio) **MP4** and extracting its audio
track to m4a via `VideoAudioExtractor` (AVFoundation's `AVAssetExportSession` —
no FFmpeg). The result is verified to actually contain an audio track. WebM is
excluded because AVFoundation can't read it.

Both resolve a direct stream URL and then hand it to the shared
`AudioStreamDownloader`, which fetches it in **5 MB HTTP byte-range chunks**
(each retried on transient errors with exponential backoff). YouTube
throttles/drops single large connections, so — like yt-dlp — ranged requests
are what make big files download reliably. We deliberately avoid
YoutubeDL-iOS's own `download(...)`: it's hardwired to a *background*
`URLSession` that doesn't complete on the Simulator.

The downloader is **self-healing** rather than fail-fast, because googlevideo
URLs expire (~6h), are IP-bound, and get rejected outright (HTTP 403/410) when
YouTube's token checks shift mid-download:

- **Re-resolve + resume.** Every download carries a *refresher* from its
  extractor: on a 403/410/416 (or a stall that survives in-place retries) the
  URL is re-resolved — the same yt-dlp `format_id` or YouTubeKit rendition —
  and the download **resumes from its current byte offset** instead of failing.
  The server's first Content-Range total overrides the extractor's metadata
  size (which can be inaccurate); a *change* in the server-confirmed total
  afterwards means a different rendition was served and aborts the download
  rather than corrupting the file, and a mid-file HTTP 200 (Range ignored)
  rewinds and rewrites the file rather than appending foreign bytes.
- **No silent truncation.** An empty or short body before the advertised size
  is a stall to retry, *not* an end-of-stream; if the remaining bytes can't be
  fetched the download **fails** — a truncated file is never saved as a
  success.
- **Verified playable.** Every finished file must pass `MediaVerifier` (a
  decodable audio/video track and a real duration via AVFoundation) before
  it's returned; an unplayable dud fails the attempt so the next player
  client / extractor gets its turn, instead of a broken track landing in the
  library.
- **Download failures fall through to other clients.** On the yt-dlp path, a
  failure *after* a successful extraction (URL rejected even across refreshes,
  truncation, failed merge, failed verification) retries via the forced player
  clients — which resolve *different* URLs — not just extraction failures. In
  the forced-client loop itself, one client's download failure moves to the
  next client rather than sinking the whole recovery.

### Any yt-dlp site (Vimeo, SoundCloud, …) — progressive only

The yt-dlp path isn't YouTube-specific: it resolves whatever URL it's given, so
Vimeo, SoundCloud and the rest of yt-dlp's catalogue work. Two constraints shape
which formats we pick:

- **Progressive only.** `AudioStreamDownloader` fetches a single file over byte
  ranges; it can't assemble an **HLS** playlist or **segmented DASH**. So
  `isProgressiveDownloadable` (and, on the Python path, yt-dlp's `protocol`
  field) filters those out, keeping only single-URL streams — including
  YouTube's DASH renditions, which *are* direct URLs. A link that offers
  **only** HLS fails fast with the clear `hlsOnly` message rather than
  downloading an unplayable playlist.
- **Playable containers.** Audio is saved raw only when it's a container
  AVFoundation can decode (`m4a`/`mp3`/`aac`/`wav`/`aiff` — so SoundCloud's
  progressive **mp3** saves directly, while an opus/webm-only stream routes to
  the muxed-video + audio-extraction fallback instead). Video stays restricted
  to decodable **H.264/HEVC** MP4.

If the YouTubeKit package isn't linked yet, its extractor throws and the composite
falls back to yt-dlp automatically. To exercise the UI with no native dependency
at all, point `DownloadManager`'s default extractor at `MockExtractor`.

The forced-client **recovery** (`extractViaForcedClients`) drives yt-dlp's Python
`YoutubeDL` directly (to pass `extractor_args`, which the structured `extractInfo`
API can't), so it needs **PythonKit** importable from the app target. It serves
two cases: re-resolving for decodable **H.264** when the default path offers only
AV1/VP9 (video mode), and re-resolving when the default path **stalls/times out
or fails** (audio *or* video). PythonKit is a transitive dependency of
YoutubeDL-iOS; if `import PythonKit` doesn't resolve, add it as an explicit
package dependency on the **OfflineListen** target in
*Project ▸ Package Dependencies*. Guarded by `#if canImport(PythonKit)`, so
without it the recovery compiles out — an AV1-only video then fails with the
clear `unplayableVideoCodec` message, and a timed-out extraction with the
timeout error.

### Diagnosing failures from the Log

The **Log** tab is the primary diagnostic tool, so failures are made as legible
as possible rather than collapsing to one opaque line:

- **The timeout no longer hides yt-dlp's real error.** When the 90s limit fires
  the queue moves on, but the abandoned extraction keeps running and its *actual*
  outcome is logged when it finally settles — either `yt-dlp's own error (arrived
  Ns in…)` with the real reason, or a note that it simply succeeded late (so you
  know the video isn't broken, extraction was just slow).
- **yt-dlp's own messages are captured.** The forced-client path installs a
  Python `logger` so yt-dlp's warnings/errors — "Sign in to confirm you're not a
  bot", "missing a PO token", "Some formats may be missing", signature/nsig
  failures — appear in the log tagged `yt-dlp(<client>):`, instead of being
  swallowed.
- **Plain-language hints.** `diagnosticHint(for:)` maps common signatures (bot
  check, PO token, private/members-only/age-restricted, unavailable, stale nsig
  engine, network) to a `Hint:` line suggesting the likely cause and next step.
  It returns nothing when it doesn't recognise the error — it never invents a
  diagnosis.
- **The log survives a crash.** The in-memory log is published on the main
  actor, so a hard native fault (most plausibly a PythonKit crash inside a
  forced-client `extract_info`) would take its buffered tail down with it — the
  very lines naming *where* it died. `DiagnosticLogFile` therefore mirrors every
  line to `Documents/diagnostics.log` with a synchronous `write()` before the
  caller proceeds, and on launch rolls the prior file to `diagnostics-previous.log`.
  The Log tab's **share** button exports both, so a trail that ends mid-step is
  still readable after a relaunch.
- **The forced-client recovery is bounded and breadcrumbed.** Each client
  attempt now runs under a hard `withTimeout` (the heartbeat alone never capped
  it, so a client that hung inside Python stalled the whole download with no
  further output); a timed-out client is logged and the loop moves to the next
  one. `.debug` breadcrumbs bracket each Python call (`Importing yt_dlp…`,
  `Running extract_info…`, `extract_info returned`) so the last persisted line
  pinpoints the exact in-flight step.
- **A stale engine refreshes itself.** When a failure's signature says the
  cached yt-dlp module is out of date with YouTube's player (nsig/signature
  extraction failures), the engine is re-downloaded automatically — once per
  session — and the URL retried, instead of waiting for the user to find
  ⋯ → Refresh yt-dlp engine.

The remaining structural gap — YouTube's PO-token enforcement and
JS-runtime-only nsig challenges, which desktop tools solve with an embedded
browser engine — is scoped as future work in
[`docs/JS-RUNTIME-PLAN.md`](docs/JS-RUNTIME-PLAN.md) (PO-token minting in a
hidden WKWebView, nsig solving via JavaScriptCore).

## Chapters

YouTube chapter markers are captured after a download as a best-effort step
(`ChapterFetcher`): a fast, metadata-only `yt-dlp` lookup
(`extract_info(download=False, process=False)` via PythonKit) reads the
`chapters` list (`title` / `start_time` / `end_time`) and stores it on the
`Track`. It runs only when the on-device yt-dlp Python module is **already
present**, so capturing chapters never triggers the tens-of-MB module download
on its own; without PythonKit/the module, tracks simply carry no chapters and
everything else is unchanged. Chapters persist in `library.json` (older
libraries decode with an empty list).

Chapters surface three ways: a jump-to list behind the library row's arrow, dots
+ a current-chapter line on the Player, and **Break Chapters into Playlist**,
which uses `AVAssetExportSession` (audio → `.m4a`, video → passthrough `.mp4`)
to cut one file per chapter into a new folder, then asks whether to delete the
original (Split & Delete vs. Split & Keep).

## Status

Built as a complete, ready-to-open Xcode project, authored on Linux without an
Xcode toolchain. The YoutubeDL-iOS integration is written against the library's
verified public API. Playback (offline, background, lock-screen) uses
AVFoundation only. The companion **watchOS app** and its phone↔watch sync are
likewise written against the documented **WatchConnectivity** / AVFoundation
APIs; its target is wired into `project.pbxproj` by hand (set the watch **Team**
in Xcode before building — see
[Required Xcode setup for the watch app](#required-xcode-setup-for-the-watch-app)).
