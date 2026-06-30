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
}

/// The authoritative set of tracks the phone wants present on the watch.
struct WatchManifest: Codable {
    var tracks: [WatchManifestTrack]
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

    // Chunked file-over-message keys. `transferFile` doesn't deliver on the
    // watchOS Simulator (and only runs in the background on device), so when the
    // watch is reachable the phone streams each audio file as a sequence of
    // `sendMessage` chunks the watch reassembles to disk.
    static let fxName = "fxName"
    static let fxIndex = "fxIndex"
    static let fxTotal = "fxTotal"
    static let fxData = "fxData"
    /// Per-message audio chunk size (bytes); kept well under the WC message limit.
    static let fxChunkSize = 48_000

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
