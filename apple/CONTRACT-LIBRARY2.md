# cobalt for apple: titles, mosaic and table library (owner request, 2026-10-05)

Owner (verbatim): "When uploading files i want to be able to set the title and not just 'upload' and
also the library should have a mosaic kind of gallery and data table list so this is an update of the
ux ui please". Also new today (owner): videos are public by default and have server thumbnails (a
server lane is adding server-made posters, `poster_url`, and a `public: true` save flag; migration
`0006`).

Additive to `CONTRACT.md`, `CONTRACT-MEDIA.md` (one media, many renditions), `CONTRACT-ORBIT.md`,
`CONTRACT-SYNC.md`, `CONTRACT-LIVE.md` and `deploy/cloudflare/APP-API-CONTRACT.md`. Code read on
2026-10-05 against the `apple-app` worktree, uncommitted state included (other lanes had
`PhotoImport.swift`, `Copy+Media.swift`, `FocusView.swift`, `RenditionHero.swift`, `Pipeline*.swift`,
`AppModel.swift`, `Store/*`, `Photos/*`, `Media/Intake.swift` and `deploy/cloudflare/api/helper/lib.js`
dirty at the time). **One D1 migration (`0007_titles.sql`), one additive keyed method on an existing
route, one additive response field, one capability flag.** Marked **(owner)** where the owner asked,
**(lane)** for calls made here and open to review. Design source: the `Library2-*.dc.html` boards
(section 11).

## 0. What exists today (read, not assumed)

- **Uploads are called "upload".** An adopted upload's session has `service = 'upload'`
  (`deploy/cloudflare/api/src/studio.ts:906`), so `GET /library` sends `"service": "upload"` for
  every uploaded file. The app titles a media `service · ref` whenever `service` is set: the library
  card (`LibraryScreen.swift:118-124` `cardTitle`), the detail header (`MediaDetail.swift:83-89`), the
  orbit caption (`HomeScreen.swift:928`, only when `ref` is also set; else the local file name) and
  VoiceOver (`HomeScreen.swift:898`, `LibraryScreen.swift:179`). An upload has no `ref`, so the library
  and the detail say **"upload"**; the orbit says the raw file name with its extension
  (`IMG_0412.mov`). Photos imports were named by the picker (a UUID); an in-flight lane renames the
  inbox copy to `from photos · 4 oct.<ext>` (`PhotoImport.swift` diff, `Copy.Media.fromPhotos`) and
  adds `Copy.Media.displayTitle(name)` (strip the extension) for the focus title only
  (`FocusView.swift:228-232`).
- **Where a title lives on the server today.** Nowhere editable. `GET /library` sends
  `title = <the post's original row's media_items.name>` (`app-routes.ts:477-486`), i.e. the cleaned
  upload file name (`cleanName`, `app-routes.ts:221-227`, max 120 chars) or cobalt's file name for a
  link save (`instagram_Dd7P496wolG`). `studio_sessions.title` is cobalt's file name
  (`0003_studio.sql`). Nothing can change either; `name` is also the download file name and the web
  library's tile label (`web/src/library/page.html:812-844`).
- **Other places that name a run**: `Pipeline.notifyLabel` (`NotifyBridge.swift:228-232`: media name
  without extension, else the link's ref) feeds the Hark opt-in `label` (≤ 60 chars,
  `APP-API-CONTRACT.md` 9.2) and the continued-processing subtitle (`ContinuedProcessing.swift:110`);
  `LiveSink` sets `LiveContentState.title` from the media name (`LiveSink.swift:86-87`), which no
  widget view draws yet (`LiveLockScreen.swift:134` shows the step headline).
- **Every file entry point funnels through `AppModel.importFile(_:)`** (`AppShell.swift:23-27`): the
  file circle's importer and window drop (`AppShell.swift:76-83`), Photos (`PhotoImport.swift`
  `finish` → `importFile(inbox)`). The share extension calls `pipeline.start(file:)` itself
  (`ShareModel.swift:106`) after restoring the other app's file name (`ShareModel.swift:348-349`).
  **There is no "paste a file" entry point**: paste reads text only (`AppShell.swift:16-20`).
- **Library UI** (`Screens/Library/*`, 685 lines): one card per media with rendition chips
  (`CONTRACT-MEDIA` 1.13); compact = inset-grouped `List` pushing `MediaDetail`; regular/wide = list
  column + detail column (`NavigationSplitView`, Mac `HSplitView`). Posters: device poster, else the
  first frame of the public webp / hosted mp4 decoded on device (`RemoteStill.swift`, 64-entry memory
  cache, a failed load stays blank). No search, sort, filter, multi-select or animation.
- **Library model** (`LibraryModel.swift`): pages of 20 by latest activity (`GET /library`), cursor,
  `refresh`/`loadMore`, `expandedPostID` (used by "open in library"), per-file save/host/delete.
  `AppModel+Media.swift` already has `saveToPhotos(_:)`, `deleteEverything(_:)` and `isBusy(_:)`.

## 1. Decisions

### Titles

