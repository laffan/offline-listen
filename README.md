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
   YouTube links are queued, the rest are skipped), pick a format (M4A/MP3),
   watch the queue. Swipe a row for **Cancel** (active/queued), **Restart**, or
   **Clear**; tap a finished row to play it.
2. **Library** — downloaded tracks; tap to play. Swipe **left** for
   Delete/Share/Archive (and bulk versions via **Select**); swipe **right** to
   classify a track as **Song** or **Podcast**. Songs always start from the
   beginning; podcasts (mic icon) resume from where you left off and show a
   progress bar. Archived tracks live in an **Archived** folder (toolbar).
3. **Player** — artwork, scrubber, play/pause, next/previous. Drives the lock
   screen and Control Center.
4. **Log** — timestamped, copyable stream of every pipeline step (queue,
   yt-dlp, conversion) with light colour coding, for diagnosing downloads.

### Pipeline

```
URL  ──►  YoutubeDL-iOS (yt-dlp on device)  ──►  AudioConverter  ──►  Documents/  ──►  AVAudioPlayer
         extracts best audio-only stream         M4A passthrough        local file       playback
                                                  (MP3 = opt-in)
```

### Source layout (`OfflineListen/`)

| File | Role |
|------|------|
| `OfflineListenApp.swift` | App entry; wires up the shared stores. |
| `Models.swift` | `Track`, `AudioFormat`, paths, helpers. |
| `LibraryStore.swift` | Persists the library to `Documents/library.json`. |
| `DownloadManager.swift` | Serial download queue + `DownloadJob`. |
| `YouTubeExtractor.swift` | `YouTubeAudioExtractor` protocol + YoutubeDL-iOS impl + a mock. |
| `YouTubeKitExtractor.swift` | Native-Swift (b5i/YouTubeKit) primary extractor. |
| `CompositeExtractor.swift` | Tries the native extractor, falls back to yt-dlp. |
| `AudioStreamDownloader.swift` | Shared chunked byte-range stream downloader. |
| `AudioConverter.swift` | M4A passthrough; gated MP3 transcode. |
| `PlaybackManager.swift` | AVFoundation engine, audio session, lock-screen controls. |
| `Logger.swift` | `LogStore` — thread-safe, app-wide log sink. |
| `*View.swift` | The four SwiftUI screens (Download, Library, Player, Log). |

The YouTube extraction step is isolated behind a `YouTubeAudioExtractor` seam (a
mock implementation is included), so adapting to a library API change touches
one file and the UI can be exercised with no native dependency.

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

## Format notes — why M4A is the default

- **M4A** is reliable and needs **no transcoding**: yt-dlp downloads the best
  audio-only stream directly as an AAC `.m4a`, which the converter just moves
  into the library. This is the path that guarantees "download + play offline."
- **MP3** requires FFmpeg to *encode*, which needs an MP3 encoder
  (`libmp3lame`/`libshine`). No FFmpeg is bundled, so MP3 is **off by default**.
  `AudioConverter.transcodeToMP3` is gated behind a `USE_FFMPEG_MP3` build flag
  with the exact `FFmpegKit.execute(...)` call sketched in comments. To enable it:
  1. Add an MP3-capable, command-style FFmpeg package (e.g. an `ffmpeg-kit`
     build that includes `libmp3lame` and exposes `FFmpegKit.execute`).
  2. Fill in the `execute` call in `AudioConverter.swift`.
  3. Add `USE_FFMPEG_MP3` to *Build Settings ▸ Swift Compiler – Custom Flags ▸
     Active Compilation Conditions*.

## Extraction: native primary + yt-dlp fallback

Extraction sits behind the `YouTubeAudioExtractor` protocol, and
`CompositeExtractor` tries a primary then a fallback (cancellation is never
treated as a failure, so Cancel doesn't trigger the fallback):

1. **`YouTubeKitExtractor` (primary)** — b5i/YouTubeKit resolves the audio-only
   stream URL natively in Swift (no Python, no engine download, fast). Pure
   `VideoInfosWithDownloadFormatsResponse.sendThrowingRequest` → best
   `AudioOnlyFormat`.
2. **`YoutubeDLExtractor` (fallback)** — the yt-dlp path, used when the native
   extractor fails. `extractInfo(url:)` resolves the video; the Download tab's
   "⋯" menu has **Refresh yt-dlp engine** to re-pull a stale module.

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
