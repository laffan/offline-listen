import SwiftUI

/// One genre or artist put aside to come back to.
///
/// Deliberately the same shape as an `ENHistoryEntry` — kind, the genre key, an
/// artist id, the name and its map colour — because it is saved *from* the
/// visit log and re-opens exactly the way a history row does: a genre shows its
/// artists, a mapped artist lands on their genre's map, a Spotify artist goes
/// straight back to their discography.
///
/// Unlike History, though, this is a **set, not a log**: saving something twice
/// lifts it back to the top rather than listing it again.
struct SavedForLaterItem: Codable, Identifiable, Hashable {
    let id: UUID
    let kind: ENVisitKind
    let genreKey: String
    let artistID: String?
    let name: String
    let color: String
    let detail: String?
    var date: Date

    init(id: UUID = UUID(), kind: ENVisitKind, genreKey: String, artistID: String? = nil,
         name: String, color: String = "", detail: String? = nil, date: Date = Date()) {
        self.id = id
        self.kind = kind
        self.genreKey = genreKey
        self.artistID = artistID
        self.name = name
        self.color = color
        self.detail = detail
        self.date = date
    }

    /// What makes two saves the same thing (the id can't — it's minted per
    /// save, and the point is that a second save isn't a second row).
    var key: String {
        "\(kind.rawValue)|\(genreKey)|\(artistID ?? "")|\(name.lowercased())"
    }
}

extension ENHistoryEntry {
    /// The same genre or artist, as something to save.
    var savedForLater: SavedForLaterItem {
        SavedForLaterItem(kind: kind, genreKey: genreKey, artistID: artistID,
                          name: name, color: color, detail: detail)
    }
}

extension AppPaths {
    static var savedForLater: URL {
        documents.appendingPathComponent("saved-for-later.json")
    }
}

/// The Saved for Later list, behind the bookmark button in the Browse tab's
/// top-right corner. App-level (wired in `OfflineListenApp`) because three
/// screens touch it — the History rows that fill it, the browser's own button
/// that shows it, and the discography page's Save for Later — and two of those
/// are pushed destinations, which don't inherit anything injected inside the
/// browser.
@MainActor
final class SavedForLaterStore: ObservableObject {
    @Published private(set) var items: [SavedForLaterItem] = []

    private static let maxItems = 300

    init() {
        guard let data = try? Data(contentsOf: AppPaths.savedForLater),
              let decoded = try? JSONDecoder().decode([SavedForLaterItem].self, from: data) else { return }
        items = decoded
    }

    var genres: [SavedForLaterItem] { items.filter { $0.kind == .genre } }
    /// Both kinds of artist row — one off the map, one off Spotify — read as
    /// "artists" to anyone looking at the list.
    var artists: [SavedForLaterItem] { items.filter { $0.kind != .genre } }

    func contains(_ item: SavedForLaterItem) -> Bool {
        items.contains { Self.sameThing($0, item) }
    }

    /// Saves (or re-saves, which just lifts it back to the top).
    func save(_ item: SavedForLaterItem) {
        items.removeAll { Self.sameThing($0, item) }
        items.insert(item, at: 0)
        if items.count > Self.maxItems {
            items.removeLast(items.count - Self.maxItems)
        }
        persist()
        appLog("Saved for later: \(item.name)", category: "Browse")
    }

    /// On/off for the buttons that read as switches — the artist bar's
    /// bookmark and the discography page's tile. Saving takes whatever
    /// flavour of the row the caller has; unsaving takes **every** row for
    /// that thing, so an artist saved off the map and re-saved off their
    /// discography can't survive one tap of "remove".
    func toggle(_ item: SavedForLaterItem) {
        guard contains(item) else { return save(item) }
        items.removeAll { Self.sameThing($0, item) }
        persist()
        appLog("Removed from Saved for Later: \(item.name)", category: "Browse")
    }

    func remove(_ item: SavedForLaterItem) {
        items.removeAll { $0.id == item.id }
        persist()
    }

