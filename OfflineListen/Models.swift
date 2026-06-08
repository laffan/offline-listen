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

/// Output container the user can pick for a download.
enum AudioFormat: String, Codable, CaseIterable, Identifiable {
    case m4a
    case mp3

    var id: String { rawValue }
    var fileExtension: String { rawValue }
    var displayName: String { rawValue.uppercased() }
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

    init(id: UUID = UUID(),
         title: String,
         artist: String = "Unknown",
         fileName: String,
         sourceURL: String,
         duration: Double = 0,
         dateAdded: Date = Date(),
         isArchived: Bool = false) {
        self.id = id
        self.title = title
        self.artist = artist
        self.fileName = fileName
        self.sourceURL = sourceURL
        self.duration = duration
        self.dateAdded = dateAdded
        self.isArchived = isArchived
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, artist, fileName, sourceURL, duration, dateAdded, isArchived
    }

    // Custom decode so libraries saved before `isArchived` existed still load.
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
