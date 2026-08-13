# Offline Listen

A SwiftUI iPhone app that downloads the audio from a video URL, saves it to the
device, and plays it back offline — including in the background with the phone
locked.

> **Personal-use tool.** Downloading from sites like YouTube may conflict with
> their Terms of Service and with copyright. Only download content you own or
> have the right to, and use this responsibly.

## What's here

Five screens (tabs), left to right. None of them carries a header title — the
vertical space goes to the content instead.

1. **Browse** — opens straight into the **Every Noise browser**: the whole
   [Every Noise at Once](https://everynoise.com) genre map, bundled into the
   app and browsable offline; tapping an artist there leads to their live
   Spotify discography, or files them into Browse as an Artist source (see
   [The Every Noise browser](#the-every-noise-browser)). The **sources** you
   keep tabs on live one tap away, behind the **stack button** in the
   top-right corner — beside a **bookmark button** holding what you've
   [saved for later](#saved-for-later) — and the stack wears a **dot** when a
   refresh has turned up
   items you haven't acted on (see
   [Browse: keeping tabs on audio sources](#browse-keeping-tabs-on-audio-sources)):
   YouTube channels/playlists, RSS feeds, a **Blog Agent** for blogs
   without a feed, an **Artist** source (following their **Top 10**, an
   AI-laid-out **Search Discography**, or their real **Spotify Discography**),
   or AI-curated Genre / Country
   lists; each refresh surfaces YouTube links, shown as compact
   name-over-artist rows, and
   every item offers **Download** (sends it to the download queue) and
   **Preview** (a listen-first modal with **Save** / **Discard**). A **Select**
   button in a source's list flips it into multi-select, so you can tick a
   batch of items and download them all in one tap. An
   **Audio/Video toggle** atop the Sources screen — the same one the Download
   tab has — sets which mode both buttons (and the bulk download) act in.
2. **Library** — downloaded tracks; tap to play. Five **tabs** across the top
   divide it — **Recent**, **Folders**, **Inbox**, **Watch**, **All** — so each
   section is one tap from the others rather than a screen you push into and
   come back out of. **All** lists
   **every** track — filed into a folder or not — so it's the full flat view
   of the library (folders are one way in, not the only one). A **search**
   field sits above
   the tabs: type anything and the list becomes results — matching **folders**
   first, then every track whose **title or artist** matches (the tabs step
   aside while it does, since a search answers across all of them). Matching
   ignores
   case and accents, so "beyonce" finds "Beyoncé", and the media-type filter
   still applies. Results come back **as you type** — see
   [Why the library is fast](#why-the-library-is-fast) for what that costs.
   A **filter** (All / Music /
   Podcasts / Video) sits at the top of the **All** tab. Swipe **left**
   for Delete/Share/Archive (and bulk versions via **Select**); swipe **right**
   on an audio track to classify it **Song** or **Podcast**. Songs start from the
   beginning; podcasts (mic icon) and videos (film icon) resume where you left
   off and show a progress bar. A track you haven't listened to yet shows a
   **green** icon. Video tracks play with picture on the Player screen. Archived
   tracks (and archived folders) live in the **Archive**, pinned to the bottom of
   the folder list.

   **Autoplay.** When a track finishes, playback advances to the next track in
   the same list and keeps going to the end — it doesn't loop. (What makes
   that dependable, including with the phone locked, is described in
   [Why autoplay keeps going](#why-autoplay-keeps-going).) In the
   **auto-aggregated** lists (the **All** tab and the Inbox), where media types
   are mixed together, autoplay **stays within the media type** you started: pick
   a song and only songs play on (podcasts and videos are skipped until the next
   song or the list ends), and likewise for podcasts and videos. A **folder is a
   curated playlist**, though, so it **plays straight through in list order**
   regardless of type — tap any track and the whole folder plays in sequence.

   **Recent.** A tab of its own — the mirror image of the Inbox — listing what
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

   **Folders** organize the library, and have a tab of their own. A folder with
   a **cover** — an album pulled down whole from a discography, or one you gave
   art to yourself — draws it as a thumbnail on the left of its row in place of
   the folder icon (an album with no art yet shows its colour there instead).
   A folder whose tracks all name the **same artist** — which
   an album pulled down from a discography is by construction — prints that
   artist under the folder's name, the same title-over-artist shape a track row
   has. It's derived from the tracks rather than stored on the folder, so an
   album you assembled by hand earns it too, an Edit Metadata fix moves it, and
   a folder of unrelated songs (which agrees on nobody) shows nothing extra. The three virtual folders that used to sit pinned above them
   — **Inbox** (every track you haven't listened to yet; starting playback — or
   a **Mark Played** swipe — clears it from the Inbox), **Recent** and
   **Watch** — are tabs now; the **Archive** is still pinned to
   the bottom. Create folders with the Folders tab's folder button; move tracks in
   via touch-and-hold → **Move to Folder** (or the bulk Select menu). The Inbox
   is itself a move target — moving a track there returns it to unlistened.
   Touch-and-hold also offers **Edit Metadata**, a modal for hand-editing the
   track **title and artist** (handy when AI Organize doesn't get it quite
   right), with **Reset to Original Title** to restore the download title —
   and, with Spotify credentials saved, **Get Album Art**, which finds the
   track's cover on Spotify and attaches it (see [Album art](#album-art)).
   A **video** track offers **Get Subtitles** as well — the same capture a
   video download makes, run on demand (see [Subtitles](#subtitles)).
   A downloaded track also offers **Convert to Video** / **Convert to
   Audio**: the file is re-downloaded from its source in the other format,
   into the same folder, and the original is replaced only once the fresh
   download has fully landed — a failed conversion costs nothing (the
   attempt shows in the Download tab like any job). Tracks with no source
   link (local-sync imports) don't offer it. A track that **names an artist**
   offers **View Discography**, which opens that artist's live Spotify
   catalogue in a sheet — the same browser the Every Noise map pushes, reached
   from the song rather than from the map ("Unknown" is the placeholder a
   download starts with, so a track wearing it doesn't offer it). The link
   itself is on the menu
   too — **Copy URL** puts it on the clipboard (to paste into the Download
   field, or anywhere else) and **View Original** opens it in the browser;
   a track with no link offers neither. Swipe
   a folder row for its slide menu: **Delete**, **Rename**, and **Archive**
   (move the whole folder, tracks and all, into the Archive).

   **Delete asks what you mean.** A folder is a grouping, so deleting one used
   to leave its tracks in the library — right for a folder you're just
   unfiling, wrong for one that *is* an album, and there's no telling which
   from the swipe. It now offers both, naming the count: **Delete Folder & 12
   Tracks** (red — the files go for good, artwork and synced copies with them,
   including anything in subfolders) or **Delete Folder Only** (the old
   behaviour: the tracks return to the library list and subfolders move up a
   level). An empty folder just asks once. **Archive** is untouched and stays
   the reversible option.

   To **reorder** the tracks inside a folder, use the **Reorder** button in
   the folder's own screen — which also shows the folder's **cover** above the
   list when it has one (see [Album art](#album-art)).

   **The "Synced" grouping.** With several sync folders mirrored in, the
   folders that mirror them can crowd out your own. Settings ▸ Local Sync ▸
   **Group under a "Synced" folder** collects them all behind a single
   **Synced** row (just above the Archive) instead. It's *purely* a display
   grouping — nothing moves on disk, no folder changes its place in the data,
   the rows keep the same swipe actions and touch-and-hold menu — so it can be
   turned on and off at any point with no effect on the sync setup.

   The folder list itself sorts two ways, chosen from the **sort** button in the
   Folders tab's toolbar: **Name** (alphabetical) or **User Order**. In User
   Order you set the sequence by hand — **touch and hold a folder and drag** it
   into place; the order persists to `folders.json`. Folders persist to
   `Documents/folders.json`.

   **Two ways to look at them.** A pair of glyphs in the Folders tab's
   **top-left corner** — opposite the sort and folder buttons — switches
   between the **list** (everything in one column, as above) and **covers**:
   three groups stacked down the screen, **albums** as a grid of their
   sleeves, then the **mixtapes** in their banner rows, then the plain
   **folders**. It's the same set of folders either way, sorted the same way —
   the sort applies within each group — with the Synced and Archive rows
   pinned beneath them as ever. The choice persists. Drag-to-reorder stays in
   the list: User Order is one sequence over *all* the folders, which three
   separate groups can't express, so setting it means switching back.

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

   **Albums.** The same menu offers **Convert to Album**, the other thing a
   folder can be: a record, wearing a **square cover** its songs share. A
   folder pulled down whole from a discography already is one; this is how any
   other folder becomes one. Tapping the sleeve on the album's own screen
   **changes or resets** the art, and a **Discography** button at the foot of
   its track list opens the artist's catalogue. **Convert to Folder** is the
   way back. See [Album folders](#album-folders).
3. **Player** — artwork, scrubber, play/pause, skip, next/previous — the same
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
   also goes fullscreen on its own when the phone rotates to landscape.

   **Subtitles.** A video downloaded with an English caption track (see
   [Subtitles](#subtitles)) draws it over the bottom of the picture, and a
   **CC button** sits in the corner of the picture — inline and fullscreen
   alike — to turn it off and on. The button only appears on a video that
   actually *has* captions, and the switch it flips is the same one in
   Settings ▸ Subtitles, where the text's size, colour and backdrop are
   chosen. For a
   chaptered track, small **dots** sit along the scrubber at each chapter's
   start and the **current chapter title** shows on its own line beneath the
   title/artist, updating as playback crosses a marker.

   **The mini player.** Whenever a track is loaded — playing, paused, or the
   one restored at launch — a bar rides just above the tab bar on
   *every other screen*: a hairline progress line, the cover, what's playing,
   play/pause and next — so you can keep browsing or searching without going
   back to the
   Player. Tapping the title opens the Player. It's about 20 points taller
   than it started out, which is what makes the cover legible and the
   transport buttons hittable without aiming. It's attached as a safe-area
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
4. **Download** — paste one or more URLs (whitespace/line-break separated; any
   http(s) link is queued and the rest of a pasted blob is skipped), choose
   **Audio** or **Video** (default Audio) from the **toggle inside the input
   field** — two small icons after the paste button, the Library's own
   music-note and film glyphs, exactly like the search-target toggle in
   Browse's Find field (it used to be a segmented picker on a line of its own,
   which spent a row of the screen saying what two icons say) — and watch the
   queue. A video download **asks which resolution** once it knows what the
   source is offering (see
   [Choosing a resolution](#choosing-a-resolution)). Links from **any site
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

   **A batch is one change to the queue.** Everything that queues several
   links from one press — **Download Album**, a playlist or Spotify
   collection's selection, a source's bulk **Select** — hands the whole set
   over at once (`enqueueBatch`) rather than a link at a time. It used to be a
   loop, and each pass published its own insert and ran its own scheduler
   pass: twenty tracks meant twenty mutations inside a single main-actor turn,
   on top of whatever the view that pressed the button was changing in the
   same turn. That combination is what the earlier bulk-download crash came
   down to — the UIKit diff under a `List` doesn't survive it — and the batch
   paths hadn't been given the same treatment the bulk-select path was. The
   queue still lists newest-first and still runs oldest-first, so a record
   downloads in tracklist order exactly as before.

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
5. **Settings** — AI configuration on top, then **Spotify** credentials, a
   **Subtitles** section, an
   **Every Noise Data** section, a
   **Local Sync** section, a
   **Blog Agent** section (posts per
   refresh / songs per post limits for the Browse tab's Blog Agent sources),
   and the **Log** as a section beneath them.
   - **Subtitles.** Whether captions show at all (the same switch the Player's
     CC button flips), their **text size**, a **colour** swatch and what sits
     **behind the text** (None / Dim / Solid), over a live sample — the only
     way to judge any of it is to see it. See [Subtitles](#subtitles).
   - **Every Noise Data.** An opt-in toggle that lets browsing the genre map
     top the bundled dataset up, a tally of what it has found, **Download New
     Data** to share that off the device, and a **Data Folder** to keep a copy
     of it in — its own folder, unrelated to Local Sync (see
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
  a track-id index, per-folder track counts, per-folder track *lists* (the
  cover grid asks each album for its tracks, to see what artwork they share),
  and the search index are each
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
synced folder keeps its sync badge, tucked into the corner of the cover), and
as a **sleeve above the track list** inside the folder itself. It's quite
separate from a **mixtape**'s hand-framed banner, which is still its own thing
(and takes precedence — a mixtape shows its banner instead).

A cover can also be given by hand: an **album** folder takes a square one from
Photos, kept beside the downloaded cover as `<folder-id>-cover.jpg` and shown
in preference to it, and copied onto every song in the folder. Which is where
album art stops being only something a download brings — see
[Album folders](#album-folders).

A folder that never went through **Download Album** can earn the same sleeve:
when *every* track in it carries the same cover — a Spotify album pasted into
the Download tab, or a folder you assembled by hand out of one record — that
image is shown. It has to be decided on **content**, not file names, because
each track's cover is saved under its own track id, so an album's twelve
identical covers are twelve identical *files*. File sizes are compared first,
straight from the directory entries (two different covers essentially never
weigh the same, so a mixed folder is ruled out without opening anything), and
only if they all match are the bytes read. The verdict is memoized against the
folder's exact set of artwork files, so opening a folder pays for it once
rather than once per redraw, and folders over 100 tracks skip the check
outright — nothing that big is an album.

Artwork is app-local display metadata: it's never synced or exported with the
file, it's deleted with the track (or the folder), and tracks without it
(YouTube feeds, searches, plain pastes) simply keep the placeholder. Decoded
images are memoized (`TrackArtwork` / `FolderArtwork`, `NSCache`s) so list
redraws never re-read disk.

## Browse: keeping tabs on audio sources

The Browse tab's **Sources** screen — behind the stack button in the top-right
corner of the genre map — watches a set of user-configured **sources** and turns
what
they surface into a curated to-listen list. Every source, whatever its type,
produces the same thing: **YouTube links with metadata** — each shown as a
compact row of just the artist/song title (no description clutter) and two
actions per item, both acting in the mode set by the **Audio/Video toggle**
atop the Sources screen:

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
  fill in as it goes.

  **The queue grows as the record does.** A release is matched against YouTube
  a track at a time, and each track offers Preview the moment *it* lands — so a
  preview started on the first hit was handed the only entry that existed yet,
  and kept it: a queue of one, next and previous dimmed for good, while the
  other twelve tracks lit up behind the sheet. That was the whole of the
  "next/previous do nothing" report. The release re-offers its list as it
  fills, the modal takes it, and the track being auditioned keeps playing and
  keeps its place in the longer list — growing the queue is not a reason to
  restart the audition.

  The transport is deliberately hard to leave dead beyond that. Which entry
  it's on and whether there's one either side are read from the list the modal
  was **built with**, so the side buttons are live from the first frame rather
  than from whenever the model behind them got handed the queue — and a tap
  hands it over itself before moving, so a button can never call into a model
  that hasn't been given the list it's meant to walk. Re-presenting the sheet
  on a track from a *different* list while it's still up (SwiftUI updates a
  sheet in place rather than rebuilding it) swaps the queue rather than leaving
  the transport walking the record before last. End-of-track is noticed the same way the
  library player notices it — a **frozen playhead**, not a paused player — so
  the auto-advance survives the same over-reporting files (see
  [Why autoplay keeps going](#why-autoplay-keeps-going)); relying on the end
  notification alone, as it used to, meant those tracks quietly ended the
  audition. And a preview that fails now *says* so, cancellations included:
  swallowing those left the modal on a spinner nothing would ever replace,
  which from the outside is indistinguishable from a next button that did
  nothing. Every move through the queue is logged under `Browse`.

  **It's a real listen, so it behaves like one.** The preview shows up on the
  **lock screen and in Control Center** exactly as a library track does —
  song and artist, the album's cover where the list knew one, a working
  scrubber — and the lock screen's transport walks *its* queue: next plays
  (downloads, then plays) the next track of the record you're auditioning, not
  the next one in the library. It keeps going with the phone **locked**, too:
  the queue and everything that moves it live below the view, so a finished
  track still rolls into the next with the screen off. (What makes both true
  is in [Lending the lock screen out](#lending-the-lock-screen-out).) The transport sits *outside* the loading state, so you
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

The button then **counts the record in** — *Downloading 3 of 12…* over a
progress bar — and becomes **Play Album** once every track has landed, which
starts the folder from its first song. That state is read from the *library*
rather than from what the row remembers doing, so it survives a redraw and
still offers to play a record you pulled down on an earlier visit.

Three things come with the album rather than being reconstructed afterwards:

- **The tracklist's order.** Downloads finish in whatever sequence the network
  serves them, and a folder holds its tracks in arrival order — so a record
  would otherwise be shuffled by how fast each song happened to download. The
  release's order is recorded at queue time and each track is slotted into the
  folder where it belongs as it arrives.
- **The song's real title and artist.** They come from the catalogue, not from
  the YouTube video title, so the library reads properly the moment a track
  lands — no waiting on the AI to clean it up, and no going without when
  there's no Anthropic key at all. (The download title is kept as the
  "original", so Edit Metadata ▸ **Reset to Original Title** still works.)
  With both already known the AI organizer is skipped for that track: guessing
  at a video name can only do worse than the catalogue's own answer, and a
  track from a discography is music by construction. The one exception is the
  **YouTube-ranked Top 10** fallback, whose "tracks" are video titles with no
  artist — those still get the AI's usual go at them.
- **The cover**, on both the tracks and the folder (see [Album art](#album-art)).

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

The **Browse** tab *is* an in-app rendition of
[Every Noise at Once](https://everynoise.com) — Glenn McDonald's
readability-adjusted scatter-plot of the musical genre space. It's the tab's
own screen (it used to sit behind a world button beside Browse's "+", and the
sources it hid behind now sit behind a button of their own), with the scan
transport and the artist bar sitting just
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
  inside a genre sorts the same three ways. Rows here swipe **right** for
  **Save for Later**, exactly as History's do — genres in the genre list,
  artists in a genre's own.
- **Scan** auto-plays through the example tracks in map order — the site's
  scan mode as a bottom transport bar (prev / play-pause / next), with the map
  following along and the current entry drawn inverted. It works on the genre
  map and inside any genre's artist map, naming the track under each entry,
  remembers where it left off on the genre level, and skips entries with no
  preview. The transport carries the same **"+"** a tapped artist gets, so
  hearing something worth following doesn't mean stopping the scan, leaving
  the mode and finding them again by hand: it halts the scan and opens the
  artist's discography in one step. On a genre scan that's the artist behind
  the genre's example track — the site names them but carries no id for them,
  so the "+" resolves the name through Spotify's catalogue and only appears
  with credentials saved.
- **Find** filters: in list mode it narrows the list; over a map it drops down
  the matches and tapping one flies the map there. At the root the field has a
  **target toggle** inside its trailing edge, and the placeholder follows it:
  - **Find Genre** — the genre index.
  - **Find Artist** — **every artist in the dataset** (~470k unique names),
    most popular matches first, each with its home genre beneath; tapping one
    opens that genre with the artist selected, centered and previewing.
    Searching that many rows per keystroke is what the bundled **artist
    index** exists for (see the "Why it isn't laggy" notes below).
  - **Search Spotify** — offered only with credentials saved, because it's the
    one target that leaves the device. It asks Spotify's own catalogue rather
    than the frozen dataset, so it reaches artists the 2024 scrape never had
    and ones the map has no room for; hits are captioned with the artist's own
    genre labels, and picking one goes **straight to their discography**. The
    visit lands in History under an over-the-air icon, which is also how it
    re-opens — there's no place on the map to send it back to. It's debounced
    twice as hard as the local search, since every keystroke past the delay is
    a real request.
- **History** is the visit log, newest first: every genre you've opened
  (guitars icon), every artist you've tapped (mic icon, with their genre
  beneath) and every Spotify search you've followed, each in its map color
  with a relative timestamp. Tapping a genre re-opens its artists; tapping an
  artist re-opens their genre with that artist selected, centered and
  previewing. Like the Library's Recent it's a log, not a set — revisits
  re-append, only consecutive repeats collapse — capped at 200, filtered by
  Find, rows swipe to delete, with a Clear History button at the bottom
  (`Documents/everynoise-history.json`). Swiping a row the **other** way
  (right) keeps it rather than forgetting it: **Save for Later** files that
  genre or artist behind the **bookmark button** in the top-right corner (see
  [Saved for Later](#saved-for-later)) and leaves the log entry where it is.
  **A genre's own page has it too**,
  scoped to that genre: which of *its* artists you've already heard is the
  useful question there, and the answer used to be reachable only from the
  root, mixed in with every other genre you'd opened. A row there doesn't push
  anything — it puts the artist back on the map, selected and playing. (Its
  rows swipe both ways too, into the same saved list.)

#### Saved for Later

History answers "what have I already looked at?", which is the wrong question
for something you meant to come back to — a genre you opened mid-scan, an
artist you liked and then browsed past. **Saved for Later** is the list of
those, behind the **bookmark button** beside the sources button in the Browse
tab's top-right corner (filled once there's anything on it). Five ways in, all
of them where you already are rather than a screen you have to go to:
**swipe right** on a row in History (at either level) or in **List** mode (a
genre, or an artist inside a genre); the **bookmark** in a tapped artist's
action bar on the map; the **bookmark** in the toolbar of a **genre's own
page**, which is how you keep the genre you're currently looking at (saving a
genre used to mean finding its row somewhere else and swiping it); and the
**Save for Later** button on an artist's
discography page, alongside Learn More and Add as Source — the lighter half of
that pair, since it keeps the artist without following them as a source. The
genre buttons are switches like the artist ones: filled while the genre is on
the list, empty when tapped again.

**Genres are first-class here.** Every genre you open is logged in History
(from the map, from the List, from a saved row), it can be saved from any of
those places, and a saved genre re-opens on **its own map** — the artists
positioned in relation to one another, which is where you were when you
decided to keep it.

The list opens as a sheet, artists first, then genres, each row wearing the
same glyph and map colour History gives it. A row leads exactly where the
History row it was saved from does — a genre shows its artists, a mapped artist
lands on their genre's map with them selected, a Spotify artist re-opens their
discography — and swipes away. Unlike History it's a **set, not a log**: saving
something twice lifts it back to the top rather than listing it again.

Being a set means deciding when two saves are the same thing, and an artist
legitimately arrives in two shapes: off the map they're a shard id inside a
genre, off Spotify (a search hit, or the discography page's button) they're a
catalogue id with no genre at all. Nothing links those two ids, so the **name**
is what they have in common — which is also what you mean when you open an
artist's page and expect the button to already read as saved. Two distinct
artists sharing a name collapse into one row; that's the price, and it beats
the same artist sitting there twice with each button disagreeing about whether
they're saved. Unsaving removes *every* row for that artist, so one tap of
"remove" can't leave a copy behind. It
persists to `Documents/saved-for-later.json`, and its store is app-level
(`SavedForLaterStore`) because a pushed discography page can't see anything
injected inside the browser.

Every one of those modes clears the bar beneath it. The maps ignore the bottom
safe area outright, and a `List` inside a `NavigationStack` never picks up an
inset applied outside the stack, so both need the number handed to them as
explicit content inset — which is what the mini player already does for
itself. The scan transport and the artist action bar are **measured** the same
way and published alongside it, so the map insets by exactly their height, a
long Find dropdown stops above them instead of running underneath, and a list's
last rows scroll clear. The bars clear the mini player themselves, so it's the
larger of the two heights that applies, not their sum.

Tapping an **artist** plays a **30-second preview of their top song** (the
snippet URL is embedded in the scraped data — no Spotify account or API key is
involved) and opens an action bar naming **the artist and the track playing**,
with a **"+"** and a **bookmark**. The bookmark is where the bar's close button
used to be: dismissing it was the least useful thing you could do to an artist
you'd just tapped — the next tap on the map replaces the selection anyway, and
leaving the mode clears it and stops the snippet — so the slot went to the one
action that *keeps* them, [saving them for later](#saved-for-later) without
leaving the map or interrupting the preview. It's a **switch**: drawn at the
"+"'s size and in the same accent, it fills in while they're on the list and
empties when tapped again.
The track name comes from the same place the snippet does: the
site labels each row `Artist "Song"`, so the bar shows the song and Scan shows
it under the artist's name. The quotes are what's read, not the whole label —
a row with no snippet carries the bare string `(no sample available)` there,
which would otherwise go up as if it were a title. The two go together
exactly: across a 41k-row sample **every artist with a preview names its
track, and only those do**. Spotify's API can supply neither — it stopped
serving `preview_url` to apps registered after November 2024 — which is why
the site's own markup is the only source for both, and why a **dataset scraped
before August 2026 leaves the line blank**: the scraper read the field from the
start and dropped it on the way into the shard, so only genres ever had one.
Re-running `tools/everynoise/scrape.py` fills it in. With **Spotify credentials**
saved (Settings ▸ Spotify), the "+" goes **straight to Browse Discography** —
no chooser popup — the artist's *real* catalogue read live from Spotify (the
scraped data carries every artist's Spotify id, but no discographies).

Sitting directly on top of the Top 10 — in the same card, not floating above
it — is the **Artist Sample Track**: the very song the 30-second snippet
played, named, matched against YouTube on sight and offered to preview or
download like any other. It's the one song you already know you liked, and it's
why you're on the page; leaving it to be rediscovered somewhere in a
hundred-track catalogue was a small absurdity. It matches itself rather than
waiting to be asked, which the release rows deliberately don't — one search for
one chosen song is a different proposition from a dozen searches for songs you
may not want. (It travels with the scan's "+" too, so following something
mid-scan lands on the page with that song at the top.)

**The row also places the song on a record.** The site hands over a title and
nothing else, so the line under it used to read "Artist Sample Track" — which
the row plainly is, and which tells you nothing you can't see. As the
discography loads, the song is looked for in the catalogue's **own tracklists**
first (free: the AI layout carries them inline, and an answer naming a record
listed right below beats one that doesn't), and failing that in **one Spotify
track search**, whose hit must be the same recording by the same artist. An
album named after the song itself is passed over — a single tells you nothing —
and when something is found, **the album's name replaces the caption**. A miss
leaves it as it was. The lookup runs alongside the YouTube match rather than
behind it: neither answer needs the other, and the row is usable the moment
either lands.

A pinned **Top 10** row with a **Search Top 10** button sits beneath it —
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
art** beside it, and the artist's portrait, name, **Learn More** bio button,
a **Save for Later** button and an **Add as Source** button heading the page
(each **glyph over its label** in a rounded tile, which is what fits three of
them across a phone on one line — as wide capsules they didn't). The last two
are a pair: **Add as
Source** files the
artist into Browse as a discography-mode **Artist source** on the spot (it
reads "In Browse" once an equivalent source exists, so it never files a
duplicate), while **Save for Later** just bookmarks them on the list behind
the browser's own bookmark button (see
[Saved for Later](#saved-for-later)) — keeping an artist without following
them. That one is a **switch**, and one that knows what it's looking at: the
tile comes up **already filled** (the accent as a solid background rather than
a tint) for an artist saved anywhere else — off the map, off a Spotify search,
off this page on an earlier visit — and tapping it again takes them off the
list. Add as Source stays one-way, since un-following a source would throw
away everything it has surfaced. Expanding a release shows its cover full-size, a **Download
Album** button, and its track names; the release's **magnifier** matches
those against YouTube in place
(ISRC-first, duration-gated — the pasted-link machinery), with live progress
in the row; when the search settles, the **matched tracks light up with
Download and Preview beside them** (Preview is the standard Browse
listen-first modal, walking the rest of the release) and misses dim to "no
match" — no picker popup. A single-track pick goes in **unfiled**: it shows
in the Library's **All** tab (and the Inbox) rather than an album folder.
**Download Album** is the opposite case and files the whole record into a
folder of its own, cover art and all.

**Finding one song you can name** is the question an album-first catalogue is
the wrong shape for — answering it means twirling records open until you spot
it — so the toolbar's **magnifier**, beside the refresh, searches every song in
the discography at once. Each hit names its release and year; tapping one
closes the sheet, **opens that release, scrolls to the song and tints it** for a
couple of seconds so it's obvious which of twelve near-identical rows was
meant. The record's tracklist may never have been loaded — that's rather the
point — so the row opens, fetches, and only then reports back that there's
something to scroll to.

The tracklists behind it are read **one record at a time, with the same call
expanding a release makes**. The batch endpoint (`/albums?ids=`) is faster on
paper and answers **403 Forbidden** under a client-credentials app, exactly as
`/tracks?ids=` and the top-tracks endpoint do — a search that can't run is
worth nothing next to one that takes a few seconds. Nothing is re-read: the AI
layout carries its tracks inline and costs no requests at all, a release opened
earlier this session is already in the metadata cache, and re-opening the sheet
resumes where it left off. Results are searchable **as they land** rather than
after the last one, with the count showing above the list; a release that won't
load is noted at the bottom rather than sinking the whole search. Only ordinary
releases are indexed — the pinned Top 10 is a *view* of the catalogue rather
than part of it, and would list the same songs twice.

This is the same screen a discography-mode **Artist source** opens in Browse —
one album-first browser, wherever a catalogue shows.

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
its own genre labels. The findings accumulate in
`Documents/EveryNoiseUpdates/` and Settings shows the tally ("412 new artists
across 37 genres · 8 genres missing from the map").
**Download New Data** shares the file off the device, and
`tools/everynoise/merge_updates.py` folds it into the bundled dataset before a
rebuild — appending artists to their genre's shard, and minting a row *and* a
shard for a label that has enough artists behind it but no place on the map at
all, positioned at the centroid of the known genres those artists were found
under.

**They show up straight away.** A rebuild of the bundled dataset can be months
after the app noticed an artist, so a harvested name is drawn into its genre's
map and list the moment it's found — the genre you're looking at when the
harvest lands redraws with the new arrivals on it. They're shown as what they
are — **underlined**, on the map and in the list alike, since everything
around them came from the scrape and means something — and beyond the mark,
**positioned at random** (hashed into the spread their genre's own artists
occupy, so they land among the right company but at no meaningful point within
it) and **assumed unpopular** (drawn at the small end of the sizes the genre
already uses, and sorted *last* in the list's Popularity order, where they
order among themselves by Spotify's own score). Everything
else about them is real: tapping one opens the action bar, and its **+** leads
to the artist's live Spotify discography like any other. The hash is the same
one `merge_updates.py` uses, off the same seed, so an artist doesn't jump
across the map when the export is eventually merged. The global **Find
Artist** index is derived from the bundled shards at build time, so it still
only knows the artists the scrape had.

**A copy lands in a folder you choose.** The records are only useful on a
computer, and Settings ▸ Download New Data plus a share sheet was the only way
out. Settings ▸ Every Noise Data ▸ **Choose Data Folder…** picks anywhere the
Files app can reach, and `everynoise-updates.jsonl` is kept current there —
rewritten whenever a harvest adds to it, at launch, and on returning to the
app (a size check skips the write when the copy is already current), and
removed when the records are discarded. It's a copy: `Documents/` stays the
original, and a folder that's unreachable just means a stale copy until next
time. **Stop Writing to …** forgets the folder and leaves the file where it is.

This is deliberately **its own folder, not a sync folder**. The two have
nothing to do with each other — one mirrors music you want on this phone, the
other drops a text file somewhere a computer will see it — and tying them
together would mean changing where your music syncs also moved the records,
and that pointing at a records folder adopted everything in it into your
library. Separate bookmarks, chosen separately, changed separately.

Two limits are inherent and recorded in `meta.json` rather than papered over:
the site's layout came from Spotify's **audio-feature** API, withdrawn with
everything else, so new rows are hashed deterministically into the spread
their genre already occupies — among the right artists, not at a meaningful
point within them; and Spotify stopped serving `preview_url` to apps created
after November 2024, so a harvested artist has **no 30-second snippet** (their
discography still opens normally, and Scan skips them).

**How many artists a visit brings back is Spotify's call, not ours.** The
request asked for the documented maximum of 50 and got a **400 "Invalid
limit"** — the same thing a client-credentials app gets from
`/artists/{id}/albums`, on values the docs call valid. It now sends no `limit`
at all and takes the server's default page, which is the only size guaranteed
not to be refused. Fewer artists per genre than the ask; considerably more
than the nothing a rejected request returns.

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

## Album folders

A folder that *is* a record is a different thing from a folder that groups
songs, and the app already knew it in one direction only: an album pulled down
whole from a discography came back wearing the release's cover. **Convert to
Album** (touch and hold a folder) says it in the other direction — this folder
is a record — and everything an album gets follows from that.

**Its cover is square, and its songs wear it.** Tapping the sleeve on an
album's own screen offers **Change Album Art**: pick an image, frame it in a
square (drag to pan, pinch or slide to zoom), and Save crops it and writes it
in two places — on the folder, and onto **every song in it**, so the record
shows in the Player, on the lock screen and in the mini player, exactly as a
Spotify-sourced download does. That last part is the point of doing it here
rather than track by track, and it does replace whatever covers those songs
were wearing.

**Reset puts it back.** The hand-picked cover is written *beside* the
downloaded one (`<folder-id>-cover.jpg` next to `<folder-id>.jpg` in
`Documents/FolderArtwork/`) rather than over it, which is what leaves anything
to go back to: **Reset Album Art** drops the custom cover, and the album
returns to the art its download brought — restored on the songs too. An album
you made yourself has no such cover to return to, so it falls back to a flat
**colour** instead, and the copies the custom art left on its songs are taken
off (matched on content, so a song carrying different art keeps it). Reset is
only offered once there's something of yours to undo.

A colour is also what a **new** album shows: converting a folder assigns one
from a small palette straight away, so it reads as a record in the cover grid
before any image is picked. A real cover always supersedes it.

**The Discography button.** At the foot of an album's track list, a
**Discography** row opens that artist's live Spotify catalogue — the same
album-first browser the Every Noise map and a Browse Artist source push (see
[The Every Noise browser](#the-every-noise-browser)), so the rest of the
record collection is one tap from the record. All a library folder knows is
the artist's *name*, so Spotify's search resolves it, and the Settings ▸
Spotify credentials are needed exactly as they are everywhere else the
catalogue is read. The button appears only when the folder's tracks agree on
**one** artist — which is the same derivation that prints the artist under a
folder's name — because a compilation has no single catalogue to send anyone
to.

Album-ness is a flag on the folder (`isAlbum` in `folders.json`) rather than
something re-derived per redraw, so the Folders tab's cover view can group by
it cheaply. Folders saved before the flag existed read back as albums if they
carry a downloaded release cover, which is exactly what they were.

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
| `Models.swift` | `Track`, `Folder`, `DownloadMode`, `LibraryFilter`, `FolderSort`, `FolderViewMode`, paths, helpers. |
| `LibraryStore.swift` | Persists the library to `Documents/library.json` and folders to `Documents/folders.json`; owns the local moves across the sync boundary (queueing replica ops), the importer's reconcile primitives, and the mixtape/album conversions — including the album cover write that lands on the folder *and* every song in it, and the reset that puts the downloaded one (or a colour) back. |
| `LocalSync.swift` | `LocalSyncStore` — the sync folder's security-scoped bookmark, the stamped manifest + journaled exporter, the coordinated importer (placeholder-aware copies), kqueue monitoring, and the off-main tree scan. |
| `DownloadManager.swift` | Download queue (two concurrent slots) + `DownloadJob` + persisted history; `enqueueAlbum`, which files a whole release into one folder in tracklist order with the catalogue's own titles/artists; `ArtworkFetcher`, the best-effort album-art fetch a finished download (or an album folder) triggers; and `VideoQualityChooser`, which puts the source's real rendition list to the user mid-extraction (once per video, hand-queued downloads only). |
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
| `Subtitles.swift` | English subtitles: the cue model and the VTT/SRT/timedtext parser (including the unrolling auto-captions need), the memoized on-disk loader, the appearance keys Settings and the Player share, and `SubtitleFetcher` — the watch-page capture with the yt-dlp metadata fallback. |
| `PlaylistResolver.swift` | Detects playlist links and flat-resolves their entries (on-device yt-dlp) so a playlist downloads into a folder. |
| `ChapterSplitter.swift` | Exports one file per chapter (AVFoundation) for "Break Chapters into Playlist". |
| `VideoMerger.swift` | Muxes a video-only + audio-only stream into one MP4. |
| `PlaybackManager.swift` | `AVPlayer` engine (audio + video), audio session (including interruption/route-change handling), the lock screen (its own and any **borrowed** by a `RemoteAudioSource` — see [Lending the lock screen out](#lending-the-lock-screen-out)), and the frozen-playhead watchdog that keeps autoplay advancing; exposes the queue's next/previous entries for the Player's neighbour labels. |
| `Logger.swift` | `LogStore` — thread-safe, app-wide log sink. |
| `AISettings.swift` | `AISettingsStore` (model/key/assist, Keychain-backed), `AIModel`, `Keychain` helper. |
| `AnthropicClient.swift` | Minimal Anthropic Messages API client (verify + single-shot completion) over URLSession. |
| `SpotifyRef.swift` | Parses `spotify:` URIs / `open.spotify.com` links into a (kind, id) pair; resolves `spotify.link` short links by redirect. |
| `SpotifyClient.swift` | Spotify Web API client: Client Credentials token (cached, 401-refreshing) + the track/album/playlist/artist metadata reads, paginated and **batched** (`/albums?ids=`, cross-album `/tracks?ids=`), plus `searchArtists(genre:)` — the one request the Every Noise dataset harvest makes — and `searchArtists(named:)` behind that browser's Spotify Find mode. Also `SpotifyRateLimiter` (the persisted, per-client-id `Retry-After` window), `SpotifyMetadataCache` (the ten-minute catalogue cache), and the popularity-ranked `derivedTopTracks`. |
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
| `DiscographyBrowserView.swift` | The shared album-first discography browser — artist header (portrait, name, Learn More bio), the Artist Sample Track row atop the Top 10, cover thumbnails/full art, names first, per-release YouTube search, **Download Album**, pinned Top 10, and the whole-catalogue song search that scrolls to and highlights its hit — plus its two catalogue providers (Spotify live / AI layout), the Wikipedia lookup + AI bio sheet, and the Browse-source wrapper that caches the first pass. |
| `BrowseView.swift` | The Browse tab: the Every Noise browser as the tab's own screen, plus the **Sources** screen behind the corner button — sources grouped by type, add-source sheet, refresh. |
| `EveryNoiseData.swift` | The bundled Every Noise dataset: models, the lazy/LRU shard-loading store, the memory-mapped global artist search (`ENArtistIndex`), and the 30-second preview player. |
| `EveryNoiseUpdates.swift` | `ENUpdateStore` — the opt-in, heavily throttled Spotify harvest that records what the frozen dataset is missing as you browse; the exportable JSONL it writes for `tools/everynoise/merge_updates.py`; `merged(_:genre:)`, which draws the findings onto the genre's map straight away; and `ENDataFolder`, the separately bookmarked folder a copy of the records is kept in. |
| `NoiseMapView.swift` | The virtualized `UIScrollView` scatter map (spatial grid + recycled labels) both noise maps render through — opens centered on its canvas, with the draggable scroll-pill ring on the right edge. |
| `SavedForLater.swift` | The Saved for Later list: the saved genre/artist model, the app-level `SavedForLaterStore` (`saved-for-later.json`), and the sheet behind the Browse tab's bookmark button. |
| `EveryNoiseView.swift` | The Every Noise browser: Map/List/Scan/History modes + Find at both levels (with the root's genre/artist/Spotify toggle), the scan transport and its "+", the artist bar whose "+" opens the live discography (or creates Artist sources when Spotify isn't set up), and the measured bottom-bar clearance the maps and lists inset by. |
| `EveryNoiseData/` | Bundled (folder reference): `genres.json` index + per-genre artist shards from the one-time `tools/everynoise/scrape.py`, plus the derived `artists.idx.z` from `build_artist_index.py`. |
| `BrowseSourceView.swift` | One source's items with per-row Download/Preview/Discard, plus a **Select** mode for bulk download; also `BrowseTrackStatusButton`, the green play button every browse list shows once a download is in the library. |
| `BrowsePreviewView.swift` | The preview modal: pipeline download, mini player with prev/play-pause/next over the queue it was opened with (auto-advancing at the end of each track — off its own frozen-playhead watchdog, not just the end notification — phone locked or not), the lock-screen metadata it borrows while it plays, Save/Discard. |
| `*View.swift` | The five SwiftUI screens, in tab order (Browse, Library, Player, Download, Settings — which embeds the Log); none of them sets a navigation title. `LibraryView.swift` also holds `LibraryTab`, the Recent/Folders/Inbox/Watch/All strip, and the Folders tab's two shapes (the list, and the cover view's album grid). `PlayerView.swift` also holds the tap-to-seek scrubber, the caption overlay (and its own 5 Hz playhead clock) and the `MiniPlayerBar` the other tabs inset above the tab bar. |
| `FolderView.swift` | Folder detail (tap-to-play, reorder, subfolders, mixtape header/Edit Cover, the album sleeve that opens its art options and the Discography row beneath its tracks), the discography push a library album makes, plus the Library's Inbox and Recent tabs. |
| `MixtapeViews.swift` | Mixtape banner rendering (non-destructive crop), the shared folder-row label, and the Edit Cover sheet (PhotosPicker + drag/pinch + font picker). |
| `AlbumViews.swift` | The album side of a folder: the stand-in colour palette, the square sleeve (cover or colour) the folder screen and the cover grid draw, the grid's own cell, and the Album Art sheet — PhotosPicker, square framing, and the crop that turns the framing into the JPEG copied onto every song. |
| `WatchFolderView.swift` | The phone's Library **Watch** tab (manage what's been sent to the watch). |
| `WatchManifest.swift` | Wire format shared by the iPhone and watch targets (the sync manifest, the remote-control `RemoteNowPlaying`/`RemoteCommand` types, + WC keys). |
| `WatchSync.swift` | Phone-side WatchConnectivity bridge: pushes the manifest + audio files, handles the watch's "Clear all". |
| `WidgetShared.swift` | Wire format shared by the app and the widget targets (the genre/artist/song rows the widget draws, their App Group storage, and the `offlinelisten://` deep links each row opens) — the same trick `WatchManifest.swift` uses for the watch. |
| `WidgetBridge.swift` | The app's half: republishes the snapshot from the Recent log and the Every Noise visit log (genres and artists as separate deduplicated lists), reloads the widget's timeline when it actually changed, and `AppRouter`, which parks a tapped row until the screen that can act on it is up. |

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
library — it only flags it for the watch. The Library's **Watch** tab is where
it lands: a *virtual* folder (its tracks really live wherever they
normally do) for managing what's on the watch. There it's deliberately spare —
tap to play, and a single swipe-left action, **Remove from Watch** (no
song/podcast swipe). Touch-and-hold a track already on the watch and the menu
shows **Remove from Watch** instead.

The phone is the **source of truth**, and the link runs both ways: tapping
**Clear all Tracks** on the watch empties the phone's **Watch** tab to match,
and removing a track from the Watch tab deletes it from the watch on the next
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

## Home screen widget

A widget puts the two threads you were in the middle of on the home screen:
what you last opened in the **Every Noise browser** beside what you last
**played**. Rows link to the thing itself — a genre opens **that genre's artist
map**, an artist opens **their page**, a song **starts playing** — rather than
to the app's front door. (At the sizes iOS allows more than one tap target;
see [Every size](#every-size-and-where-the-small-ones-tap-goes) below.)

Touch and hold it → **Edit Widget** for its one option, **Browse**:

- **Genres** (the default) — the genres you last opened.
- **Artists** — the artists you last tapped, on the map or through the Find
  field's Spotify search. Each row names the genre you found them in.
- **Genres & Artists** — both, **interleaved by recency**: the browse history
  as it happened, with each row's glyph saying which kind it is (the same
  `guitars` / `music.mic` / over-the-air glyphs the browser's own History uses).

The two kinds are kept as **separate lists** in the snapshot rather than being
filtered out of one merged list, which is what stops **Artists** coming up
empty after a run of genre visits. Both lists are deduplicated, because
Browse's History and the Library's Recent are *logs*: they collapse only
consecutive repeats, so the top entries can otherwise be the same genre — or
the same song — twice over.

### Every size, and where the small one's tap goes

Every size shows **both** lists — a browse row and a song row at the least.
What changes is how deep they go, and how many tap targets WidgetKit will give
them:

| Size | Layout | Taps |
|------|--------|------|
| **Small** | stacked, one row each | one |
| **Medium** | two columns, two rows each | per row |
| **Large** | two stacked sections, three rows each | per row |
| **Extra Large** (iPad) | two columns, four rows each | per row |
| **Rectangular** (lock screen) | stacked, one row each | one |

A **small** widget — and any lock-screen one — has exactly **one** tap target:
`Link` views inside it are **ignored** and only `widgetURL` is read. That's
WidgetKit's rule, not a choice, and it doesn't stop those sizes showing both
rows, since seeing what you were doing is most of what a small square is for.

The tap goes to the **song**. Picking by recency instead would mean the same
button doing different things on different days, which is the last thing a
home-screen button should do; playing is also the action this app exists for,
while the browse row is there to be read. Rather than leave that to be
discovered, the row that *is* the destination wears a **play glyph** — and with
nothing played yet, the browse row takes the tap and the glyph moves off it.

### How it gets its data

A widget extension is its own process with its own container. It can't read
`Documents/`, so `everynoise-history.json` and `recents.json` are out of
reach — and decoding a 200-entry log plus the whole library to draw a handful
of rows is not work a widget has the budget for anyway. So the app leaves a
small **pre-resolved snapshot** (`widget-snapshot.json`) in the **App Group**
container, and the widget only ever reads that. Four of each list are stored:
enough for the largest size, and enough for **Genres & Artists** to merge two
lists down to four.

The halves are written independently, because they come from separate stores:
songs from `LibraryStore`'s `saveRecents()`, genres and artists from
`EveryNoiseStore`'s `saveHistory()` — the single funnel each log's mutations
already pass through. Each writer re-reads the snapshot, replaces its own half
and writes it back, so neither can clobber the other's rows. The browse half is
also refreshed **from disk at launch**, since the browser's visit log isn't
loaded at all until the Browse tab is opened.

Each row carries the **date** it happened, used only for ordering — that's what
lets the single-item sizes pick a winner across two lists and **Genres &
Artists** interleave. Nothing shows a timestamp, so no clock has to be kept
current: a write that changes nothing is dropped (those save paths fire far
more often than the top rows change, and WidgetKit meters reloads), and when
something *does* change the app reloads this widget's timeline explicitly. The
widget's own timeline policy is therefore `.never` — it spends no wake-ups
re-reading a file that can't have changed on its own.

Taps come back on the URL scheme the Share Extension already uses —
`offlinelisten://genre?key=…`, `offlinelisten://artist?genre=…&id=…` (or
`?spotify=…&name=…` for one off the map), `offlinelisten://track?id=…`.
`WidgetDeepLink` builds and parses them, compiled into both targets so the two
sides can't drift; anything it doesn't recognise — `offlinelisten://import` —
still falls through to the shared-inbox drain. Neither destination is reachable
synchronously from `onOpenURL`, so `AppRouter` parks the link: `RootView` picks
the tab and starts the track, and the Every Noise browser opens the browse
target once its index has finished loading off disk — which on a cold launch
from a widget tap is *after* the link arrives. A track that has since been
deleted, or a genre key a rebuilt dataset no longer carries, logs a warning
under `Widget` and does nothing.

### Required Xcode setup for the widget

The project wires up the **OfflineListenWidget** target, embeds it in the app
and declares the entitlement, but — exactly as with the Share Extension —
**signing and the App Group must be set in Xcode**:

1. Select the **OfflineListenWidget** target → *Signing & Capabilities* → set
   your **Team**.
2. Confirm it has the **App Groups** capability with the same
   `group.com.offlinelisten.app` the app and the Share Extension use. Without
   it the widget draws its empty state — it has nothing to read.
3. The bundle id defaults to `com.offlinelisten.app.OfflineListenWidget` (a
   child of the app id); change it to match if you changed the app's.

The widget target deploys to **iOS 17**, while the app stays on 16. That's what
the options pane costs: a configurable widget needs a configuration intent, and
the App Intents one (`AppIntentConfiguration`) is iOS 17+. The alternative for
iOS 16 is a SiriKit `.intentdefinition` file, which only exists as Xcode
codegen — not something this project, authored without an Xcode toolchain, can
carry honestly. An iOS 16 phone runs the app exactly as before and simply isn't
offered the widget.

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
   Xcode register/provision it). The **widget** target uses the same group —
   see [Required Xcode setup for the widget](#required-xcode-setup-for-the-widget).
   If you change the group id, update it in all three entitlements files and in
   `SharedInbox.appGroup`.
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

### Why autoplay keeps going

Advancing to the next track sounds like one line — listen for
`AVPlayerItemDidPlayToEndTime`, load the next one — and that line is not
enough. Three separate things used to strand the queue, most visibly with the
phone locked, where nothing on screen said why the music had stopped:

- **The item swap left a gap of silence.** Loading a track dropped the current
  item (`replaceCurrentItem(with: nil)`) before installing the new one. An app
  playing audio in the background stays alive *because* it is playing audio;
  that instant with nothing to play is exactly when iOS is entitled to suspend
  it, and a suspended app doesn't start the next track. The new item is now
  swapped straight in, so the player is never empty.
- **Nothing was listening for interruptions.** A call, Siri, an alarm or
  headphones being unplugged pauses the player without any end-of-item
  notification. The app went on believing it was playing — the lock screen
  agreed — while the track it was on never finished, so the queue never moved
  again. `AVAudioSession`'s **interruption** and **route-change**
  notifications are now handled: the app follows the system into paused, and
  resumes when the interruption ends and says it should.
- **The end notification doesn't always come.** Some downloaded audio
  over-reports its length — AVFoundation reads certain HE-AAC/SBR streams as
  roughly *twice* their real duration, the same quirk the scrubber already
  refuses to trust — so the samples run out at a timestamp AVFoundation
  doesn't consider the end, and the notification never fires at all. A
  **watchdog** on the existing half-second ticker now catches it: a player
  that has stopped while the app still thinks it's playing has either ended
  or been interrupted, and the playhead says which. At the end (judged
  against *both* clocks — the item's own duration and the one recorded at
  download time, whichever the audio actually ran out on) the queue advances;
  mid-track it's an interruption, so the state is corrected and the track is
  left alone. Two consecutive ticks are required, so a seek or a momentary
  stall can't be mistaken for a stop.

Two smaller things fell out of the same pass: `AVPlayerItemFailedToPlayToEnd`
now advances the queue too (a file that gives up three seconds from the end
shouldn't be the last thing you hear), and the ticker runs in the run loop's
`.common` modes so scrolling a list doesn't stop the watchdog's clock. Every
advance logs its reason at debug level under the `Player` category, so a
queue that stops can be diagnosed from the Log rather than guessed at.

A later pass closed the case that was left: the queue advanced with the phone
locked, and then **stopped a second later**, which from outside is
indistinguishable from never having advanced at all. Four things came out of it,
and the first is the actual culprit:

- **The watchdog was mistaking a *loading* item for a stopped one.** A freshly
  swapped-in `AVPlayerItem` reports `.paused` until its asset is ready, and in
  the background — cold file, throttled CPU — that can outlast the two ticks
  the watchdog waits. It then read the *new* track's playhead, found it nowhere
  near the end, concluded "stopped mid-track", and marked playback paused one
  second after autoplay had just started it. Unlocked, the swap was quick
  enough that the window never opened. The watchdog now stands down until
  `currentItem.status == .readyToPlay` — an item that hasn't finished loading
  is not a stopped one.
- **The gap is held open on purpose.** An app with the `audio` background mode
  is alive *because* it is playing; the swap between two items is a moment of
  silence in which iOS is entitled to suspend it. Both the library player's
  track change and (much longer — seconds, not milliseconds) the preview
  modal's download of its next track now run under a `BackgroundActivity`
  assertion, which is what buys the time to get the next sound started.
- **The player's rate is watched directly**, so the end of a track is noticed
  the instant it happens rather than up to a second later on the ticker. KVO
  fires whatever mode the run loop is in, and a second of silence saved is a
  second less in which a locked phone can suspend the app.
- **An item that never loads at all** posts *neither* end-of-play notification —
  it simply sits at rate 0 — so a single unreadable file used to end the queue
  in silence. Its `status` is now watched too, and a failure advances like any
  other ending.

With three independent routes to "this track is over", they can and do arrive
together, so the advance is claimed once per track and the duplicates are
dropped — otherwise the second report would skip the song the first one had
just started.

A third pass found why the queue could still stop dead between two tracks, and
the file that does it turned out to be measurable: `"City of New Orleans" runs
to 306s, not the 153s recorded at download`. **Exactly double** — the HE-AAC/SBR
over-read, caught in the act.

What that file does is not what any of the three routes was watching for. The
samples run out at the true end, 153 seconds in, but the item still believes
there is half a track to come, so it doesn't stop, doesn't stall, doesn't report
`.paused` and doesn't post its end notification. **It runs its clock on through
silence that isn't there**, all the way to the length it thinks the file is.
Every check the app had looks for something that has *halted*, and nothing here
has. So the queue sat out the phantom remainder — on a doubled file, the length
of the song over again — which from outside is a player that reached the end of
a track and never moved on.

**The duration recorded at download wins that argument**, and it's worth being
precise about why: it comes from the source's own metadata, while the other
figure is AVFoundation's reading of a container it is known to misread. (When a
duration *is* read off the file — a local-sync import — the two are literally
the same number, so there's no disagreement to have.) A playhead past the
recorded end, on a file claiming far more than that, is the audio being over
whatever the container says is left, and the track ends there. The gap has to be
large before the recorded figure is allowed to end a track early — a quarter as
long again, and at least ten seconds — so ordinary slop between a container and
its metadata never clips anything. An over-read is around double; nothing else
comes close.

The scrubber follows the same rule, and for one revision it didn't: letting the
display switch to the file's clock mid-play is what sent the bar jumping back to
the halfway mark at the end of a track and doubled the time printed beside it.
The recorded figure is what's shown, so the bar fills exactly as the music runs
out; the file's own figure is read only when there is no recorded one, or when
the file is the *shorter* of the two — the direction that isn't the over-read.

That leaves the case where playback genuinely does halt, and there the ground
truth is the **playhead**, not the rate: a clock that has stopped while the app
still believes it is playing means playback has stopped, whatever
`timeControlStatus` claims. So the watchdog watches the playhead too, and reads
a frozen one three ways — at the end by either clock, the track is over after a
second; short of that, an item whose buffer has drained with nothing left to
fill it (a local file has nothing to stream, so that means the samples ran out)
is called after three; and anything still frozen after six seconds is called
regardless, because no local file recovers from that and a stopped queue is the
worse outcome. Two smaller holes closed with it: an item that never becomes
playable and never reports failing either — it just sits at `.unknown` — used
to switch the watchdog off for the rest of the session, so that wait is now
bounded; and every counter is cleared on any change the app makes itself (a
load, a seek, a pause, a resume), so a reading from before the change can't be
compared with one from after. The reason for each advance goes to the Log under
`Player`, and names which route noticed.

### Lending the lock screen out

There is one `MPNowPlayingInfoCenter` and one `MPRemoteCommandCenter` for the
whole app, and iOS arbitrates neither: whoever writes last wins, and the ticker
above rewrites both twice a second on the library player's behalf. So a second
player — the Browse **preview modal**, which is a real listen, often a whole
album's worth — was invisible from outside the app. Its title and artist were
overwritten as fast as they could have been set, and the lock screen's
next-track button walked the library queue you *couldn't* hear rather than the
record you were auditioning.

A preview now **borrows** both. `PlaybackManager` takes a `RemoteAudioSource`
(`beginRemoteAudio` / `endRemoteAudio`); while one is installed it publishes
that source's now-playing instead of its own — title and artist split out of
the item's "Artist — Song" line, the release's cover art, duration and
playhead — and every control that isn't the in-app Player screen routes to it:
the lock screen, Control Center, the headphones, and the watch. The library
player is paused behind it and gets the lock screen back, with its own track on
it, the moment the modal closes or its Save hands playback over.

It keeps the lock screen through the **silent gap** between two previews as
well, so the next track's name is up while it is still downloading rather than
the paused library track flickering back in.

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
  `android_vr`, `ios`, `android`, `web_safari`, `mweb`, `web`) one at a time,
  whose H.264 URLs
  need no descrambling — the same renditions Safari plays — and takes the first
  that yields a decodable stream. The order matters for quality: it accepts the
  first client that works, so the no-token, **higher-resolution** source (`tv`,
  up to 1080p H.264) leads — it's also the most reliable on device under
  YouTube's 2024–25 SABR / PO-token tightening, whereas `ios` is increasingly
  gated or slow — and `android`, whose formats SABR frequently caps low (360p),
  follows; the web-family clients come last because on device they usually fail
  the n-challenge (no JS runtime). **`android_vr` sits second and earns it**:
  it's the client modern yt-dlp reaches for by default on a runtime with no JS
  (no nsig, no PO token), and on device it returns the whole H.264 ladder —
  144p through 720p, every rung carrying a real URL — where `tv` can fail on
  DRM or a stale player and `android` arrives SABR-stripped to a single 360p
  muxed stream. Its absence is what made a film whose 720p H.264 was there all
  along save at 360p. When the
  recovered H.264 is much lower than what was offered, the log says so — a 360p
  save from a 2160p AV1-only source reads as a codec ceiling, not a bug. Only if
  every client still yields nothing decodable does the download fail with a clear
  `unplayableVideoCodec` message.

  A video download also captures the source's **English subtitles**, when it
  has any — see below.

### Choosing a resolution

A video download **asks which resolution to take**, and it asks at the only
moment the question can be answered honestly: **after the extraction has run**,
with the list the source actually turned out to offer. A standing
Best/1080p/720p preference — which is what the preview modal has — is the wrong
shape for a download. It can only name tiers the app guessed at, while
YouTube's real answer varies per video and per session: a 4K upload with H.264
no higher than 720p, a video whose taller renditions are AV1-only and therefore
undecodable here, a 360p-and-nothing-else rescue through the forced-client
recovery. So the picker lists **streams that are really there** — height,
codec, the size where the source declared one, and whether the stream carries
sound or will be **downloaded alongside the best audio track and muxed into one
file** (`VideoMerger`), which is exactly how the higher resolutions are
possible at all. Only renditions this device can decode are listed; the codec
ceiling described above still applies, so a video offering 2160p in AV1 only
genuinely has 720p as its best.

**Getting a list worth showing.** The yt-dlp wrapper's `extractInfo` hands back
only the formats *its own* `bestvideo,bestaudio` selector settled on — usually
two — not the ladder underneath them. That's invisible most of the time, but it
means the question "what does this source offer?" can't be answered from the
default extraction: a video with 144p→720p H.264 available comes back as a
single rendition, and a picker with one row is no picker. So when a download
asked to choose and the default answer is that thin, the app **reads the
client's whole format list** the way the codec recovery does. It's a second
resolve, paid only on a download that asked, and only when the first answer
couldn't be chosen from. A source that genuinely offers one device-playable
rendition doesn't prompt at all — it says so in the Log ("Only one
device-playable quality here (360p)") and gets on with it.

**It asks once, and only where asking is welcome.** One download resolves more
than once — the default extraction, then the forced-client recovery, then any
mid-download URL refresh — so the answer is memoized against the URL for ten
minutes; that also means a **Restart** straight after a failure doesn't
re-ask. And the question is raised only for a download you queued *by hand*: a
single pasted link, a hit picked from the Download tab's search, a restart.
Everything queued as a **batch** — playlist children, album tracks, Browse's
bulk download, a format conversion — runs unattended on the **last resolution
you chose** (best available until you've chosen one), because forty prompts is
not a feature.

The sheet is presented from the app's root rather than the Download tab, since
the download that asks may have been started from Browse. Dismissing it takes
the best available — a picker you can ignore is better than a download that
stalls — and a prompt nobody answers falls back to that standing preference
after two minutes, so a phone in a pocket can't hold a pipeline slot.

**One question at a time.** Both pipeline slots can be resolving hand-queued
videos at once, and a second prompt used to overwrite the first's resume
handler: the download waiting on *that* answer was never resumed, so it held
its slot for the rest of the session (two of them wedged the queue outright)
and the runtime reported the abandoned continuation as a misuse. A download
that comes up while someone is already being asked now takes the standing
preference, and says so in the Log.

## Subtitles

Every **video** download tries to bring its **English captions** with it. The
capture runs after the file has landed, best-effort and off the queue, exactly
as the album-art fetch does: a video with no captions is the ordinary case, so
a miss is logged at debug level and costs the download nothing. Audio downloads
skip it — there's no picture to draw captions over.

Two routes, in order:

- **The YouTube page.** YouTube publishes its caption tracks in the watch
  page's player response (`captionTracks`), which is a plain HTTPS read that
  needs nothing installed — the fast path, and the one that covers nearly every
  download. A **human-written** track is taken over the machine transcript
  (`kind: "asr"`) whenever there is one.
- **yt-dlp's metadata**, for anything else — and for a YouTube page that won't
  give them up. Same rules `ChapterFetcher` lives by: it runs only when the
  yt-dlp Python module is **already present**, so capturing subtitles never
  triggers the tens-of-MB module download on its own, and everything touching
  the interpreter goes through the app-wide `PythonGate`. On the Mac the real
  yt-dlp binary answers the same question.

Whatever comes back — WebVTT, SRT, or YouTube's own timedtext XML — is parsed
into plain cues and written as a standard **`.vtt`** in
`Documents/Subtitles/<track-id>.vtt`, recorded on the track
(`subtitleFileName`). It's app-local display metadata like artwork: never
synced or exported, and deleted with the track.

**Auto-generated captions need unrolling.** YouTube writes them as *rolling*
text: each cue repeats the line already on screen and adds a few words, with a
hair-thin cue in between carrying the finished line. Read literally, every line
shows twice. So the parser drops cues shorter than a tenth of a second, strips
a cue's opening line when it's the one already showing, and drops exact
repeats — along with WebVTT's inline markup (`<c>`, per-word timestamps), which
is what makes each of those cues look different in the first place.

**Drawing them.** The cue is rendered by the app rather than by AVFoundation (a
sidecar file isn't part of the asset), which is also what makes it styleable.
The overlay prefers its **own** periodic observer on the player at 5 Hz to the
app's 2 Hz progress ticker: half a second is nothing for a scrubber and plainly
late for a subtitle. Looking a cue up is a binary search over an array already
in memory, and the observer only exists while a captioned video is on screen.
It is not allowed to be a single point of failure, though: **until that
observer has actually delivered a tick, the playhead comes from the app's own
ticker** — the one the scrubber visibly runs on. A caption that can only appear
if a second clock starts is a caption that silently doesn't appear. Settings ▸
**Subtitles** sets the size, colour and backdrop; the Player's **CC button**
and the Settings toggle are the same switch.

**Getting them for a video you already have.** Touch and hold any video track
for **Get Subtitles** (**Refresh Subtitles** once it has some): the same
capture, on demand. It's the way back for everything downloaded before captions
existed, for a video whose captions were published after you saved it, and for
a capture that came back empty because the source was being difficult. Tracks
with no source link (local-sync imports) don't offer it.

**When nothing appears.** Captions that don't show look identical whether
nothing was captured, the cues sit at the wrong times, the playhead never
moved, or the film simply isn't saying anything just there — so the app
distinguishes them rather than leaving it to guesswork. Tapping **CC** flashes
**"Subtitles on · N lines"** (or "Subtitles off") over the picture, so the
switch is never silent. And the Log's `Subtitles` category records the whole
chain at debug level: which route answered the capture and with how many cues,
how many cues the file parsed to when the player loaded it (a warning if that's
zero, or if the file a track points at has gone missing), what the first and
last cue times are, and the moment the caption clock starts ticking.

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
The **home screen widget** is hand-wired the same way, against the documented
**WidgetKit** / **App Intents** APIs; it needs the **Team** and the shared
**App Group** set in Xcode before it can read anything, and it deploys to iOS
17 while the app stays on 16 — see
[Required Xcode setup for the widget](#required-xcode-setup-for-the-widget).
