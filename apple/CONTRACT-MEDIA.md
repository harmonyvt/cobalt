# cobalt for apple: one media, many renditions (owner request, 2026-10-04)

Owner (verbatim): "I am also thinking for the orbit we dont show duplicate webp and video of the
same file? like there is one media and tabbed options in the detail page i can select but in
cobalt its not seperate and the orbit will priotise webp if available and I am wondering maybe we
could have multiple webp for a video? This is a big change but i think its much cleaner please"
Follow-up (verbatim): "This is also for the library and app wide please."
Owner answers (2026-10-05): deleting a media = "Everything but is there a way to keep backward
compatibility"; sharing the same post again later = a new media (the recommended default). Each
webp keeps its own public URL.

Additive to `CONTRACT.md`, `CONTRACT-LIVE.md`, `CONTRACT-ORBIT.md`, `CONTRACT-SYNC.md` and
`deploy/cloudflare/APP-API-CONTRACT.md`. Code read on 2026-10-04/05 against the `apple-app` worktree
(uncommitted state included). **One additive keyed API route and one capability flag** for
"delete everything" (section 6); no D1 migration, no existing route changes. The web library page
change in wave W2 is web-Worker-only and optional. Marked **(owner)** where the owner asked for it,
**(lane)** for calls made here and open to review. Design source: the `Media-*.dc.html` boards
(section 11).

## 0. What exists today (read, not assumed)

- **Server already groups.** `GET /library` (keyed) returns one post per source with its files:
  `POST_KEY_SQL` = `COALESCE(<upload: link substr>, session_id, link, id)`
  (`deploy/cloudflare/api/src/app-routes.ts:348-350`, contract `APP-API-CONTRACT.md:325-336`),
  posts ordered by `MAX(created_at)` of their files (`app-routes.ts:417-421`). `media_items.session_id`
  is indexed (`d1/migrations/0004_library.sql`, `idx_media_items_session`). Many webps per session
  are already normal: `studio_renders` has one row per render (`0003_studio.sql`), and a reopened
  expired session keeps its renders in the original post through the `upload:<sid>` link trick.
- **The app's library is already one card per post** (`LibraryScreen.swift:106-117`, one
  `Section` + `DisclosureGroup` per `LibraryPost`), expanding into one `FileRow` per server file
  (webp / mp4 link / private copy). Pills are per role (`Library.swift:101-109`).
- **The device store is flat.** `OfflineStore` keeps one `Record` per file, `kind .original | .webp`
  (`OfflineStore.swift:5-28`, `704-749`). A webp record carries the studio `sessionID` it was
  rendered from and its public `remoteURL` (`PipelineFlows.swift:703-716`); an original carries its
  `sessionID` (studio, upload) or none (plain cobalt save, picker item; `PipelineFlows.swift:442`,
  `488-491`, `606-607`). Identity is per file only (`duplicateIndex`, `OfflineStore.swift:278-287`).
  The render's trim and crop are **not** stored anywhere locally, and the server keeps the crop only
  in the DO job record (`APP-API-CONTRACT.md` 10.3), so the meta line can only show them for webps
  made on this device.
- **The orbit shows files, not media.** `orbitVideos = store.latest(maxItems)`
  (`HomeScreen.swift:184-209`): a video and each of its webps are separate planets; the original
  wears a sparkles dot when any webp of its session exists (`HomeScreen.swift:212-215`,
  `OrbitView.swift:113`, `PlanetBadge.swift:71-79`).
- **Two detail screens.** A planet opens `MediaDetail` for one record: `PostDetail` (the library's
  file rows) when the library has the post, else `LocalMediaDetail` (`MediaDetail.swift:12-38`).
  A webp planet therefore opens a detail of the webp alone.
- **Photos ledger keys are already per file** (`PhotosLedger.swift:6-20`: `s:<sid>` original,
  `w:<url>` webp, `r:<url>` picker, `i:<id>` other): grouping needs no ledger change.
- **No search surface exists** (`grep searchable apple/Cobalt` is empty).
- **What an API key can delete today (read 2026-10-05):** only a public webp, one at a time:
  `DELETE /media/<name>` with `MEDIA_NAME_REGEX = ^[A-Za-z0-9]{10}\.webp$`
  (`deploy/cloudflare/api/src/gate.ts:88`, `225-229`) → the DO's `deleteMedia` deletes the R2
  object and soft-deletes its `media_items` row (`webp.ts:581-589`, `library.ts:89-105`
  `markMediaDeleted`). A hosted `.mp4` (`host` row, bucket `media`) and the private original
  (`saved`/`upload` row, bucket `originals`, plus `studio_sessions.r2_key`) **cannot** be deleted
  with a key; only the web library can, behind Cloudflare Access (`web/src/library.ts:596-615`
  `itemDelete`: R2 delete, `deleted_at`, and for an original it expires every session reading that
  `r2_key`). Public files are served `cache-control: public, max-age=31536000, immutable`
  (`app-routes.ts:638`, `publish.ts:83`, `webp.ts:528`), so a deleted link can keep answering from
  Cloudflare's edge cache or a chat app's own cache for a while; today's per-file delete has the
  same limit.
- **Web library page is flat**: one tile per file plus studio tiles sorted by time
  (`deploy/cloudflare/web/src/library/page.html:880-884`, `entries()`), from `/api/library`
  (flat `items` + `studios`).

## 1. Decisions

1. **(owner) One media per source, owning its renditions.** A *media* is one source (a saved post,
   an uploaded file): at most one **video** rendition (the original; for a still image upload, the
   image) and zero or more **webp** renditions, each with its own trim, crop, size, quality and
   public link. Every surface shows the media once; renditions are tabs inside it.
2. **(lane) Identity: an explicit local `mediaID` per record, not a derived key.** Session ids do
   not name a media: a reopened expired session (library 5d) has a new `sid` for the same video,
   and an upload's server post id is the item id, not a session. A link does not either (a carousel
   post's items share one link). So each `Record` stores `mediaID` (an opaque local id: the id of the
   media's first record). Resolution at `add`, **inside the coordinated index write** (same place as
   `duplicateIndex`, so the app and the share extension can never split one media):
   1. the caller's explicit `mediaID` (the run was started from a media: "another webp", the
      library's "make a webp"), unless that media already has a different original (invariant:
      at most one original per media; a second original becomes its own media);
   2. else the `mediaID` of any record with the same non-nil `sessionID`;
   3. else a new media (`mediaID = record.id`).
   An original added after its webps (keep-original landing late, or the share extension's
   background original) joins them by rule 2. The share extension needs no code change.
