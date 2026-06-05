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

    init(id: UUID = UUID(),
         title: String,
         artist: String = "Unknown",
         fileName: String,
         sourceURL: String,
         duration: Double = 0,
         dateAdded: Date = Date()) {
        self.id = id
        self.title = title
        self.artist = artist
        self.fileName = fileName
        self.sourceURL = sourceURL
        self.duration = duration
        self.dateAdded = dateAdded
    }

    /// Absolute on-disk location resolved at access time.
    var fileURL: URL {
        AppPaths.documents.appendingPathComponent(fileName)
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
