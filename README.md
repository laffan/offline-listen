# Offline Listen

A SwiftUI iPhone app that downloads the audio from a video URL, saves it to the
device, and plays it back offline — including in the background with the phone
locked.

> **Personal-use tool.** Downloading from sites like YouTube may conflict with
> their Terms of Service and with copyright. Only download content you own or
> have the right to, and use this responsibly.

## What's here

Three screens (tabs):

1. **Download** — paste one or more URLs (whitespace/line-break separated; only
   YouTube links are queued, the rest are skipped), choose **Audio** or **Video**
   (default Audio), watch the queue. Swipe a row for **Cancel** (active/queued),
   **Restart**, or **Clear**; tap a finished row to play it.
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
- `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` for lock-screen metadata
  and transport controls.

Start a track, lock the phone — audio keeps playing and the controls appear on
the lock screen.

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

## Extraction: native primary + yt-dlp fallback

Extraction sits behind the `MediaExtractor` protocol, and `CompositeExtractor`
tries a primary then a fallback (cancellation is never treated as a failure, so
Cancel doesn't trigger the fallback):

1. **`YouTubeKitExtractor` (primary)** — b5i/YouTubeKit resolves the audio-only
   stream URL natively in Swift (no Python, no engine download, fast). Pure
   `VideoInfosWithDownloadFormatsResponse.sendThrowingRequest` → best
   `AudioOnlyFormat`.
2. **`YoutubeDLExtractor` (fallback)** — the yt-dlp path, used when the native
   extractor fails. `extractInfo(url:)` resolves the video; the Download tab's
   "⋯" menu has **Refresh yt-dlp engine** to re-pull a stale module.

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

If the YouTubeKit package isn't linked yet, its extractor throws and the composite
falls back to yt-dlp automatically. To exercise the UI with no native dependency
at all, point `DownloadManager`'s default extractor at `MockExtractor`.

## Status

Built as a complete, ready-to-open Xcode project, authored on Linux without an
Xcode toolchain. The YoutubeDL-iOS integration is written against the library's
verified public API. Playback (offline, background, lock-screen) uses
AVFoundation only.