3. **(lane) Legacy index migration, once, deterministic.** Records without `mediaID` get one in
   `reconciled` (one coordinated write, like the poster-size backfill):
   1. group by non-nil `sessionID`; the group's id = the earliest-`createdAt` original's id, else
      the earliest webp's id; a group with two originals keeps the earliest, the other becomes its own;
   2. a webp-only group joins an original from another session when its records' `link` equals the
      `link` of **exactly one** original that has a `sessionID` (the reopened-session case);
      ambiguous or nil link: stays its own media;
   3. records with no `sessionID` (plain saves, picker items): their own media.
   Same input gives the same ids in both processes. Never reorders, deletes or moves files.
4. **(owner, lane) The planet's face is the newest webp, else the video.** "Newest" = latest
   `createdAt`. No per-webp "show on orbit" choice (one fewer control; the detail opens on the face).
   Deleting the face webp falls back to the next newest, then the video.
5. **(lane) Media order = latest activity.** `latestAt` = max `createdAt` of its renditions, newest
   first, in the orbit, `store.media` and the library (the server already orders posts by
   `MAX(created_at)`). A new webp on an old media makes it the newest planet.
6. **(owner) "make webp" changes the same planet.** In focus the planet already crossfades to the
   webp after the shimmer (`CONTRACT-ORBIT` 2.5); with grouping no second planet ever appears: the
   run's media is held out of the orbit while in focus (by `mediaID`, not by session) and springs
   back into the newest slot of band 0 wearing the new face.
7. **(lane) Planet badge.** The type capsule shows the **face's** file type (`webp`, `mp4`…); when
   the media has 2 or more webps it reads `webp ×3` (count of webps). The separate sparkles
   "has webp" dot is removed (the face says it); the link dot stays (the video was hosted). Compact
   planets (< 48 pt) keep one symbol dot (`sparkles` for a webp face, `film` for video) plus the
   link dot; no count. VoiceOver (custom action names): "open instagram Dd7P496wolG, video and 3
   webps".
8. **(lane) One detail screen app-wide: `MediaDetail` over a `MediaItem`.** The orbit, the library
   (compact list, regular/wide split, Mac), the inspector's "made from this video" rows and the
   debug hooks all open the same screen. `MediaItem` merges the device's `StoredMedia` with the
   library's `LibraryPost` (section 4.2), so a webp made on the Mac shows on the iPhone's tabs and a
   local-only webp shows before the library reloads. `PostDetail` and `LocalMediaDetail` go away.
9. **(lane) Tabs.** Shown only when the media has 2+ renditions. Order: `video`, then webps oldest
   to newest (`webp 1`, `webp 2`…; a lone webp is just `webp`); a new webp appears at the end and is
   selected. Native segmented `Picker` when the tab count fits (compact width: up to 4; regular and
   Mac: up to 6), else a horizontally scrolling chip row (selected chip filled) that scrolls the
   selection into view. **Tabs sit at the top, above the hero** (the hero's height changes with each
   rendition's aspect; a picker under it would jump). Opens on the face, or on the rendition the
   caller names. ⌘1…⌘9 select tabs on iPad keyboards and the Mac.
10. **(lane) Per-tab content, exactly one prominent button (`CONTRACT-ORBIT` 2b).**
    - hero: the rendition at its real aspect (a cropped webp is square/4:5…), max 360 pt tall on
      iPhone; video = the existing `DetailPlayer` (muted loop, tap for controls, lent orbit player);
      webp = `AnimatedImageView`; evicted = poster dimmed + `icloud`; type capsule top right.
    - meta line (Plex Mono caption): video `14.8 s · 720×1280 · 4.3 MB · saved yesterday 13:59`;
      webp `00:02.0 → 00:12.0 · crop 1:1 · 480×480 · 2.4 MB · made today 20:52` (trim and crop only when
      known; else `10.1 s · 480×854 · 4.5 MB · made …`).
    - link line under it when public: `media.capybaraharmony.com/PrEvIeW001.webp` (selectable).
    - **webp tab**: primary `copy webp link` (bounce → `copied`); secondary row: `share`,
      `save to photos`, `another webp`. The secondary row is the focus's stacked choice button
      (icon over word, 52 pt, `FocusView.swift:1325-1340` `ChoiceLayout.stacked`): three words
      like "save to photos" do not fit one line at a third of 336 pt.
    - **video tab** (fork with studio): primary `make another webp` (`make a webp` when it has none);
      secondary row: `public share` (not hosted) or `copy video link` (hosted), `save to photos`,
      `share`. Plain cobalt: primary `save to photos`, secondary `share`.
    - then the existing "on this iphone" `OfflineCopySection`, **for the selected rendition**.
    - toolbar `more` menu (`ellipsis.circle`), in this order: `open in library` (from the orbit,
      when the library has the post); `remove from this iphone` (whole media, frees space only);
      `delete this webp` (webp tab only, destructive); `delete everything` (destructive, last,
      only when the media has something on the server; 1.12).
11. **(lane) "another webp" = the focus flow, not an editor inside the detail.** It pops the detail
    (zoom back into the planet), lifts that planet into focus with the trim strip open (and the crop
    button), exactly like the library's "trim a new webp" today (`AppShell.swift:175`,
    `AppModel.swift:286`), with `targetMediaID` set so the result joins this media. One place makes
    webps (progress card, star growth, Live Activity, shimmer); duplicating it in the detail would
    fork that story. The source is the local original when on disk, else the session, else the
    library item reopened (5d).
