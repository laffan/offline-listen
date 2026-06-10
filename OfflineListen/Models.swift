import Foundation

/// Centralised filesystem locations for the app.
enum AppPaths {
    /// The app sandbox Documents directory. All downloaded audio lives here so it
    /// survives relaunches and is available fully offline.
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var libraryIndex: URL {
        documents.appendingPathComponent("library.json")
    }

    static var foldersIndex: URL {
        documents.appendingPathComponent("folders.json")
    }

    /// Scratch directory used while a download/convert is in flight.
    static var work: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A Documents file name based on `base` that doesn't collide with an
    /// existing file, disambiguating with " (2)", " (3)", … if needed.
    static func uniqueDocumentName(base: String, ext: String) -> String {
        let directory = documents
        var candidate = "\(base).\(ext)"
        var counter = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "\(base) (\(counter)).\(ext)"
            counter += 1
        }
        return candidate
    }
}

/// What the user wants from a download: just the audio, or the full video.
enum DownloadMode: String, Codable, CaseIterable, Identifiable {
    case audio
    case video

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .audio: return "Audio"
        case .video: return "Video"
        }
    }
}

/// Library list filter.
enum LibraryFilter: String, CaseIterable, Identifiable {
    case all
    case music
    case podcasts
    case video

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .all: return "All"
        case .music: return "Music"
        case .podcasts: return "Podcasts"
        case .video: return "Video"
        }
    }

    func matches(_ track: Track) -> Bool {
        switch self {
        case .all: return true
        case .music: return !track.isVideo && track.kind == .song
        case .podcasts: return !track.isVideo && track.kind == .podcast
        case .video: return track.isVideo
        }
    }
}

/// How a track behaves on playback. Songs always start from the beginning;
/// podcasts resume from their saved playhead.
enum TrackKind: String, Codable {
    case song
    case podcast
}

/// A user-created folder that groups library tracks. Deleting a folder never
/// deletes its tracks — they just return to the main library list.
struct Folder: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var dateCreated: Date

    init(id: UUID = UUID(), name: String, dateCreated: Date = Date()) {
        self.id = id
        self.name = name
        self.dateCreated = dateCreated
    }
}

/// A single downloaded track stored in the library.
struct Track: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var artist: String
    /// File name only (relative to `AppPaths.documents`) so the library survives
    /// the sandbox path changing between installs.
    var fileName: String
    var sourceURL: String
    var duration: Double
    var dateAdded: Date
    var isArchived: Bool
    var kind: TrackKind
    /// Saved playhead in seconds; used to resume podcasts between sessions.
    var lastPosition: Double
    /// True if this is a video file (plays with picture); false for audio-only.
    var isVideo: Bool
    /// The folder this track lives in, or nil for the main library list.
    var folderID: UUID?
    /// True once playback of the track has been started at least once; tracks
    /// where this is false make up the Inbox.
    var hasBeenPlayed: Bool

    init(id: UUID = UUID(),
         title: String,
         artist: String = "Unknown",
         fileName: String,
         sourceURL: String,
         duration: Double = 0,
         dateAdded: Date = Date(),
         isArchived: Bool = false,
         kind: TrackKind = .song,
         lastPosition: Double = 0,
         isVideo: Bool = false,
         folderID: UUID? = nil,
         hasBeenPlayed: Bool = false) {
        self.id = id
        self.title = title
        self.artist = artist
        self.fileName = fileName
        self.sourceURL = sourceURL
        self.duration = duration
        self.dateAdded = dateAdded
        self.isArchived = isArchived
        self.kind = kind
        self.lastPosition = lastPosition
        self.isVideo = isVideo
        self.folderID = folderID
        self.hasBeenPlayed = hasBeenPlayed
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, artist, fileName, sourceURL, duration, dateAdded, isArchived, kind, lastPosition, isVideo, folderID, hasBeenPlayed
    }

    // Custom decode so libraries saved before these fields existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        artist = try c.decode(String.self, forKey: .artist)
        fileName = try c.decode(String.self, forKey: .fileName)
        sourceURL = try c.decode(String.self, forKey: .sourceURL)
        duration = try c.decode(Double.self, forKey: .duration)
        dateAdded = try c.decode(Date.self, forKey: .dateAdded)
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        kind = try c.decodeIfPresent(TrackKind.self, forKey: .kind) ?? .song
        lastPosition = try c.decodeIfPresent(Double.self, forKey: .lastPosition) ?? 0
        isVideo = try c.decodeIfPresent(Bool.self, forKey: .isVideo) ?? false
        folderID = try c.decodeIfPresent(UUID.self, forKey: .folderID)
        hasBeenPlayed = try c.decodeIfPresent(Bool.self, forKey: .hasBeenPlayed) ?? false
    }

    /// Absolute on-disk location resolved at access time.
    var fileURL: URL {
        AppPaths.documents.appendingPathComponent(fileName)
    }
}

extension String {
    /// A filesystem-safe version of the string suitable for a file name:
    /// path-illegal and control characters removed, whitespace collapsed, and
    /// trimmed to `maxLength` characters. Falls back to "audio" if empty.
    func sanitizedFileName(maxLength: Int = 50) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        var cleaned = components(separatedBy: illegal).joined(separator: " ")
        cleaned = cleaned
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if cleaned.count > maxLength {
            cleaned = String(cleaned.prefix(maxLength))
        }
        // Trailing dots/spaces are problematic in file names.
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return cleaned.isEmpty ? "audio" : cleaned
    }
}

extension Double {
    /// Formats a number of seconds as `m:ss` (or `h:mm:ss`).
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
