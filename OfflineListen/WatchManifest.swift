import Foundation

/// The wire format shared between the iPhone app and the watchOS app for keeping
/// the watch's offline library in sync. Compiled into **both** targets (like
/// `SharedInbox.swift` is shared by the app and the Share Extension) so the
/// phone's encode and the watch's decode never drift apart.
///
/// The phone is the source of truth: it pushes a full `WatchManifest` describing
/// exactly which tracks should live on the watch, plus the audio files
/// themselves. The watch renders its List from the manifest and prunes any local
/// file whose `fileName` no longer appears in it.

/// One track in the watch manifest. A lightweight projection of `Track` carrying
/// only what the watch needs to list and play it offline.
struct WatchManifestTrack: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var artist: String
    /// File name only (relative to the watch's Documents directory), matching the
    /// name the audio file is transferred under.
    var fileName: String
    var duration: Double
    /// `TrackKind.rawValue` ("song" / "podcast"). Kept as a string so the watch
    /// target doesn't need to share the phone's `TrackKind` type.
    var kindRaw: String
    /// The name of the playlist (folder) this track was sent as part of, or nil
    /// when it was sent on its own. The watch groups by this for the List pane.
    var folderName: String?
    /// Position in the phone's watch set, so the watch can preserve order.
    var order: Int
    /// Total audio file size in bytes, so the watch can show sync % from the size
    /// of its in-progress `.part` file. 0 when unknown (older phone build).
    var byteSize: Int
    /// Saved podcast playhead (seconds) at sync time, for cold-start resume. Live
    /// changes flow via position-sync messages. 0 for songs / unknown.
    var lastPosition: Double

    init(id: UUID, title: String, artist: String, fileName: String, duration: Double,
         kindRaw: String, folderName: String?, order: Int, byteSize: Int = 0, lastPosition: Double = 0) {
        self.id = id
        self.title = title
        self.artist = artist
        self.fileName = fileName
        self.duration = duration
        self.kindRaw = kindRaw
        self.folderName = folderName
        self.order = order
        self.byteSize = byteSize
        self.lastPosition = lastPosition
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, artist, fileName, duration, kindRaw, folderName, order, byteSize, lastPosition
    }

    // Decode tolerant of older payloads missing the newer fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        artist = try c.decode(String.self, forKey: .artist)
        fileName = try c.decode(String.self, forKey: .fileName)
        duration = try c.decode(Double.self, forKey: .duration)
        kindRaw = try c.decode(String.self, forKey: .kindRaw)
        folderName = try c.decodeIfPresent(String.self, forKey: .folderName)
        order = try c.decode(Int.self, forKey: .order)
        byteSize = try c.decodeIfPresent(Int.self, forKey: .byteSize) ?? 0
        lastPosition = try c.decodeIfPresent(Double.self, forKey: .lastPosition) ?? 0
    }
}

/// The authoritative set of tracks the phone wants present on the watch.
struct WatchManifest: Codable {
    var tracks: [WatchManifestTrack]
}

/// A snapshot of what the **phone** is currently playing, pushed to the watch so
/// the watch's Listen pane can repurpose itself into a remote control
/// ("Controlling iPhone"). Sent on every meaningful phone-side transition (start,
/// pause/resume, seek, track change); the watch interpolates the playhead locally
/// between snapshots. A `nil` snapshot (signalled by `WatchSyncKeys.remoteStop`)
/// means the phone isn't playing anything, so the watch drops out of remote mode.
struct RemoteNowPlaying: Codable, Equatable {
    var trackID: UUID
    var title: String
    var artist: String
    var duration: Double
    var elapsed: Double
    var isPlaying: Bool
    /// True for a podcast — the watch then shows the 15s/30s jump transport
    /// (mirroring the phone's lock screen) instead of previous/next.
    var isPodcast: Bool
}

/// Transport commands the watch sends back to the phone while acting as its
/// remote. String-valued so the watch target needn't share any phone types.
enum RemoteCommand {
    static let togglePlayPause = "togglePlayPause"
    static let next = "next"
    static let previous = "previous"
    static let skipForward = "skipForward"
    static let skipBackward = "skipBackward"
}

/// Keys and command values used across the WatchConnectivity channel.
enum WatchSyncKeys {
    /// Application-context key whose value is a JSON-encoded `WatchManifest`.
    static let manifest = "manifest"

    /// Message/userInfo key naming a command from the watch to the phone.
    static let command = "command"
    /// Command sent when the user taps "Clear all Tracks" on the watch, so the
    /// phone empties its Watch folder to match.
    static let clearAllCommand = "clearAll"

    /// userInfo key carrying a watch-side log line for the phone to surface in
    /// its Log tab, so the whole sync is debuggable from one place.
    static let log = "log"

    /// Position-sync userInfo keys (either direction): a podcast playhead update.
    static let positionID = "posID"     // track id (UUID string)
    static let positionValue = "posValue" // seconds (Double)

    // Remote-control keys. While the phone is playing, it pushes its now-playing
    // snapshot to the watch, which repurposes its Listen pane into a remote and
    // sends transport commands back.
    static let remoteState = "remoteState"   // phone → watch: JSON-encoded RemoteNowPlaying
    static let remoteStop = "remoteStop"     // phone → watch: phone playback ended (value: true)
    static let remoteCommand = "remoteCmd"   // watch → phone: a RemoteCommand string

    // Resumable chunked-stream keys. `transferFile` is the primary path, but on
    // device pairs where the system file-transfer channel never establishes
    // (it accepts the transfer yet moves no bytes), the phone streams the file
    // over the live message channel instead. The watch keeps a `.part` file and
    // reports how many bytes it already has, so a dropped connection resumes from
    // that offset rather than restarting.
    static let fxQuery = "fxQuery"   // phone → watch: value is the file name; asks the current offset
    static let fxName = "fxName"     // chunk message: the file name
    static let fxOffset = "fxOffset" // chunk message: byte offset this chunk starts at
    static let fxData = "fxData"     // chunk message: the bytes
    static let fxEof = "fxEof"       // chunk message: true on the final chunk
    static let fxHave = "fxHave"     // watch → phone reply: bytes the watch now holds
    static let fxDone = "fxDone"     // watch → phone reply: the whole file is present
    static let fxOk = "fxOk"         // watch → phone reply: chunk accepted at the expected offset
    /// Per-message chunk size. The WatchConnectivity message ceiling is ~64 KB,
    /// so this is the practical maximum payload per round-trip.
    static let fxChunkSize = 50_000

    // Per-file `transferFile` metadata keys (a self-describing copy of the
    // manifest fields, so a file can be ingested even before/without a manifest).
    static let metaID = "id"
    static let metaTitle = "title"
    static let metaArtist = "artist"
    static let metaFileName = "fileName"
    static let metaDuration = "duration"
    static let metaKind = "kindRaw"
    static let metaFolderName = "folderName"
    static let metaOrder = "order"
}
