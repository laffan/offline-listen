import SwiftUI

struct DownloadView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackManager

    /// Switches to the player tab after starting playback.
    let onPlay: () -> Void

    @State private var urlText = ""
    @State private var mode: DownloadMode = .audio
    @FocusState private var urlFieldFocused: Bool

    /// True while a YouTube search is in flight (spinner on the button).
    @State private var searching = false
    /// The finished search awaiting a pick (drives the results modal).
    @State private var searchResults: DownloadSearchResults?
    /// A query that came back empty (drives the failure alert).
    @State private var failedQuery: String?
    /// Which album groups are twirled open. Empty by default — a record put in
    /// the queue whole is *one* thing you asked for, and twelve rows of it
    /// burying everything else is the reason the grouping exists.
    @State private var expandedAlbums: Set<UUID> = []

    /// The input reads as a search term when it's non-empty and contains no
    /// downloadable link — then the button flips from Download to Search. A
    /// Spotify reference counts as a link (including the `spotify:track:…` URI
    /// form, which isn't a URL at all).
    private var isSearch: Bool {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !trimmed.split(whereSeparator: { $0.isWhitespace })
            .contains { DownloadManager.isDownloadableToken(String($0)) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                inputCard

                if downloads.jobs.isEmpty {
                    ContentUnavailableViewCompat(
                        title: "No downloads yet",
                        systemImage: "arrow.down.circle",
                        description: "Paste a video, playlist or Spotify link above to start downloading, or type anything else to search YouTube. A playlist or album downloads into its own folder."
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    List {
                        ForEach(listItems) { item in
                            switch item {
                            case .job(let job):
                                jobRow(job)
                            case .album(let album):
                                DisclosureGroup(isExpanded: expansion(of: album.id)) {
                                    ForEach(album.jobs) { job in
                                        jobRow(job)
                                    }
                                } label: {
                                    AlbumDownloadGroupHeader(albumID: album.id,
                                                             title: album.title,
                                                             count: album.jobs.count)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .miniPlayerClearance()
                }
            }
            .padding(.top)
            // No title — the input field says what this screen is, and the
            // height a header would take goes to the queue.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Button {
                            Task { await YoutubeDLExtractor.refreshEngine() }
                        } label: {
                            Label("Refresh yt-dlp engine", systemImage: "arrow.triangle.2.circlepath")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Clear") { downloads.clearFinished() }
                        .disabled(downloads.jobs.isEmpty)
                }
            }
            .sheet(item: $downloads.pendingPlaylist) { pending in
                PlaylistPickerView(pending: pending)
            }
            .sheet(item: $searchResults) { search in
                SearchResultsView(search: search, mode: mode)
            }
            .alert("No results",
                   isPresented: Binding(get: { failedQuery != nil },
                                        set: { if !$0 { failedQuery = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Nothing came back for “\(failedQuery ?? "")”. Check the connection or try different words.")
            }
        }
    }

    private var inputCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    // Paste leads the field rather than trailing it: it's what
                    // you reach for *before* typing anything, and the left edge
                    // is where a hand goes first.
                    if urlText.isEmpty {
                        Button {
                            if let pasted = Pasteboard.string {
                                urlText = pasted
                            }
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Paste")
                    } else {
                        Button {
                            urlText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Clear")
                    }

                    TextField("Paste a URL or search YouTube", text: $urlText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.webSearch)
                        .focused($urlFieldFocused)
                        .submitLabel(isSearch ? .search : .go)
                        .onSubmit(submit)
                }
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))

                modeToggle
            }

            Button(action: submit) {
                if searching {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                } else {
                    Label(isSearch ? "Search" : "Download",
                          systemImage: isSearch ? "magnifyingglass" : "arrow.down")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty || searching)
        }
        .padding(.horizontal)
    }

    /// The Audio/Video toggle — a control of its **own, beside the field**
    /// rather than riding inside it, wearing the Library's music/film glyphs.
    ///
    /// It began as a segmented picker on its own line, which spent a row of the
    /// screen saying what two icons say; then it moved inside the field, where
    /// it fitted but had to shrink to caption-sized glyphs squeezed between the
    /// text and the field's edge. Out here it keeps the compactness and gets
    /// icons you can actually see — and read at a glance, which matters for the
    /// one control that decides what a download *is*.
    private var modeToggle: some View {
        HStack(spacing: 4) {
            ForEach(DownloadMode.allCases) { candidate in
                Button {
                    mode = candidate
                } label: {
                    Image(systemName: candidate.icon)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(mode == candidate ? Color.white : Color.secondary)
                        .frame(width: 40, height: 34)
                        .background(mode == candidate ? Color.accentColor : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Download as \(candidate.displayName)")
            }
        }
        .padding(4)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    /// URLs download; anything else searches YouTube.
    private func submit() {
        let text = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if isSearch {
            search(for: text)
        } else {
            // A link pasted by hand is the one download worth stopping to ask
            // about — see `VideoQualityChooser`.
            downloads.enqueueLinks(from: urlText, mode: mode, asksQuality: true)
            urlText = ""
            urlFieldFocused = false
        }
    }

    /// Fetches the top YouTube results for the term and presents them in the
    /// pick-a-result modal. The query stays in the field so a miss is easy to
    /// refine.
    private func search(for query: String) {
        guard !searching else { return }
        searching = true
        urlFieldFocused = false
        appLog("Searching YouTube for \"\(query)\"…", category: "Queue")
        Task { @MainActor in
            let results = await YouTubeSearchResolver.topVideos(matching: query, limit: 5)
            searching = false
            if results.isEmpty {
                failedQuery = query
                appLog("Search returned no results for \"\(query)\".", level: .warning, category: "Queue")
            } else {
                searchResults = DownloadSearchResults(query: query, results: results)
                appLog("Search found \(results.count) result(s) for \"\(query)\".",
                       level: .success, category: "Queue")
            }
        }
    }

    private func jobRow(_ job: DownloadJob) -> some View {
        DownloadJobRow(job: job)
            .contentShape(Rectangle())
            .onTapGesture { playFinished(job) }
    }

    /// The queue as this screen lists it: an album's tracks folded into one
    /// collapsible group, everything else a row of its own.
    ///
    /// A record's jobs go in as one contiguous batch, so the group takes the
    /// place of the first of them and the rest simply drop out of the top
    /// level. Finishing a half-landed album (Download Album on a record that
    /// crashed partway) queues a second batch for the same folder, and those
    /// join the group they belong to rather than starting a second one.
    private var listItems: [DownloadListItem] {
        var members: [UUID: [DownloadJob]] = [:]
        for job in downloads.jobs {
            guard let id = job.folderID, job.albumTitle != nil else { continue }
            members[id, default: []].append(job)
        }
        var items: [DownloadListItem] = []
        var placed: Set<UUID> = []
        for job in downloads.jobs {
            guard let id = job.folderID, let title = job.albumTitle else {
                items.append(.job(job))
                continue
            }
            guard placed.insert(id).inserted else { continue }
            items.append(.album(AlbumDownloadGroup(id: id, title: title,
                                                   jobs: members[id] ?? [job])))
        }
        return items
    }

    private func expansion(of albumID: UUID) -> Binding<Bool> {
        Binding(get: { expandedAlbums.contains(albumID) },
                set: { open in
                    if open { expandedAlbums.insert(albumID) } else { expandedAlbums.remove(albumID) }
                })
    }

    /// Tapping a finished download plays it and switches to the player.
    private func playFinished(_ job: DownloadJob) {
        guard job.state == .finished,
              let id = job.trackID,
              let track = library.tracks.first(where: { $0.id == id }) else { return }
        playback.play(track, in: library.activeTracks)
        onPlay()
    }
}

/// One album's worth of the queue: the folder its tracks are filing into, the
/// release's name, and the jobs themselves in tracklist order.
private struct AlbumDownloadGroup: Identifiable {
    let id: UUID
    let title: String
    let jobs: [DownloadJob]
}

/// One row of the Download tab's list — a job on its own, or a whole record.
private enum DownloadListItem: Identifiable {
    case job(DownloadJob)
    case album(AlbumDownloadGroup)

    var id: String {
        switch self {
        case .job(let job): return job.id.uuidString
        case .album(let album): return "album:\(album.id.uuidString)"
        }
    }
}

/// The header of an album's group: its sleeve, its name, how much of it has
/// landed, and one bar across the whole record.
///
/// The counts come off `DownloadManager.albumProgress` rather than from the
/// jobs directly — a job publishes to its own row and nowhere else, so a header
/// reading their properties would simply never redraw (see
/// `AlbumDownloadProgress`).
private struct AlbumDownloadGroupHeader: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var library: LibraryStore

    /// The album folder the record's tracks are filing into — also the group's
    /// identity, and how its cover is found.
    let albumID: UUID
    let title: String
    /// How many jobs the group holds, for the moment before the tally lands.
    let count: Int

    private var progress: AlbumDownloadProgress? { downloads.albumProgress[albumID] }

    var body: some View {
        HStack(spacing: 12) {
            cover
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let progress, !progress.isComplete {
                    ProgressView(value: progress.fraction)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// The release's cover, drawn the same way the Library's album rows draw
    /// it — the art the download attached to the folder, or the album's
    /// stand-in colour until it lands. A record whose folder has since been
    /// deleted (its downloads outliving it in the history) keeps a plain
    /// square rather than nothing at all.
    @ViewBuilder
    private var cover: some View {
        if let folder = library.folder(withID: albumID) {
            AlbumCoverArt(folder: folder,
                          image: FolderCover.thumbnail(for: folder,
                                                       tracks: library.tracks(in: folder.id)),
                          cornerRadius: 5)
                .frame(width: 40, height: 40)
        } else {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: "square.stack")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
        }
    }

    private var statusLine: String {
        guard let progress else { return tracks(count) }
        if progress.isComplete {
            return progress.stopped > 0
                ? "\(progress.finished) of \(tracks(progress.total)) · \(progress.stopped) didn’t arrive"
                : "\(tracks(progress.total)) downloaded"
        }
        return "\(progress.settled) of \(tracks(progress.total)) · \(Int(progress.fraction * 100))%"
    }

    private func tracks(_ n: Int) -> String {
        "\(n) track\(n == 1 ? "" : "s")"
    }
}

private struct DownloadJobRow: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject var job: DownloadJob

    private var isActiveOrQueued: Bool {
        job.state.isActive || job.state == .queued
    }

    /// The library track this finished job produced, while it still exists — so
    /// the row shows the same (AI-cleaned) title/artist the Library does, and
    /// keeps up as the AI organizes it.
    private var track: Track? {
        guard let id = job.trackID else { return nil }
        return library.tracks.first { $0.id == id }
    }

    private var displayTitle: String {
        let live = track?.title
        return (live?.isEmpty == false ? live : nil) ?? job.title
    }

    /// The artist to show beneath the title: the live track's, else the
    /// persisted snapshot's. Nil (hidden) when it's unknown or still in flight.
    private var displayArtist: String? {
        for candidate in [track?.artist, job.artist] {
            if let a = candidate, !a.isEmpty, a.lowercased() != "unknown" { return a }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(.subheadline)
                    .lineLimit(1)
                if let displayArtist {
                    Text(displayArtist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 8) {
                statusIcon
                // A long resolution (a Spotify album's per-track YouTube
                // matching) counts itself off here; everything else reads the
                // plain state label.
                Text(job.progressNote ?? job.state.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if job.state == .downloading, job.progress > 0 {
                    Spacer()
                    Text("\(Int(job.progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if job.state == .downloading, job.progress > 0 {
                ProgressView(value: job.progress)
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if isActiveOrQueued {
                Button(role: .destructive) {
                    downloads.cancel(job)
                } label: {
                    Label("Cancel", systemImage: "stop.circle")
                }
            } else {
                Button(role: .destructive) {
                    downloads.remove(job)
                } label: {
                    Label("Clear", systemImage: "trash")
                }
            }

            Button {
                downloads.restart(job)
            } label: {
                Label("Restart", systemImage: "arrow.clockwise")
            }
            .tint(.blue)

            // The row shows the video's title once it's known, so the link it
            // came from is otherwise unreachable from here.
            Button {
                Pasteboard.copy(job.url)
            } label: {
                Label("Copy URL", systemImage: "doc.on.doc")
            }
            .tint(.gray)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job.state {
        case .finished:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled:
            Image(systemName: "stop.circle").foregroundStyle(.secondary)
        case .queued:
            Image(systemName: "clock").foregroundStyle(.secondary)
        default:
            ProgressView().controlSize(.mini)
        }
    }
}

/// The popup shown after a playlist link resolves: lists its entries with
/// checkmarks (all selected by default), a Select-All toggle, and a Download
/// button that queues the chosen entries into a folder. Cancelling — or
/// dismissing the sheet — downloads nothing. The decision is delivered back to
/// the waiting download job via `pending.decide`.
struct PlaylistPickerView: View {
    let pending: PendingPlaylist

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<PlaylistEntry.ID>
    /// Guards against `decide` being called twice (e.g. a button tap followed by
    /// the sheet's `onDisappear`); the download side is idempotent too.
    @State private var decided = false

    init(pending: PendingPlaylist) {
        self.pending = pending
        // Everything selected by default — "grab the whole list" is one tap.
        _selected = State(initialValue: Set(pending.entries.map(\.id)))
    }

    private var allSelected: Bool { selected.count == pending.entries.count }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(pending.entries) { entry in
                        Button {
                            toggle(entry.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selected.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(entry.id) ? Color.accentColor : .secondary)
                                Text(entry.title)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    HStack {
                        Text("\(pending.entries.count) items · \(pending.mode.displayName)")
                        Spacer()
                        Button(allSelected ? "Deselect All" : "Select All") {
                            selected = allSelected ? [] : Set(pending.entries.map(\.id))
                        }
                        .font(.caption.weight(.semibold))
                        .textCase(nil)
                    }
                }
            }
            .navigationTitle(pending.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { finish(nil) }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Download (\(selected.count))") {
                        let chosen = pending.entries.filter { selected.contains($0.id) }
                        finish(chosen)
                    }
                    .fontWeight(.semibold)
                    .disabled(selected.isEmpty)
                }
            }
            .onDisappear { finish(nil) }
        }
    }

    private func toggle(_ id: PlaylistEntry.ID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func finish(_ entries: [PlaylistEntry]?) {
        guard !decided else { return }
        decided = true
        pending.decide(entries)
        dismiss()
    }
}

/// The resolution picker: what the source turned out to offer, once the
/// extraction has run. Not a menu of tiers the app hopes exist — every row is
/// a stream that is actually there, with its codec, its size where the source
/// declared one, and whether it comes with sound or will be muxed with the
/// best audio track (which is how the taller resolutions are possible at all).
///
/// Dismissing takes the best available, which is what the app did before it
/// asked — a picker you can ignore is better than a download that stalls
/// waiting for you.
struct VideoQualityPickerView: View {
    let pending: PendingVideoQuality

    @Environment(\.dismiss) private var dismiss
    /// Guards against deciding twice (a tap, then `onDisappear`).
    @State private var decided = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(pending.renditions) { rendition in
                        Button {
                            finish(rendition.height)
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rendition.label)
                                        .font(.body.weight(.medium))
                                    Text(rendition.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "arrow.down.circle")
                                    .foregroundStyle(Color.accentColor)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("\(pending.renditions.count) qualities available")
                } footer: {
                    Text("Only resolutions this device can decode are listed. A stream with no sound of its own is downloaded together with the best audio and the two are combined into one file.")
                }

                Section {
                    Button("Best Available") { finish(nil) }
                        .fontWeight(.semibold)
                }
            }
            .navigationTitle(pending.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { finish(nil) }
                }
            }
            .onDisappear { finish(nil) }
        }
    }

    private func finish(_ height: Int?) {
        guard !decided else { return }
        decided = true
        pending.decide(height)
        dismiss()
    }
}

/// A finished Download-tab search: the query plus its top YouTube results,
/// presented as a pick-a-result modal via `.sheet(item:)`.
struct DownloadSearchResults: Identifiable {
    let id = UUID()
    let query: String
    let results: [YouTubeSearchResult]
}

/// The search-results modal: the top YouTube hits for the typed term, each row
/// styled like a Browse item — title, channel, and **Download** / **Preview**.
/// Both observe the tab's Audio/Video toggle: Download queues in that mode,
/// and Preview opens the same listen-first modal Browse uses (audio or video —
/// Save files it into the library).
private struct SearchResultsView: View {
    let search: DownloadSearchResults
    let mode: DownloadMode

    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss

    /// The result being previewed (drives the nested preview modal), and the
    /// whole result set as the modal's queue — so previewing the top hit can
    /// run down the rest with next/previous or on its own.
    @State private var previewItem: BrowseItem?
    @State private var previewQueue: [BrowseItem] = []
    /// Results already sent to the queue (their row shows a status instead).
    @State private var sent: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(search.results) { result in
                        SearchResultRow(result: result,
                                        sent: sent.contains(result.videoID),
                                        onDownload: { download(result) },
                                        onPreview: { preview(result) })
                    }
                } header: {
                    Text("Top \(search.results.count) result(s) · \(mode.displayName)")
                }
            }
            .listStyle(.plain)
            .navigationTitle("“\(search.query)”")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(item: $previewItem) { item in
            BrowsePreviewView(item: item, mode: mode, queue: previewQueue)
        }
    }

    private func download(_ result: YouTubeSearchResult) {
        // One hit picked out of a list of five: as deliberate as a pasted
        // link, so it gets the same quality question. The row's own title and
        // channel go with it, so the queue lists what was picked rather than
        // the link behind it.
        downloads.enqueue(urlString: result.url, mode: mode,
                          queuedTitle: result.title,
                          queuedArtist: result.channel.isEmpty ? nil : result.channel,
                          asksQuality: true)
        sent.insert(result.videoID)
    }

    /// Opens the preview on this result with the whole result list behind it.
    /// The items are built once here so the tapped one *is* the queue's entry
    /// (a fresh `BrowseItem` would carry a different id and lose its place).
    private func preview(_ result: YouTubeSearchResult) {
        let queue = search.results.map(browseItem(for:))
        previewQueue = queue
        previewItem = queue.first { $0.url == result.url } ?? browseItem(for: result)
    }

    /// Wraps a search result as a transient `BrowseItem` so the shared preview
    /// modal can play it. The item lives nowhere in the Browse store — its
    /// save/discard bookkeeping there is a harmless no-op.
    private func browseItem(for result: YouTubeSearchResult) -> BrowseItem {
        BrowseItem(sourceID: UUID(),
                   title: result.title,
                   detail: result.channel,
                   url: result.url,
                   videoID: result.videoID)
    }
}

/// One search hit: title, channel, and the same Download/Preview button pair
/// a Browse row carries.
private struct SearchResultRow: View {
    let result: YouTubeSearchResult
    let sent: Bool
    let onDownload: () -> Void
    let onPreview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(result.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)

            if !result.channel.isEmpty {
                Text(result.channel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if sent {
                // Turns into a green play button once the download is in the
                // library, so a search hit can be heard without leaving the
                // results.
                BrowseTrackStatusButton(sourceURL: result.url,
                                        pendingIcon: "checkmark.circle.fill",
                                        pendingLabel: "Sent to Downloads",
                                        showsCaption: true)
            } else {
                HStack(spacing: 10) {
                    Button(action: onDownload) {
                        Label("Download", systemImage: "arrow.down")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(action: onPreview) {
                        Label("Preview", systemImage: "play.circle")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Lightweight stand-in for `ContentUnavailableView` to keep the iOS 16 floor.
struct ContentUnavailableViewCompat: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
}