12. **(owner, 2026-10-05) Three ways to get rid of things, from cheap to final.**
    - `remove from this iphone` (whole media, kept): every local record of the media goes (files,
      posters, flipbooks); the planet leaves the orbit; the server, the library card and every public
      link stay. Frees space only; nothing is lost.
    - `delete this webp` (one webp tab): on the server when it has a deletable name
      (`DELETE /media/<name>.webp`, as `LibraryModel.delete` does), and the local record. A webp the
      server cannot delete with a key (no name) offers "remove this webp from this iphone" instead.
    - `delete everything` (owner: "Everything"): the whole media, for everyone: every webp and its
      public link, the hosted video link if any, the private original on the server, the studio
      sessions that read it, and every local copy. Photos keeps its copies (the ledger keeps their
      keys, so the album sync never re-adds them). **Decision: (b) with fallback (a).**
      - (b) when the server says `features.delete_post`: one call, `DELETE
        /library/items/<any file id of the post>/post` (section 6). Reasons: the private original and
        a hosted `.mp4` cannot be deleted with a key today (section 0), so a client-only fan-out
        cannot do "everything"; one server call deletes in a fixed safe order (expire the sessions
        first so nothing new is rendered into the post, then the files), refuses while a render or
        save of the post is running, and reports exactly what is left; and it is small (one handler
        reusing `POST_KEY_SQL`, the list's session key, `markMediaDeleted`'s update and R2 `delete`)
        and testable on `node:sqlite` like `library.test.ts`.
      - (a) when the flag is absent (an older deploy of this fork, the legacy fork): the app deletes
        each webp that has a deletable name with the existing `DELETE /media/<name>.webp`, one at a
        time, then removes the local copies of what it deleted. What stays is said in the confirm
        and in the result: the private copy and the video's public link ("delete those on the web").
      - plain cobalt (no library): the action is not shown; `remove from this iphone` is the only one.
    - **Confirm** (`confirmationDialog`, destructive button `delete everything`, cancel `keep`):
      title "delete everything?"; message built from what exists, e.g. "the video, its public link
      and its 3 webps are deleted for everyone. links you shared stop working. this can't be
      undone." Fallback (a) message: "its 3 webps are deleted for everyone and their links stop
      working. the private copy and the video's public link stay on the server; delete those on the
      web." (section 3).
    - **While deleting**: the menu item and the primary button disable; a small inline progress
      line under the actions ("deleting…"). The app refuses to start while this media's own run is
      in progress on this device (focus, a detached render or keep-original on one of its
      sessions): the item is disabled with the footnote "still making a webp from this. try again
      when it's done." The server's 409 covers runs started elsewhere and shows the same line.
    - **Done**: the detail pops (zoom back), the planet fades out of the orbit (Reduce Motion: fade),
      the library drops the card, and a short status "deleted." shows on the screen underneath.
    - **Partial** (the server deleted some files and not others, or in fallback (a) some
      `DELETE /media` failed): nothing that was confirmed deleted comes back; local copies of the
      deleted renditions are removed; the detail stays open showing what is left as its tabs, with
      the inline error "couldn't delete all of it. 1 file is still there." and a `try again` button
      (the same call again: it is idempotent). Network failure before any answer: "couldn't delete
      that. it is still there." and `try again`.
    - Caveat said in the contract, not in the UI copy: deleted public files can still be served from
      Cloudflare's edge cache or a chat app's cache for a while (they are `immutable`, one year);
      purging the cache needs a zone API token the Worker does not have. Out of scope; same as
      today's per-file delete.
13. **(lane) Library: one card per media, chips, pushes the detail.** The card keeps preview (now
    the face: newest webp, else the video), title, meta; the role pills become **rendition chips**:
    `video` (outline, `film`; a trailing `link` glyph when hosted, `lock` when it is only a private
    copy) and `webp` / `webp ×3` (filled, `sparkles`). Tapping the card pushes `MediaDetail` on the
    face; tapping a chip opens that tab (`webp ×3` → newest webp). The in-place expansion with file
    rows is removed (tabbed renditions do not fit in a list row; one detail app-wide). Regular/wide:
    the split's detail column is `MediaDetail`. Counts subtitle unchanged ("15 posts · 24 files",
    the server's numbers).
14. **(lane) Storage limit by media.** Phase 1 (files, oldest added first) is unchanged per record,
    but protection covers **every record of the newest 12 media** (by `latestAt`) instead of the
    newest 12 records. Phase 2 (dropping posters/flipbooks) drops **whole media** only, oldest
    `latestAt` first, and only when all its records are file-less, so a media never loses its face
    record while keeping others. "13 videos · 54 MB" counts media with at least one file
    (`StorageUsage.mediaCount`), no longer webps as extra "videos".
15. **(lane) Photos sync unchanged.** Keys stay per file; the video syncs once per media
    (`s:<sid>`), webps once per rendition (`w:<url>`) when "include webps" is on (PhotoKit keeps a
    webp as a still, `CONTRACT-SYNC` G-W). A detail's `save to photos` records the same key.
16. **(lane) Run-scoped surfaces unchanged.** The share sheet's done state, the Live Activity,
    Dynamic Island and the notifications describe one run, which makes exactly one rendition: copy
    stays ("your webp is ready.", "webp ready"). Their deep link already lands on the focused media.
    No edits under `apple/CobaltShare/**` or `apple/CobaltWidgets/**` in this work.
17. **(lane) Web library page groups too (wave W2, optional).** A new web route
    `GET /api/library/posts?limit&cursor` proxies the API's `GET /library` through the existing
    service binding (`x-cobalt-service`; `lookupThen` already accepts it, `gate.ts:134-141`), and the
    page shows one tile per post with the same chips; the flat `/api/library` stays for the filters
    and back-compat. No API, D1 or Access change.

## 2. Surface table (every place a video and its webps appear separately today)

| surface | today | after |
|---|---|---|
| orbit planets (`HomeScreen.orbitVideos`, `OrbitView`) | one planet per file; video and each webp separate | one planet per media; face = newest webp, else video (1.4) |
| planet badge (`PlanetBadge`) | record's type + link dot + sparkles "has webp" dot | face type, `webp ×3` when 2+ webps, link dot (1.7) |
| orbit VoiceOver value and actions (`HomeScreen.swift:844-855`) | "13 videos · 54 MB" counting webps; "open <file name>" per file | media count; "open <title>, video and 3 webps" per media |
| home subtitle / settings "stored here" (`Copy.offline`) | `usage.count` = records with a file | `usage.mediaCount` (1.14) |
| star → planet birth | new planet per new file | new planet per new media only |
| focus result (`FocusView.swift:87-97`) | first stored webp of the session | this run's webp; the media's other webps untouched |
| focus close (`HomeScreen.swift:768-781`) | finds the original by session; webp may land as a 2nd planet | the media by `mediaID`, newest slot, new face (1.6) |
| planet tap → detail (`HomeScreen.swift:422-434`) | detail of that one file (a webp alone) | `MediaDetail` of the media, on the face tab |
| detail screens (`MediaDetail.swift`) | `PostDetail` (file rows) or `LocalMediaDetail` | one tabbed `MediaDetail` (1.8-1.12) |
| library compact (`LibraryList`) | card per post, expands to file rows | card per media with chips, pushes `MediaDetail` (1.13) |
| library regular/wide, Mac (`LibrarySplit`) | list + `PostDetail` | list + `MediaDetail` |
| library pills (`PostPills`) | webp / mp4 link / private | `video` (+ link / lock) and `webp ×N` chips |
| library preview (`PostPreview`) | local original, else first webp | face (newest webp, else video) |
| inspector "made from this video" (`Inspector.swift:22-26`) | library webp files of the session | `MediaItem` webps (local + server), `webp 1…n`, tap opens that tab |
| storage limit (`OfflineStore.enforce`) | newest 12 records protected; records dropped singly | newest 12 media protected; phase 2 drops whole media (1.14) |
| photos sync | per file keys | unchanged (1.15) |
| share sheet done state | the run's webp | unchanged; the webp joins its media by session (rule 1.2.2) |
| Live Activity / Dynamic Island / notifications | the run | unchanged (1.16) |
| debug `-previewDetail N` (`AppShell.swift:87`) | index into `store.videos` | index into `store.media` |
| search | none exists | none |
| web library page (`page.html:880`) | tile per file + studio tiles | tile per post with chips (W2, optional, 1.17) |
| server `GET /library` | one post per source with files | unchanged |
| deleting a whole post | web only (Access), file by file; the app can delete webps only | `delete everything` in the detail: `DELETE /library/items/<id>/post` (b), else per-webp fan-out (a) (1.12) |
| old app builds 1.0/1.1, web library page, upstream-style clients | — | unchanged: no existing route, response or row shape changes; deleted rows are soft-deleted exactly as the web's delete does, so every list just stops showing them |