    /// Whether two saved rows are the same genre or the same artist.
    ///
    /// Not just `key ==`, because one artist legitimately arrives in two
    /// shapes: off the map they're a shard id inside a genre, off Spotify (a
    /// search hit, or the discography page's own button) they're a catalogue
    /// id with no genre at all. Nothing links those two ids, so the **name**
    /// is what they have in common — which is also what the user means when
    /// they open a page and expect the button to already read as saved. Two
    /// distinct artists sharing a name collapse into one row; that's the
    /// price, and it's a good deal cheaper than the same artist appearing
    /// twice and each button disagreeing about whether they're saved.
    private static func sameThing(_ a: SavedForLaterItem, _ b: SavedForLaterItem) -> Bool {
        if a.key == b.key { return true }
        // A genre is its key on the map, whatever it's called.
        if a.kind == .genre || b.kind == .genre {
            return a.kind == b.kind && a.genreKey == b.genreKey
        }
        if a.kind == b.kind, let idA = a.artistID, let idB = b.artistID, idA == idB { return true }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedSame
    }

    func clear() {
        items.removeAll()
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: AppPaths.savedForLater, options: .atomic)
    }
}

/// The swipe-right action every list of genres and artists carries: keep this
/// one for later. A modifier rather than a copy per list, since all four of
/// them (History at both levels, the genre list, a genre's artist list) want
/// exactly the same button — and it reads the store itself, so a caller only
/// has to say *what* the row is.
private struct SaveForLaterSwipe: ViewModifier {
    @EnvironmentObject private var saved: SavedForLaterStore

    let item: SavedForLaterItem

    func body(content: Content) -> some View {
        content.swipeActions(edge: .leading, allowsFullSwipe: true) {
            let already = saved.contains(item)
            Button {
                saved.save(item)
            } label: {
                Label(already ? "Saved" : "Save for Later",
                      systemImage: already ? "bookmark.fill" : "bookmark")
            }
            .tint(already ? .gray : .orange)
        }
    }
}

extension View {
    /// Swipe this row right to put `item` on the Saved for Later list.
    func saveForLaterSwipe(_ item: SavedForLaterItem) -> some View {
        modifier(SaveForLaterSwipe(item: item))
    }
}

/// The Saved for Later list: the genres and artists put aside from History (or
/// from an artist's own page), grouped by kind. A row opens the thing itself —
/// the same three destinations a History row leads to — and swipes away.
struct SavedForLaterView: View {
    @EnvironmentObject private var saved: SavedForLaterStore
    @Environment(\.dismiss) private var dismiss

    /// Handed the picked item, after the sheet has closed — the browser owns
    /// the navigation, exactly as it does for History.
    let onOpen: (SavedForLaterItem) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if saved.items.isEmpty {
                    ContentUnavailableViewCompat(
                        title: "Nothing saved yet",
                        systemImage: "bookmark",
                        description: "Swipe right on a History row — or use Save for Later on an artist's page — to keep something to come back to."
                    )
                } else {
                    list
                }
            }
            .navigationTitle("Saved for Later")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var list: some View {
        List {
            section("Artists", saved.artists)
            section("Genres", saved.genres)
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private func section(_ title: String, _ entries: [SavedForLaterItem]) -> some View {
        if !entries.isEmpty {
            Section(title) {
                ForEach(entries) { item in
                    Button {
                        // Close first: the destinations are pushes on the
                        // browser's own stack, which can't happen under a sheet.
                        dismiss()
                        onOpen(item)
                    } label: {
                        row(item)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            saved.remove(item)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private func row(_ item: SavedForLaterItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(for: item.kind))
                .foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .foregroundStyle(item.color.isEmpty ? Color.primary : Color(noiseHex: item.color))
                    .lineLimit(1)
                if let detail = item.detail {
                    Text(item.kind == .spotify ? detail : "in \(detail)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(item.date.formatted(.relative(presentation: .named)))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func icon(for kind: ENVisitKind) -> String {
        switch kind {
        case .genre: return "guitars"
        case .artist: return "music.mic"
        case .spotify: return ENFindMode.spotify.icon
        }
    }
}
