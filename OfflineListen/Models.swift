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

    /// Persisted download history (completed/failed/cancelled jobs), so the
    /// Download tab survives relaunches instead of clearing on quit.
    static var downloadsHistory: URL {
        documents.appendingPathComponent("downloads.json")
    }

    /// The user-chosen sync folders, resolved from their security-scoped
    /// bookmarks by `LocalSyncStore` at launch, keyed by each root's id.
    /// These are *replicas*: the app never plays from them — synced files are
    /// copied in and out of the per-root local stores, which is what the
    /// library actually uses. Cloud providers (Dropbox, iCloud Drive) serve
    /// placeholders and can evict files, so only a local copy is dependable.
    /// (An unresolvable root — provider offline — is simply absent here.)
    static var syncRootURLs: [UUID: URL] = [:]

    /// The app-local home of synced files: `Documents/Synced/`, with one
    /// subdirectory per sync root (named by its id), each mirroring that sync
    /// folder's directory structure. Synced tracks play from here — always
    /// materialized, always offline.
    static var syncLocalStore: URL {
        let url = documents.appendingPathComponent("Synced", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The local store for one sync root.
    static func syncLocalStore(for rootID: UUID) -> URL {
        let url = syncLocalStore.appendingPathComponent(rootID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Where cover images for *unsynced* mixtape folders live (a synced
    /// mixtape's cover lives in its directory's `.mixtapedata` instead).
    static var mixtapeCovers: URL {
        let url = documents.appendingPathComponent("MixtapeCovers", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The hidden per-folder directory a synced mixtape keeps its cover image
    /// and style in, so the mixtape travels with the files.
    static let mixtapeDataDirName = ".mixtapedata"

    /// A file name based on `base` that doesn't collide with anything already
    /// in `directory`, disambiguating with " (2)", " (3)", … if needed.
    /// `ext` may be empty for a directory name.
    static func uniqueName(base: String, ext: String, in directory: URL) -> String {
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        var candidate = "\(base)\(suffix)"
        var counter = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "\(base) (\(counter))\(suffix)"
            counter += 1
        }
        return candidate
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

/// Preferred resolution for a video download (the preview modal's quality
/// picker). `best` takes the tallest stream offered; a capped tier takes the
/// tallest at or below its height. Always constrained by what the source
/// actually offers in a device-playable codec — a preference can't conjure a
/// rendition YouTube didn't serve.
enum VideoQuality: String, Codable, CaseIterable, Identifiable {
    case best
    case p1080
    case p720
    case p480
    case p360

    var id: String { rawValue }

    /// The resolution cap, nil for `best`.
    var maxHeight: Int? {
        switch self {
        case .best: return nil
        case .p1080: return 1080
        case .p720: return 720
        case .p480: return 480
        case .p360: return 360
        }
    }

    var displayName: String {
        switch self {
        case .best: return "Best"
        case .p1080: return "1080p"
        case .p720: return "720p"
        case .p480: return "480p"
        case .p360: return "360p"
        }
    }

    /// The candidate that best honours this preference: the tallest at or
    /// below the cap, or — when everything on offer is above it — the lowest
    /// offered, so a strict cap degrades to "smallest available" rather than
    /// failing.
    func pick<T>(from candidates: [T], height: (T) -> Int) -> T? {
        guard let cap = maxHeight else {
            return candidates.max(by: { height($0) < height($1) })
        }
        let within = candidates.filter { height($0) <= cap }
        if !within.isEmpty {
            return within.max(by: { height($0) < height($1) })
        }
        return candidates.min(by: { height($0) < height($1) })
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

/// How the folder list is ordered: the user's hand-set drag order, or
/// alphabetically by name.
enum FolderSort: String, CaseIterable, Identifiable {
    case userOrder
    case name

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .userOrder: return "User Order"
        case .name: return "Name"
        }
    }
}

/// How a track behaves on playback. Songs always start from the beginning;
/// podcasts resume from their saved playhead.
enum TrackKind: String, Codable {
    case song
    case podcast
}

/// The three media categories autoplay keeps to: when one track finishes,
/// playback advances to the next track of the *same* category, skipping over
/// the others until the list ends. Mirrors the library's Song/Podcast/Video
/// distinction (a video is a video regardless of its song/podcast kind).
enum PlaybackCategory: Hashable {
    case song
    case podcast
    case video
}

/// A single chapter marker within a track (as exposed by YouTube / yt-dlp).
/// `start`/`end` are seconds from the start of the track.
struct Chapter: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var start: Double
    var end: Double

    init(id: UUID = UUID(), title: String, start: Double, end: Double) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
    }
}

extension Array where Element == Chapter {
    /// Index of the chapter that contains `time` (the last whose start is at or
    /// before it), or nil when there are no chapters.
    func index(at time: Double) -> Int? {
        guard !isEmpty else { return nil }
        var result = 0
        for (i, chapter) in enumerated() where chapter.start <= time + 0.001 {
            result = i
        }
        return result
    }

    /// The chapter that contains `time`, if any.
    func chapter(at time: Double) -> Chapter? {
        guard let i = index(at: time) else { return nil }
        return self[i]
    }
}

/// File types the library recognises as playable, used when scanning the
/// local sync folder. Mirrors what the download pipeline can produce plus the
/// other containers AVFoundation decodes.
enum PlayableMedia {
    static let audioExtensions: Set<String> = ["m4a", "mp3", "aac", "wav", "aiff", "aif"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    static func isVideo(extension ext: String) -> Bool {
        videoExtensions.contains(ext.lowercased())
    }

    static func isPlayable(extension ext: String) -> Bool {
        let lower = ext.lowercased()
        return audioExtensions.contains(lower) || videoExtensions.contains(lower)
    }
}

/// How a mixtape folder draws its title banner: which part of the cover image
/// shows behind the title (a non-destructive crop — the original image is kept
/// untouched, separately framed for the tall header and the short list row),
/// which font/colour the title uses, whether it sits on a tape chip, and how
/// it's justified in the list row. Persisted in `folders.json` and, for synced
/// mixtapes, mirrored to the folder's `.mixtapedata/style.json` so the look
/// travels with the files.
struct MixtapeStyle: Codable, Hashable {
    /// Font family/PostScript name for the title, nil for the system font.
    var fontName: String?
    /// Title colour as "#RRGGBB", nil for white.
    var textColorHex: String?
    /// True to centre the title in the folder-list row (default left).
    var centered: Bool
    /// True to draw a tape-like chip behind the title.
    var tape: Bool
    /// Tape colour as "#RRGGBB", nil for masking-tape white.
    var tapeColorHex: String?
    /// Header-banner crop: zoom applied on top of aspect-fill (1…4) and pan as
    /// a fraction of the banner's size (clamped at render to the image's
    /// actual overflow, so a short banner can legitimately store values well
    /// past ±1).
    var zoom: Double
    var offsetX: Double
    var offsetY: Double
    /// The list row's own crop — the row is much shorter than the header, so
    /// it gets its own framing.
    var rowZoom: Double
    var rowOffsetX: Double
    var rowOffsetY: Double

    /// The default tape colour: masking-tape white.
    static let defaultTapeHex = "#F2EBDC"

    init(fontName: String? = nil, textColorHex: String? = nil,
         centered: Bool = false, tape: Bool = false, tapeColorHex: String? = nil,
         zoom: Double = 1, offsetX: Double = 0, offsetY: Double = 0,
         rowZoom: Double = 1, rowOffsetX: Double = 0, rowOffsetY: Double = 0) {
        self.fontName = fontName
        self.textColorHex = textColorHex
        self.centered = centered
        self.tape = tape
        self.tapeColorHex = tapeColorHex
        self.zoom = zoom
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.rowZoom = rowZoom
        self.rowOffsetX = rowOffsetX
        self.rowOffsetY = rowOffsetY
    }

    private enum CodingKeys: String, CodingKey {
        case fontName, textColorHex, centered, tape, tapeColorHex
        case zoom, offsetX, offsetY, rowZoom, rowOffsetX, rowOffsetY
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName)
        textColorHex = try c.decodeIfPresent(String.self, forKey: .textColorHex)
        centered = try c.decodeIfPresent(Bool.self, forKey: .centered) ?? false
        tape = try c.decodeIfPresent(Bool.self, forKey: .tape) ?? false
        tapeColorHex = try c.decodeIfPresent(String.self, forKey: .tapeColorHex)
        zoom = try c.decodeIfPresent(Double.self, forKey: .zoom) ?? 1
        offsetX = try c.decodeIfPresent(Double.self, forKey: .offsetX) ?? 0
        offsetY = try c.decodeIfPresent(Double.self, forKey: .offsetY) ?? 0
        rowZoom = try c.decodeIfPresent(Double.self, forKey: .rowZoom) ?? 1
        rowOffsetX = try c.decodeIfPresent(Double.self, forKey: .rowOffsetX) ?? 0
        rowOffsetY = try c.decodeIfPresent(Double.self, forKey: .rowOffsetY) ?? 0
    }
}

/// A user-created folder that groups library tracks. Deleting a folder never
/// deletes its tracks — they just return to the main library list. Folders can
/// nest (`parentID`); a folder that mirrors a directory in the local sync
/// folder is `isSynced` and remembers its directory as `syncedPath`.
struct Folder: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var dateCreated: Date
    /// True when the folder (and everything inside it) has been archived. Like a
    /// track's `isArchived`, this hides the folder from the main library and
    /// surfaces it in the Archive instead.
    var isArchived: Bool
    /// The folder this folder lives in, or nil at the root of the library.
    var parentID: UUID?
    /// True when the folder mirrors a directory inside a sync folder.
    var isSynced: Bool
    /// Which sync root the folder belongs to (only while `isSynced`).
    var syncRootID: UUID?
    /// Directory path relative to the sync root (only while `isSynced`).
    var syncedPath: String?
    /// True when the folder is a mixtape: its title draws over a cover-image
    /// banner and it can't contain subfolders.
    var isMixtape: Bool
    /// The mixtape's banner style (crop + font). Meaningful while `isMixtape`.
    var mixtape: MixtapeStyle

    init(id: UUID = UUID(), name: String, dateCreated: Date = Date(), isArchived: Bool = false,
         parentID: UUID? = nil, isSynced: Bool = false, syncRootID: UUID? = nil, syncedPath: String? = nil,
         isMixtape: Bool = false, mixtape: MixtapeStyle = MixtapeStyle()) {
        self.id = id
        self.name = name
        self.dateCreated = dateCreated
        self.isArchived = isArchived
        self.parentID = parentID
        self.isSynced = isSynced
        self.syncRootID = syncRootID
        self.syncedPath = syncedPath
        self.isMixtape = isMixtape
        self.mixtape = mixtape
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, dateCreated, isArchived, parentID, isSynced, syncRootID, syncedPath, isMixtape, mixtape
    }

    // Custom decode so folders.json saved before newer fields existed still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        dateCreated = try c.decode(Date.self, forKey: .dateCreated)
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        parentID = try c.decodeIfPresent(UUID.self, forKey: .parentID)
        isSynced = try c.decodeIfPresent(Bool.self, forKey: .isSynced) ?? false
        syncRootID = try c.decodeIfPresent(UUID.self, forKey: .syncRootID)
        syncedPath = try c.decodeIfPresent(String.self, forKey: .syncedPath)
        isMixtape = try c.decodeIfPresent(Bool.self, forKey: .isMixtape) ?? false
        mixtape = try c.decodeIfPresent(MixtapeStyle.self, forKey: .mixtape) ?? MixtapeStyle()
    }

    /// The synced folder's directory inside its root's app-local sync store
    /// (`Documents/Synced/<root-id>/…`), nil while unsynced. The matching
    /// directory in the replica (the user's sync folder) is maintained by the
    /// exporter.
    var syncedDirectoryURL: URL? {
        guard isSynced, let rootID = syncRootID, let path = syncedPath else { return nil }
        return AppPaths.syncLocalStore(for: rootID).appendingPathComponent(path, isDirectory: true)
    }

    /// Where this mixtape's cover image lives. Always app-local; a synced
    /// mixtape's `.mixtapedata/cover.jpg` in the replica is an exported copy.
    var coverURL: URL? {
        guard isMixtape else { return nil }
        return AppPaths.mixtapeCovers.appendingPathComponent("\(id.uuidString).jpg")
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
    /// The title the track was downloaded with, recorded on first rename so
    /// "Reset to Original" can restore it. Nil while never renamed.
    var originalTitle: String?
    /// YouTube/yt-dlp chapter markers, in order. Empty when the source had none.
    var chapters: [Chapter]
    /// True when this track has been pushed to the Apple Watch for offline
    /// listening. The phone is the source of truth; the "Watch" virtual folder
    /// lists every track where this is set (see `LibraryStore.watchTracks`).
    var sentToWatch: Bool
    /// True when the track is mirrored to a sync folder. Its file lives in
    /// that root's app-local sync store (`Documents/Synced/<root-id>/…`) and
    /// `fileName` is a path relative to that store (it may contain directory
    /// components); the same relative path names its exported copy in the
    /// replica.
    var isSynced: Bool
    /// Which sync root the track belongs to (only while `isSynced`).
    var syncRootID: UUID?

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
         hasBeenPlayed: Bool = false,
         originalTitle: String? = nil,
         chapters: [Chapter] = [],
         sentToWatch: Bool = false,
         isSynced: Bool = false,
         syncRootID: UUID? = nil) {
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
        self.originalTitle = originalTitle
        self.chapters = chapters
        self.sentToWatch = sentToWatch
        self.isSynced = isSynced
        self.syncRootID = syncRootID
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, artist, fileName, sourceURL, duration, dateAdded, isArchived, kind, lastPosition, isVideo, folderID, hasBeenPlayed, originalTitle, chapters, sentToWatch, isSynced, syncRootID
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
        originalTitle = try c.decodeIfPresent(String.self, forKey: .originalTitle)
        chapters = try c.decodeIfPresent([Chapter].self, forKey: .chapters) ?? []
        sentToWatch = try c.decodeIfPresent(Bool.self, forKey: .sentToWatch) ?? false
        isSynced = try c.decodeIfPresent(Bool.self, forKey: .isSynced) ?? false
        syncRootID = try c.decodeIfPresent(UUID.self, forKey: .syncRootID)
    }

    /// Absolute on-disk location resolved at access time. A synced track lives
    /// in its root's app-local sync store (`Documents/Synced/<root-id>/…`) —
    /// never in the user's sync folder itself, whose files may be cloud
    /// placeholders.
    var fileURL: URL {
        if isSynced, let rootID = syncRootID {
            return AppPaths.syncLocalStore(for: rootID).appendingPathComponent(fileName)
        }
        return AppPaths.documents.appendingPathComponent(fileName)
    }

    /// On-disk size in bytes (0 when the file is missing/unreadable).
    var fileSizeBytes: Int {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int ?? 0
    }

    /// On-disk size in KB (0 when the file is missing/unreadable); for logs/UI.
    var fileSizeKB: Int { fileSizeBytes / 1024 }

    /// True when the track carries chapter markers worth surfacing.
    var hasChapters: Bool { chapters.count > 1 }

    /// The media category autoplay keeps to when advancing through a list.
    var playbackCategory: PlaybackCategory {
        if isVideo { return .video }
        return kind == .podcast ? .podcast : .song
    }

    /// Whether the track resumes from its saved playhead instead of starting
    /// over. Podcasts and videos remember where you left off; songs always
    /// start at 0. (Gates position save/restore and the library progress bar.)
    var remembersPosition: Bool {
        playbackCategory == .podcast || playbackCategory == .video
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

extension String {
    /// Pads the string on the left with `pad` until it's at least `width` long.
    func leftPadded(to width: Int, with pad: Character) -> String {
        count >= width ? self : String(repeating: pad, count: width - count) + self
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