## 3. Copy (lowercase, exact; new file `apple/Cobalt/Design/Copy+Media.swift`)

```swift
extension Copy {
    enum Media {
        static let video = "video"
        static let webp = "webp"
        static func webpTab(_ n: Int) -> String { "webp \(n)" }                  // 1-based, creation order
        static func webpCount(_ n: Int) -> String { n > 1 ? "webp ×\(n)" : "webp" }   // badge and chip
        static let tabsA11y = "which file"
        static func tabA11y(_ name: String, _ i: Int, of n: Int) -> String { "\(name), \(i) of \(n)" }
        static func planetA11y(title: String, webps: Int, hasVideo: Bool) -> String {
            let w = webps == 0 ? "" : (webps == 1 ? "1 webp" : "\(webps) webps")
            switch (hasVideo, webps) {
            case (true, 0): return "open \(title), video"
            case (true, _): return "open \(title), video and \(w)"
            default: return "open \(title), \(w)"
            }
        }
        static let makeAWebp = "make a webp"
        static let makeAnotherWebp = "make another webp"
        static let anotherWebp = "another webp"
        static let copyWebpLink = "copy webp link"
        static let copyVideoLink = "copy video link"
        static let publicShare = "public share"
        static let share = "share"
        static let savePhotos = "save to photos"
        static let copied = "copied"
        static let more = "more"
        static let deleteWebp = "delete this webp"
        static let deleteWebpTitle = "delete this webp for everyone?"
        static let deleteWebpMessage = "discord embeds stop working. the video and its other webps stay."
        static var removeWebpTitle: String { "remove this webp from this \(Copy.device)?" }
        static let removeWebpMessage = "the public link keeps working."
        static var removeMedia: String { "remove from this \(Copy.device)" }
        static var removeMediaTitle: String { "remove from this \(Copy.device)?" }
        static func removeMediaMessage(webps: Int) -> String {
            let what = webps == 0 ? "the video" : "the video and its \(webps == 1 ? "webp" : "\(webps) webps")"
            return "\(what) leave this \(Copy.device). your library and public links keep them."
        }
        static let deleteEverything = "delete everything"
        static let deleteEverythingTitle = "delete everything?"
        /// (b): "the video, its public link and its 3 webps are deleted for everyone. links you shared
        /// stop working. this can't be undone." Parts that do not exist are left out.
        static func deleteEverythingMessage(video: Bool, hosted: Bool, webps: Int) -> String {
            var parts: [String] = []
            if video { parts.append("the video") }
            if hosted { parts.append("its public link") }
            if webps > 0 { parts.append(webps == 1 ? "its webp" : "its \(webps) webps") }
            let list = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and " + parts.last! : (parts.first ?? "everything")
            let plural = parts.count > 1 || webps > 1
            return "\(list) \(plural ? "are" : "is") deleted for everyone. links you shared stop working. this can't be undone."
        }
        /// (a), an older server: only the webps can go.
        static func deleteEverythingFallbackMessage(webps: Int) -> String {
            let w = webps == 1 ? "its webp is" : "its \(webps) webps are"
            return "\(w) deleted for everyone and \(webps == 1 ? "its link stops" : "their links stop") working. the private copy and the video's public link stay on the server; delete those on the web."
        }
        static let deleting = "deleting…"
        static let deleted = "deleted."
        static func deletePartial(remaining: Int) -> String {
            "couldn't delete all of it. \(remaining == 1 ? "1 file is" : "\(remaining) files are") still there."
        }
        static let stillOnServer = "the private copy and the video's public link are still on the server. delete them on the web."
        static let deleteBusy = "still making a webp from this. try again when it's done."
        static let tryAgain = "try again"
        static let openInLibrary = "open in library"
        static let delete = "delete"
        static let remove = "remove"
        static let keep = "keep"
        static let deleteFailed = "couldn't delete that. it is still there."
        static func videoMeta(seconds: String?, size: String?, bytes: String?, when: String) -> String   // "14.8 s · 720×1280 · 4.3 MB · saved yesterday 13:59"
        static func webpMeta(range: String?, crop: String?, size: String?, bytes: String?, when: String) -> String // "00:02.0 → 00:12.0 · crop 1:1 · 480×480 · 2.4 MB · made today 20:52"
        static func cropBadge(_ aspect: String) -> String { "crop \(aspect)" }          // "crop 1:1", "crop" for free
    }
}
```
`videoMeta`/`webpMeta` join the non-nil parts with " · " and prefix `when` with "saved " / "made "
(`Format.when`). The range uses the existing `Copy.timecodeRange`; when no trim is known the webp
meta leads with `Format.seconds(duration)`.

## 4. Pinned CobaltKit API (additive; UI lanes build against exactly this)

### 4.1 Store (`Store/OfflineStore.swift`, new `Store/StoredMedia.swift`)

