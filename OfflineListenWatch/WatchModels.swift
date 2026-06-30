import Foundation

/// Filesystem locations for the watch app. Transferred audio lives in the
/// watch's own Documents directory so it's available fully offline.
enum WatchPaths {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    /// The persisted index of what's on the watch.
    static var index: URL {
        documents.appendingPathComponent("watch-library.json")
    }
}

/// A track stored on the watch for offline listening. Built from a
/// `WatchManifestTrack` pushed by the phone plus the transferred audio file. A
/// deliberately small projection of the phone's `Track` — the watch doesn't need
/// chapters, archive state, source URLs, etc.
struct WatchTrack: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var artist: String
    var fileName: String
    var duration: Double
    /// "song" or "podcast" (`TrackKind.rawValue` on the phone).
    var kindRaw: String
    /// Playlist this track was sent as part of, or nil when sent on its own.
    var folderName: String?
    /// Position in the phone's watch set, preserved for ordering.
    var order: Int
    /// Locally-saved playhead (seconds) so podcasts resume between sessions.
    var lastPosition: Double
    /// Total file size in bytes (from the manifest); used to show sync % from the
    /// in-progress `.part` file. 0 when unknown.
    var byteSize: Int

    init(id: UUID,
         title: String,
         artist: String,
         fileName: String,
         duration: Double,
         kindRaw: String,
         folderName: String?,
         order: Int,
         lastPosition: Double = 0,
         byteSize: Int = 0) {
        self.id = id
        self.title = title
        self.artist = artist
        self.fileName = fileName
        self.duration = duration
        self.kindRaw = kindRaw
        self.folderName = folderName
        self.order = order
        self.lastPosition = lastPosition
        self.byteSize = byteSize
    }

    /// Builds a watch track from a manifest entry, carrying over a previously
    /// saved playhead when we already had this track.
    init(manifest m: WatchManifestTrack, lastPosition: Double = 0) {
        self.init(id: m.id, title: m.title, artist: m.artist, fileName: m.fileName,
                  duration: m.duration, kindRaw: m.kindRaw, folderName: m.folderName,
                  order: m.order, lastPosition: lastPosition, byteSize: m.byteSize)
    }

    var isPodcast: Bool { kindRaw == "podcast" }
    /// Podcasts resume from their saved playhead; songs always start over.
    var remembersPosition: Bool { isPodcast }

    /// Absolute on-disk location, resolved at access time.
    var fileURL: URL {
        WatchPaths.documents.appendingPathComponent(fileName)
    }

    /// True once the audio file has actually landed on the watch (transfers
    /// arrive after the manifest, so a row can briefly exist without its file).
    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// Sync progress 0...1: 1 once the file is present, otherwise the fraction of
    /// the in-progress `.part` file received (needs the manifest's `byteSize`).
    var syncProgress: Double {
        if isAvailable { return 1 }
        guard byteSize > 0 else { return 0 }
        let partURL = WatchPaths.documents.appendingPathComponent(fileName + ".part")
        let part = ((try? FileManager.default.attributesOfItem(atPath: partURL.path))?[.size] as? Int) ?? 0
        return min(Double(part) / Double(byteSize), 1)
    }
}

extension Double {
    /// Formats a number of seconds as `m:ss` (or `h:mm:ss`). Duplicated from the
    /// phone's `Models.swift` to keep the watch target self-contained.
    var asPlaybackTime: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let total = Int(self.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
