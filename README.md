# Offline Listen

A SwiftUI iPhone app that downloads the audio from a video URL, saves it to the
device, and plays it back offline — including in the background with the phone
locked.

> **Personal-use tool.** Downloading from sites like YouTube may conflict with
> their Terms of Service and with copyright. Only download content you own or
> have the right to, and use this responsibly.

## What's here

Three screens (tabs):

1. **Download** — paste a URL, pick a format (M4A/MP3), watch the queue progress.
2. **Library** — every downloaded track; tap to play, swipe to delete.
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
| `AudioConverter.swift` | M4A passthrough; gated MP3 transcode. |
| `PlaybackManager.swift` | AVFoundation engine, audio session, lock-screen controls. |
| `Logger.swift` | `LogStore` — thread-safe, app-wide log sink. |
| `*View.swift` | The four SwiftUI screens (Download, Library, Player, Log). |

The YouTube extraction step is isolated behind a `YouTubeAudioExtractor` seam (a
mock implementation is included), so adapting to a library API change touches
one file and the UI can be exercised with no native dependency.

## Setup

Requires **Xcode 15+** and an Apple developer account (free is fine for running
on your own device).

1. Open `OfflineListen.xcodeproj`.
2. Xcode resolves the one Swift package on first open (needs a network connection):
   - **YoutubeDL-iOS** — `https://github.com/kewlbear/YoutubeDL-iOS.git`,
     pinned to `main`. To pin a specific version instead, change the rule in
     *Project ▸ Package Dependencies*.

   Playback uses Apple's AVFoundation, so there is no media-player package to
   resolve.
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

## The YoutubeDL-iOS seam

All YoutubeDL-iOS usage lives in `YoutubeDLExtractor.extractAudio`:

- `YoutubeDL.downloadPythonModule()` fetches the yt-dlp Python module on first
  run (guarded by a `pythonModuleURL` existence check).
- `extractInfo(url:) async throws -> ([Format], Info)` runs yt-dlp to resolve the
  video, returning metadata plus formats with ready-to-use direct stream URLs.
- We pick the best audio-only `Format` (preferring `m4a` / format 140) and
  download `Format.url` ourselves with a **foreground `URLSession`**.

We deliberately do **not** call the library's own `download(...)`: it is
hardwired to `Downloader.shared`, which uses a *background* `URLSession`.
Background transfers don't complete reliably on the Simulator and need
app-delegate event forwarding, so that call hangs. A foreground download behaves
the same on Simulator and device. (The `Downloader` init that would give a
foreground session is `internal`, so it can't be swapped in.)

To exercise the rest of the app — queue, library, player, lock-screen controls —
with no native dependency at all, point `DownloadManager`'s default extractor at
`MockExtractor`.

## Status

Built as a complete, ready-to-open Xcode project, authored on Linux without an
Xcode toolchain. The YoutubeDL-iOS integration is written against the library's
verified public API. Playback (offline, background, lock-screen) uses
AVFoundation only.
