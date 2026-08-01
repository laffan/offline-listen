# Offline Listen

A SwiftUI iPhone app that downloads the audio from a video URL, saves it to the
device, and plays it back offline — including in the background with the phone
locked.

> **Personal-use tool.** Downloading from sites like YouTube may conflict with
> their Terms of Service and with copyright. Only download content you own or
> have the right to, and use this responsibly.

## What's here

Five screens (tabs):

1. **Download** — paste one or more URLs (whitespace/line-break separated; any
   http(s) link is queued and the rest of a pasted blob is skipped), choose
   **Audio** or **Video** (default Audio), watch the queue. Links from **any site
   yt-dlp supports** work — YouTube, Vimeo, SoundCloud and ~hundreds more — not
   just YouTube — plus **Spotify** links, which take a different route (see
   **Spotify links** below). Swipe a row for **Cancel** (active/queued), **Restart**, or
   **Clear**; tap a finished row to play it. Each finished row shows the track's
   **title and artist** (kept in step with the Library, so an AI-cleaned name
   shows here too). The queue is a **running history** — it persists across
   relaunches (`Documents/downloads.json`, capped at the 500 most recent), so
   what you've downloaded stays listed until you **Clear** it; only in-flight
   jobs are dropped on quit. The tab's **badge** shows how many downloads are
   active or queued. The queue runs **up to two downloads at once** (see
   [the pipeline notes](#browse-keeping-tabs-on-audio-sources) — the network
   work runs in parallel while everything touching the embedded Python
   interpreter stays serialized).

   **Search.** The same single input field doubles as a search box: type
   anything that *isn't* a link and the button flips from **Download** to
   **Search**. It scrapes YouTube's results page and returns the **top 5
   videos** in a popup styled like a Browse list — title, channel, and
   **Download** / **Preview** per row. Both observe the tab's **Audio/Video
   toggle**: Download queues the pick in that mode, and Preview opens the same
   listen-first modal Browse uses — with a picture, in Video mode — where Save
   files it into the library. A URL still behaves exactly as before — the
   process only changes when no link is detected.

   **Playlists.** Paste a **YouTube playlist** link — either the dedicated
   `…/playlist?list=…` page or a `watch?v=…&list=…` link opened from inside a
   playlist — and the app resolves its entries and shows a **selection popup**
   listing every video. Everything is checked by default, so **Download** grabs
   the whole list in one tap; or check off just the ones you want (a
   **Select All / Deselect All** toggle is in the header). Confirming creates a
   **folder named after the playlist** and queues the chosen entries into it (in
   playlist order, using the same Audio/Video mode); cancelling — or dismissing
   the popup — downloads nothing. A playlist row sits in the queue while it
   resolves and while the popup is open, then reports how many downloads it
   spawned. Auto-generated **mixes/radios** (`RD…` list ids) and the auth-only
   **Watch Later** / **Liked** lists are treated as ordinary single-video links,
   not playlists. Resolving the entry list uses the on-device yt-dlp module, so —
   like chapter capture — it works only once that module has been fetched by a
   prior download. The same selection popup also serves **Spotify** albums,
   playlists and artists.

   **Spotify links.** Paste a Spotify **track**, **album**, **playlist** or
   **artist** — the `open.spotify.com/…` link (localized `intl-xx` share links
   and `?si=…` share tokens included), the `spotify:track:…` URI, or a
   `spotify.link` short link — and the app reads its metadata from Spotify,
   matches **each track to a YouTube video**, and sends the results through the
   ordinary download pipeline. A single track queues one download, like pasting
   one YouTube link; an album, playlist or artist gets the **same selection
   popup** a YouTube playlist does and lands in a **folder named after the
   album/playlist/artist** (re-pasting reuses that folder rather than making a
   second one). The queue row counts the matching off — *Resolving 42 of 137…* —
   since every track costs a YouTube search; one paste resolves at most **200**
   tracks, and anything past that is dropped and logged.

   Every track resolved from Spotify also carries its **album art** into the
   download — the finished track wears the cover in the Player, the lock
   screen and the mini player (see [Album art](#album-art)).

   Matching is ISRC-first: an ISRC names a specific *recording*, so a hit is
   almost always the right master rather than a live take or a lyric-video
   re-upload. Failing that it searches `"artist - title"` and rejects any result
   whose length differs from Spotify's by more than 15 seconds. A track nothing
   matches is skipped with a warning — the rest of the playlist still comes
   through — and the **Log** records every resolution (which query matched, and
   the video it chose), which is where to look if a wrong track lands.

   This is **not** a Spotify player: nothing is downloaded *from* Spotify, which
   only supplies the track list. It needs free developer credentials (Settings ▸
   **Spotify**, below) and reads **public** metadata only,
   so your saved songs and private playlists aren't visible to it. Podcast
   episodes and audiobooks aren't supported, and a playlist's local files and
   episodes are skipped (each noted in the Log). Unlike the YouTube playlist
   path, none of this touches the on-device yt-dlp module, so Spotify links work
   on a fresh install — only the downloads they spawn need the extractor.
2. **Browse** — keeps tabs on and curates different audio **sources** (see
   [Browse: keeping tabs on audio sources](#browse-keeping-tabs-on-audio-sources)).
   Add YouTube channels/playlists, RSS feeds, a **Blog Agent** for blogs
   without a feed, an **Artist** source (following their **Top 10**, an
   AI-laid-out **Search Discography**, or their real **Spotify Discography**),
   or AI-curated Genre / Country
   lists; each refresh surfaces YouTube links, shown as compact
   name-over-artist rows, and
   every item offers **Download** (sends it to the download queue) and
   **Preview** (a listen-first modal with **Save** / **Discard**). A **world
   button** beside the "+" opens the **Every Noise browser** — the whole
   [Every Noise at Once](https://everynoise.com) genre map, bundled into the
   app and browsable offline; tapping an artist there leads to their live
   Spotify discography, or files them into Browse as an Artist source (see
   [The Every Noise browser](#the-every-noise-browser)). A **Select**
   button in a source's list flips it into multi-select, so you can tick a
   batch of items and download them all in one tap. An
   **Audio/Video toggle** beneath the Browse title — the same one the Download
   tab has — sets which mode both buttons (and the bulk download) act in.
3. **Library** — downloaded tracks; tap to play. The **Tracks** section lists
   **every** track — filed into a folder or not — so it's the full flat view
   of the library (folders are one way in, not the only one). A **search**
   field sits under
   the title: type anything and the list becomes results — matching **folders**
   first, then every track whose **title or artist** matches. Matching ignores
   case and accents, so "beyonce" finds "Beyoncé", and the media-type filter
   still applies. Results come back **as you type** — see
   [Why the library is fast](#why-the-library-is-fast) for what that costs.
   A **filter** (All / Music /
   Podcasts / Video) sits directly beneath the **Tracks** header. Swipe **left**
   for Delete/Share/Archive (and bulk versions via **Select**); swipe **right**
   on an audio track to classify it **Song** or **Podcast**. Songs start from the
   beginning; podcasts (mic icon) and videos (film icon) resume where you left
   off and show a progress bar. A track you haven't listened to yet shows a
   **green** icon. Video tracks play with picture on the Player screen. Archived
   tracks (and archived folders) live in the **Archive**, pinned to the bottom of
   the folder list.

   **Autoplay.** When a track finishes, playback advances to the next track in
   the same list and keeps going to the end — it doesn't loop. In the
   **auto-aggregated** lists (the Tracks root and the Inbox), where media types
   are mixed together, autoplay **stays within the media type** you started: pick
   a song and only songs play on (podcasts and videos are skipped until the next
   song or the list ends), and likewise for podcasts and videos. A **folder is a
   curated playlist**, though, so it **plays straight through in list order**
   regardless of type — tap any track and the whole folder plays in sequence.

   **Recent.** A virtual folder — the mirror image of the Inbox — listing what
   you've **played**, most recent first, with each row showing when. A track
   joins it the moment playback *starts*; it doesn't have to finish. It's a
   **log, not a set**: the same track appears once per listen, so a track you
   keep coming back to shows up repeatedly — only *consecutive* repeats are
   collapsed, since restarting the track you're already on isn't a new listen.
   Nothing lives there (the tracks stay wherever they are), so removing a row —
   or **Clear** — only forgets the listen. The log keeps the last 200 plays in
   `Documents/recents.json`.

   **Chapters.** Tracks that carry YouTube chapter markers show an **arrow**
   after the title, set off by a left border so it reads as a button distinct
   from the row: tapping the **title** plays the track normally, tapping the
   **arrow** opens a list of chapters to jump to. Touch-and-hold such a track
   for **Break Chapters into Playlist**, which exports one file per chapter into
   a new folder named after the track and then asks whether to delete the
   original — turning a chaptered recording into a proper playlist. The
   chapter list also highlights the chapter currently playing.

   **Folders** organize the library, under a **Folders** header (mirroring the
   Tracks one). A folder with a **cover** — an album pulled down whole from a
   discography — draws it as a thumbnail on the left of its row in place of
   the folder icon. An **Inbox** pinned to the top collects every track you haven't
   listened to yet (starting playback — or a **Mark Played** swipe — clears it
   from the Inbox), **Recent** and **Watch** sit beneath it, user folders below
   those, and the **Archive** is pinned to
   the bottom. Create folders with the toolbar's folder button; move tracks in
   via touch-and-hold → **Move to Folder** (or the bulk Select menu). The Inbox
   is itself a move target — moving a track there returns it to unlistened.
   Touch-and-hold also offers **Edit Metadata**, a modal for hand-editing the
   track **title and artist** (handy when AI Organize doesn't get it quite
   right), with **Reset to Original Title** to restore the download title —
   and, with Spotify credentials saved, **Get Album Art**, which finds the
   track's cover on Spotify and attaches it (see [Album art](#album-art)).
   A downloaded track also offers **Convert to Video** / **Convert to
   Audio**: the file is re-downloaded from its source in the other format,
   into the same folder, and the original is replaced only once the fresh
   download has fully landed — a failed conversion costs nothing (the
   attempt shows in the Download tab like any job). Tracks with no source
   link (local-sync imports) don't offer it. Swipe
   a folder row for its slide menu: **Delete** (the folder only — its tracks
   return to the library),
   **Rename**, and **Archive** (move the whole folder, tracks and all, into the
   Archive). To **reorder** the tracks inside a folder, use the **Reorder**
   button in the folder's own screen.

   **The "Synced" grouping.** With several sync folders mirrored in, the
   folders that mirror them can crowd out your own. Settings ▸ Local Sync ▸
   **Group under a "Synced" folder** collects them all behind a single
   **Synced** row (just above the Archive) instead. It's *purely* a display
   grouping — nothing moves on disk, no folder changes its place in the data,
   the rows keep the same swipe actions and touch-and-hold menu — so it can be
   turned on and off at any point with no effect on the sync setup.

   The folder list itself sorts two ways, chosen with the toggle on the right of
   the **Folders** header: **Name** (alphabetical) or **User Order**. In User
   Order you set the sequence by hand — **touch and hold a folder and drag** it
   into place; the order persists to `folders.json`. Folders persist to
   `Documents/folders.json`.

   **Folders nest.** A folder's own screen has the same folder-plus button to
   create a subfolder, and any subfolders list in a **Folders** section above
   the tracks. (Nesting is what lets the local sync folder's directory tree
   mirror into the library — see
   [Local sync](#local-sync-a-folder-that-mirrors-part-of-the-library).)

   **Mixtapes.** Touch-and-hold a folder for **Convert to Mixtape**: the
   folder's title now draws over a cover-image banner — in the folder list and
   atop its own screen — with an **Edit Cover** button at the bottom of its
   track list for picking the image, positioning the crop, and choosing a
   title font. **Convert to Folder** turns it back. See
   [Mixtape folders](#mixtape-folders).
4. **Player** — artwork, scrubber, play/pause, skip, next/previous — the same
   control suite for audio and video, and it drives the lock screen and
   Control Center. A track downloaded with **album art** (anything
   Spotify-sourced — see [Album art](#album-art)) shows its real cover in
   place of the gradient placeholder — on the lock screen and in the mini
   player too. **Tap anywhere on the scrub bar to jump there**; dragging
   works as before, so you never have to drag the playhead across a track
   just to skip ahead. Beneath the transport, the **previous track** is named
   on the left and the **next track** on the right (labelled as such, with
   artist under title) — tap either to go straight to it. Video is
   edge-to-edge in portrait, and **tapping the picture hands it the whole
   screen**: title, transport, nav and tab bars all step aside, and a tap
   brings back the floating controls with a button to shrink it again. It
   also goes fullscreen on its own when the phone rotates to landscape. For a
   chaptered track, small **dots** sit along the scrubber at each chapter's
   start and the **current chapter title** shows on its own line beneath the
   title/artist, updating as playback crosses a marker.

   **The mini player.** Whenever a track is loaded — playing, paused, or the
   one restored at launch — a low-profile bar rides just above the tab bar on
   *every other screen*: a hairline progress line, what's playing, play/pause
   and next — so you can keep browsing or searching without going back to the
   Player. Tapping the title opens the Player. It's attached as a safe-area
   inset outside each tab's `NavigationStack`, and with nothing loaded it
   takes up no room at all. That inset draws the bar but does **not** reach
   the UIKit-backed containers *inside* the stack (the navigation controller
   hosts each screen in its own hosting controller, which sees only UIKit's
   safe area) — left alone, every List/Form's last row hides behind the bar.
   So the bar publishes its measured height as `\.miniPlayerHeight`, and each
   scrollable screen re-declares it locally via `.miniPlayerClearance()` —
   that's what actually makes content scroll clear. The Every Noise maps take
   the same height as extra scroll inset, and their scan/artist-preview bars
   pad themselves by it, since the maps run edge to edge under the tab bar.
5. **Settings** — AI configuration on top, then **Spotify** credentials, an
   **Every Noise Data** section, a
   **Local Sync** section, a
   **Blog Agent** section (posts per
   refresh / songs per post limits for the Browse tab's Blog Agent sources),
   and the **Log** as a section beneath them.
   - **Every Noise Data.** An opt-in toggle that lets browsing the genre map
     top the bundled dataset up, a tally of what it has found, and **Download
     New Data** to share that off the device (see
     [Keeping the dataset from ageing](#keeping-the-dataset-from-ageing)).
   - **Local Sync.** Pick a folder (in Files — On My iPhone, iCloud Drive, or
     any file provider) to sync part of the library with; see
     [Local sync](#local-sync-a-folder-that-mirrors-part-of-the-library).
     Removing the sync folder keeps its files — they just leave the library.
     A **Group under a "Synced" folder** toggle appears once a sync folder is
     configured: purely a display choice for the Library's folder list, safe to
     flip either way at any time.
   - **AI model & API key.** Pick **Haiku** (fast/cheap) or **Sonnet** (more
     capable), paste an Anthropic API key, and **Verify & Save** — the key is
     checked against the API and, on success, stored in the device **Keychain**
     so it persists between sessions. Once a key is saved, an **AI assist with
     organization** toggle appears.
   - **Spotify credentials.** A **client ID** and **client secret** from a free
     app at [developer.spotify.com](https://developer.spotify.com), then
     **Verify & Save** — checked against Spotify and, on success, stored in the
     **Keychain**, exactly like the AI key. They're what makes pasted Spotify
     links work. Authorization is the **Client Credentials** flow: the app signs
     in as *itself*, not as you, so it reads **public** metadata only — no liked
     songs, no private or collaborative playlists, no user library. A private
     playlist's link fails with a message saying so rather than silently
     returning nothing. When Spotify is rate limiting the app, this section
     shows the **countdown** until the window clears, plus **Forget the wait
     and retry** (see the Spotify-politeness notes under
     [The Every Noise browser](#the-every-noise-browser)).
   - **Log** — a row that opens the timestamped, copyable stream of every
     pipeline step (queue, yt-dlp, conversion, AI) with light colour coding, for
     diagnosing downloads.

### AI-assisted organization

With a verified key and **AI assist** turned on, the AI lightweight-organizes
your library via Anthropic's Messages API:

- **On download**, each finished audio track is sent to the chosen model with its
  **title and duration**. The model decides **music vs. podcast** (auto-setting
  the track's kind, so the Library filter and resume/lock-screen behaviour follow
  suit) and, for music, extracts a **clean track title and artist** from the noisy
  YouTube title (dropping "Official Video", channel names, brackets, view counts,
  …). Library rows already show the title prominently with the artist in smaller,
  lower-opacity text beneath it — now that line is populated.
- **On demand**, any already-downloaded audio track gets an **AI Organize** entry
  in its touch-and-hold menu (shown only when a key is configured), so older
  tracks can be tidied up too.

A title the AI rewrites records the original, so **Edit Metadata → Reset to
Original Title** still restores the download title. AI work is best-effort and runs off the
download queue — failures are logged, never fatal. No key, no AI: everything else
is unchanged.

### Why the library is fast

The Library screen asks the same few questions over and over — is this track's
folder archived, how many tracks does that folder hold, which tracks match what
I've typed — and it asks them once per row, per redraw. Answered from scratch
each time, those questions are quadratic in the size of the library, and on a
few hundred tracks that was enough to stall search for seconds before the first
result appeared. Three things keep it quick, and they're worth preserving:

- **`LibraryStore` memoizes its derived state.** The set of archived folder ids
  (the closure of `isArchived` over the parent links), the active-track list,
  a track-id index, per-folder track counts, and the search index are each
  computed once and cached. Every cache is dropped by a `didSet` on `tracks` /
  `folders`, so nothing can go stale — mutate the arrays as usual and the
  answers rebuild on next read.
- **Search matches on folded text, not collated text.**
  `localizedStandardContains` re-derives its case/diacritic collation on *every*
  comparison. Both sides are folded once instead (`searchKey`), and the
  comparison is a plain literal substring search — same "beyonce finds Beyoncé"
  behaviour, a fraction of the work.
- **The views resolve a result list once per redraw.** `row(for:in:)` takes the
  whole list as the playback queue, so passing a computed property directly made
  each row recompute the entire search. `searchList` / `libraryList` bind it to
  a local first. Typing is debounced by 150 ms on top, so a burst of keystrokes
  rebuilds the list once rather than once per letter.

### Album art

Album art is part of the download wherever the cover is known up front —
which today means everything that comes **through Spotify metadata**: pasted
Spotify tracks/albums/playlists/artists, and every download or preview-save
from a Spotify-backed discography page (Every Noise's Browse Discography, a
Spotify Discography source). The enqueue carries the cover's URL on the
`DownloadJob`; once the finished track lands in the library the image is
fetched **best-effort** (a failure just keeps the placeholder, never an
error) into `Documents/Artwork/<track-id>.jpg` and recorded on the track
(`artworkFileName`). From there it shows:

- in the **Player**, replacing the gradient placeholder;
- on the **lock screen / Control Center** (`MPMediaItemPropertyArtwork`,
  loaded once per track change — never on the 2 Hz tick);
- as a small cover in the **mini player**.

Tracks that arrived *without* a cover aren't stuck with the placeholder:
with Spotify credentials saved, touch-and-hold any track and **Get Album
Art** searches Spotify by the track's (AI-cleaned) artist + title and
attaches the best hit's cover through the same fetcher — best-effort like
every artwork fetch, so a miss logs and changes nothing.

**Folders wear covers too.** An album downloaded whole from a discography
(**Download Album**, above) keeps the release's cover on the *folder*, in
`Documents/FolderArtwork/<folder-id>.jpg` — drawn as the thumbnail on the left
of its row in the Library's folder list, in place of the folder glyph (a
synced folder keeps its sync badge, tucked into the corner of the cover). It's
quite separate from a **mixtape**'s hand-framed banner, which is still its own
thing.

Artwork is app-local display metadata: it's never synced or exported with the
file, it's deleted with the track (or the folder), and tracks without it
(YouTube feeds, searches, plain pastes) simply keep the placeholder. Decoded
images are memoized (`TrackArtwork` / `FolderArtwork`, `NSCache`s) so list
redraws never re-read disk.

## Browse: keeping tabs on audio sources

The **Browse** tab watches a set of user-configured **sources** and turns what
they surface into a curated to-listen list. Every source, whatever its type,
produces the same thing: **YouTube links with metadata** — each shown as a
compact row of just the artist/song title (no description clutter) and two
actions per item, both acting in the mode set by the **Audio/Video toggle**
beneath the Browse title:

- **Download** — sends the link straight to the download queue in the
  toggle's mode. Browse downloads are filed into a **library folder named
  after the source** (a "Brian Eno" Discography lands in a "Brian Eno"
  folder), so everything from one source stays together; those tracks, being
  unlistened, still surface in the **Inbox** until you play them. Once the
  download **lands in the library**, the row's button becomes a **green play
  button**: tapping it starts that track *in the background*, leaving you on
  the list you were working through (tap again to pause). Until then it's the
  plain green marker — a queued download has nothing to play yet. This is the
  same control everywhere a list offers a download: a source's items, the Every
  Noise discography, and the Download tab's search results.
- **Preview** — its icon **fills in** once you've opened it, so a long list
  shows at a glance what you've already auditioned (the button keeps working —
  it's a breadcrumb, not a decision). It opens a modal that downloads the audio — or, in Video mode,
  the video, its picture spanning the full width of the pane — and plays it in
  its own
  **mini player** (scrubber, **previous / play-pause / next** — separate from
  the main Player, which it pauses while auditioning), with **Save** and
  **Discard** buttons.

  **It previews a queue, not one track.** The list you tapped in comes along:
  the side buttons walk it (with an *N of M* counter under them), and a track
  that plays to its end **rolls straight into the next one**, so a source's
  new items — or a whole album in the discography browser — can be auditioned
  hands-off. Each track it moves to is marked previewed, so the breadcrumbs
  fill in as it goes. The transport sits *outside* the loading state, so you
  can skip past a slow resolve instead of waiting for it, and the audio layout
  is deliberately tight — with no picture to frame, the sheet doesn't need the
  vertical space a video preview does. A caller with nothing to walk (one
  search result) simply has the side buttons disabled. A video
  preview also carries a **quality picker** (Best / 1080p / 720p / 480p /
  360p, remembered between previews): changing it restarts the preview at the
  chosen resolution, and Save files whatever was downloaded. The preference is
  always bounded by what the source offers in a device-playable codec — a
  capped tier takes the tallest rendition at or below it, and if everything on
  offer is above the cap the smallest available is used. The
  modal's title and description are **selectable**, and the selection menu
  gains a **Browse Artist** action: select an artist's name and it adds an
  Artist source for it on the spot (first refresh included) — hear something
  you like, select the name, and their catalogue starts filling in. Save
  files the already-downloaded audio into the library as a normal track (it
  lands in the Inbox and gets the same best-effort AI organization as any
  download) — and saving **mid-listen doesn't cut the song off**: playback
  hands off to the main Player at the same position and keeps going in the
  background while you carry on browsing. The handoff deliberately does
  **not** count as listening — auditioning a track in the preview is how you
  decided to keep it, so the saved track stays in the Inbox until you play
  it from the library. Discard deletes the file and hides
  the item for good. Dismissing
  the modal without deciding deletes the temp file and leaves the item
  untouched.

**More.** A **YouTube Channel**, **RSS Feed** or **Blog Agent** list ends with a
**More** button that pulls the *next page* of what the source lists — a refresh
only ever re-reads the newest page, so this is the only way further back. Each
kind pages the way it can: a channel leaves the RSS feed behind (it carries only
the latest 15 entries and doesn't paginate) and reads the channel's own videos
page, then follows YouTube's continuation tokens the way the site does when you
scroll; a feed follows its `rel="next"` link, or `?paged=N`; a Blog Agent
re-triages the homepage and reads the articles it hasn't read yet. Older items
merge in like any refresh — already-curated rows keep their state — and when a
source has nothing further the button retires to "Nothing older to load".

The **Audio/Video toggle** appears on a source's own screen too, not just the
Browse root, so the mode can be changed where the Download/Preview buttons are.

**Downloading a whole album.** In the album-first discography browser (an
Artist source in either Discography mode, or Every Noise's Browse Discography),
twirling a release open shows its cover, then a **Download Album** button, then
the tracklist. One tap matches the whole record against YouTube — running the
search itself first if you haven't — and queues every track that matched into
a **library folder named after the release**, wearing the release's **cover
art** as its thumbnail in the Library's folder list. From a Browse source the
album folder nests inside the source's own folder (everything from one source
still stays together); from Every Noise it's a top-level folder. Misses are
left out — "all available tracks" means what matched, and the tracklist below
shows which those were. Re-downloading an album reuses its folder rather than
making a second one, and the pinned **Top 10** / **Highlights** rows offer the
same button as **Download All** (their folder is qualified by the artist, since
"Top 10" alone would collide across every artist you browse).

**Bulk download.** A **Select** button at the top of a source's list turns on
multi-select (the same edit-mode selection the Library uses): the per-row
Download/Preview buttons give way to selection circles, you tick as many items
as you like — across albums or posts in a grouped list — and a **Download (N)**
button queues the whole set at once, in the current Audio/Video mode.
**Everything ticked is queued — already-downloaded and saved rows included**,
which is how a batch mistakenly grabbed as audio gets re-pulled as video: flip
the toggle, tick them again, Download. **Done** leaves select mode.

**Re-downloading one item.** Touch and hold any row for **Download** /
**Download Again** (in the current Audio/Video mode) — the way back for a
single item whose row button has already given way to the dealt-with marker.
(For a track already in the library, the Library's **Convert to
Video/Audio** does the same job while also replacing the original file.)

Seven **source types**, in two families:

| Type | How it works |
|------|--------------|
| **YouTube Channel** | Scrape/RSS: watches the channel's upload feed (`/feeds/videos.xml`). Accepts a channel URL, `@handle`, bare `UC…` id, or plain channel name — see [Resolving a channel](#resolving-a-channel). |
| **YouTube Playlist** | Scrape/RSS: watches the playlist's feed. Accepts a playlist URL (anything with `list=`) or a bare playlist id. Items keep the **playlist page's own order** — a playlist is curated, so unlike every other source its list isn't sorted newest-first. |
| **RSS Feed** | RSS reader: parses any RSS/Atom feed and keeps **only the posts that contain YouTube links** (a music blog's roundups, a newsletter's song-of-the-day). A post with several links yields one item per video. |
| **Blog Agent** | AI agent: RSS-reader behaviour for blogs **without a feed**. The agent fetches the homepage, asks the model which of the page's links are individual recent articles (telling posts apart from nav/category/about links is exactly the judgement call heuristics get wrong — and the model may only *pick from* the links found on the page, never invent one), then reads the most recent ones. Each article becomes a **post** — a section headed by its title + date, with three parts: a one-or-two-sentence **summary**, the **YouTube tracks** actually linked in the article (Download/Preview like any Browse item), and a list of the **artists it names**. Tapping an artist opens a popup to spin up a new **Artist** source — Top 10 or Search Discography — for that name on the spot — so a text-only write-up with no embedded videos still turns into something to follow. (This replaces the earlier "guess the songs and search YouTube for each" step, which resolved unreliably.) **Settings ▸ Blog Agent** caps how many **posts per refresh** are read and how many **songs per post** are taken (defaults 5 and 5), so a link-heavy blog can't flood the list. |
| **Artist** | One of three **modes** picked when the source is added. **Top 10** (AI): the model lists the artist's **top 10 most popular tracks**, ranked, digging deeper on each refresh — the ordinary item list. **Search Discography** (AI) and **Spotify Discography** both open the **album-first discography browser** instead (the same screen the Every Noise browser's Browse Discography uses): the first pass shows just **albums and song names** — a model call laying out the catalogue (Highlights pinned on top), or Spotify's real release list (a pinned **Top 10** with its **Search Top 10** button — agent-listed when an AI key is saved, catalogue-ranked by Spotify's per-track popularity for artists the model doesn't know, YouTube's own search ranking when Spotify has nothing to rank, the 403-gated top-tracks endpoint only as a final resort — then Albums / Singles & EPs / Compilations) — and each release's **search** button matches its tracks against YouTube on demand, right in the list (matched tracks light up with Download/Preview; misses dim). Nothing is resolved up front, so opening a big catalogue is instant and a refresh no longer costs a search per track. The first pass is **cached per source** (`Documents/Discographies/`); the screen's toolbar refresh re-fetches it. Downloads file into a folder named after the source, like every Browse download. The browser opens on the **artist page**: their Spotify portrait up top, name beneath it in large type, and a **Learn More** button — an AI-written brief bio, grounded on (and linking to) the artist's Wikipedia entry when one exists. Albums show their **cover art** as a row thumbnail and full-size when twirled open, and every download from here carries that art along (see [Album art](#album-art)). The Spotify mode needs the Settings ▸ Spotify credentials (and no AI key); the typed name is resolved to the artist via Spotify's search. (Discography was a separate source type once; sources created back then keep working as Artist sources in Search Discography mode.) |
| **Genre** | AI: popular songs in a genre, across artists. |
| **Country** | AI: popular songs from a country (by artists from that country). The country field has a **globe button** that opens a searchable modal of every country (built from the system's localized ISO region list) in case the right name isn't obvious. |

The AI music types can be scoped to an **era** (Artist only in Top 10 mode — a
discography spans the whole catalogue by definition): the add sheet offers an
**Era** picker (Any era, or a decade from 1950s–2020s), the chosen decade
steers the suggestions — early Dylan, 1980s synth-pop, 1970s Mali — and a
blank name auto-fills with the era folded in, e.g. "Mali (1970s)", so two
eras of the same subject read apart in the source list.

Every AI request logs its **full prompt and response** to the Log (debug
level, category `Browse`), so a refresh that comes back thin can be diagnosed
on-device: the summary lines distinguish "the model suggested little" from
"YouTube search resolved little". (A discography's first pass is layout only —
per-track YouTube lookups happen in the browser, per release, on demand — so
the old per-refresh lookup caps are gone.)

The AI types use the **Anthropic key from Settings** (they're unavailable
until one is saved — except an Artist source in **Spotify Discography** mode,
which reads Spotify instead and needs only those credentials). For Artist /
Genre / Country the model is asked for real, well-known songs — title and
artist — and is deliberately **never trusted to produce YouTube links** (it
hallucinates video ids); each suggestion is instead resolved to a real video
by scraping the top result of a YouTube search. For Artist (Top 10) / Genre /
Country, on a refresh the model is told what it already suggested so it digs
deeper instead of repeating itself (so refreshing keeps surfacing the
next-most-popular tracks); refreshing a discography re-lays the catalogue and
replaces the cached first pass.

**Agent blockers.** Sites behind bot protection refuse automated readers —
a 403/429 for non-browser clients, or a Cloudflare-style challenge
interstitial served with a 200 ("Just a moment…", "Verify you are human").
The Blog Agent detects both and the source row shows a distinct
**"Agent blocked"** error status instead of a generic failure or a silently
empty list. A single blocked *article* is skipped (the rest still land); the
error is raised when the homepage — or every article — refuses the agent.

**Curation state persists** (`Documents/browse.json`): every item remembers
whether it's new, sent to Downloads, saved, or discarded — so a refresh never
resurrects something you've already dealt with, and the source list shows a
badge with each source's count of new items. Items that fall out of a feed's
window are kept: Browse is a running log to curate, not a mirror of the feed.
Sources refresh on demand (per-source, or pull-to-refresh / the toolbar button
for everything); refresh errors show on the source row and in the **Log**
(category `Browse`).

### The Every Noise browser

The **world button** beside Browse's "+" opens an in-app rendition of
[Every Noise at Once](https://everynoise.com) — Glenn McDonald's
readability-adjusted scatter-plot of the musical genre space. It **pushes
within Browse's own navigation** (the tab bar stays put, like every other
Browse screen), with the scan transport and the artist bar sitting just
above the tabs. The site froze in
late 2024 when Spotify revoked its API access, so its data is static — which is
what makes bundling it reasonable: a **one-time scrape**
(`tools/everynoise/scrape.py`, a modernized descendant of
[laffan/everynoise-scrape](https://github.com/laffan/everynoise-scrape)) bakes
the whole map into the app, and everything below works offline except the
preview snippets themselves.

It mirrors the site's own controls — **Map**, **List** and **Scan** modes plus
a **Find** field — at both levels:

- **Map** is the genre scatter-plot itself: every genre in the site's own
  position, color and size (nearby genres really do sound alike). Tapping a
  genre reveals its **constituent artists**, likewise positioned in rough
  relation to one another on the genre's own map. Both maps **open centered**
  on their canvas rather than at the top-left corner, and a **scroll pill** —
  a draggable white ring hugging the right edge — maps onto the full vertical
  scroll, so the ~15-screen-tall genre map can be traversed in one drag
  (the system scroll indicator can't be grabbed).
- **List** is the same set alphabetically, each genre in its map color with a
  per-row preview play button. A **sort menu** beside the Find field switches
  the order to **Similarity** — the site's own list behavior, since map
  distance *is* the similarity measure. In similarity mode every row grows a
  **resort button**: tap it and the list re-orders around that entry (it
  lands on top, its sonic neighbors follow), exactly like clicking a genre
  on the site. A third order, **Popularity**, reads the scraped font-size
  percent — the site's popularity cue — biggest names first. The artist list
  inside a genre sorts the same three ways.
- **Scan** auto-plays through the example tracks in map order — the site's
  scan mode as a bottom transport bar (prev / play-pause / next), with the map
  following along and the current entry drawn inverted. It works on the genre
  map and inside any genre's artist map, remembers where it left off on the
  genre level, and skips entries with no preview.
- **Find** filters: in list mode it narrows the list; over a map it drops down
  the matches and tapping one flies the map there. At the root the field has a
  **genre/artist toggle** inside its trailing edge (the placeholder follows —
  "Find Genre" / "Find Artist"): artist mode searches **every artist in the
  dataset** (~470k unique names) and drops down the most popular matches, each
  with its home genre beneath — tapping one opens that genre with the artist
  selected, centered and previewing. Searching that many rows per keystroke
  is what the bundled **artist index** exists for (see the "Why it isn't
  laggy" notes below).
- **History** (root level, an addition of ours) is the visit log, newest
  first: every genre you've opened (guitars icon) and every artist you've
  tapped (mic icon, with their genre beneath), each in its map color with a
  relative timestamp. Tapping a genre re-opens its artists; tapping an artist
  re-opens their genre with that artist selected, centered, and previewing.
  Like the Library's Recent it's a log, not a set — revisits re-append, only
  consecutive repeats collapse — capped at 200, filtered by Find, rows swipe
  to delete, with a Clear History button at the bottom
  (`Documents/everynoise-history.json`).

Tapping an **artist** plays a **30-second preview of their top song** (the
snippet URL is embedded in the scraped data — no Spotify account or API key is
involved) and opens an action bar with a **"+"**. With **Spotify credentials**
saved (Settings ▸ Spotify), the "+" goes **straight to Browse Discography** —
no chooser popup — the artist's *real* catalogue read live from Spotify (the
scraped data carries every artist's Spotify id, but no discographies). A
pinned **Top 10** row with a **Search Top 10** button sits at the top —
the artist's most popular tracks, matched against YouTube on tap, which is
where the popup's old Top 10 option went. The tracklist comes from four
sources, in order: the **AI agent** (with a key saved — one call, and it
knows the popular canon), then — since the prompt forbids invented tracks,
the model answers empty for the map's long tail of artists it doesn't
know — the **catalogue itself**, its releases' tracklists ranked by
Spotify's own per-track popularity score; when Spotify has nothing to rank
either, **YouTube's own search ranking** stands in (the long tail very
often lives there — the artist's top results become the list directly, each
row pre-matched since it *is* a video, full-album-length uploads filtered
out); Spotify's dedicated top-tracks endpoint is only the final resort,
because newer client-credentials apps find it 403-gated. Beneath it,
releases group into
Albums / Singles & EPs / Compilations, newest first — each with its **cover
art** beside it, and the artist's portrait, name, **Learn More** bio button
and an **Add as Source** button heading the page — the latter files the
artist into Browse as a discography-mode **Artist source** on the spot (it
reads "In Browse" once an equivalent source exists, so it never files a
duplicate). Expanding a release shows its cover full-size, a **Download
Album** button, and its track names; the release's **magnifier** matches
those against YouTube in place
(ISRC-first, duration-gated — the pasted-link machinery), with live progress
in the row; when the search settles, the **matched tracks light up with
Download and Preview beside them** (Preview is the standard Browse
listen-first modal, walking the rest of the release) and misses dim to "no
match" — no picker popup. A single-track pick goes in **unfiled**: it shows
in the Library's Tracks list (and the Inbox) rather than an album folder.
**Download Album** is the opposite case and files the whole record into a
folder of its own, cover art and all. This is
the same screen a discography-mode **Artist source** opens in Browse — one
album-first browser, wherever a catalogue shows.

Without Spotify configured (or for an artist the scrape carries no Spotify id
for), the "+" keeps the old popup: file the artist into Browse as a regular
**Artist source** — **Top 10** or **Search Discography** — with the first
refresh kicked off immediately.

**Spotify politeness.** The browser is careful with the modest quota a free
developer app gets, three ways. **Batch endpoints**: a Top 10 derivation
reads its releases through `/albums?ids=` (20 albums, tracklists included,
in one request) and recovers ISRC/popularity with one `/tracks?ids=` sweep
across *all* of them — ~5 requests where one-album-at-a-time cost ~24, so a
whole artist (open + Top 10) runs ~6–8 requests instead of nearly 30.
**Caching**: catalogue reads are cached app-wide for ten minutes
(`SpotifyMetadataCache`) — an artist's portrait and album list, and each
album's tracklist, are fetched once, so opening a page, searching its Top
10 and expanding a release share those reads, and re-opening an artist
costs nothing (a derivation also pre-warms every release it touched).
**Rate-limit honesty** (`SpotifyRateLimiter`): a 429's `Retry-After` is
recorded **globally**, short windows are quietly waited out (with one
polite retry), and long ones fail fast with the actual wait in the
message. That global part matters — Spotify *extends* the penalty window
while requests keep arriving, so a client that pressed on (as this one
used to) turned one burst into minutes of 429s, surfacing on screens that
only cost two requests.

Escalated penalties are real — a repeatedly tripped development-mode app
can be timed out for an **hour** — so the recorded window also **persists
across launches** (a relaunch that forgot it would re-trip the 429 and
extend it), and it's keyed to the **client id** that earned it: a newly
created Spotify app starts with a clean quota, so pasting fresh
credentials is the honest shortcut out of a long window (verification
with new credentials bypasses the old app's block automatically).
Settings ▸ Spotify shows the countdown whenever a window is in force,
along with **Forget the wait and retry** — an escape hatch that drops
only the app's *memory* of the window, so the next tap tests reality:
it either works (the record was stale) or re-records a fresh 429.

The Log tells the two failure shapes apart: *"N min left of the recorded
rate-limit window — the … request was not sent"* is the app waiting out
its own record, while *"rate limited reading the … — Retry-After Ns"* is
Spotify answering 429 to a real request. If a brand-new app's credentials
draw the second line immediately, the throttle is upstream of the client
id — Spotify also meters by network address when it's been hammered —
and the cure is waiting, or switching networks (Wi-Fi ↔ cellular changes
the address).

**Why it isn't laggy.** The dataset is big (6,291 genres, ~630k artist rows),
and the site itself chugs on an iPad, so nothing is ever
loaded or laid out wholesale. The genre **index** (`genres.json`) is read once,
off the main thread, when the browser opens. Each genre's **artist shard**
(`EveryNoiseData/genres/<key>.z`, raw-DEFLATE-compressed JSON) is inflated only
when that genre is opened, with a small LRU keeping recent genres warm. And the
maps are **virtualized**: a `UIScrollView` with a spatial grid materializes
only the labels intersecting the visible rect (plus a margin), recycling them
from a pool as the map pans — a few hundred live views at most, whatever the
dataset size (`NoiseMapView`). The maps render with the **vertical axis
reversed** relative to the scraped page coordinates (the site's y grows
downward, CSS-style; the renderer flips it once, at layout).

The **global artist search** (Find Artist) gets the same treatment: ~470k
names is far too many to decode into Swift values per keystroke, so it never
parses anything. `tools/everynoise/build_artist_index.py` derives a flat text
index from the shards (`EveryNoiseData/artists.idx.z`, ~12 MB packed) — one
line per unique artist, led by a case/diacritic-folded copy of the name, kept
in the genre where they're drawn biggest and ordered by that size. On first
search the app inflates it once into Caches and **memory-maps** it
(`ENArtistIndex`); each keystroke (debounced) is then a raw byte scan whose
first N hits are automatically the most popular matches — tens of
milliseconds, no allocation per row, and only touched pages ever resident.

The repo carries the scraped dataset (6,291
genres, ~630k artist rows, ~57 MB of shards, plus the derived artist index),
so a fresh clone builds with the
whole map included; a build somehow missing it shows a clear explanation
instead of an empty map.

**A sharp edge for future work here:** the browser sits inside Browse's
`NavigationStack`, and `navigationDestination` content is hosted by that
stack — so a pushed screen inherits the app-level environment objects but
*not* ones injected locally inside the browser. Hand the browser's own
`store`/`player` to pushed destinations explicitly (a missed one crashes at
first push). Relatedly, anything new pinned to the bottom of these screens
must read `\.miniPlayerHeight` and pad itself, as the scan and artist bars
do — the maps ignore the bottom safe area, so the mini player's inset doesn't
push bottom bars up on its own.

Ideas deliberately left on the table: pinch-zoom on the maps (the site has
none either); scan continuing to play beneath a pushed genre view. (A global
artist search used to sit on this list — the derived artist index is what
crossed it off, as **Download Album** did for per-release "download all
matched".)

#### Keeping the dataset from ageing

The map is a scrape of a page that stopped updating in late 2024, but the
genre space didn't. **Settings ▸ Every Noise Data ▸ Collect updates as I
browse** (off by default; needs the Spotify credentials) closes that gap
opportunistically: opening a genre also asks Spotify — **once per genre** —
which artists it currently files under that label, and records every name the
bundled shard is missing, along with the artist's Spotify id, popularity and
its own genre labels. Nothing in the app changes on the spot; the findings
accumulate in `Documents/EveryNoiseUpdates/` and Settings shows the tally
("412 new artists across 37 genres · 8 genres missing from the map").
**Download New Data** shares the file off the device, and
`tools/everynoise/merge_updates.py` folds it into the bundled dataset before a
rebuild — appending artists to their genre's shard, and minting a row *and* a
shard for a label that has enough artists behind it but no place on the map at
all, positioned at the centroid of the known genres those artists were found
under.

Two limits are inherent and recorded in `meta.json` rather than papered over:
the site's layout came from Spotify's **audio-feature** API, withdrawn with
everything else, so new rows are hashed deterministically into the spread
their genre already occupies — among the right artists, not at a meaningful
point within them; and Spotify stopped serving `preview_url` to apps created
after November 2024, so a harvested artist has **no 30-second snippet** (their
discography still opens normally).

**Why this can't get you rate limited.** It is one request per genre *visit*,
behind four independent brakes: it's **opt-in**; only **one harvest runs at a
time**, no closer than **20 seconds** apart and delayed a few seconds behind
the tap so it never races the screen you're waiting on; it's capped at **150
requests a day** and won't re-ask a genre for **30 days**; and a harvest is
**dropped outright** — not queued — whenever `SpotifyRateLimiter` knows of a
live 429 window, since sending during one is exactly what makes Spotify extend
it. A heavy browsing session costs about what opening twenty artists in the
discography browser does.

Preview downloads run through the **same pipeline** as the download queue but
jump ahead of queued jobs, since the user is sitting in the modal waiting.
While every pipeline slot is busy the modal says so ("Waiting for the
download queue to free up…").

The pipeline runs **up to two downloads at once** — a real help on batch
downloads (a ticked-off discography, a whole playlist). What's parallel is
the *network* work: chunked stream downloads, native (YouTubeKit)
extractions, AVFoundation conversion. Everything that enters the **embedded
Python interpreter** — a yt-dlp extraction, the forced-client recovery, a
mid-download URL re-resolve, chapter capture, playlist resolution, the
JS-runtime plugin import — is serialized app-wide through a single **Python
gate** (`PythonGate`), because two concurrent interpreter calls can crash the
app. The gate is release-on-completion: a timed-out extraction that's still
grinding inside Python keeps holding it, so new Python work *waits* for the
zombie to settle instead of crashing into it (a stronger guarantee than the
old wait-briefly-then-proceed heuristic). In practice: two native-extraction
downloads overlap fully; when both jobs need yt-dlp, their resolutions take
turns while their downloads still overlap.

## Local sync: a folder that mirrors part of the library

Settings ▸ **Local Sync** lets you pick folders — anything the Files app can
reach (On My iPhone, iCloud Drive, Dropbox, any file provider) — to mirror
with. **Several sync folders can be configured at once** (each is a *root*
with its own id; with more than one, "Sync to Local" becomes a submenu naming
them). Access persists across launches via security-scoped bookmarks; a root
whose provider is unreachable shows a warning icon in Settings and simply
pauses until it's back.

Each folder is a **replica, not live storage**: cloud providers serve
*placeholder* files that must be downloaded through file coordination before
they're readable, and can evict them again — so the app never plays from a
sync folder directly. Synced files live app-local in
`Documents/Synced/<root-id>/` (mirroring that folder's directory structure)
and always play offline; per root, two background workers keep the two sides
identical:

- The **importer** scans the folder (off the main thread — a cloud directory
  can block on the network) and compares each file's size/mtime **stamp**
  against a persisted manifest (`Documents/sync-manifest.json`). New or
  changed files are copied in with a coordinated read — which is what makes a
  provider download its placeholder — and each track appears as its copy
  lands. Files that vanished from the folder leave the library (and the local
  store). Directories become (nested) folders, playlist trees arrive as
  playlists.
- The **exporter** drains a persisted journal (`Documents/sync-pending.json`)
  of write-through ops produced by in-app changes: **Sync to Local** copies a
  track or folder out, moves/renames/deletes of synced items update the
  replica, mixtape edits rewrite `.mixtapedata`. If the folder is unreachable
  the ops wait and retry on the next pass — the in-app change never fails or
  blocks. Reconciliation is skipped while exports are pending, so a stale
  replica can't undo the changes waiting to be written. Settings shows the
  mirror's state, counting the files as they go — **Syncing 12 of 133 tracks**
  (the total grows as the pass discovers work: a root's exports are counted
  when its journal drains, its imports once its replica has been scanned, and
  it reads a plain *Syncing…* until the first count is in) / N changes waiting
  / Up to date.

Synced items wear a **sync icon** (`arrow.triangle.2.circlepath`) but
otherwise behave exactly like everything else — tap to play, reorder,
classify, archive, send to the watch. Passes run on filesystem events
(kqueue, for local folders), on returning to the foreground, and after every
in-app change; cloud providers don't reliably signal, so foregrounding the
app is what picks up remote edits there.

**Deleting** a synced folder keeps the app's promise that deleting a folder
never deletes tracks: its files move into the plain library first, then the
directory (and its replica copy) is removed. **Removing a sync folder** in
Settings, though, removes its synced content: the library only mirrors
folders it's still connected to, so that root's tracks and folders leave the
library and its local store is deleted — the sync folder's own files are
never touched. Playable types:
`m4a`/`mp3`/`aac`/`wav`/`aiff` audio and `mp4`/`mov`/`m4v` video; hidden
files and folders are ignored. The trade-off of the copy model is deliberate:
each synced file exists twice (app copy + provider copy) — that's what makes
playback offline-proof.

## Mixtape folders

**Convert to Mixtape** (touch-and-hold a folder) dresses a playlist up as a
mixtape: the folder's name draws over a **cover-image banner** — in the folder
list and as a header inside the folder — in a font of your choosing. Inside a
mixtape, an **Edit Cover** button at the bottom of the track list opens the
editor: pick an image from Photos and frame it — **separately for the tall
header and the short list row** (drag to pan, a zoom slider per preview, pinch
also works on the big one), as a **non-destructive crop**: only zoom/pan
values are stored, the image is kept whole, so the framing can be changed any
time. The title gets a **font picker listing every system font family** (each
name rendered in its own face), a **text colour**, **left/center
justification** for the list row, and an optional **tape chip** behind it —
masking-tape white by default, with preset swatches and a free colour well.
**Convert to Folder** reverts it, discarding cover and style. Mixtapes can't
contain folders, so only childless folders offer the conversion.

Style (crop, font, colours, tape, justification) persists in `folders.json`;
the cover JPEG lives in `Documents/MixtapeCovers/<folder-id>.jpg`. A mixtape
**synced to local** keeps a second copy of all of it in the sync folder: a
hidden **`.mixtapedata`** directory (`cover.jpg` + `style.json`) inside its
replica directory, written through the export journal on every conversion and
cover/style edit. That's what makes mixtapes **sync between devices** when
the sync folder is a cloud drive: importing a directory that contains
`.mixtapedata` brings it into the library *as* a mixtape — cover, crop, font,
tape and all — and a remote `.mixtapedata` change (another device editing the
cover) is picked up on the next pass. Remote changes are adopted only when
the `.mixtapedata` stamps actually changed, so a stale replica can't undo an
in-app style edit.

### Pipeline

```
URL  ──►  extractor (native / yt-dlp)  ──►  chunked download  ──►  Documents/  ──►  AVPlayer
         best audio-only or muxed mp4       (+ audio extract       local file       audio/video
                                             for audio mode)                         playback
                                       └──►  HLS segments joined (fMP4)
                                             when only a playlist is offered
```

### Source layout (`OfflineListen/`)

| File | Role |
|------|------|
| `OfflineListenApp.swift` | App entry; wires up the shared stores. |
| `Models.swift` | `Track`, `Folder`, `DownloadMode`, `LibraryFilter`, `FolderSort`, paths, helpers. |
| `LibraryStore.swift` | Persists the library to `Documents/library.json` and folders to `Documents/folders.json`; owns the local moves across the sync boundary (queueing replica ops), the importer's reconcile primitives, and the mixtape conversions. |
| `LocalSync.swift` | `LocalSyncStore` — the sync folder's security-scoped bookmark, the stamped manifest + journaled exporter, the coordinated importer (placeholder-aware copies), kqueue monitoring, and the off-main tree scan. |
| `DownloadManager.swift` | Download queue (two concurrent slots) + `DownloadJob` + persisted history; `ArtworkFetcher`, the best-effort album-art fetch a finished download triggers. |
| `PythonGate.swift` | App-wide async mutex serializing every embedded-Python call, so the two-slot pipeline never runs concurrent interpreter work. |
| `YouTubeExtractor.swift` | `MediaExtractor` protocol + YoutubeDL-iOS impl + a mock. |
| `YouTubeKitExtractor.swift` | Native-Swift (b5i/YouTubeKit) primary extractor. |
| `VimeoExtractor.swift` | Native-Swift Vimeo extractor: finds the (signed) player config for the title, progressive MP4s and HLS playlist — no Python. |
| `CompositeExtractor.swift` | Tries the native extractor, falls back to yt-dlp. |
| `JSChallengeSolver.swift` | Solves YouTube's `n`/`sig` challenges by running the `yt-dlp-ejs` scripts in JavaScriptCore. |
| `POTokenMinter.swift` | Mints PO tokens via BotGuard in a hidden WKWebView (needs vendored `botguard.js`). |
| `PythonBridge.swift` | Installs the Swift↔Python callbacks and registers the on-device yt-dlp provider plugin. |
| `ytdlp/` | Bundled (folder reference): the `yt-dlp-ejs` solver scripts + the `yt_dlp_plugins` provider package. |
| `AudioStreamDownloader.swift` | Shared chunked byte-range stream downloader. |
| `VideoAudioExtractor.swift` | Extracts audio from a muxed video via AVFoundation. |
| `HLSDownloader.swift` | Saves an HLS (`.m3u8`) stream by fetching and joining its fMP4 segments — the fallback that makes Vimeo (progressive-free) work, with no FFmpeg. |
| `ChapterFetcher.swift` | Best-effort capture of YouTube chapter markers via the on-device yt-dlp module. |
| `PlaylistResolver.swift` | Detects playlist links and flat-resolves their entries (on-device yt-dlp) so a playlist downloads into a folder. |
| `ChapterSplitter.swift` | Exports one file per chapter (AVFoundation) for "Break Chapters into Playlist". |
| `VideoMerger.swift` | Muxes a video-only + audio-only stream into one MP4. |
| `PlaybackManager.swift` | `AVPlayer` engine (audio + video), audio session, lock screen; exposes the queue's next/previous entries for the Player's neighbour labels. |
| `Logger.swift` | `LogStore` — thread-safe, app-wide log sink. |
| `AISettings.swift` | `AISettingsStore` (model/key/assist, Keychain-backed), `AIModel`, `Keychain` helper. |
| `AnthropicClient.swift` | Minimal Anthropic Messages API client (verify + single-shot completion) over URLSession. |
| `SpotifyRef.swift` | Parses `spotify:` URIs / `open.spotify.com` links into a (kind, id) pair; resolves `spotify.link` short links by redirect. |
| `SpotifyClient.swift` | Spotify Web API client: Client Credentials token (cached, 401-refreshing) + the track/album/playlist/artist metadata reads, paginated and **batched** (`/albums?ids=`, cross-album `/tracks?ids=`), plus `searchArtists(genre:)` — the one request the Every Noise dataset harvest makes. Also `SpotifyRateLimiter` (the persisted, per-client-id `Retry-After` window), `SpotifyMetadataCache` (the ten-minute catalogue cache), and the popularity-ranked `derivedTopTracks`. |
| `SpotifySettings.swift` | `SpotifySettingsStore` — the Keychain-backed client id/secret (mirrors `AISettingsStore`). |
| `SpotifyResolver.swift` | Spotify metadata → `ResolvedPlaylist`: ISRC-first YouTube matching with a duration gate, bounded and concurrent. |
| `AIOrganizer.swift` | Builds the prompt, calls the API, writes music/podcast + clean metadata back to the library. |
| `BrowseModels.swift` | `BrowseSourceKind`, `BrowseSource`, `BrowseItem` + status — the Browse tab's data model. |
| `BrowseStore.swift` | Persists sources/items to `Documents/browse.json`; orchestrates refreshes and the new/downloaded/saved/discarded lifecycle. |
| `FeedParser.swift` | Minimal RSS 2.0 + Atom parser (XMLParser) shared by the YouTube feeds and the generic RSS reader. |
| `BrowseFetchers.swift` | YouTube channel/playlist feed fetch (+ channel-id resolution by page scrape), the YouTube-link-filtered RSS reader, and the search-result resolver. |
| `AIDiscovery.swift` | AI song discovery for Artist/Genre/Country sources (suggestions via the Messages API, links via the search resolver). |
| `BlogAgent.swift` | The Blog Agent source: homepage fetch → AI link triage → article reads → per-article summary + artist extraction + YouTube-link harvest, with bot-protection ("agent blocked") detection. |
| `DiscographyAgent.swift` | The AI catalogue layout behind Search Discography mode: albums + track names + a Highlights list, one model call, no YouTube work (matching moved into the browser, on demand). |
| `DiscographyBrowserView.swift` | The shared album-first discography browser — artist header (portrait, name, Learn More bio), cover thumbnails/full art, names first, per-release YouTube search, **Download Album**, pinned Top 10 — plus its two catalogue providers (Spotify live / AI layout), the Wikipedia lookup + AI bio sheet, and the Browse-source wrapper that caches the first pass. |
| `BrowseView.swift` | The Browse tab: sources grouped by type, add-source sheet, refresh, and the world button into the Every Noise browser. |
| `EveryNoiseData.swift` | The bundled Every Noise dataset: models, the lazy/LRU shard-loading store, the memory-mapped global artist search (`ENArtistIndex`), and the 30-second preview player. |
| `EveryNoiseUpdates.swift` | `ENUpdateStore` — the opt-in, heavily throttled Spotify harvest that records what the frozen dataset is missing as you browse, and the exportable JSONL it writes for `tools/everynoise/merge_updates.py`. |
| `NoiseMapView.swift` | The virtualized `UIScrollView` scatter map (spatial grid + recycled labels) both noise maps render through — opens centered on its canvas, with the draggable scroll-pill ring on the right edge. |
| `EveryNoiseView.swift` | The Every Noise browser: Map/List/Scan modes + Find at both levels (with the root's genre/artist toggle), the scan transport, and the artist bar whose "+" opens the live discography (or creates Artist sources when Spotify isn't set up). |
| `EveryNoiseData/` | Bundled (folder reference): `genres.json` index + per-genre artist shards from the one-time `tools/everynoise/scrape.py`, plus the derived `artists.idx.z` from `build_artist_index.py`. |
| `BrowseSourceView.swift` | One source's items with per-row Download/Preview/Discard, plus a **Select** mode for bulk download; also `BrowseTrackStatusButton`, the green play button every browse list shows once a download is in the library. |
| `BrowsePreviewView.swift` | The preview modal: pipeline download, mini player with prev/play-pause/next over the queue it was opened with (auto-advancing at the end of each track), Save/Discard. |
| `*View.swift` | The five SwiftUI screens (Download, Browse, Library, Player, Settings — which embeds the Log). `PlayerView.swift` also holds the tap-to-seek scrubber and the `MiniPlayerBar` the other tabs inset above the tab bar. |
| `FolderView.swift` | Folder detail (tap-to-play, reorder, subfolders, mixtape header/Edit Cover) and Inbox screens. |
| `MixtapeViews.swift` | Mixtape banner rendering (non-destructive crop), the shared folder-row label, and the Edit Cover sheet (PhotosPicker + drag/pinch + font picker). |
| `WatchFolderView.swift` | The phone's **Watch** virtual-folder screen (manage what's been sent to the watch). |
| `WatchManifest.swift` | Wire format shared by the iPhone and watch targets (the sync manifest, the remote-control `RemoteNowPlaying`/`RemoteCommand` types, + WC keys). |
| `WatchSync.swift` | Phone-side WatchConnectivity bridge: pushes the manifest + audio files, handles the watch's "Clear all". |

The companion watch app lives under `OfflineListenWatch/` (see
[Companion Apple Watch app](#companion-apple-watch-app)).

The extraction step is isolated behind a `MediaExtractor` seam (a mock
implementation is included), so adapting to a library API change touches one
file and the UI can be exercised with no native dependency.

## Companion Apple Watch app

A bundled **watchOS app** (`OfflineListenWatch/`) lets you push Music and Podcast
tracks to your Apple Watch and listen **offline** — on a run, away from the phone.
It's **audio only** (video isn't sent to the watch).

**Three panes** (swipe between them):

1. **List** — the tracks and playlists that have been pushed to the watch.
   Playlists you sent as a folder stay grouped; loose tracks sit below. A row
   that's still transferring shows its live **Syncing… N%** and isn't tappable
   yet; once the file lands it becomes playable. Tap a track to play it (and jump
   to Listen).
2. **Listen** — now-playing title/artist, a progress bar, and transport buttons:
   **previous / play-pause / next** for songs, **jump-back-15 / play-pause /
   jump-forward-30** for podcasts (mirroring the lock screen). The **Digital Crown
   adjusts volume** while this pane is showing. Podcasts resume where you left
   off, and their playhead **syncs both ways** with the phone — listen on one,
   pick up where you stopped on the other.

   **Remote for the phone.** When the **phone** is playing a track and the watch
   isn't playing its own audio, this same pane repurposes itself into a remote
   control: a **"Controlling iPhone"** banner above the phone's now-playing
   title/artist and progress, with the identical transport buttons now driving
   the phone instead of the watch. The progress bar advances on the watch between
   updates, play/pause responds instantly, and podcasts get the 15s/30s jumps
   just as on the lock screen. The moment you start a track from the watch's own
   List, local playback takes over and the remote steps aside.
3. **Settings** — an **Output** preference (**Bluetooth** / **Speaker**) and a
   **Clear all Tracks** button (with a confirmation step) that deletes every
   saved file on the watch. (watchOS routes audio at the system level — Bluetooth
   when connected, otherwise the built-in speaker — so the preference steers the
   system route rather than forcing a port.)

### Sending from the phone

Touch-and-hold a **track** (or a **playlist/folder**) in the library and choose
**Send to Watch**. Sending **never changes the item's place** in your phone
library — it only flags it for the watch. A **Watch** folder appears directly
below the **Inbox**: a *virtual* folder (its tracks really live wherever they
normally do) for managing what's on the watch. There it's deliberately spare —
tap to play, and a single swipe-left action, **Remove from Watch** (no
song/podcast swipe). Touch-and-hold a track already on the watch and the menu
shows **Remove from Watch** instead.

The phone is the **source of truth**, and the link runs both ways: tapping
**Clear all Tracks** on the watch empties the phone's **Watch** folder to match,
and removing a track from the Watch folder deletes it from the watch on the next
sync.

### How the sync works

Transport is **WatchConnectivity** (`WCSession`). The phone pushes the
authoritative set as a JSON **manifest** via `updateApplicationContext` (the watch
renders its List from it and **prunes** any local file no longer listed). Audio
files travel one of two ways:

- **`transferFile`** — the system's background file-transfer API — when the watch
  isn't reachable (so a queued track keeps delivering after you pocket the phone).
- A **resumable stream** over the live message channel when the watch app *is*
  reachable. The phone asks the watch how many bytes of the file it already has
  (the watch keeps a `.part` file) and sends the rest in chunks; if the
  connection drops the next attempt **resumes from that offset** instead of
  restarting. This exists because the system file-transfer channel doesn't
  establish on every device pair (it accepts the transfer but moves no bytes) —
  the resumable stream delivers regardless, as long as the watch app is open.

Whichever path lands the whole file first wins; the other is cancelled. The Watch
folder shows real byte-level progress.

The same channel carries the **remote-control** traffic: while the phone is
playing, it pushes a small now-playing snapshot (`RemoteNowPlaying`) to the watch
on every transition (start / pause / resume / seek / track change), throttling
the playhead-only updates since the watch interpolates locally; the watch sends
back a transport command (`RemoteCommand`) when you tap a button on the remote.
Both ride the live message channel and require no extra setup.

The watch sends a small `clearAll` message
back when you clear it, and mirrors each sync step to the phone's **Log** tab
(`⌚`-prefixed) so the whole exchange is debuggable from one place. The wire format
(`WatchManifest.swift`) is compiled into **both** targets so encode and decode
can't drift — the same trick the Share Extension uses with `SharedInbox.swift`.

> **Tip:** for the fastest, most reliable delivery, **keep the watch app open**
> (the List pane) while syncing — that keeps the watch reachable so the resumable
> stream runs.

### Watch source layout (`OfflineListenWatch/`)

| File | Role |
|------|------|
| `OfflineListenWatchApp.swift` | App entry; wires up the watch stores. |
| `WatchModels.swift` | `WatchTrack` + paths (the watch's own lightweight library). |
| `WatchLibraryStore.swift` | Persists `watch-library.json`; applies the manifest, prunes/ingests files. |
| `WatchConnectivityManager.swift` | Watch-side WC delegate: receives the manifest + files, sends "Clear all". |
| `WatchPlaybackManager.swift` | `AVPlayer` audio engine + Now Playing (the iPhone player's core, audio only); also holds the phone's now-playing for remote mode. |
| `WatchRootView.swift` | The three swipeable panes. |
| `WatchListView.swift` / `WatchListenView.swift` / `WatchSettingsView.swift` | The List / Listen / Settings panes. The Listen pane doubles as the phone **remote** when the phone is playing. |

## Share from other apps

A **Share Extension** lets you send a link straight from Safari, the YouTube
app, etc. into Offline Listen:

1. In another app, tap Share → **Offline Listen**.
2. The extension stashes the URL in the shared App Group container and opens the
   app via the `offlinelisten://` URL scheme.
3. On launch/foreground the app drains the shared URLs and auto-enqueues them as
   M4A downloads (see `SharedInbox` + `importShared()` in `OfflineListenApp`).
   A shared *list* — a YouTube playlist, or an album/playlist shared from the
   Spotify app — takes the same route a pasted one does: the selection popup and
   its own folder.

The extension does no downloading itself (extensions have a tight memory budget);
it just hands the URL to the app.

### Required Xcode setup for the extension

The project wires up the second target, entitlements, and URL scheme, but
**signing and the App Group must be configured in Xcode** (they can't be set
from source alone):

1. Select each target (**OfflineListen** and **ShareExtension**) →
   *Signing & Capabilities* → set your **Team**.
2. Confirm both targets have the **App Groups** capability with the same group,
   `group.com.offlinelisten.app` (the `.entitlements` files declare it; let
   Xcode register/provision it). If you change the group id, update it in both
   entitlements files and in `SharedInbox.appGroup`.
3. Bundle IDs default to `com.offlinelisten.app` and
   `com.offlinelisten.app.ShareExtension` — change both (keep the extension a
   child of the app id) if those are taken.

### Required Xcode setup for the watch app

The project wires up the **OfflineListenWatch** target, embeds it in the iOS app,
and sets `WKCompanionAppBundleIdentifier`, but **signing must be set in Xcode**:

1. Select the **OfflineListenWatch** target → *Signing & Capabilities* → set your
   **Team** (a watch app needs its own provisioning).
2. The watch bundle id defaults to `com.offlinelisten.app.watchkitapp` (a child
   of the app id). If you changed the app's bundle id, update the watch's to
   match and keep `WKCompanionAppBundleIdentifier` (in `OfflineListenWatch/Info.plist`)
   equal to the **iOS app's** id.
3. The watch target needs **no extra capabilities** — WatchConnectivity requires
   no entitlement, and the watch keeps its library in its own container (so the
   watch entitlements file is intentionally empty).
4. Run the **OfflineListenWatch** scheme on a paired watch (or a paired
   iPhone + Watch Simulator pair) to test the sync end-to-end.

## Setup

Requires **Xcode 15+** and an Apple developer account (free is fine for running
on your own device).

1. Open `OfflineListen.xcodeproj`.
2. Xcode resolves two Swift packages on first open (needs a network connection):
   - **YouTubeKit** — `https://github.com/b5i/YouTubeKit.git` — the native-Swift
     primary extractor.
   - **YoutubeDL-iOS** — `https://github.com/kewlbear/YoutubeDL-iOS.git` — the
     yt-dlp fallback extractor.

   YouTubeKit is pinned **up-to-next-major from 2.8.0** (it's actively
   maintained and tracks YouTube's changes — use Xcode's *Update Package*
   to pull new releases deliberately); YoutubeDL-iOS is pinned to `main`
   (the repo is dormant — the yt-dlp *engine* it downloads at runtime is
   what actually updates). Playback uses Apple's AVFoundation — no
   media-player package.
3. Select the **OfflineListen** scheme and your device (or a Simulator — note
   the on-device yt-dlp download needs network).
4. Set your **Signing Team** under *Signing & Capabilities* and adjust
   `PRODUCT_BUNDLE_IDENTIFIER` (default `com.offlinelisten.app`) if needed.
5. Build & run.

The **Every Noise browser's** dataset ships in the repo
(`OfflineListen/EveryNoiseData/`, bundled via a folder reference) — nothing to
set up. It came from the one-time `tools/everynoise/scrape.py` run; the site's
data is frozen, so it never needs re-scraping (see `tools/everynoise/README.md`
if you ever want to regenerate it).

> **First download is slow:** YoutubeDL-iOS fetches the `yt-dlp` Python module
> (tens of MB) on first use, then caches it. A network connection is required
> for that step and for every download; playback is fully offline.

### Running on macOS

macOS is an official build target — as **Mac (Designed for iPad)**, which
runs the iOS build natively on Apple silicon. The project declares it
(`SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = YES`), so on an Apple silicon Mac
the destination **My Mac (Designed for iPad)** appears in Xcode's run
menu — select it and Build & Run; everything ships in the one app: the whole
Every Noise dataset, the embedded Python / yt-dlp pipeline, background audio.

Why not Mac Catalyst (deliberately `SUPPORTS_MACCATALYST = NO`): the
extraction stack's native dependencies — YoutubeDL-iOS's embedded Python
above all — are compiled for the **iOS** SDK, and a Catalyst build would need
every one of them rebuilt against the Mac Catalyst SDK, which the dormant
YoutubeDL-iOS doesn't provide. Designed-for-iPad sidesteps that entirely by
running the untouched iOS binaries, so the whole download pipeline works on
the Mac exactly as it does on the phone. (Intel Macs can't run
Designed-for-iPad; there this stays an iPhone/iPad app.) The Share Extension
and the watch app remain platform-specific, and Local Sync's folder picker
reads Mac folders through the same Files-provider flow.

## Background / lock-screen playback (the success criterion)

Three pieces make this work, already configured:

- `UIBackgroundModes = [audio]` in `Info.plist`.
- `AVAudioSession` set to the `.playback` category in `PlaybackManager`.
- `MPNowPlayingInfoCenter` (now-playing metadata **and** an explicit
  `playbackState`, which iOS 13+ needs to reliably surface the controls) +
  `MPRemoteCommandCenter` for the lock-screen transport buttons.

Start a track, lock the phone — audio keeps playing and the controls appear on
the lock screen.

The lock screen / Control Center renders only **three** transport buttons (a
centre play/pause plus two side buttons), and iOS shows *either* the
next/previous-track commands *or* the skip-forward/backward commands — never
both (enabling both makes them conflict and the skip buttons silently fail to
appear). So `PlaybackManager` chooses the side pair **per track** in
`updateTransportButtons()`: **songs and videos** get **next/previous-track**,
while **podcasts** get **jump ahead 30s / back 15s** (more useful for long
episodes). Whichever pair isn't shown stays available from the in-app Player,
whose controls call `next()` / `previous()` / `skipForward()` directly.

## Audio vs. Video

- **Audio** (default) saves an AAC `.m4a` — the best audio-only stream, or, if a
  video has none, the audio extracted from a muxed MP4. No transcoding.
- **Video** saves an `.mp4`. Modern YouTube usually serves **separate**
  video-only and audio-only (DASH) streams, so we download the best video plus
  the best audio and **mux them natively** with `AVMutableComposition`
  (`VideoMerger`, no FFmpeg) — auto-detecting whether the video already has audio
  so it's never doubled. Video renders through `AVPlayerViewController` (for
  the picture and PiP) but is driven by the app's own transport controls — the
  same suite audio gets — and keeps its audio in the background.

  Video selection is **codec-aware** (`PlayableVideoCodec`): only **H.264**
  (`avc1`/`avc3`) and **HEVC** (`hvc1`/`hev1`) are chosen, because AVFoundation
  can't decode the **AV1** (`av01`) or **VP9** streams YouTube increasingly
  serves — an AV1 file plays its timeline but shows a blank QuickTime
  placeholder with no picture or sound. When *only* such codecs are on offer (it
  happens when the on-device player JS can't be resolved and every H.264 URL,
  which needs nsig descrambling, gets dropped), the yt-dlp path runs a
  **recovery**: it re-resolves forcing alternate **player clients** (`tv`,
  `ios`, `android`, `web_safari`, `mweb`, `web`) one at a time, whose H.264 URLs
  need no descrambling — the same renditions Safari plays — and takes the first
  that yields a decodable stream. The order matters for quality: it accepts the
  first client that works, so the no-token, **higher-resolution** source (`tv`,
  up to 1080p H.264) leads — it's also the most reliable on device under
  YouTube's 2024–25 SABR / PO-token tightening, whereas `ios` is increasingly
  gated or slow — and `android`, whose formats SABR frequently caps low (360p),
  follows; the web-family clients come last because on device they usually fail
  the n-challenge (no JS runtime). When the
  recovered H.264 is much lower than what was offered, the log says so — a 360p
  save from a 2160p AV1-only source reads as a codec ceiling, not a bug. Only if
  every client still yields nothing decodable does the download fail with a clear
  `unplayableVideoCodec` message.

## Extraction: native primaries + yt-dlp fallback

Extraction sits behind the `MediaExtractor` protocol, and `CompositeExtractor`
tries a primary then a fallback (cancellation is never treated as a failure, so
Cancel doesn't trigger the fallback). Each extractor advertises which URLs it can
handle via `canHandle(_:)`, so the composite **skips** a primary that doesn't
apply (the YouTube-only native extractor on a SoundCloud link) and goes
straight to the next one, instead of logging a guaranteed failure. They nest —
Vimeo, then YouTubeKit, then yt-dlp — so each site takes the fastest route that
knows it:

0. **`VimeoExtractor` (primary, Vimeo only)** — Vimeo's web player runs off a
   JSON **player config** listing the title, duration, any **progressive** MP4s
   and the **HLS** master playlist. Plain HTTPS and `Codable` — no Python, no
   interpreter gate, no 90-second window. Progressive files are downloaded
   directly when Vimeo still offers them (for audio: the smallest rendition,
   then AVFoundation extracts its audio track, since Vimeo publishes no
   audio-only stream); otherwise the playlist goes to `HLSDownloader`.

   Getting the config is the fiddly part, because **Vimeo signs the config
   URL**: requesting `player.vimeo.com/video/{id}/config` directly returns
   **403 even for a public video**. The signature lives on the `config_url`
   printed into the player's own page, so the extractor reads pages first —
   the player page (`player.vimeo.com/video/{id}`), which usually inlines the
   whole config as `window.playerConfig`, then the watch page — and only falls
   back to the unsigned endpoint, which still serves videos whose owner allows
   unrestricted embedding. Unlisted links (`vimeo.com/{id}/{hash}`) carry their
   hash through. Anything it can't read — an album, an embed shape it doesn't
   know, a password-protected or embed-restricted video — throws, and the
   composite falls through to yt-dlp as before.
1. **`YouTubeKitExtractor` (primary, YouTube only)** — b5i/YouTubeKit resolves
   the audio-only stream URL natively in Swift (no Python, no engine download,
   fast). Pure `VideoInfosWithDownloadFormatsResponse.sendThrowingRequest` → best
   `AudioOnlyFormat`. `canHandle` returns true only when a YouTube video id can be
   parsed, so non-YouTube links bypass it.
2. **`YoutubeDLExtractor` (fallback)** — the yt-dlp path, used when the native
   extractor fails. `extractInfo(url:)` resolves the video; the Download tab's
   "⋯" menu has **Refresh yt-dlp engine** to re-pull a stale module. The URL is
   first **canonicalised** to `https://www.youtube.com/watch?v=ID` — the mobile
   host (`m.youtube.com`) and tracking/autoplay params (`pp`, `ra`, …) are
   stripped, since a parameterised mobile URL can push on-device extraction down
   a slower path.

   The default `extractInfo` call runs first — it's also what bootstraps the
   embedded Python runtime (PYTHONHOME, the unpacked stdlib, PythonKit's module
   search path), so the forced-client recovery, which drives Python directly,
   **must** run after it (calling it first crashes with `No module named
   'encodings'`).

   **The default attempt gets a 60s window for YouTube (90s for other sites),
   then falls to the forced fast player clients.** Modern yt-dlp (2026.x) with no
   JS runtime resolves via the JS-less `android_vr` client — a plain network
   call, no nsig — so there's no pure-Python descrambling to stall the
   interpreter; the window just needs to be long enough for that network resolve
   (an earlier, much shorter grace was cutting it off and turning perfectly
   downloadable videos into timeouts). Once the on-device JS runtime is wired,
   the web client's nsig is solved in JavaScriptCore in a couple of seconds, so
   the longer window never reintroduces a stall. If the default still fails, it
   **falls to the forced fast player clients**, one at a time. The
   client order is **mode-aware**: **audio** leads with the pre-signed
   `ios`/`android` clients (resolution is irrelevant and they dodge YouTube's
   `tv`-client DRM experiment, [yt-dlp #12563](https://github.com/yt-dlp/yt-dlp/issues/12563)),
   while **video** leads with `tv` for its higher-resolution H.264; the
   web-family clients (`web_safari`/`mweb`/`web`) come last in both. Non-YouTube sites (Vimeo,
   SoundCloud, …) have no such fast fallback and can legitimately be slow, so
   they keep the full 90s timeout and only **retry with the forced clients** if
   the default extraction stalls or fails. This forced-client recovery handles
   **both audio and video** downloads (see below).

If a video exposes **no dedicated audio-only stream**, both extractors fall back
to downloading the smallest muxed (video+audio) **MP4** and extracting its audio
track to m4a via `VideoAudioExtractor` (AVFoundation's `AVAssetExportSession` —
no FFmpeg). The result is verified to actually contain an audio track. WebM is
excluded because AVFoundation can't read it.

Both resolve a direct stream URL and then hand it to the shared
`AudioStreamDownloader`, which fetches it in **5 MB HTTP byte-range chunks**
(each retried on transient errors with exponential backoff). YouTube
throttles/drops single large connections, so — like yt-dlp — ranged requests
are what make big files download reliably. We deliberately avoid
YoutubeDL-iOS's own `download(...)`: it's hardwired to a *background*
`URLSession` that doesn't complete on the Simulator.

The downloader is **self-healing** rather than fail-fast, because googlevideo
URLs expire (~6h), are IP-bound, and get rejected outright (HTTP 403/410) when
YouTube's token checks shift mid-download:

- **Re-resolve + resume.** Every download carries a *refresher* from its
  extractor: on a 403/410/416 (or a stall that survives in-place retries) the
  URL is re-resolved — the same yt-dlp `format_id` or YouTubeKit rendition —
  and the download **resumes from its current byte offset** instead of failing.
  The server's first Content-Range total overrides the extractor's metadata
  size (which can be inaccurate); a *change* in the server-confirmed total
  afterwards means a different rendition was served and aborts the download
  rather than corrupting the file, and a mid-file HTTP 200 (Range ignored)
  rewinds and rewrites the file rather than appending foreign bytes.
- **No silent truncation.** An empty or short body before the advertised size
  is a stall to retry, *not* an end-of-stream; if the remaining bytes can't be
  fetched the download **fails** — a truncated file is never saved as a
  success.
- **Verified playable.** Every finished file must pass `MediaVerifier` (a
  decodable audio/video track and a real duration via AVFoundation) before
  it's returned; an unplayable dud fails the attempt so the next player
  client / extractor gets its turn, instead of a broken track landing in the
  library.
- **Download failures fall through to other clients.** On the yt-dlp path, a
  failure *after* a successful extraction (URL rejected even across refreshes,
  truncation, failed merge, failed verification) retries via the forced player
  clients — which resolve *different* URLs — not just extraction failures. In
  the forced-client loop itself, one client's download failure moves to the
  next client rather than sinking the whole recovery.

### Any yt-dlp site (Vimeo, SoundCloud, …)

The yt-dlp path isn't YouTube-specific: it resolves whatever URL it's given, so
Vimeo, SoundCloud and the rest of yt-dlp's catalogue work. Two constraints shape
which formats we pick:

- **Progressive first, HLS as a fallback.** `AudioStreamDownloader` fetches a
  single file over byte ranges; it can't assemble an **HLS** playlist or
  **segmented DASH**. So `isProgressiveDownloadable` (and, on the Python path,
  yt-dlp's `protocol` field) picks single-URL streams first — including
  YouTube's DASH renditions, which *are* direct URLs. When a site offers
  **nothing but HLS**, the playlist goes to `HLSDownloader`, which reads the
  playlist itself: it picks a variant (by resolution, restricted to
  device-decodable codecs), fetches the `EXT-X-MAP` init segment and every media
  segment, and appends them into one file. Modern HLS — Vimeo's included — is
  **fMP4**, and those segments concatenated *are* a valid fragmented MP4 that
  AVFoundation reads natively. No FFmpeg. Only if there's no readable HLS either
  does the download fail with the `hlsOnly` message. Segmented DASH remains
  unsupported, as do **MPEG-TS** segments (joining those doesn't produce
  anything AVFoundation can open — it's detected and reported rather than saved)
  and encrypted streams.

  Audio mode takes the master's **audio-only rendition** when there is one — a
  fraction of the bytes, and no extraction step. A video variant that carries no
  sound of its own (it names an `AUDIO` group instead) has that rendition
  fetched too and muxed back in by `VideoMerger`, exactly as the YouTube DASH
  path already does. A **live** stream is the one inherent limit: it has no end,
  so only VOD can be saved.

  This is the second half of what makes **Vimeo** work (the first is
  `VimeoExtractor`, which reaches the same playlist without Python at all).
  Vimeo retired progressive files for most accounts, so an ordinary Vimeo link
  offers HLS and nothing else, and the download used to fail before it started.

  > The first cut of this handed the playlist to `AVAssetExportSession`
  > instead. That was wrong twice over: a remote HLS `AVURLAsset` exposes **no
  > `AVAssetTrack`s at all** (they only materialize through an `AVPlayerItem`),
  > so the "does this carry video?" precheck rejected every stream it was given;
  > and an HLS asset reports itself non-exportable anyway. Apple's supported
  > offline-HLS route, `AVAssetDownloadTask`, produces a `.movpkg` bundle — not
  > a file this app can move into the library, play by path, share, or send to
  > the watch.
- **Playable containers.** Audio is saved raw only when it's a container
  AVFoundation can decode (`m4a`/`mp3`/`aac`/`wav`/`aiff` — so SoundCloud's
  progressive **mp3** saves directly, while an opus/webm-only stream routes to
  the muxed-video + audio-extraction fallback instead). Video stays restricted
  to decodable **H.264/HEVC** MP4.

If the YouTubeKit package isn't linked yet, its extractor throws and the composite
falls back to yt-dlp automatically. To exercise the UI with no native dependency
at all, point `DownloadManager`'s default extractor at `MockExtractor`.

The forced-client **recovery** (`extractViaForcedClients`) drives yt-dlp's Python
`YoutubeDL` directly (to pass `extractor_args`, which the structured `extractInfo`
API can't), so it needs **PythonKit** importable from the app target. It serves
two cases: re-resolving for decodable **H.264** when the default path offers only
AV1/VP9 (video mode), and re-resolving when the default path **stalls/times out
or fails** (audio *or* video). PythonKit is a transitive dependency of
YoutubeDL-iOS; if `import PythonKit` doesn't resolve, add it as an explicit
package dependency on the **OfflineListen** target in
*Project ▸ Package Dependencies*. Guarded by `#if canImport(PythonKit)`, so
without it the recovery compiles out — an AV1-only video then fails with the
clear `unplayableVideoCodec` message, and a timed-out extraction with the
timeout error.

### Diagnosing failures from the Log

The **Log** tab is the primary diagnostic tool, so failures are made as legible
as possible rather than collapsing to one opaque line:

- **The timeout no longer hides yt-dlp's real error.** When the 90s limit fires
  the queue moves on, but the abandoned extraction keeps running and its *actual*
  outcome is logged when it finally settles — either `yt-dlp's own error (arrived
  Ns in…)` with the real reason, or a note that it simply succeeded late (so you
  know the video isn't broken, extraction was just slow).
- **yt-dlp's own messages are captured.** The forced-client path installs a
  Python `logger` so yt-dlp's warnings/errors — "Sign in to confirm you're not a
  bot", "missing a PO token", "Some formats may be missing", signature/nsig
  failures — appear in the log tagged `yt-dlp(<client>):`, instead of being
  swallowed.
- **Non-YouTube failures get a diagnostic probe.** The default path goes through
  YoutubeDL-iOS's structured `extractInfo`, which takes no options — so there's
  nowhere to hang a `logger`, and on a non-YouTube link (whose failure the
  YouTube-only forced-client sweep can't help with anyway) a timeout used to
  read as 90 blank seconds. Now the sweep is skipped for those links, and a
  **metadata-only probe** re-runs the extraction the one way that *can* be
  logged — driving Python directly with a capture logger and
  `download=False, process=False` — purely so yt-dlp says where it got stuck
  (`yt-dlp(probe): [vimeo] …: Downloading webpage`). Its result is discarded;
  the job still fails with the original error. A probe that *succeeds* says the
  extraction works but overran its window — slow on device, not broken — and
  says so.
- **Plain-language hints.** `diagnosticHint(for:)` maps common signatures (bot
  check, PO token, private/members-only/age-restricted, unavailable, stale nsig
  engine, network) to a `Hint:` line suggesting the likely cause and next step.
  It returns nothing when it doesn't recognise the error — it never invents a
  diagnosis.
- **The log survives a crash.** The in-memory log is published on the main
  actor, so a hard native fault (most plausibly a PythonKit crash inside a
  forced-client `extract_info`) would take its buffered tail down with it — the
  very lines naming *where* it died. `DiagnosticLogFile` therefore mirrors every
  line to `Documents/diagnostics.log` with a synchronous `write()` before the
  caller proceeds, and on launch rolls the prior file to `diagnostics-previous.log`.
  The Log tab's **share** button exports both, so a trail that ends mid-step is
  still readable after a relaunch.
- **The forced-client recovery is bounded and breadcrumbed.** Each client
  attempt now runs under a hard `withTimeout` (the heartbeat alone never capped
  it, so a client that hung inside Python stalled the whole download with no
  further output); a timed-out client is logged and the loop moves to the next
  one. `.debug` breadcrumbs bracket each Python call (`Importing yt_dlp…`,
  `Running extract_info…`, `extract_info returned`) so the last persisted line
  pinpoints the exact in-flight step.
- **A stale engine refreshes itself.** When a failure's signature says the
  cached yt-dlp module is out of date with YouTube's player (nsig/signature
  extraction failures), the engine is re-downloaded automatically — once per
  session — and the URL retried, instead of waiting for the user to find
  ⋯ → Refresh yt-dlp engine.

### On-device JavaScript runtime (nsig solving + PO tokens)

YouTube's 2025–26 countermeasures made "extraction" require running the site's
own player JavaScript: the `n`/`sig` challenges now need a real JS runtime (yt-dlp
uses Deno on desktop), and PO (proof-of-origin) tokens are minted by BotGuard, a
JS attestation program. iOS ships two first-party JS engines, so the app closes
this gap on device rather than depending on whichever unauthenticated player
client YouTube hasn't gated yet — the plan is
[`docs/JS-RUNTIME-PLAN.md`](docs/JS-RUNTIME-PLAN.md).

- **nsig/sig solving via JavaScriptCore (active).** `JSChallengeSolver` runs the
  pinned [`yt-dlp-ejs`](https://github.com/yt-dlp/ejs) challenge-solver scripts
  (`OfflineListen/ytdlp/scripts/`) in JavaScriptCore — the same scripts a desktop
  Deno/QuickJS runtime would run. A small Python plugin
  (`ytdlp/plugins/…/offlinelisten.py`) registers as a yt-dlp **JS-challenge
  provider** and calls back into Swift via a PythonKit bridge (`PythonBridge`);
  once it reports available, yt-dlp selects the web player clients again (whose
  renditions are the ones Safari plays) instead of falling back to its JS-less
  client set. Wired into the forced-client recovery and, from the second download
  on, the default web path.
- **PO-token minting via WKWebView.** `POTokenMinter` runs Google's BotGuard
  program in a hidden `WKWebView` and mints `gvs`/`player` tokens (lazily, cached
  for hours, refreshed on 403), fed to yt-dlp through a registered **PO-token
  provider**. The whole flow is vendored as `botguard.js` (bundled from
  [`bgutils-js`](https://github.com/LuanRT/BgUtils)); because the WebView runs in
  the `youtube.com` origin, its network calls are same-origin, so Swift makes no
  HTTP calls of its own. If `botguard.js` is ever removed the provider goes
  dormant and extraction is unchanged.

Both providers are strictly best-effort: any failure logs a `.warning` and
extraction proceeds exactly as it did before. The runtime registers lazily, at a
point that's been observed safe — once a prior `extractInfo` has bootstrapped the
embedded Python and the interpreter is idle — so the plugin import never races a
running extraction. **In practice: download one easy video first (it bootstraps
Python cleanly), and hard videos then resolve on device in the same session**; a
first-ever hard video fails cleanly rather than downloading. The forced-client
fallback also refuses to run while a timed-out extraction is still executing in
the interpreter, so concurrent extractions can't crash the app. Each failed job
logs a single `Failure class: …` line (`nsig` | `po-token` | `bot-check` |
`http-403` | `timeout` | `hls-only` | …) so a week of diagnostics logs can be
tallied by failure mode.

The remaining gap — age-gated / members-only content needing a signed-in
session — is scoped as optional cookie import (Phase 3) in the plan.

## Chapters

YouTube chapter markers are captured after a download as a best-effort step
(`ChapterFetcher`): a fast, metadata-only `yt-dlp` lookup
(`extract_info(download=False, process=False)` via PythonKit) reads the
`chapters` list (`title` / `start_time` / `end_time`) and stores it on the
`Track`. It runs only when the on-device yt-dlp Python module is **already
present**, so capturing chapters never triggers the tens-of-MB module download
on its own; without PythonKit/the module, tracks simply carry no chapters and
everything else is unchanged.

It also starts the embedded interpreter first if nothing else has this session
(`PythonBridge.ensurePythonRunning()`), and skips itself entirely if it can't.
That isn't defensive tidiness: a download served by the **native** Vimeo or
YouTubeKit extractors never runs a yt-dlp extraction, so chapter capture becomes
the first thing to touch Python — and touching it uninitialized doesn't throw,
it kills the process (`ModuleNotFoundError: No module named 'encodings'`), which
took the app down right after an otherwise perfect download. `PlaylistResolver`
takes the same guard, since resolving a pasted playlist is often the first thing
a launch does. Chapters persist in `library.json` (older
libraries decode with an empty list).

Chapters surface three ways: a jump-to list behind the library row's arrow, dots
+ a current-chapter line on the Player, and **Break Chapters into Playlist**,
which uses `AVAssetExportSession` (audio → `.m4a`, video → passthrough `.mp4`)
to cut one file per chapter into a new folder, then asks whether to delete the
original (Split & Delete vs. Split & Keep).

## Status

Built as a complete, ready-to-open Xcode project, authored on Linux without an
Xcode toolchain. The YoutubeDL-iOS integration is written against the library's
verified public API. Playback (offline, background, lock-screen) uses
AVFoundation only. The companion **watchOS app** and its phone↔watch sync are
likewise written against the documented **WatchConnectivity** / AVFoundation
APIs; its target is wired into `project.pbxproj` by hand (set the watch **Team**
in Xcode before building — see
[Required Xcode setup for the watch app](#required-xcode-setup-for-the-watch-app)).