```swift
/// What a webp was made from, as the app sent it. Nil for webps made elsewhere or before this.
public struct WebpClip: Sendable, Codable, Equatable {
    public var start: Double
    public var length: Double
    public var crop: CropRect?          // nil = whole frame
    public var quality: WebpQuality?
    public var width: Int?              // requested width
    public init(start: Double, length: Double, crop: CropRect?, quality: WebpQuality?, width: Int?)
}

extension StoredVideo {
    public var mediaID: String          // never empty; derived for legacy records (1.3)
    public var clip: WebpClip?          // .webp only
}
// Record gains `mediaID: String?` and `clip: WebpClip?` (decodeIfPresent; nil in an old index).

public struct StoredMedia: Sendable, Equatable, Identifiable {
    public let id: String               // the mediaID
    public let original: StoredVideo?
    public let webps: [StoredVideo]     // oldest → newest by createdAt (tab order)
    public var face: StoredVideo { get }        // webps.last ?? original!  (a media is never empty)
    public var renditions: [StoredVideo] { get } // [original] + webps
    public var latestAt: Date { get }           // max createdAt
    public var sessionIDs: Set<String> { get }
    public var link: URL? { get }               // original's link, else the newest webp's
    public var title: String { get }            // original's name, else the face's name without ".webp"
    public var isHosted: Bool { get }           // original?.publicURL != nil
}

extension OfflineStore {
    public internal(set) var media: [StoredMedia]          // latest activity first; rebuilt in adopt()
    public func latestMedia(_ n: Int) -> [StoredMedia]
    public func media(id: String) -> StoredMedia?
    public func media(containing videoID: String) -> StoredMedia?
    public func media(session id: String) -> StoredMedia?   // any record with that sessionID
    /// `add` gains two trailing defaulted parameters; every existing call compiles unchanged.
    public func add(file: URL, kind: StoredVideo.Kind, media: MediaInfo, sessionID: String?,
                    link: URL?, remoteURL: URL?, move: Bool, publicURL: URL? = nil,
                    mediaID: String? = nil, clip: WebpClip? = nil) async throws -> StoredVideo
    /// Every record of the media (files, posters, flipbooks). False (nothing removed) when any of
    /// them is pinned by a running pipeline.
    @discardableResult public func removeMedia(_ id: String) async -> Bool
}
extension StorageUsage { public var mediaCount: Int }      // media with at least one file
```
`videos`, `latest(_:)`, `remove(_:)`, `evict(_:)`, `attach` keep their meaning (per record).
`backfillPreviewFrames()` works on the faces of `latestMedia(35)` first, then their originals.
`seed(_:)` (previews) keeps `mediaID`/`clip` of the seeds.

### 4.2 MediaItem (new `Models/MediaItem.swift`)

```swift
public struct Rendition: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable { case video, webp(number: Int) }   // number: 1-based, creation order
    public var id: String               // "video", else the local record id, else "f:<library file id>"
    public var kind: Kind
    public var local: StoredVideo?      // the device's record (kept or evicted)
    public var file: LibraryFile?       // .webp: its public file; .video: the private copy
    public var hosted: LibraryFile?     // .video only: the hosted mp4 link
    public var publicURL: URL?          // the webp's url, or the video's public link
    public var width: Int?
    public var height: Int?
    public var duration: Double?
    public var bytes: Int64?
    public var createdAt: Date
    public var clip: WebpClip?
    public var deletableName: String?   // the server's media_name when `DELETE /media/<name>` takes it
}

public struct MediaItem: Sendable, Equatable, Identifiable {
    public var id: String               // local mediaID, else "post:<post id>"
    public var local: StoredMedia?
    public var post: LibraryPost?
    public var service: String?
    public var ref: String?
    public var link: URL?
    public var renditions: [Rendition]  // video first (when any), then webps oldest → newest
    public var face: Rendition { get }  // newest webp, else video
    public var webpCount: Int { get }
    public var latestAt: Date { get }
    public func rendition(id: String) -> Rendition?
    /// Join rules: a local webp and a post file are one rendition when `remoteURL == file.url`;
    /// a local media and a post are one item when any local `sessionID` is `post.id` or
    /// `post.session?.id`, or any webp URL matches. The video rendition merges the local original,
    /// the post's private copy and its hosted link. A webp only on one side is kept.
    public static func merge(local: StoredMedia?, post: LibraryPost?) -> MediaItem?
}

extension AppModel {
    public func mediaItem(for local: StoredMedia) -> MediaItem     // joins library.posts
    public func mediaItem(for post: LibraryPost) -> MediaItem      // joins store.media
    /// "another webp" / "make a webp": home tab, focus on this media with the trim open; the run's
    /// webp joins this media (`Pipeline.targetMediaID`). Generalises `trimNewWebp(from:)`, which stays.
    public func makeWebp(for item: MediaItem) async
    /// Server delete when `deletableName` is set (then `library` drops the file), and the local record.
    public func deleteWebp(_ rendition: Rendition, of item: MediaItem) async throws
    /// `store.removeMedia`; false when a rendition is in use.
    @discardableResult public func removeFromDevice(_ item: MediaItem) async -> Bool
    /// True while this device runs something for the media (focus, a detached render, a
    /// keep-original on one of its sessions): `delete everything` is disabled.
    public func isBusy(_ item: MediaItem) -> Bool
    /// `delete everything` (1.12). (b) when `capabilities.deletePost` and the item has a post:
    /// `client.deletePost(anchor: post.files.first.id)`; else (a): `deleteMedia(name:)` for every
    /// webp with a `deletableName`, one at a time. Local records are removed for every rendition the
    /// server confirmed gone; on `.done` the whole local media goes (`store.removeMedia`) and
    /// `library` drops the post. Throws `PipelineFailure.serverBusy` for the server's 409 and the
    /// mapped failure when no answer came; never throws for a partial result.
    public func deleteEverything(_ item: MediaItem) async throws -> DeleteOutcome
}

public enum DeleteOutcome: Sendable, Equatable {
    case done                                         // (b) nothing left anywhere
    case partial(remaining: Int)                      // some files still on the server; retry is safe
    case leftOnServer(hostedLink: Bool, privateCopy: Bool)   // (a) finished: the webps are gone, these stay
}
```

### 4.2b Client and capabilities (`API/*`, `Models/Server.swift`)

```swift
extension Capabilities { public var deletePost: Bool }     // `features.delete_post`, false when absent

public struct PostDeleteResult: Sendable, Equatable, Decodable {
    public var deletedFiles: Int                           // `deleted.files`
    public var deletedBytes: Int64                         // `deleted.bytes`
    public var remaining: [String]                         // file ids still live; [] on success
}
// CobaltClient protocol gains (HTTPCobaltClient, PreviewClient and the test fakes implement it):
func deletePost(anchor itemID: String) async throws -> PostDeleteResult
```
`HTTPCobaltClient.deletePost`: `DELETE /library/items/<id>/post` with `Authorization: Api-Key`;
200 → result; 502 with `error.library.partial` → result decoded from the error body (not thrown);
409 `error.library.busy` → `CobaltError.api(code:httpStatus:)` mapped to
`PipelineFailure.serverBusy` (`ErrorMap.swift` gains the code; no new `PipelineFailure` case, so
no UI switch changes); 404 → `PipelineFailure.expired` (the post is gone already: treated as done
by `deleteEverything`). `PreviewClient` in `.renditions`: the first call answers partial with one
file remaining, the second succeeds (so the retry path previews and tests).

### 4.3 Pipeline (`Pipeline/*`)

```swift
extension Pipeline {
    public internal(set) var targetMediaID: String?   // set by makeWebp(for:), cleared with the run
    public var mediaID: String? { get }               // the run's media once anything is stored
}
```
`finishRender` passes `mediaID: targetMediaID` and `clip:` (the `RenderRequest` it sent: start,
length, crop, quality, width) to `store.add`. The keep-original paths pass `targetMediaID` too.

