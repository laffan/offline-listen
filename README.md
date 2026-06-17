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
2. **Library** — downloaded tracks; tap to play. A **filter** (All / Music /
   Podcasts / Video) is at the top. Swipe **left** for Delete/Share/Archive (and
   bulk versions via **Select**); swipe **right** on an audio track to classify
   it **Song** or **Podcast**. Songs/videos start from the beginning; podcasts
   (mic icon) resume where you left off and show a progress bar. Video tracks
   (film icon) play with picture on the Player screen. Archived tracks live in an
   **Archived** folder (toolbar).

   **Folders** organize the library: an **Inbox** pinned to the top collects
   every track you haven't listened to yet (starting playback — or a
   **Mark Played** swipe — clears it from the Inbox), and user folders sit
   below it, above the unfiled tracks. Create folders with the toolbar's
   folder button; move tracks in via touch-and-hold → **Move to Folder** (or
   the bulk Select menu). The Inbox is itself a move target — moving a track
   there returns it to unlistened. Touch-and-hold also offers **Rename**, whose
   modal includes **Reset to Original** to restore the download title. Swipe a
   folder row for its slide menu: **Delete**
   (the folder only — its tracks return to the library), **Rename**, and
   **Reorder** (drag-reorder the tracks inside it). Folders persist to
   `Documents/folders.json`.
3. **Player** — artwork, scrubber, play/pause, skip, next/previous — the same
   control suite for audio and video. Video is edge-to-edge in portrait and
   goes fullscreen automatically when the phone rotates to landscape (tap the
   picture to toggle the floating controls). Drives the lock screen and
   Control Center.
4. **Log** — timestamped, copyable stream of every pipeline step (queue,
   yt-dlp, conversion) with light colour coding, for diagnosing downloads.

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
| `Models.swift` | `Track`, `Folder`, `DownloadMode`, `LibraryFilter`, paths, helpers. |
| `LibraryStore.swift` | Persists the library to `Documents/library.json` and folders to `Documents/folders.json`. |
| `DownloadManager.swift` | Serial download queue + `DownloadJob`. |
| `YouTubeExtractor.swift` | `MediaExtractor` protocol + YoutubeDL-iOS impl + a mock. |
| `YouTubeKitExtractor.swift` | Native-Swift (b5i/YouTubeKit) primary extractor. |
| `CompositeExtractor.swift` | Tries the native extractor, falls back to yt-dlp. |
| `AudioStreamDownloader.swift` | Shared chunked byte-range stream downloader. |
| `VideoAudioExtractor.swift` | Extracts audio from a muxed video via AVFoundation. |
| `VideoMerger.swift` | Muxes a video-only + audio-only stream into one MP4. |
| `PlaybackManager.swift` | `AVPlayer` engine (audio + video), audio session, lock screen. |
| `Logger.swift` | `LogStore` — thread-safe, app-wide log sink. |
| `*View.swift` | The four SwiftUI screens (Download, Library, Player, Log). |
| `FolderView.swift` | Folder detail (tap-to-play, reorder) and Inbox screens. |

The extraction step is isolated behind a `MediaExtractor` seam (a mock
implementation is included), so adapting to a library API change touches one
file and the UI can be exercised with no native dependency.

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

## Setup

Requires **Xcode 15+** and an Apple developer account (free is fine for running
on your own device).

1. Open `OfflineListen.xcodeproj`.
2. Xcode resolves two Swift packages on first open (needs a network connection):
   - **YouTubeKit** — `https://github.com/b5i/YouTubeKit.git` — the native-Swift
     primary extractor.
   - **YoutubeDL-iOS** — `https://github.com/kewlbear/YoutubeDL-iOS.git` — the
     yt-dlp fallback extractor.

   Both are pinned to `main`; change the rule in *Project ▸ Package Dependencies*
   to pin versions. Playback uses Apple's AVFoundation — no media-player package.
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
both. We surface **jump ahead 30s / back 15s** on the side buttons (the most
useful for long tracks and podcasts); next/previous-track stays available from
the in-app Player. Enabling both command pairs makes them conflict and the
skip buttons silently fail to appear, so `PlaybackManager` explicitly disables
`nextTrackCommand` / `previousTrackCommand`.

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
  **recovery**: it re-resolves forcing alternate **player clients** (`ios`,
  `web_safari`, `android`, `tv`, `mweb`, `web`) one at a time, whose H.264 URLs
  need no descrambling — the same renditions Safari plays — and takes the first
  that yields a decodable stream. Only if every client still yields nothing
  decodable does the download fail with a clear `unplayableVideoCodec` message.

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

   If that default extraction **stalls or times out** (90s) — which happens when
   yt-dlp's default *web* client has to run YouTube's nsig descrambling through
   the slow pure-Python JS interpreter on device — the extractor automatically
   **retries with forced fast player clients** (`ios`, `web_safari`, `android`,
   `tv`, `mweb`, `web`, one at a time). Those clients return stream URLs that
   need no descrambling — the same renditions Safari plays, so they succeed for
   videos that play fine in the browser but hang the default path. This forced-
   client recovery handles **both audio and video** downloads (see below).

If a video exposes **no dedicated audio-only stream**, both extractors fall back
to downloading the smallest muxed (video+audio) **MP4** and extracting its audio
track to m4a via `VideoAudioExtractor` (AVFoundation's `AVAssetExportSession` —
no FFmpeg). The result is verified to actually contain an audio track. WebM is
excluded because AVFoundation can't read it.

Both resolve a direct stream URL and then hand it to the shared
`AudioStreamDownloader`, which fetches it in **5 MB HTTP byte-range chunks**
(each retried on transient errors). YouTube throttles/drops single large
connections, so — like yt-dlp — ranged requests are what make big files download
reliably. We deliberately avoid YoutubeDL-iOS's own `download(...)`: it's
hardwired to a *background* `URLSession` that doesn't complete on the Simulator.

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

## Status

Built as a complete, ready-to-open Xcode project, authored on Linux without an
Xcode toolchain. The YoutubeDL-iOS integration is written against the library's
verified public API. Playback (offline, background, lock-screen) uses
AVFoundation only.