1. **(owner) Every media has a title, shown everywhere, resolved in one place.** Pinned resolver
   `MediaTitle.resolve` (section 4.1), in this order:
   1. the **custom title** (server `custom_title`, or this device's pending/offline copy);
   2. a **link save**: `service · ref` (`instagram · Dd7P496wolG`, today's two-tone rendering);
   3. a **file** (upload, Photos, share-sheet file, picker item): the file name without its media
      extension (`IMG_0412`, `crop-gestures`, `from photos · 4 oct`); `service == "upload"` counts as
      no service, which is the "upload" bug;
   4. `cobalt`.
   The custom title always wins, for uploads and link saves alike.
2. **(lane) Defaults are the file names; no title is sent with the upload.** Files: the name the
   file had (`IMG_0412.mov` → `IMG_0412`). Photos: the in-flight lane's inbox name
   (`from photos · 4 oct`, the capture date from the file's own metadata, else the import date;
   the year only when not this year). Share sheet: the other app's name (already restored). The
   upload starts the instant the file is picked, before anything is typed, so a `title` query
   parameter on `PUT /studio/upload` would only ever carry the default the server already has
   (`name`); it is **not** added. The owner's title goes through the rename route once the upload
   has an item id (decision 4).
3. **(owner) A title field right after picking, never blocking.** After any file intake on a fork
   whose server has `features.titles` (Files importer, Photos, window drop, the share sheet), the
   upload starts **first**; then the **title sheet** rises over the save tab (iPhone/iPad:
   `.sheet` with `.presentationDetents([.height(248)])`, background interaction enabled, keyboard up;
   Mac: the same view in a sheet, 420 pt wide). Content: the heading `name it`, a single-line
   `TextField` prefilled with the default and **fully selected** (typing replaces it, the clear
   button empties it), a live line under it with the upload's own progress
   (`uploading · 1.2 of 18.2 MB`, then `reading the video`, the same `ProgressStory` detail the card
   shows), `done` (`.glassProminent`, the screen's one prominent button) and `skip` (plain). Return
   = done. Swipe down = skip. `skip` keeps the default (nothing is sent). An unchanged prefilled
   value counts as skip. The run never waits for the sheet; if the run fails while the sheet is up,
   the sheet stays (the typed title is kept on the pipeline for `try again`) and the card behind it
   shows the error as today. On a server without `features.titles` the sheet is not shown (rename
   later is local-only, decision 7). Plain cobalt: no uploads, no sheet.
   - **Share sheet**: no nested sheet in the extension. While a **file** uploads, its progress card
     gains one inline row: a `TextField` (`title`, prefilled, selected on first tap) with `done` on
     the keyboard; link shares get no field (their default is `service · ref`; rename later).
   - **Paste a file** does not exist (section 0) and is **not** added here; when it is, it calls
     `importFile` and inherits the sheet.
4. **(lane) How a typed title reaches the server.** `done` calls `pipeline.setTitle(_:)`. Before
   the upload returns its item id the title is held on the run (`pendingTitle`); the moment the
   `PUT /studio/upload` answer arrives (`UploadResult.item.id`) the pipeline sends
   `PATCH /library/items/<item id>/post {"title": …}` (section 6). After that, `setTitle` sends it
   at once. A failed PATCH goes to a small persisted queue (`TitleQueue`, app group, keyed by item id)
   flushed on foreground, on `library.refresh()` and on the next run; dropped on 200, 404, or after
   7 days. The share extension writes its pending title onto the `SharedJob` (`pendingTitle`) so the
   app applies it when it resumes the job if the extension was closed first. The title also lands
   on this device's records (decision 8) immediately, so the focus card, orbit caption, Live
   Activity and notifications use it before the server has answered.
5. **(owner) Rename any media later.** Two places, one alert:
   - **detail**: the navigation title gets a title menu (`toolbarTitleMenu`, iOS inline title and
     the Mac window title) with `rename` (`pencil`); iPad regular, where the centred title is removed
     (`MediaDetail.swift` comment at the `.toolbar(removing:)`), the trailing title `Text` becomes a
     `Menu` with the same item. The `more` menu (`ellipsis.circle`) also gets `rename` as its first
     item (discoverable on every width).
   - **library**: the context menu's `rename` (mosaic tile, table row, iPhone list row).
   - **the alert** (`.alert` with a `TextField`, native on iOS and macOS): title `rename`, field
     prefilled with the current title and selected, message `leave it empty to use "<default>".`,
     buttons `save` and `cancel`. The field caps input at 80 (section 4.1 counting). Saving the
     default text, or empty, clears the custom title.
   - Optimistic: the new title shows at once everywhere; a failure reverts it and shows
     `couldn't rename that. try again.` (the detail's inline error line; the library's status toast).
6. **(lane) Validation, identical on both sides.** Trim leading/trailing whitespace and line
   breaks; reject (server) / strip (client) control characters `U+0000-U+001F`, `U+007F-U+009F`,
   `U+2028`, `U+2029`; at most **80 Unicode code points** (Swift `unicodeScalars.count`, JS
   `Array.from(t).length`; the client cuts at the last whole `Character` that fits, never splitting
   a grapheme); empty after trimming = clear. The server never sees an invalid title from this app;
   its `400` exists for other callers.
7. **(lane) Capability.** `features.titles: true` from the server that has section 6. Absent (an
   older deploy of this fork, the legacy fork): no title sheet; rename stays available but writes
   this device only, and the alert's message adds `only on this iphone until the server is
   updated.` Plain cobalt (no library): rename is local-only and says nothing extra (there is no
   server copy to disagree with).
8. **(lane) This device keeps the title too.** `StoredVideo.title: String?` (all records of a media
   carry the same value; additive `decodeIfPresent`). Written by a local rename, by `setTitle`
   during a run, and **synced down** on every `library.refresh()`/`loadMore()` for each post that
   joins a local media (`MediaItem.joins`) and has a `custom_title` different from the local one.
   The orbit and focus never wait for the library to show a title.
9. **(owner) Where the title shows** (all through decision 1):

   | surface | file today | after |
   |---|---|---|
   | orbit caption + planet VoiceOver | `HomeScreen.swift:898`, `:928` | `item.titleText` |
   | focus title | `FocusView.swift:228-232` | the run's title (`pipeline.runTitle`) else `item.titleText` |
   | detail header (all widths) | `MediaDetail.swift:83-89` | `item.titleText`, renamable (decision 5) |
   | library mosaic caption, table/list title | `Screens/Library/*` | `row.title` |
   | Hark label (`PUT /studio/<sid>/notify`) and continued-processing subtitle | `NotifyBridge.swift:228-232` | `MediaTitle.label(_, limit: 60)`; a rename during a run re-sends the opt-in (idempotent, replaces `label`) |
   | Live Activity | `LiveSink.swift:86-87`; not drawn (`LiveLockScreen.swift:134`) | `state.title` = run title; Lock Screen and Dynamic Island **expanded** draw it as a one-line caption above the headline (middle truncation); compact unchanged |
   | web library | `web/src/library/page.html:812-844` | the post's custom title in place of the file name (wave W2, optional, section 8) |
   | share sheet done card | `apple/CobaltShare/**` | unchanged (it names the run's result, `CONTRACT-MEDIA` 1.16) |

### Library views

10. **(owner) Two views, one remembered switcher: `mosaic` and `table`.** Per device
    (`UserDefaults`, key `library.view`), default `mosaic`. iPhone: a two-segment icon `Picker`
    (`square.grid.2x2` / `list.bullet`, a11y "mosaic" / "table") at the navigation bar's leading
    edge; iPad: the same control in the toolbar; Mac: the toolbar's view control (Finder's place for
    it) plus `view ▸ as mosaic ⌘1` / `as table ⌘2` menu commands. Switching keeps the scroll anchor
    on the same post when it is on screen.
11. **(lane) The cards retire.** The mosaic takes the picture role, the table the information role;
    the chips' job (open a given tab) moves to badges plus the context menu's open, and the detail's
    tabs are one tap away. Three layouts would triple the AX-size, empty-state and evidence work for
    a view the owner did not ask for. `MediaCard`, `RenditionChip` and the `LibrarySplit` list go;
    `MediaPreview`/`RemoteStill` are reworked into the tile and thumbnail (section 5).
12. **(owner) Mosaic: a dense masonry of faces at their real aspect.**
    - Columns: `n = max(2, floor((width - 2·margin + gap) / (minTile + gap)))`, `gap` 6 pt, `margin`
      12 pt; `minTile` 108 pt iPhone (3 columns at 390 pt, 4-5 landscape), 150 pt iPad, 160 pt Mac;
      2 columns at accessibility text sizes. Tile height = column width × face aspect, the aspect
      clamped to 16:9 … 9:16 (a 1206×2622 screen recording shows as 9:16, filled and centred).
    - Placement: newest first, each tile into the currently shortest column (ties → leftmost); a new
      page only appends, so tiles never jump while loading. Pure function `MasonryPlan` (4.3).
      VoiceOver reads tiles in date order (accessibility sort priority = −index), not column order.
    - Face picture, first that exists. A **video** face: this device's poster → the server's
      `poster_url` → the first frame of the hosted mp4 (today's `RemoteStill`) → the grey frame
      gradient. A **webp** face (the server makes no webp posters): this device's poster → the first
      frame of the public webp (`RemoteStill`) → the video's server poster (a stand-in at the wrong
      crop, better than grey) → the gradient.
    - **Animation**: only webp faces, only while ≥ 80 % visible (`onScrollVisibilityChange`), at most
      4 at once on iPhone and 8 on iPad/Mac (nearest the viewport centre win), paused while the
      scroll is moving and resumed 0.3 s after it settles, never with Reduce Motion, Low Power Mode,
      the scene inactive, or (for a webp not on this device) an expensive or constrained network
      (`NWPathMonitor`). Remote webps come through a library `URLSession` with a 200 MB disk
      `URLCache` (public media is `immutable`).
    - **Badges** (same family as the planet badge, `CONTRACT-MEDIA` 1.7): top right the face type
      capsule (`webp`, `webp ×3`, `mp4`, `mov`, `gif`, `png`); a `link` dot when anything of the media
      is public; bottom left the length for a video face (`14.8 s`), only on tiles at least 80 pt
      tall (a 16:9 tile in 3 columns is 62 pt and has no room). Under 90 pt wide: type symbol dot
      only.
    - **Caption**: one line of title at the tile's foot on a soft dark scrim (Plex Mono 10.5 pt,
      middle truncation). Owner question 1 (section 10) may turn it off.
    - **Tap**: iPhone → push `MediaDetail` on the face with the zoom transition from the tile
      (`matchedTransitionSource`); iPad/Mac → select, and the detail column shows it (decision 15).
    - **Context menu** (long press; right click on Mac), preview = the face at its aspect with title
      and meta under it. Items in order: `open` (`arrow.up.left.and.arrow.down.right`); `copy webp
      link` (`doc.on.doc`, newest public webp, when one exists); `copy video link` (`doc.on.doc`, when
      hosted); `share` (`square.and.arrow.up`: the face's public link, else the file); `save to
      photos` (`photo.badge.arrow.down`, the face rendition, `AppModel.saveToPhotos`); `rename`
      (`pencil`); divider; `delete everything…` (`trash`, destructive, only when the media has
      something on the server; the `CONTRACT-MEDIA` 1.12 confirm and outcomes, unchanged).
    - **A tile whose picture fails** (HTTP error, undecodable, missing): the gradient with a centred
      `photo.badge.exclamationmark` (secondary ink), caption and badges unchanged, still opens; it
      retries when it scrolls back into view and on refresh. VoiceOver value `picture didn't load`.
13. **(owner) Table: iPad and Mac a real `Table`; iPhone a dense two-line list.**
    - iPad/Mac columns (all sortable, `KeyPathComparator`): `title` (24 pt face thumbnail +
      title), `service` (`instagram`, `x`, `file` for uploads), `length` (`14.8 s`), `resolution`
      (`720×1280`), `files` (`video + webp ×3`, `image`, `video`), `size` (all the post's files,
      `12.8 MB`), `public` (`link` + `public` / `lock` + `private`), `date` (latest activity,
      `today 21:04`). Default sort: date, newest first. Header click sorts; again reverses.
    - **Width rule (found on the iPad board, 2026-10-05):** at 1194 pt with the detail column open
      the table gets ≈ 750 pt and eight columns do not fit (the title column collapses to
      `instagram · Dd7P…` and the date clips). Below **860 pt of table width** `service` and
      `resolution` drop out (conditional `TableColumn`s): a link save's title already names its
      service, and the detail column shows the resolution. Closing the detail brings all eight
      back. No user column customization in this pass (one less persisted state).
    - iPhone row (≥ 56 pt): 44 pt face thumbnail at its aspect; line 1 the title (semibold, one
      line, middle truncation) with trailing badges (`webp ×3` capsule, `link` dot); line 2 in
      caption ink `14.8 s · 720×1280 · 12.8 MB · today 21:04`. AX sizes: thumbnail above, lines
      wrap. Toolbar `arrow.up.arrow.down` menu: a `sort` picker (date, title, length, size,
      resolution, files, public; picking the current key again reverses it; the current one carries
      `chevron.down`/`chevron.up`) and a `show` picker (everything, public, private, uploaded files).
      The same menu exists in the mosaic and on iPad/Mac (where it mirrors the table's sort).
    - Same context menu as the mosaic (`.contextMenu(forSelectionType:)` on the Table).
14. **(lane) Search, sort, filter.** `.searchable` prompt `search titles` (iPhone: navigation bar
    drawer; iPad/Mac: toolbar): matches the resolved title, the custom title, service, ref and file
    names, case- and diacritic-insensitive. The server pages by latest activity only, so any search,
    any filter other than `everything`, or any sort other than date-newest first **loads the whole
    library** first (`LibraryModel.loadAll`, pages of 50, cap 1000 posts) with a quiet line
    `loading the whole library · 60 of 140` above the results; then sorts/filters on device. No
    search result: `nothing matches "<q>".`. No server search parameter (lane call: a personal
    library is tens to hundreds of posts; one more server route is not worth it).
15. **(lane) iPad and Mac: the detail is an inspector column, not a split.** A mosaic or an
    8-column table in today's 300-440 pt list column would be useless, so the content takes the
    width and `MediaDetail` (in its own `NavigationStack`) sits in a trailing `.inspector` (360-460
    pt, resizable). Selecting a tile or row shows it there (the inspector opens if closed); a toolbar
    `sidebar.trailing` button toggles it (`⌥⌘I` on Mac). Its open/closed state is remembered per device
    (`library.inspector`); the first default is open, on the newest post, when the content is at
    least 1100 pt wide (iPad landscape, a normal Mac window), else closed until something is selected. Empty inspector: `pick something to
    see it here.` Return/double-click do nothing more (the detail is already beside it).
16. **(lane) Paging, refresh, states.** First page 20 (today), the next page when the last 6 tiles
    or the last row appear; a footer spinner, and on failure a footer `couldn't load more.` +
    `try again`. Pull to refresh (iOS); `⌘R` `refresh library` (Mac, view menu). First load: the
    mosaic shows 9 skeleton tiles at mixed aspects (static grey, no shimmer), the table/list a
    spinner row; failed and empty keep `LibraryProblem` (`can't load the library.` + `try again`;
    `nothing here yet.`). Subtitle unchanged (`15 posts · 24 files`, server counts).
17. **(lane) "open in library".** `LibraryModel.locate(postID:)` loads pages until the post is
    loaded (cap 1000), then: mosaic scrolls it to centre and pulses a 2 pt focus ring for 1.6 s
    (Reduce Motion: no pulse, a 1.6 s static ring); table selects the row (iPad/Mac: the inspector
    shows it). Not found: status toast `couldn't find that in the library.`
18. **(lane) No multi-select in this pass.** The only batch actions worth having are destructive
    (delete N posts for everyone); adding that to a UI refresh is the riskiest possible scope. Owner
    question 2 can add it as wave W3.
19. **(lane) Public by default + server posters change nothing structural**: the `public` column
    and the `link` dot read the files the server lists; the tile prefers `poster_url`. Checked
    against the poster lane's in-flight work at the end of this pass (uncommitted
    `APP-API-CONTRACT.md` section 13, `0006_posters_public.sql`, `app-routes.ts`): `GET /library` sends
    `poster_url` on each file and on each post (the original's poster, else any file's), a
    `https://media.capybaraharmony.com/<10 base62>.jpg`, behind `features.poster`; **webps get
    none** (ffmpeg here cannot decode animated WebP), so a webp face keeps today's first-frame
    decode of the public webp (decision 12's webp chain). Section 4.2's decode matches; Fable
    rechecks once that lane lands. The UI only reads `Rendition.posterURL` / `LibraryPost.posterURL`.

## 2. Surface table

| surface | today | after |
|---|---|---|
| library compact (`LibraryList`) | inset-grouped cards with chips | mosaic (default) or two-line list, switcher remembered, search, sort/show menu, context menus |
| library regular/wide (`LibrarySplit`) | list column + detail column | mosaic or `Table` full width + detail in an inspector |
| library Mac | `HSplitView` list + detail | same as iPad, toolbar view control, `⌘1/⌘2`, `⌘R`, `⌥⌘I` |
| library picture | device poster, else first frame decoded on device | + server `poster_url`; visible webps animate within a budget; a failed picture shows a glyph |
| upload title | "upload" in library/detail, file name with extension on the orbit | title sheet after picking; default = file name without extension |
| rename | none | detail title menu + `more` menu; library context menu |
| server | `title` = original's file name | + `custom_title`, `PATCH /library/items/<id>/post`, `features.titles` |
| Hark label / continued processing | file name or ref | the media title (≤ 60) |
| Live Activity | title carried, not drawn | drawn on Lock Screen and expanded island |
| web library | file names | custom titles (W2, optional) |

## 3. Copy (lowercase, exact; new `apple/Cobalt/Design/Copy+Library.swift`)

```swift
extension Copy {
    enum Library2 {
        // views, sort, show, search
        static let mosaic = "mosaic"
        static let table = "table"
        static let view = "view"                                   // switcher a11y label
        static let sort = "sort"
        static let show = "show"
        static let sortDate = "date", sortTitle = "title", sortLength = "length", sortSize = "size"
        static let sortResolution = "resolution", sortFiles = "files", sortPublic = "public"
        static let newestFirst = "newest first", oldestFirst = "oldest first"   // a11y values for date
        static let ascending = "ascending", descending = "descending"           // a11y values otherwise
        static let showEverything = "everything", showPublic = "public", showPrivate = "private"
        static let showUploads = "uploaded files"
        static let searchPrompt = "search titles"
        static func noMatch(_ q: String) -> String { "nothing matches \"\(q)\"." }
        static func loadingAll(_ n: Int, of total: Int) -> String { "loading the whole library · \(n) of \(total)" }
        static let loadMoreFailed = "couldn't load more."
        static let notFound = "couldn't find that in the library."
        static let pickSomething = "pick something to see it here."
        static let pictureFailed = "picture didn't load"                       // VoiceOver value
        static let refresh = "refresh library"                                 // Mac menu, ⌘R
        static let asMosaic = "as mosaic", asTable = "as table"                // Mac view menu
        static let toggleDetail = "show or hide the detail"                    // inspector button a11y

        // table columns and cells
        static let colTitle = "title", colService = "service", colLength = "length"
        static let colResolution = "resolution", colFiles = "files", colSize = "size"
        static let colPublic = "public", colDate = "date"
        static let serviceFile = "file"                                        // service cell of an upload
        static let isPublic = "public", isPrivate = "private"
        enum Original { case video, image }                                   // an uploaded png/jpg/heic/gif/webp is an image
        static func files(original: Original?, webps: Int) -> String {         // "video + webp ×3", "image", "webp ×2"
            let w = webps > 0 ? Copy.Media.webpCount(webps) : nil
            let o = original.map { $0 == .video ? "video" : "image" }
            switch (o, w) {
            case (let o?, let w?): return "\(o) + \(w)"
            case (let o?, nil): return o
            case (nil, let w?): return w
            case (nil, nil): return "—"
            }
        }

        // context menu
        static let open = "open"
        static let copyWebpLink = "copy webp link"
        static let copyVideoLink = "copy video link"
        static let share = "share"
        static let saveToPhotos = "save to photos"
        static let rename = "rename"
        static let deleteEverything = "delete everything…"                    // confirm: Copy.Media (CONTRACT-MEDIA 3)

        // titles
        static let nameIt = "name it"
        static let titleField = "title"                                       // field a11y label
        static let done = "done"
        static let skip = "skip"
        static func titleCount(_ n: Int) -> String { "\(n) of 80" }           // shown from 60 code points
        static let renameTitle = "rename"
        static func renameMessage(default d: String) -> String { "leave it empty to use \"\(d)\"." }
        static let renameLocalOnly = "only on this iphone until the server is updated."
        static let save = "save"
        static let cancel = "cancel"
        static let renameFailed = "couldn't rename that. try again."
    }
}
```

Defaults are not copy: `from photos · 4 oct` is `Copy.Media.fromPhotos` (in-flight lane) and the
file default is the file name minus its extension (`MediaTitle.stripExtension`, 4.1).

## 4. Pinned CobaltKit API (additive; UI lanes build against exactly this)

### 4.1 Titles (new `Models/MediaTitle.swift`)

```swift
public enum MediaTitle {
    public static let maxLength = 80            // Unicode code points
    public static let notifyLength = 60         // Hark label limit (APP-API-CONTRACT 9.2)

    public enum Resolved: Sendable, Equatable {
        case custom(String)
        case post(service: String, ref: String?)    // link save: "instagram · Dd7P496wolG"
        case file(String)                           // upload / Photos / share file: name without extension
        case none                                   // "cobalt"
    }

    /// Decision 1. `service` "upload" or empty counts as nil. `fileName` is the original's name
    /// (server `title`, else the local original's name).
    public static func resolve(custom: String?, service: String?, ref: String?, fileName: String?) -> Resolved
    /// Decision 6: trimmed, controls stripped, cut to 80 code points on a Character boundary; nil when empty.
    public static func clean(_ raw: String) -> String?
    /// Strips only media extensions: mp4 mov m4v gif webp png jpg jpeg heic (case-insensitive).
    public static func stripExtension(_ name: String) -> String
    /// Flattened text ("instagram · Dd7P496wolG", "cobalt"), cut to `limit` code points with "…".
    public static func text(_ r: Resolved, limit: Int = maxLength) -> String
}

extension MediaItem {
    public var customTitle: String? { get }     // post?.customTitle ?? local's StoredVideo.title (decision 8)
    public var title: MediaTitle.Resolved { get }
    public var titleText: String { get }        // MediaTitle.text(title)
    public var defaultTitleText: String { get } // the title without the custom one (the rename alert's message)
}
```

### 4.2 Wire and client (`Models/Library.swift`, `Models/MediaItem.swift`, `Models/Server.swift`, `API/*`, `Preview/*`)

```swift
// LibraryPost
public var customTitle: String?          // "custom_title", decodeIfPresent
public var posterURL: URL?               // "poster_url" on the post, decodeIfPresent (nil when the server sends none)
// LibraryFile
public var posterURL: URL?               // "poster_url" on each file, decodeIfPresent (assumed shape, decision 19)
// Rendition
public var posterURL: URL?               // merge: the webp's file poster; the video: hosted ?? private copy
// Capabilities
public var titles: Bool = false          // features.titles

// CobaltClient (default implementation throws PipelineFailure.unsupported, like deletePost)
func setTitle(anchor itemID: String, _ title: String?) async throws -> PostTitleResult   // PATCH /library/items/<id>/post
public struct PostTitleResult: Sendable, Equatable { public var post: String; public var title: String? }
```

`HTTPCobaltClient.setTitle`: body `{"title": <string|null>}`, `content-type: application/json`;
200 → result; 400 `error.library.bad_title` → `PipelineFailure.server(code:)`; 404 →
`.server(code: "error.library.not_found")`; others as `deletePost` maps them. `PreviewClient`
answers from its in-memory library (and fails the first call for item `PrEvIeWitem000008` when the
scenario is `.renameFails`, a new `PreviewScenario` case).

### 4.3 Library model (`Models/LibraryModel.swift`, new `Models/LibraryView.swift`, new `Models/MasonryPlan.swift`)

```swift
public enum LibraryViewMode: String, Sendable, CaseIterable { case mosaic, table }
public enum LibrarySortKey: String, Sendable, CaseIterable { case date, title, length, size, resolution, files, visibility }
public struct LibrarySort: Sendable, Equatable { public var key: LibrarySortKey; public var ascending: Bool
    public static let newest = LibrarySort(key: .date, ascending: false) }
public enum LibraryShow: String, Sendable, CaseIterable { case everything, publicOnly, privateOnly, uploads }

/// One media as the views show it: derived, value, sortable (table key paths are non-optional).
public struct LibraryRow: Identifiable, Sendable, Equatable {
    public let id: String                // post id
    public let item: MediaItem
    public let title: String             // item.titleText
    public let service: String           // "instagram", "x", "file"
    public let length: Double            // -1 unknown
    public let width: Int?, height: Int?
    public let pixels: Int               // w×h, 0 unknown
    public let hasVideo: Bool            // the media has an original rendition
    public let originalIsImage: Bool     // that original is an image upload (png, jpg, heic, gif, webp)
    public let webps: Int
    public let fileCount: Int            // renditions
    public let bytes: Int64              // all of the post's files
    public let isPublic: Bool            // any public file
    public let visibilityRank: Int       // 1 public, 0 private (sort)
    public let date: Date                // item.latestAt
    public let faceAspect: Double        // h / w of the face, 16:9 when unknown
    public let isUpload: Bool
}

// LibraryModel gains (stored on the class, not in an extension):
extension LibraryModel {
    public var viewMode: LibraryViewMode { get set }      // persisted "library.view"
    public var sort: LibrarySort { get set }              // persisted "library.sort" ("date.desc")
    public var show: LibraryShow { get set }              // persisted "library.show"
    public var query: String { get set }                  // not persisted
    public var needsWholeLibrary: Bool { get }            // query non-empty || show != .everything || sort != .newest
    public private(set) var loadingAll: (loaded: Int, total: Int)?
    public func loadAll(cap: Int = 1000) async            // pages of 50 until next == nil or cap
    public func locate(postID: String) async -> Bool      // loads until found (cap 1000)
    public func setCustomTitle(_ title: String?, post id: String)   // optimistic local edit; AppModel calls it
}

extension AppModel {
    public var libraryRows: [LibraryRow] { get }          // posts → mediaItem(for:) → filtered, searched, sorted
    /// Decision 5: optimistic (library + store), PATCH when the media has a server file and caps.titles,
    /// reverts and rethrows on failure. nil or the default text clears.
    public func rename(_ item: MediaItem, to raw: String?) async throws
}

/// Decision 12 placement. Pure; tested.
public struct MasonryPlan: Equatable, Sendable {
    public struct Slot: Equatable, Sendable { public let index: Int; public let column: Int; public let y: Double; public let height: Double }
    public let columns: Int, columnWidth: Double, slots: [Slot], height: Double
    public static func columns(width: Double, minTile: Double, gap: Double, margin: Double, accessibility: Bool) -> Int
    public static func make(aspects: [Double], width: Double, columns: Int, gap: Double, margin: Double) -> MasonryPlan
    public static func clampAspect(_ hOverW: Double) -> Double   // 9/16 ... 16/9
}
```

Persistence: an injected `UserDefaults` (standard in the app, a fresh suite in tests). No `Store/*`
edit for the view state.

### 4.4 Titles in the run, the store and the share job (wave W2: these files are dirty in other lanes now)

```swift
// Pipeline
public private(set) var runTitle: String?        // the typed title for this run (nil = default)
public func setTitle(_ raw: String?)             // decision 4; safe at any state; ignored once reset
// notifyLabel: MediaTitle.text(resolved with runTitle, limit: 60); a change while an opt-in is live re-PUTs it
// LiveSink: title = runTitle ?? media name without extension
// StoredVideo
public var title: String?                        // decision 8, decodeIfPresent
// OfflineStore
public func setTitle(_ title: String?, media id: String) async   // every record of the media, one coordinated write
// SharedJob
public var pendingTitle: String?
// TitleQueue (new, Pipeline/TitleQueue.swift): app-group JSON, enqueue(itemID:title:), flush(client:) async
```

## 5. UI behaviour (files)

- `Screens/Library/LibraryScreen.swift` (rewrite): chrome (title, counts subtitle, switcher,
  sort/show menu, paste/file buttons, `.searchable`), the `loadingAll` line, mode switch, iPhone
  push with zoom transition, iPad/Mac inspector, `locate` for "open in library", `#Preview`s.
- new `LibraryMosaic.swift` (masonry with `MasonryPlan`, one `LazyVStack` per column, skeleton,
  footer), `LibraryTile.swift` (face, badges, caption, failed state, focus ring),
  `LibraryTable.swift` (iPad/Mac `Table`, iPhone `List` rows), `LibraryMenus.swift` (context menu,
  sort/show menu, view switcher), `RenameAlert.swift` (the alert as a `ViewModifier`
  `.renameAlert(item:isPresented:)`, reused by the detail in W2), `AnimationBudget.swift`
  (decision 12 budget, scroll phase, Reduce Motion, Low Power, network), `LibraryMediaCache.swift`
  (the library `URLSession`/`URLCache`).
- `LibraryParts.swift`: keeps `LibraryCardCopy.meta` → becomes the list row meta; `RenditionChip`,
  `CardPress` removed if unused elsewhere (`grep` first). `RemoteStill.swift`: loader returns
  success/failure (for the failed tile), memory cache 300, disk via `LibraryMediaCache`.
- Mac: the toolbar view control and `⌘1/⌘2/⌘R/⌥⌘I` are `.commands`/`keyboardShortcut` on the
  library's own toolbar items (no `CobaltApp.swift` edit).

## 6. Server (additive; wave W2, after the poster lane lands; `APP-API-CONTRACT.md` section 14)

- **Migration `deploy/cloudflare/d1/migrations/0007_titles.sql`** (the poster lane owns `0006`):

  ```sql
  -- Custom titles (CONTRACT-LIBRARY2 6): one per post, keyed by the same post key GET /library
  -- groups by. Absent row = no custom title (the app shows its default).
  CREATE TABLE media_titles (
      post_key   TEXT PRIMARY KEY,
      title      TEXT NOT NULL,      -- 1..80 code points, trimmed, no control characters
      key_id     TEXT,               -- api_keys.id (or service:library) that set it
      updated_at INTEGER NOT NULL    -- ms
  );
  ```

  Why a migration (lane): a custom title must be (a) distinguishable from the default so it can be
  cleared, (b) independent of whichever file row would carry it (deleting that webp must not lose
  it), and (c) possible for every post kind, including webp-only `/webp` posts with no original.
  Overwriting `media_items.name` fails all three and changes download names.
- **`PATCH /library/items/<id>/post`** (keyed; `gate.ts:214-215` block: `DELETE` → existing
  `library_post_delete`, `PATCH` → `lookupThen(req, "library_post_title", { id })`, other methods
  404). Body JSON ≤ 1024 bytes `{"title": string | null}` (any other shape, too large, or bad JSON →
  `400 error.library.bad_title`). The anchor must be a **live** row (`deleted_at IS NULL`), else
  `404 error.library.not_found`; post key = `POST_KEY_SQL` on it. Validation = decision 6. Non-empty
  → `INSERT … ON CONFLICT(post_key) DO UPDATE SET title, key_id, updated_at`; null/empty → `DELETE`.
  `200 {"status":"success","post":"<post key>","title":"<title>"|null}`, `cache-control: no-store`.
  D1 failure → `503 error.api.generic`. Idempotent. Never wakes the container or a DO.
- **`GET /library`**: each post gains `"custom_title": string | null` (one more query:
  `SELECT post_key, title FROM media_titles WHERE post_key IN (…)`). `title` is unchanged.
- **`DELETE /library/items/<id>/post`** (section 12): also deletes the post's `media_titles` row
  after the files (step 4; failure logged, not reported).
- **`POST /library/items/<id>/publish`** (5c): when the new `host` row's post key differs from the
  source's (the image case, `APP-API-CONTRACT.md` 5a "known gap"), copy the source post's custom
  title to the new key (`INSERT OR IGNORE`).
- **Capability**: `features.titles: true` (`app-routes.ts` `capabilities()`, next to `delete_post`).
- Not changed: `PUT /studio/upload` (decision 2), `POST /studio`, notify (the app sends the title as
  `label`), the web `/api/library` (W2 web lane reads `media_titles` itself, optional).
- **Tests** (`test/library.test.ts` on `node:sqlite`, `test/gate.test.ts`, `test/worker.test.ts`):
  set, replace, clear (null and `"  "`), 81 code points → 400, exactly 80 (with an emoji counted as
  its code points) → 200, `\n` inside → 400, leading/trailing spaces trimmed, bad JSON / number /
  missing key / > 1024 bytes → 400; anchor on any file of a post (saved original, webp, upload,
  reopened-session render) → the same `post`; deleted anchor → 404; `GET /library` shows
  `custom_title` on the right post only and `null` elsewhere; delete-post removes it; 5c image host
  copies it; gate: `PATCH` keyed → decision, no key → 401, `GET/POST …/post` still 404, service
  header allowed; `/capabilities` has `titles: true`; existing suites green.

## 7. SF Symbols (new `apple/Cobalt/Design/Symbols+Library.swift`; all resolved with
`NSImage(systemSymbolName:)` on this Mac on 2026-10-05, Darwin 27; recheck on the macOS 26 SDK in the gate)

| use | symbol |
|---|---|
| mosaic view | `square.grid.2x2` |
| table view | `list.bullet` |
| sort/show menu | `arrow.up.arrow.down` |
| sort direction mark | `chevron.down` / `chevron.up` |
| open | `arrow.up.left.and.arrow.down.right` |
| copy webp link / copy video link | `doc.on.doc` (→ `checkmark`) |
| share | `square.and.arrow.up` |
| save to photos | `photo.badge.arrow.down` |
| rename | `pencil` |
| delete everything | `trash` (destructive, last) |
| tile picture failed | `photo.badge.exclamationmark` |
| public / private cell | `link` / `lock` |
| inspector toggle | `sidebar.trailing` |
| face type dots | `film`, `sparkles`, `photo` (existing) |

## 8. Lanes, waves, ownership

| wave | lane | owns (writes only these) | done when |
|---|---|---|---|
| W1 (now) | K1 · KIT (`sonnet-lane`) | new `CobaltKit/Sources/CobaltKit/Models/{MediaTitle,LibraryView,MasonryPlan}.swift`; `Models/{Library,LibraryModel,MediaItem,Server,AppModel+Media}.swift`; `API/{Client,HTTPCobaltClient}.swift`; `Preview/{PreviewClient,PreviewData,PreviewContext}.swift` (+ `.renameFails`, posts with `custom_title` and `poster_url` fixtures); `CobaltKit/Tests/**` (new files only) | 4.1-4.3 compile on iOS and macOS, section 9 K tests green, every existing call site unchanged |
| W1 ‖ after K1 | L · LIBRARY (`sonnet-lane`) | `apple/Cobalt/Screens/Library/**`; new `apple/Cobalt/Design/{Copy+Library,Symbols+Library}.swift` | gates; `#Preview`s in 9 L; reads `Copy.Media` and `AppModel+Media` only |
| W2 (after the in-flight lanes land) | K2 · RUN (`sonnet-lane`) | `CobaltKit/Sources/CobaltKit/{Pipeline/*, Store/StoredMedia.swift, Store/OfflineStore.swift, Share/*, Live/LiveSink.swift, Models/AppModel.swift}`; new `Pipeline/TitleQueue.swift`; tests | 4.4; title sync-down in `LibraryModel` hooks (K1 leaves a `didApply(page:)` seam); 9 K2 tests |
| W2 ‖ | S · API (`sonnet-lane`) | `deploy/cloudflare/d1/migrations/0007_titles.sql`; `deploy/cloudflare/api/src/{gate,app-routes,worker}.ts`; `deploy/cloudflare/api/test/**`; `APP-API-CONTRACT.md` (section 14, verbatim from 6; the poster lane took section 13); `README.md` (one line). Starts only after the poster lane's `0006`/`app-routes.ts` edits land; edit on top, never revert | `cd deploy/cloudflare/api && npm test && npm run typecheck`; `cf deploy --dry-run`. Deploy and `0007` apply are the owner's |
| W2 ‖ after K2 | T · TITLES UI (`sonnet-lane`) | new `apple/Cobalt/Shared/TitleSheet.swift`; `apple/Cobalt/App/{AppShell,ShellActions,PhotoImport}.swift` (present the sheet after `importFile`; Photos passes nothing new: its name is already the default); `apple/Cobalt/Screens/Home/{MediaDetail,FocusView,HomeScreen}.swift` (title resolver, detail title menu); `apple/Cobalt/Screens/Detail/DetailMenu.swift` (`rename` first); `apple/Cobalt/Design/Copy+Media.swift` (`displayTitle` forwards to `MediaTitle.stripExtension`); `apple/CobaltShare/**` (inline title row); `apple/CobaltWidgets/{LiveLockScreen,LiveViews,CobaltLiveActivity}.swift` (title caption) | gates; 9 T previews and evidence |
| W2 ‖ optional | W · WEB (`sonnet-lane`) | `deploy/cloudflare/web/src/library.ts` (items gain `title` = the post's `media_titles.title` via the same post key SQL), `web/src/library/page.html` (+ regenerated `page.generated.ts`), `web/test/**` | `cd deploy/cloudflare/web && npm test && npm run typecheck`; headless screenshot against a fixture. After S (it reads `0007`) |
| W3 | V · verify (`sonnet-lane`) | none (evidence to a session path) | section 9 V, pass/fail per line |

Not touched by anyone here: `apple/Cobalt/App/CobaltApp.swift`, `apple/project.yml` (new files are
picked up by the source globs; K1 confirms with `xcodegen generate`), `api/**`, `web/**` upstream,
`Screens/Detail/RenditionHero.swift`, `HeroControls.swift`. L never edits `MediaDetail.swift`; T
reuses L's `RenameAlert.swift` read-only. Rules as `CONTRACT.md` 3: shared types only in CobaltKit; a
UI lane that needs more API asks Fable; no lane commits or pushes.

**Cost (estimates, not measured)**: K1 ≈ 1 sonnet-lane session (≈ 600 lines incl. tests); L ≈ 2
sessions (largest: mosaic, table, menus, inspector, animation budget, ≈ 1,200 lines, previews,
evidence); K2 ≈ 1 session (≈ 400 lines, the store/share edits are small but sit on hot files); S ≈
0.5 session (≈ 250 lines incl. tests); T ≈ 1-1.5 sessions (sheet, detail, share row, widgets); W ≈
0.5 (optional); V ≈ 0.5-1. Fable gates each wave (4 commands + diff review).

## 9. Gates, tests, evidence

**Gates** (every lane; Fable reruns): `CONTRACT.md` section 9's four commands (xcodegen; iOS build on
iPhone 17 Pro / iOS 26.5; macOS build; `cd apple/CobaltKit && swift test`), no `warning:` lines from
`apple/`; S and W also their `npm test && npm run typecheck`.

**K tests** (`swift test`):
- `MediaTitle.resolve`: custom wins over a link save and a file; `service: "upload"` + file name →
  `.file("IMG_0412")`; link save without custom → `.post`; nothing → `.none`.
- `clean`: trims, strips `\n`/`\u{7}`/`\u{2028}`, 81 code points → 80, an emoji sequence at the cut
  is not split, `"   "` → nil; `stripExtension` keeps `clip.v2` and strips `.MOV`; `text` truncates
  to 60 with `…`.
- decoding: a post with and without `custom_title`/`poster_url`; a file with `poster_url`;
  `features.titles` present/absent; old fixtures still decode.
- `setTitle` against `LoopbackServer`: 200 set, 200 clear (body `{"title":null}`), 400, 404, 401.
- `AppModel.rename` with `PreviewClient`: optimistic then confirmed; `.renameFails` → reverted +
  thrown; default text → clears; no `titles` capability → local only, no request.
- `LibraryRow`: bytes sum, `isPublic`, files counts, upload → service `file`; sort by every key both
  ways with ties broken by date then id; `show` filters; search folds case and diacritics and
  matches ref and file names; `needsWholeLibrary`; `loadAll` stops at `next == nil` and at the cap;
  `locate` loads until found; prefs round-trip through an injected `UserDefaults`.
- `MasonryPlan`: 3 columns at 390 pt / 108 pt; 2 at AX; shortest-column placement on a fixture of
  the board's aspects equals the board's columns; appending a page never moves earlier slots;
  aspects clamp at 16:9 / 9:16.
- K2: `setTitle` before the item id → PATCH right after the PUT answer (order asserted); after → at
  once; PATCH failure → `TitleQueue`, flushed on the next refresh; `notifyLabel` uses the run
  title cut to 60; `StoredVideo.title` decodes absent; `store.setTitle` writes every record of the
  media; sync-down sets a joined media's title from `custom_title`.

**L `#Preview`s** (all with `.renditions` unless noted): mosaic compact/regular/wide; mosaic AX3;
mosaic with one failing picture (`-previewMediaDir` missing file); skeleton; table iPhone; Table
iPad 1194 with inspector; Table Mac; sort menu open; search with no match; empty; failed; loading
all line; plain cobalt (no library tab, nothing to preview).

**T `#Preview`s**: title sheet (Files default, Photos default, long title at 72 of 80, run failed
behind it); rename alert (fork, local-only message); detail title menu; share card with the title
row; Lock Screen with a title caption.

**V checklist** (iPhone 17 Pro sim iOS 26.5, iPad sim 1194×834, Mac; `-previewScenario renditions`;
every screenshot/recording and log saved to a session path):
1. mosaic: 3 columns, real aspects, badges, captions; scroll → only ≤ 4 webps animate, none while
   scrolling, none with Reduce Motion or Low Power (toggle both); a failing tile shows the glyph and
   still opens; tap → detail with zoom; long press → menu, each item does its job (copy → pasteboard
   check; rename → title everywhere: tile, detail, orbit caption).
2. table: iPhone sort menu (every key, reverse), show filters, search incl. a no-match; iPad Table
   header sorts, 6 columns with the detail open at 1194 pt and 8 with it closed (report what iPadOS
   does with the column widths), inspector follows selection; Mac Table + `⌘1/⌘2/⌘R/⌥⌘I`.
3. switcher remembered across relaunch, per device.
4. "open in library" from a detail → the tile/row lit; a post beyond page 1 is found.
5. title sheet: Files pick → upload starts (progress moves) while the sheet is up; type, `done` →
   library, detail, orbit, Lock Screen caption show it; `skip` keeps `IMG_0412`; Photos default
   `from photos · <date>`; kill the network after `done` → the queue applies it on the next refresh.
6. share sheet with a file → inline title → the app's library shows it.
7. live server only after S is deployed and `0007` applied by the owner, on a throwaway upload made
   for the test: PATCH set/clear, `GET /library` `custom_title`, web library title (if W ran).

## 10. Owner questions (defaults apply unless the owner says otherwise)

1. **Titles on mosaic tiles**: a one-line caption on every tile (default), or a pure picture wall
   with titles only in the context-menu preview and VoiceOver? Default: captions on (the owner asked
   for titles everywhere).
2. **Multi-select** (select several tiles/rows to delete everything or copy links): not in this pass
   (default, decision 18), or add it as wave W3?

Risks: the poster lane's `poster_url` shape is assumed (decision 19); animated tiles cost battery and
data (bounded by decision 12, measured only in V); `loadAll` on a very large library is capped at
1000 posts and says so; a rename on a device without the server capability diverges until the
server is updated (said in the alert); the web library shows custom titles only if W ships.

## 11. Mockup boards (session scratchpad `library2/project/`, merged into the canvas by Fable)

- `Library2-Mosaic.dc.html` (iPhone 390×844): the mosaic, switcher, tap → detail, simulated long
  press → context menu (rename works, delete everything confirms), one tile whose picture fails,
  the animation budget visible as "playing" marks, reset.
- `Library2-Table.dc.html` (iPhone 390×844): the two-line list, sort/show menu (every key, reverse),
  search with a no-match state, switcher back to mosaic.
- `Library2-Table-iPad.dc.html` (iPad 1194×834): sortable `Table` (click headers), inspector detail
  column following the selection, inspector toggle.
- `Library2-Upload-Title.dc.html` (iPhone 390×844): pick (files / photos) → the upload starts and the
  title sheet rises prefilled → type or skip while the progress keeps moving → the result and the
  library tile carry the title; rename from the detail's title menu, including the failing first
  try.
**Checked** (2026-10-05, `scratchpad/library2/validate.mjs`, 90 assertions, and `dupkeys.cjs`, which
catches a duplicated key in any object literal and was itself checked against an injected
duplicate): the exact `support.js` head line, `<x-dc>`/`<helmet>`, `class Component extends
DCLogic`, no `innerHTML`, no emoji, every tag closed, every `{{binding}}` resolving on the first
render and in each opened state, every referenced still present, and each board's behaviour run with a
fake clock (masonry columns and clamp, animation pause, long press vs tap, rename capped at 80 code
points, delete counts, sort/show/search, the PATCH only after the PUT's 201, failure keeps the
title). The boards were also rendered in a local test-only stand-in runtime (copied from the
`media-detail` session's `test/support.js`, not the canvas runtime) and screenshotted; that pass
found a key collision (`detail`) and an iPad column overflow the static checks missed, both fixed
(the second became decision 13's width rule). **Not verified**: the canvas runtime itself;
`onScroll` and `onFocus` are not used by any earlier board (`onInput`, `onPointer*`, `onKeyDown`
are), so the scroll pause and select-on-focus may be inert in the canvas.
Stills are real frames reused from the `media-detail` and `sparse-orbit` boards (the
`Dd7P496wolG` clip and its crops; the owner's uploads `crop-gestures.mov`, `photoclip`, `counter15`,
`plain`, `clipA`, `clipB`, `anim`); posts, sizes and times are `PreviewData.libraryPage` plus those
uploads' real sizes; the five other link posts have no stills and show the grey frame at their real
aspect, as the app does without a poster.