### 4.4 Preview data

New `PreviewScenario.renditions` (and `.happy` seeds it too): the store holds the instagram
`Dd7P496wolG` media (`PreviewData.long`: 14.77 s, 720×1280, 4,331,778 B) with three webps:
`PrEvIeW001.webp` 480×854, 10.1 s, 4,500,000 B, clip 0–10.1, no crop (the existing fixture);
`PrEvIeW005.webp` 480×480, 10.0 s, 2,371,210 B, clip 2.0–12.0, crop 1:1 (sizes of the real
`crop/e2e-dbg3/result.webp` render); `PrEvIeW006.webp` 480×600, 5.4 s, 1,600,000 B, clip 9.0–14.4,
crop 4:5 (synthetic). The library post gains the two new files. Plus a webp-only media (keep videos
off) and a plain save, so every face/badge case previews.

## 5. UI behaviour

- **Orbit** (`OrbitView` takes `[StoredMedia]`): planet id, `matchedTransitionSource` id and the
  player pool key are the **media id**. Box = face aspect (`OrbitGeometry.box(for: face)`); a face
  change springs the box to the new aspect and crossfades the picture (Reduce Motion: crossfade
  only). Tiers unchanged: front 3 play the face (a webp face uses `AnimatedImageView`, a video face
  a pooled player), inner bands flip the face's flipbook, outer bands its poster.
- **Focus**: the run's media is excluded from the orbit while focused (`store.media(session:)` /
  `pipeline.mediaID`); `finishClose` marks the media fresh; the focus player is adopted by the pool
  only when the face is still the video.
- **Detail** (`MediaDetail(model:item:initial:)`): section 1.9-1.12. Wide (iPad regular, Mac sheet
  ≥ 700 pt): two columns, tabs + hero left, a grouped `Form` right (meta as `LabeledContent` rows:
  length, trim, crop, size, bytes, made; the link row with copy/share icon buttons; the primary;
  the secondary row; the offline section). Delete confirmations are `confirmationDialog`s; a failed
  delete shows `Copy.Media.deleteFailed` inline under the actions and keeps the tab. `delete
  everything` follows 1.12 (`AppModel.deleteEverything`, `DeleteOutcome`): `.done` pops and fades
  the planet; `.partial` keeps the detail on what is left with `deletePartial` + `try again`;
  `.leftOnServer` pops and shows `stillOnServer` as the status underneath.
- **Library**: section 1.13; `PostPreview` takes a `MediaItem`; `FileRow.swift` is deleted once the
  detail no longer uses it (the per-rendition actions live in the detail).
- **Inspector**: "made from this video" lists `item.renditions` webps as rows `webp 1 · 480×854 ·
  4.5 MB`; tapping one opens `MediaDetail` on it.

## 6. Server

Already there and unchanged: `GET /library` grouping (`app-routes.ts:348-350`, `417-480`),
`DELETE /media/<name>.webp` (keyed), `POST /library/items/<id>/studio` (reopen). Not stored anywhere
server-side: a render's crop (DO job record only), so a webp made on another device shows size and
length but no "crop 1:1"; accepted (no migration). W2 web route is web-Worker-only (1.17).

### 6.1 New (additive): delete a whole post — `DELETE /library/items/<id>/post` (keyed)

Lane S writes this into `deploy/cloudflare/APP-API-CONTRACT.md` as section 12, verbatim.

- **Gate** (`gate.ts`, in the existing `/library/items/<id>/<sub>` block): sub `post`, method
  `DELETE` → `lookupThen(req, "library_post_delete", { id })`; any other method on `post` → 404.
  `<id>` is checked by the existing `^[A-Za-z0-9]{16}$` (else 404). Auth exactly like the other
  library routes: `Authorization: Api-Key <key>` (D1 lookup) or the web Worker's
  `x-cobalt-service` (key id `service:library`); missing/invalid key → the existing 401 codes.
  Answered by the Worker from D1 + R2 (`MEDIA`, `ORIGINALS`); the container and the DOs are never
  woken. No CORS (the web page does not call it; a later web change may, through the service
  binding).
- **Which post**: the anchor row is read **including soft-deleted rows**
  (`SELECT … FROM media_items WHERE id = ?1`; unknown → 404 `error.library.not_found`), and its post
  key is computed with the same `POST_KEY_SQL` as `GET /library`. The post's sessions are the
  `studio_sessions` whose list key (`CASE WHEN s.link LIKE 'upload:%' THEN substr(s.link, 8) ELSE
  s.id END`, `app-routes.ts:448`) equals that key.
- **Busy** → `409 {"status":"error","error":{"code":"error.library.busy"}}`, nothing changed: any of
  those sessions has `status = 'saving'` and `created_at > now − 15 min`, or a `studio_renders` row
  with `status = 'pending'` and `created_at > now − 15 min` (older pending rows are lost jobs and do
  not block).
- **Order** (each step idempotent):
  1. expire the post's sessions: `UPDATE studio_sessions SET expires_at = now WHERE id IN (…) AND
     expires_at > now` (no new render or source read can start: they answer 410, as today);
  2. for every live row of the post (`deleted_at IS NULL`), oldest first: `R2.delete(r2_key)` in its
     bucket (`media` → `MEDIA`, `originals` → `ORIGINALS`; deleting a missing object succeeds), then
     `UPDATE media_items SET deleted_at = now WHERE id = ? AND deleted_at IS NULL`. A row whose R2
     delete throws stays live and is reported in `remaining`;
  3. for each of the post's sessions, `ORIGINALS.delete(session.r2_key)` when set (covers an
     original with no row; failure is logged, not reported: its session is already expired, so it
     can no longer be read through any route).
- **Responses** (`cache-control: no-store`, JSON):
  - `200 {"status":"success","post":"<post key>","deleted":{"files":4,"bytes":12471210},"remaining":[]}`;
    a second call for the same post (or any anchor of it, deleted or not) → `200` with
    `"deleted":{"files":0,"bytes":0}`: **idempotent**, so the app's retry is always safe.
  - `502 {"status":"error","error":{"code":"error.library.partial"},"post":"…","deleted":{…},"remaining":["<item id>",…]}`
    when at least one row could not be deleted. Extra keys on an error body are additive; old
    clients never call this route.
  - `404 error.library.not_found`, `409 error.library.busy`, `400`-class gate rejections as today,
    `503 error.api.generic` when D1 itself fails before anything changed.
- **Capability**: `GET /capabilities` gains `features.delete_post: true` (`app-routes.ts:185`).
  Absent = false: the app uses fallback (a).
- **Accepted race**: a render POSTed in the instant between the busy check and step 1 can still
  finish and add one webp row; it shows as a one-webp post the owner can delete again.
- **Backward compatibility**: no existing route, gate decision, response shape, row shape or
  migration changes. Rows are soft-deleted exactly as the web's `itemDelete` does
  (`web/src/library.ts:596-615`), so the web library, `GET /library`, old app builds (1.0/1.1, which
  only list and per-webp delete) and plain cobalt clients (`POST /`) see nothing new except that
  deleted things are gone. `OriginalsBucket`/`PublishBucket` interfaces gain `delete(key)` (the real
  R2 binding has it; the test fakes add it).
- **Tests** (`test/library.test.ts`, real SQL on `node:sqlite`; `test/gate.test.ts`;
  `test/worker.test.ts`): a post of saved original + 2 studio webps + host mp4 → all rows soft-deleted,
  all four R2 keys deleted, sessions expired, `200` with the counts; second call → `200` zeros;
  anchored on an already-deleted row → same post; an upload post (`upload:<id>` session link) and a
  reopened saved session (renders stay in the original post) → whole post; a `/webp`-job post keyed
  by link → only its rows, another post with a different link untouched; a pending render < 15 min →
  `409`, nothing changed; a pending render > 15 min → proceeds; R2 delete throwing for one key →
  `502 error.library.partial`, that row live, the others deleted, retry → `200`; gate: 15/17-char id
  → 404, `GET/POST …/post` → 404, no key → 401, service header → allowed; `GET /library` after the
  delete no longer lists the post and `counts` drop; `/capabilities` has `delete_post: true`; the
  existing suites stay green (old routes unchanged).

## 7. SF Symbols (new `apple/Cobalt/Design/Symbols+Media.swift`; all checked to exist on macOS 26)

| use | symbol |
|---|---|
| video tab chip / compact face dot | `film` |
| webp chip / face dot / another webp | `sparkles` |
| hosted (chip glyph, planet dot) | `link` |
| private-only (chip glyph) | `lock` |
| more menu | `ellipsis.circle` |
| delete this webp | `trash` |
| delete everything | `trash` (destructive role, last in the menu) |
| remove from this iphone | `xmark.bin` (existing `Symbol.removeOffline`) |
| try again (partial delete) | `arrow.clockwise` (existing `Symbol.retry`) |
| copy link | `doc.on.doc` → `checkmark` |
| share | `square.and.arrow.up` |
| save to photos | `photo.badge.arrow.down` |
| public share | `link.badge.plus` |
| make a webp | `sparkles` |
| crop meta badge | `crop` |
| open in library | `photo.on.rectangle.angled` (existing `Symbol.library`) |

## 8. Lanes, waves, ownership

| wave | lane | owns (writes only these) | done when |
|---|---|---|---|
| W0 | A · CORE (`sonnet-lane`) | `apple/CobaltKit/**`; `apple/Cobalt/Design/Copy+Media.swift`, `apple/Cobalt/Design/Symbols+Media.swift` (verbatim from 3 and 7); in `apple/Cobalt/Screens/Home/MediaDetail.swift` **only** an added shim `init(model:item:initial:)` (the old `init(model:video:)` stays) forwarding to today's views via `item.local?.face`, so W1 lanes compile in parallel | section 4 compiles on iOS and macOS with every existing call site unchanged; section 9 CORE tests green; the app still builds and behaves as before |
| W0 ‖ | S · API (`sonnet-lane`) | `deploy/cloudflare/api/src/{gate,app-routes,worker,studio,publish}.ts` (the route, the capability flag, `delete` on the two bucket interfaces), `deploy/cloudflare/api/test/**`, `deploy/cloudflare/APP-API-CONTRACT.md` (new section 12, verbatim from 6.1), `deploy/cloudflare/README.md` (one line). Several of these files already carry uncommitted edits from earlier lanes: edit on top, never revert | `cd deploy/cloudflare/api && npm test && npm run typecheck` green with the 6.1 tests; `cf deploy --dry-run` builds. Deploying is the owner's |
| W1 | B · ORBIT (`sonnet-lane`) | `apple/Cobalt/Screens/Home/{HomeScreen,OrbitView,OrbitGeometry,PlanetBadge,FocusView,HeroFlight,StarView}.swift`, `apple/Cobalt/Screens/Home/Media.swift` | gates; `#Preview`s and sim evidence of section 9 B. `FocusView.swift` already has uncommitted edits from earlier lanes: edit on top, never revert |
| W1 ‖ | C · DETAIL (`sonnet-lane`) | `apple/Cobalt/Screens/Home/MediaDetail.swift` (rewrite), new `apple/Cobalt/Screens/Detail/**`, `apple/Cobalt/Screens/Home/Inspector.swift`, `apple/Cobalt/App/{AppShell,ShellActions,DebugHooks}.swift` | gates; `#Preview`s: 1, 2, 4, 6 renditions (segmented vs chip row), evicted webp, webp-only media, plain cobalt, wide two-column, AX5 Dynamic Type, delete confirm and failure, delete everything: confirm (b) and (a) wording, deleting, partial + try again, busy-disabled |
| W2 | D · LIBRARY (`sonnet-lane`) | `apple/Cobalt/Screens/Library/**` | gates; `#Preview`s compact / regular / wide with the `.renditions` scenario |
| W2 ‖ | W · WEB (`sonnet-lane`, optional) | `deploy/cloudflare/web/src/{index.ts,library.ts}`, `deploy/cloudflare/web/src/library/page.html` (+ regenerated `page.generated.ts`), `deploy/cloudflare/web/test/**` | `cd deploy/cloudflare/web && npm test && npm run typecheck`; headless screenshot of the page against a fixture |
| W3 | V · verification (`sonnet-lane`) | none (evidence to a session path) | section 9 V checklist, pass/fail per line |

Not touched by anyone: `apple/CobaltShare/**`, `apple/CobaltWidgets/**`, `apple/Cobalt/App/CobaltApp.swift`
(uncommitted edits from other work), `deploy/cloudflare/api/**` outside lane S's list, D1
migrations. CORE builds `deletePost` against the pinned 6.1 shapes with `PreviewClient` and a
`LoopbackServer` fixture, so S and CORE run in parallel; the app works against an undeployed
server through fallback (a). Rules as
`CONTRACT.md` 3: shared types only in CobaltKit; a UI lane that needs more API asks Fable;
`project.yml` is CORE's (new `Screens/Detail` folder is picked up by the existing source glob, CORE
confirms); no lane commits or pushes.

## 9. Gates, tests, evidence

**Gates** (every lane; Fable reruns): the four commands of `CONTRACT.md` section 9 (xcodegen; iOS
build on iPhone 17 Pro / iOS 26.5; macOS build; `cd apple/CobaltKit && swift test`), no `warning:`
lines from `apple/`. Lane W also `cd deploy/cloudflare/web && npm test && npm run typecheck`.

**CORE tests** (temp dirs, injected clock):
- grouping: original + 2 webps of one session = 1 media; face = newest webp; `latestAt` order; a new
  webp on an old media moves it first;
- order independence: webp added before its original (same session) → 1 media;
- explicit `mediaID` from a reopened session joins; a second original with an explicit id of a
  media that has one → its own media;
- two `OfflineStore` instances on one root adding the original and the webp of one session
  concurrently → 1 media (rule 2 inside the coordinated write);
- migration: a fixture `index.json` without `mediaID` (session group; reopened-session webp with
  the same link as exactly one original; same link on two originals → stays separate; picker
  originals with one link → separate; orphan webp) → the expected groups; run twice → same ids;
  a second instance reading it → same ids; no file touched;
- eviction: the newest 12 **media** protected; phase 2 drops whole media only when all file-less;
  `usage.mediaCount`;
- `removeMedia`: removes all records and files; refuses when a rendition is pinned;
- face fallback after removing the newest webp, then the last webp;
- `MediaItem.merge`: join by webp URL, by `post.id`, by `post.session.id`; video rendition merges
  private copy + hosted link + local; numbering by `createdAt`; local-only and server-only webps kept;
- `PhotosKey.of` unchanged for every fixture record (regression);
- pipeline: `finishRender` stores `clip` and `mediaID = targetMediaID`; `makeWebp(for:)` on an
  expired session goes through `POST /library/items/<id>/studio` (PreviewClient);
- decoding: an old `Record` (no `mediaID`, no `clip`) decodes; encode → decode round trip.
- delete everything: `capabilities.deletePost` from `features.delete_post` (present / absent);
  `HTTPCobaltClient.deletePost` against `LoopbackServer` for 200, 502 partial (decoded, not thrown),
  409 → `.serverBusy`, 404, 401; `AppModel.deleteEverything` (b) done → local media removed, post
  dropped from `library`; (b) partial → only confirmed renditions removed locally, retry → done;
  (a) without the flag → one `DELETE /media/<name>` per deletable webp, `.leftOnServer(hostedLink:
  privateCopy:)` true/false per what the post had, a failing webp → `.partial(remaining: 1)`;
  `isBusy` true while the pipeline's session belongs to the media; Photos ledger untouched.

**V checklist** (iPhone 17 Pro sim iOS 26.5, iPad sim, Mac; `-previewScenario renditions`; save
every screenshot/recording and the log):
1. orbit: one planet for `Dd7P496wolG` with `webp ×3`, showing the newest webp (`PrEvIeW006`,
   4:5); no second planet for the video; `-previewOrbitCount 30` badge spread;
2. focus: "another webp" from the detail → trim open on the same planet → make webp (preview
   timings) → shimmer → the planet's face is the new webp, `webp ×4`, newest slot; screen recording;
3. detail: each tab (video, webp 1-3), the chip row at 5+ renditions, evicted webp, delete confirm,
   delete failure (preview `renderBusy`-style failing delete), remove from this iphone; Reduce
   Motion; AX5 Dynamic Type; VoiceOver labels from the accessibility inspector;
3b. delete everything (`.renditions`): the confirm text, the partial state with `try again`, the
   retry finishing, the planet fading out and the library card gone; the same with the server's
   capability switched off (fallback message and `leftOnServer` result); disabled with the busy
   footnote while a preview render runs. Live server only after lane S is deployed by the owner,
   on a throwaway post made for the test, never on existing media;
4. library: compact card chips, tap card → detail on face, tap `video` chip → video tab; iPad
   split; Mac;
5. migration on a real device index: copy the owner's simulator/app-group `Videos/index.json`
   (or the fixture) into a clean sim container, launch, diff the index before/after (only
   `mediaID` added), orbit count = media count;
6. Photos ledger untouched by the migration (`Sync/photos.json` byte-identical).

## 10. Risks and owner questions

- **Q1 answered (owner, 2026-10-05): deleting a media deletes everything**, with backward
  compatibility kept: additive route + capability flag, fallback to per-webp deletes on an older
  server (1.12, 6.1). `remove from this iphone` stays as the space-only option.
- **Q2 answered (owner, 2026-10-05): sharing the same post again later makes a new media** (the
  server makes a new post for a new session too); "another webp" from the detail adds to an
  existing one. Merging by link would split from the server's grouping and misgroup carousel items.
- Deleted public files can linger in Cloudflare's edge cache and chat apps' caches (`immutable`,
  one year); a cache purge needs a zone token the Worker lacks. Same as today; not addressed.
- `delete everything` is irreversible and covers the private original: the confirm says so, it is
  the last, destructive item of a menu (never a swipe or a primary button), and the V lane only
  exercises it on a throwaway post.
- Mixed-version window: an old build of the share extension would drop the unknown `mediaID` key
  when it rewrites the index. App and extension ship in one bundle, and migration is
  deterministic, so only explicit joins (1.2.1, reopened sessions) could be lost; they re-derive
  through the link rule in most cases.
- A picker item's webp (`convertPickerItem` uploads it into a new adopted session) is a separate
  media from the picker item's saved original (no shared session). Accepted; rare.
- Planet box changes aspect when the face changes (9:16 video → 1:1 webp); band capacities are
  computed per box, so the orbit lane re-runs the `-previewOrbitAudit` numbers.

## 11. Mockup boards (session scratchpad `media-detail/project/`, merged into the canvas by Fable)

- `Media-Detail.dc.html` (iPhone 390×844): the tabbed detail; tabs switch hero/meta/actions;
  delete (first attempt fails on purpose, then works), "another webp" adds `webp 4` and the tabs
  turn into a chip row at 5; reset.
- `Media-Detail-iPad.dc.html` (iPad 1194×834): the wide two-column detail.
- `Media-Orbit.dc.html` (iPhone): today vs after on the orbit (duplicate planets vs one planet with
  `webp ×3`), and "make webp" changing the same planet.
- `Media-Library.dc.html` (iPhone): library cards with rendition chips; tapping opens the detail.
- The boards predate the 2026-10-05 answers and are not updated: their `more` menu shows "remove
  from this iphone" and "delete this webp" but not `delete everything`; section 1.12 is the source.
Stills are real: frames of `diag/source.mp4` (the `Dd7P496wolG` clip) and of the real cropped
render `crop/e2e-dbg3/result.webp` (webp 2). Webp 1 and webp 3 stills are cut from the source
video to stand in for renders that were not made.
