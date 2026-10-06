# cobalt for apple: photos first-class, galleries, and "make a video" (owner request, 2026-10-06)

Owner (verbatim): "https://www.instagram.com/p/Ddy0-gpGg5U/ in cobalt this wouldnt be able to be downloaded and why? and maybe
we can have it be able to work with gallery insta like this post which gets all media and then I can combine it into one video,
select just one to save or like save all individually?"
Follow-ups (verbatim, same day): "I think we should support photos not just video and like the flows etc (think of more that i
might want)"; "for the share sheet if it needs to choose multi files or need guidance of what to do then it like shows the
sheet?"; "I want you to mock all this up firstly"; "It can also support x gallery
https://x.com/ilokineedsleep/status/2106850389551374806?s=20".

## Owner decisions 2026-10-06 (answers to section 11)

1. **First release = "core + repost tools".** The v1 core (save all / pick / make a video, photos everywhere, copy text from
   photos, save and share several at once, copy all links, handle titles) **plus** the repost frame (9:16 / 1:1 with the blurred
   fill), crop a photo, and one long image / PDF export. These three move from v2 into v1: decisions 1.22-1.27, API 18.6.
2. **Paste choice screen: A**, the grid with every item ticked (decision 1.10).
3. **Gallery detail: B**, kind tabs + pager + thumbnail strip (decision 1.18).
4. **Share sheet with no answer after 8 s: save everything** (decision 1.12; the default, accepted).
5. **Galleries in a pasted batch or a Shortcut: save everything.** This reverses CONTRACT-PARALLEL owner question 3 ("first
   video"); that file's owner-decisions block says so. **Interim:** until the gallery server (section 18, `features.gallery`) is
   deployed, a batch and a Shortcut keep today's first-video behaviour, because an older server cannot save photos at all.
6. **Make-a-video defaults: auto length, crossfade, the post's own shape, no sound** (decision 1.15; accepted).

Still open, not asked: nothing. Owner question 1's remaining "later" list (collections, a public page per gallery, Live Photo →
webp, alt text, upscale) and the v2 list (music from another saved video, your own photos as one gallery, title from shared
text) stay out of this release.

**Status: designed and decided. Server lanes GS1 (helper) and GS2 (API + migration 0009) are dispatchable now (section 8.1-8.2).
App lanes wait for the CONTRACT-PARALLEL wave (L2 live, L3 shell, L4 home tray, L5 Shortcuts) and the library bug lane (owns
`Screens/Library/**`) to land.** Additive to
`CONTRACT.md`, `CONTRACT-MEDIA.md`, `CONTRACT-LIBRARY2.md`, `CONTRACT-VISIBILITY.md`, `CONTRACT-OFFLINE.md`, `CONTRACT-PARALLEL.md`,
`CONTRACT-SHARE-QUICK.md` and `deploy/cloudflare/APP-API-CONTRACT.md` (its **section 18**, written with this file). Code read on
2026-10-06 against the `apple-app` worktree, uncommitted state included. Marked **(owner)** where the owner asked, **(lane)** for
calls made here and open to review.

## 0. Why that post cannot be saved today (read and run, not assumed)

- **cobalt answers a picker.** `POST /` for `instagram.com/p/Ddy0-gpGg5U` returns `status: "picker"` with 10 items, all `photo`,
  no audio; for the X post `2106850389551374806`, `picker` with 4 `photo` items (both resolved by the coordinator on 2026-10-06
  with `scratchpad/ig-probe.mjs`, no media downloaded). Photo-only carousels are normal on Instagram, X, TikTok photo posts.
- **The server saves the first video of a picker, or nothing.** `helper/lib.js:611-620`: `items.find(video) ?? items.find(gif)`,
  else `JobError("error.webp.no_video")` (test `api/test/helper.test.ts:494-510`). So the share sheet (which goes straight to
  `POST /studio`), a pasted batch and a Shortcut all fail on a photo carousel.
- **The app's picker can only send photos to Photos.** `PipelineFlows.swift:435-437` turns a picker into `.picker(items:)`;
  `savePickerItems` (`:753-791`) downloads each item and calls `savePhoto` (the camera roll); a photo is never stored in cobalt,
  the library or Files. `convertPickerItem` (`:793-809`) only takes video/gif (`PickerItem.canWebp`, `Wire.swift:44`). Nothing lands
  as a media: no planet, no library post, no link.
- **A single-photo link is saved as a broken video.** cobalt answers `redirect`/`tunnel` with a jpeg; the helper's fetch probes it
  (`helper/server.js:412-416`), and ffmpeg reports a jpeg as a video stream, so the probe passes; `videoExt` (`lib.js:201-208`) knows
  no image type and returns `mp4`; the Durable Object coerces any non-video type to `video/mp4` (`studio.ts:1989-1993`). Checked
  here by running the helper's own `parseVideoInfo` on ffmpeg's output for a 1080×1350 jpeg: `{"duration":0.04,"width":1080,
  "height":1350}`, `videoExt` → `mp4`. Result: `originals/<sid>.mp4`, `video/mp4`, a 0.04 s "video". Not run against the live server.
- **Photos already exist in one place:** an image upload (`PUT /studio/upload` of png/jpeg/heic/webp) is stored as a private row
  and stops there (`app-routes.ts:345-351`: "Images stop here"); posters skip images until `CONTRACT-VISIBILITY` decision 7's P2.
- **The data model already groups by session.** `GET /library` makes one post per `COALESCE(<upload link>, session_id, link, id)`
  (`app-routes.ts:440-442`), so N rows that share a session are one post with no new grouping code.
- **Telemetry categories are a closed list** (`TELEMETRY-CONTRACT.md:27`); an unknown `cat` rejects the whole batch.

## 1. Decisions

### Model

1. **(owner, lane) Photos are first-class media.** A *media* (CONTRACT-MEDIA 1.1) is one source with:
   - **items**: 1 to 20 originals, in the source's order: photos, videos, gifs (a single video post is one video item, exactly
     today's media; a single photo post is one photo item; a gallery is 2+ items);
   - **made renditions**: webps (as today), **videos made from it** (the slideshow, 1.15), **crops** of a photo (1.23) and
     **exports** (the long image and the PDF, 1.25). Repost frames are made on demand and not kept (1.24).
   CONTRACT-MEDIA's "at most one video rendition" becomes "at most one original **per item**".
2. **(lane) A gallery is ONE media.** One paste, one share, one Shortcut run = one media, one planet, one library tile, one title,
   one public switch, one delete. Reasons: the server already groups by session (section 0); the owner thinks of the post, not its
   slides ("save all individually" is served by per-photo actions inside it); ten planets for one carousel would bury the orbit.
3. **(lane) The choice is keyed off cobalt's answer, never the site.** `picker` with 2+ items → a gallery; one item (`redirect`,
   `tunnel`, or a 1-item picker) → a single media. Instagram carousels, X multi-photo and mixed tweets, TikTok photo posts, Reddit
   galleries, Bluesky: same code path.
4. **(lane) Server storage**: one studio session per save (as today), N `media_items` rows sharing its `session_id`, each with
   `item_index` (0-based) and `role 'item'`; private originals in R2 `cobalt-originals` at `originals/<sid>-<nn>.<ext>` (`nn` two
   digits); photos keep their real type (`image/jpeg`, `png`, `webp`, `heic`); each photo row gets a **thumb** (`poster`, a 480 px
   wide public unguessable JPEG, CONTRACT-VISIBILITY 7) made inside the same helper job, so no extra helper slots. Visibility per
   row as CONTRACT-VISIBILITY (public by default from the app: one mirror per item). The session's `r2_key` names the **lead item**
   (the first video, else item 0), so every existing session reader keeps working. Migration `0009_gallery.sql`, additive
   (APP-API-CONTRACT 18.1).
5. **(lane) Old app builds in the field (1.0-1.7) see one file per post.** `GET /library` without `v=3` lists a gallery as its lead
   item plus its webps (what those builds can draw); other items, made videos and crops are left out of that shape. New builds send
   `v=3` and get everything (APP-API-CONTRACT 18.4). Requests without the new `items` field behave exactly as today, except that a
   single photo is now stored as a photo (fixing section 0's bug; an old build then shows an image session it cannot play, which is
   no worse than the 0.04 s clip it plays today).
6. **(lane) Titles** (`MediaTitle.resolve`, CONTRACT-LIBRARY2 1.1, one added rule): a link save's default is `service · @handle`
   when the link names an author (`x.com/<handle>/status/<id>`, `tiktok.com/@<handle>/…`), else `service · ref` as today; cobalt's
   `twitter` service displays as `x`. So the X post is **`x · @ilokineedsleep`** and the Instagram one **`instagram · Ddy0-gpGg5U`**
   (an Instagram `/p/` link names no author). Tweet text as a title is not available: cobalt's response carries no text and the
   upstream `api/` stays untouched; the text an app shares alongside a link is v2 (owner decision 1). Items are named
   `photo 3 of 10` / `video 2 of 4` in the UI and `03.jpg` on disk (8).
7. **(lane) Uploads.** A photo picked from Photos arrives as JPEG (`PHPickerConfiguration.preferredAssetRepresentationMode =
   .compatible`), so public links open in Discord and browsers; the HEIC stays in Photos. Each picked file is its own media in v1;
   "these photos as one gallery" is v2 (needs upload grouping on the server; owner decision 1 keeps it out).
8. **(lane) On this iPhone (CONTRACT-OFFLINE).** A kept single photo is a flat file in the visible root (`IMG_2207.jpg`); a kept
   **gallery is a folder** named by the title (`instagram · Ddy0-gpGg5U/` with `01.jpg … 10.jpg`, `video.mp4`, `webp 1.webp`), the
   folder carrying the media's extended attribute so a rename in Files is followed (OFFLINE decision 6) and a rename in cobalt renames
   the folder while the owner has not (decision 8). Keep and remove act on the whole media. "keep videos on this iphone" becomes
   **"keep saves on this iphone"** (same setting key). Mac (`FolderSync` until wave M): the same folder layout under
   `~/Movies/cobalt`. Photos app: unchanged rule (album off by default, owner's "Files only"); "save to photos" per photo, per
   selection and "save all to photos" from the detail; ledger keys `g:<sid>:<n>` for items, `m:<url>` for a made video.
9. **(lane) Telemetry**: no new category (an older server would reject the batch). Events in `pipeline`: `gallery choice`
   (`{items, photos, videos, choice: all|some|video, picked}`), `gallery saved` (`{items, failed}`), `slideshow start|done|fail`
   (`{items, seconds, frame, fade, code?}`); in `share`: `share choice` (`{waited_ms, choice}`).

### The flows (every entry point decides the same way)

10. **(owner) Paste in the app (focus): option A, "grid, all ticked"** (board `Gallery-Paste`; owner decision 2). One screen: every
    item ticked; `save all 10` is the one prominent button (`save 3 of 10` after unticking; disabled with "pick at least one" at 0);
    `make a video` is the second; `cancel`. X's 4 items show as 2×2, 5+ as a 4-column grid (scrolls past 12). A single item never
    asks: it saves at once, as a video does today. The save is one job in the server's line (CONTRACT-PARALLEL), shows "saving 4 of
    10", and lands as one planet.
11. **(lane) Partial saves keep what they got.** An item that fails to download (Instagram item links are signed and expire) leaves
    the rest saved; the media shows it as "photo 7 couldn't be fetched" with `try again`, which asks the server to **re-resolve the
    post** and fetch only the missing indices (APP-API-CONTRACT 18.3); a post whose item count changed answers
    `error.studio.gallery_changed` ("the post changed since; open it in the app to pick again").
12. **(owner) Share sheet: notification only, unless there is a choice; 8 s unanswered saves everything (owner decision 4)** (board `Share-Gallery`). The extension (app group or
    not: every path is one server request) reads the link and sends `POST /` (cobalt's resolve, the stored key) **and** `GET
    /capabilities` together:
    - **answer within 700 ms**: one item → today's instant share (`POST /studio`, the local notification, close; nothing shown);
      a picker → the **choice sheet** appears once, at the height of its content (318 pt for 10 photos): title and count, a strip of
      thumbnails, `save all 10` (prominent), `make a video` (3 s a photo, crossfade, as posted; one tap, no settings), `pick…` (grows
      once to a grid with ticks and `save 3 of 10`).
    - **no answer at 700 ms**: a one-row card (116 pt): "checking the link" (after 2.5 s "waking the server · 4 s"), the link's title,
      `save everything now`, and close. When the answer comes it either closes itself (one item: "sent to cobalt") or grows **once**
      into the choice sheet. The sheet changes height at most once per decision, never empty space (the owner's two complaints).
    - **no answer at 8 s**: `POST /studio {items: "all"}` and close with the notification "saving everything to cobalt · open
      cobalt to pick later" (nothing is lost; deleting is cheap later).
    - a server without `features.gallery`: the one-line card "this server can't save photo posts yet" with `open cobalt` / close.
    Budgets pinned: 700 ms and 8 s. The resolve is one cobalt call (warm: typically well under a second; a cold container took 6 s in
    CONTRACT-SHARE-QUICK's measurements); not measured from the extension on a device.
13. **(owner, decision 5) Batch paste and Shortcuts save everything** (from the deploy of `features.gallery`; until then they
    keep today's first-video behaviour, which is all an older server can do). A gallery in a pasted batch or a Shortcut has nobody to ask: the server saves
    all items. This **reverses CONTRACT-PARALLEL owner question 3's default** ("first video"), which loses every photo post (owner
    decision 5). Shortcuts "Save links" gains one parameter, `Galleries`: `save everything` (default) · `first video only` · `make a
    video` (3 s a photo, crossfade, as posted). A gallery returns one `CobaltSave` with `kind` (`video|photo|gallery`), `itemCount`
    and `itemLinks: [URL]` (the public links, in order). "Get latest saves" `Kind` gains `photos` and `galleries`. No new action in v1.
14. **(lane) Plain cobalt (no fork server)** keeps today's picker (save to Photos) for galleries; single photos save to Photos.

### Make a video (the slideshow)

15. **(owner; defaults accepted, decision 6) A video made from the items, in the same media.** Board `Gallery-Combine`. The sheet: a live preview that plays the
    real plan, a timeline (one segment per item, proportional), and four controls:
    - **each photo**: `auto` (default) · `2 s` · `3 s` · `5 s`; tap a segment, then `−`/`+` (0.5 s steps, 1 to 15 s) to set one
      ("set by you"; `auto` puts it back).
    - **auto rule** (lane): Live Text on the device counts each photo's words; a photo with no text gets **3 s**, text gets
      **2 s + 0.2 s a word, clamped to 3–8 s**. The "What is JEV?" carousel's stand-in counts give 57 s instead of a flat 30 s. Where
      no reading is possible (share sheet, Shortcuts) the plan is 3 s a photo.
    - **between**: `cut` · `crossfade` (default, 0.3 s; the length stays the sum of the slides).
    - **frame**: `as posted` (default: the most common item aspect, 1080 on the short side; 4:5 → 1080×1350) · `9:16` (1080×1920)
      · `1:1` (1080×1080). An item of another shape sits on a **blurred, darkened copy of itself** (no black bars, nothing cut).
    - **sound**: `none`; `the videos' own` when the post has videos (photos silent); `from a saved video` is v2 (disabled, "later").
    - Videos and gifs in a mixed post play their own length (a gif once) and cannot be stretched.
    - Summary: length, size, estimated server time; over **3:00** the button is disabled with the reason before anything is sent.
16. **(lane) It runs on the server's helper, in the server's line.** One job kind `slideshow` (APP-API-CONTRACT 18.5): the Durable
    Object streams each item's original into the helper, the helper composes each still once, crossfades and encodes, the DO stores
    the result as a `role 'slideshow'` row of the same post (private original + public mirror per the post's visibility, a poster).
    From the app's screen it carries `priority: "focused"` (ahead of waiting saves, CONTRACT-PARALLEL 2.4); closing the sheet never
    stops it (the tray shows it); the result is a `video` tab in the detail, and "make a webp" from it is the existing focus flow.
17. **(lane) Measured cost of the pinned recipe** (section 6.3; one local run on an M4 Pro core, ffmpeg 9.0.1 from Homebrew (the container uses ffmpeg-static; not compared), 10
    synthetic 1080×1350 stills, 43 s): constant 30 fps 12-16 s (noisy); **variable frame rate with duplicate frames dropped (kept at
    least every 0.5 s): 2.3 s, 0.92 MB, duration 42.97 s for a planned 43.00 s**. The container is a `basic` instance
    (`api/cloudflare.config.ts:20`); assuming it is about 8× slower, a 57 s slideshow takes about 30 s there. Not measured on the
    container; mixed posts (real video frames) are not measured at all.

### Presentation

18. **(owner) Detail: option B, "kind tabs + pager"** (board `Gallery-Detail`; owner decision 3). Tabs at the top as CONTRACT-MEDIA
    1.9: `photos 10` · `video` · `webp` (made renditions after the items; `video 1`, `video 2` and `webp 1…` when several). The photos
    tab: a pager (arrows, swipe, `3 / 10` on the photo) and a strip of thumbnails (current outlined, a missing one red with `!`). One
    prominent button: `copy photo link` when public, `share` when private, `try again` on a missing photo; secondary row `share` ·
    `to photos` · `copy text`. Meta `photo 3 of 10 · 1080×1350 · 206 KB · saved today 14:02` and the link under it. A `public · 12
    links` switch for the whole media (items and made videos; webps keep their own switch, CONTRACT-VISIBILITY 6). `more`: rename ·
    make a video · repost frame… · long image / pdf… · select photos (strip ticks; share / to photos / delete N) · save all to photos · copy all links · delete this photo
    · delete everything. Deleting the last photo becomes "delete everything".
19. **(lane) One photo** (board `Photo-Detail`): the same screen without the strip: zoom (double-tap, pinch), `text` (Live Text
    highlight, `copy text`), link, public switch, Photos, share; `crop` (v1, 1.23) makes a **new rendition** and never rewrites the
    original. A photo inside a gallery has the same `crop` in its secondary row (the third button becomes `crop`, `copy text` moves
    under the photo as on this board).
20. **(lane) Library** (board `Library-Mixed`): one tile per media. A gallery tile is its cover with a count badge (stack glyph +
    `10`, no length); a photo tile says `jpg`; videos and webps as today. A **kind row** of chips above the mosaic: `all` · `videos`
    · `photos` · `galleries` · `webps`, each with its count; it combines with "on this iphone" and with sort (new sort key `kind`:
    galleries, photos, videos, webps). The table gains a kind column (`gallery · 10 · 57.0 s · 4.3 MB`). An empty combination says
    "no galleries kept on this iphone yet." with `show everything`. Subtitle `10 posts · 25 items` (the server's counts).
21. **(lane) Orbit** (board `Orbit-Photos`): a photo planet is the still at its aspect with `jpg` (no player, no flipbook); a gallery
    planet is its face with two card edges behind and a stack + count badge instead of a type; in the front band it turns through
    its items every 3 s (crossfade; Reduce Motion: holds photo 1); inner bands show the face. Face rule (CONTRACT-MEDIA 1.4,
    extended): newest webp, else newest made video, else item 0. VoiceOver: "open instagram Ddy0-gpGg5U, 10 photos, a video and a
    webp".

### Repost tools (v1, owner decision 1)

22. **(lane) One renderer on the device, three uses.** `FrameRenderer` (CobaltKit, Core Image + ImageIO, no server) draws a photo
    into a frame: aspect `1:1` · `4:5` · `9:16` · `3:4` · `free` (crop only), fill `cut` (a movable, zoomable rectangle; outside it is
    cut) or `blur` (the whole photo centred on a blurred, darkened copy of itself: the same look as the slideshow, CIGaussianBlur
    radius 24 at 1080 px, brightness −0.08). Output JPEG, quality 0.9, sRGB, 1080 px on the short side (never upscaled past the
    source's long side ×1.0; a smaller source keeps its size). It runs on the device because it needs no ffmpeg, the source is
    already local (kept file, or the thumb-then-original download the detail does anyway), it answers in well under a second, and it
    keeps the helper (one job at a time) for saves and encodes. Not measured on a device.
23. **(owner) Crop a photo → a stored rendition.** From the photo viewer (a single photo, or one photo of a gallery). Frame chips,
    fill segmented control, drag/pinch the rectangle in `cut`; `save crop`. The JPEG uploads with `PUT /library/items/<item id>/made`
    (APP-API-CONTRACT 18.6) as `role 'crop'`, `made_from` = that item, `made_spec` = `{"aspect":"9:16","fill":"blur","rect":[x,y,w,h]}`
    (normalised 0-1 of the source). It appears as a tab (`crop 9:16`; on a gallery, under the photo's strip cell a small `1 crop`
    badge and in the photos tab's pager as `photo 3 · crop 9:16`), is public or private with the media's switch, gets a server poster,
    can be deleted alone (`delete this crop`), and is kept offline with the media (1.27). Failure: the upload fails → stays in crop
    mode with "couldn't upload the crop. the photo is unchanged." and `save crop` again (board `Photo-Detail`). Plain cobalt / no
    `features.gallery`: `save crop` becomes `save to photos` (nothing stored server-side).
24. **(owner) Repost frame → made on demand, not stored.** From a gallery's `more` (or a photo's `more`): pick `9:16` or `1:1` (and
    `4:5`), fill `blurred bars` (default) or `cut to fit`, then `save this one` (Photos), `all 10` (every photo to Photos, one
    `PHPhotoLibrary` change, `photosKey` none: these are new files the owner asked for) or `share` (the share sheet with the files).
    Nothing is uploaded and no rendition is created: reposting wants files in Photos, ten extra server files per carousel would
    clutter the media, and any one frame can still be kept by making it a crop (`keep in cobalt` on the single-photo screen calls
    1.23 with the same spec). Videos in a mixed post are skipped with "2 videos skipped" (framing video is the webp flow's crop).
25. **(owner) One long image / PDF → a stored export rendition.** From a gallery's `more`: `long image` or `pdf`.
    - **long image**: the photos stacked top to bottom in post order, each scaled to a common width (1080, or the narrowest
      photo's width when smaller), no gaps; JPEG 0.85. Height cap 30,000 px: past it the width is scaled down so the whole post fits
      (10 × 1350 = 13,500 fits at 1080). Videos are skipped (their poster is not a photo of the post); a video-only gallery hides it.
    - **pdf**: PDFKit; page size from the photos' shape (one photo per page, page = the photo's aspect at 72 dpi width 595 pt:
      reading order, the right default for text carousels) **or** `6 a page` (A4, 3×2 contact sheet with `photo n` captions). Default
      **one a page**; the board shows the contact sheet (`More-Ideas`). The PDF's title metadata = the media's title; when a photo's
      Live Text was read, its lines are drawn over it in invisible text (`CGContext.setTextDrawingMode(.invisible)`) so the PDF is
      searchable and copyable; unread photos are image-only.
    - Both upload as `role 'export'`, `made_from` = the item ids used, `made_spec` = `{"kind":"long"|"pdf","layout":"one"|"six"}`;
      they appear as a tab after the made videos (`long image`, `pdf`); one of each per media: making it again replaces the old one
      (the old row is deleted after the new one is stored). Public by the media's switch (a PDF link opens in Safari and Discord
      shows it as a file). Sizes: about 2.6 MB for the long image, 1.9 MB for the 6-a-page PDF of the 10 slides (estimates).
26. **(lane) Public/private, posters.** Crops and exports follow the media's one switch (1.18) like items; the server makes a poster
    for a crop and a long image (an image poster, APP-API-CONTRACT 18.2's poster fix); a PDF has no server poster and the app draws
    its first page locally.
27. **(lane) Offline (CONTRACT-OFFLINE).** Crops and exports are kept with the media: in a gallery's folder as `03 · crop 9:16.jpg`,
    `long image.jpg`, `<title>.pdf`; for a single photo, flat beside it as `IMG_2207 · crop 9:16.jpg` (FolderNaming's `<title> ·
    <rendition>` pattern). Repost frames are not kept (1.24). Mac `FolderSync` copies the same names.
28. **(lane) Shortcuts: no new action.** `CobaltSave.madeLinks: [URL]` lists the public links of made videos, crops and exports
    (newest first) next to `itemLinks`; "Get latest saves" can return them. A "frame for repost" action is not in v1: Shortcuts'
    own image actions already resize and crop.

## 2. Surface table

| surface | today | after |
|---|---|---|
| paste a gallery (app) | picker: save items to Photos only | grid, all ticked; save all / some / make a video; one media |
| paste one photo | saved as a 0.04 s mp4 (fork) | saved as a photo media |
| batch paste, Shortcuts | server takes the first video, else fails `no_video` | server saves everything (Shortcuts parameter) |
| share sheet, one item | instant share | unchanged |
| share sheet, gallery | server takes the first video, else fails | resolve first; the compact choice sheet; 8 s cap saves everything |
| orbit | one planet per file; galleries absent | photo planets; one gallery planet with count, turning in front |
| library | videos and webps | + photos, galleries; kind chips, kind sort, kind column |
| detail | video + webp tabs | + photos tab with pager and strip; one-photo viewer; per-photo actions |
| on this iphone / Mac folder | flat files | a folder per gallery; photos as files |
| Photos app | picker items only | per photo / selection / all, by hand; album off by default (unchanged) |
| public links | per file | per photo; one switch per media; "copy all links" |
| delete | per webp, delete everything | + delete one photo / a selection / a crop / an export; delete everything covers items and everything made |
| crop a photo | the video crop only (webps) | on device; stored as a `crop` rendition tab |
| repost frame | — | on device; 9:16 / 1:1 / 4:5, blurred bars or cut; to Photos or share, not stored |
| long image / pdf | — | on device; stored as an `export` rendition tab, public by the media's switch |
| old builds 1.0-1.7 | — | see a gallery as its lead item; nothing else changes |

## 3. Copy (lowercase, exact; new `apple/Cobalt/Design/Copy+Gallery.swift`)

```swift
extension Copy {
    enum Gallery {
        static func saveAll(_ n: Int) -> String { "save all \(n)" }
        static func saveSome(_ k: Int, of n: Int) -> String { "save \(k) of \(n)" }
        static let pickOne = "pick at least one"
        static let tickAll = "tick all", untickAll = "untick all"
        static let allTickedHint = "all ticked: tap a photo to leave it out"
        static let makeVideo = "make a video", makeTheVideo = "make the video", makeAnother = "make another"
        static func count(photos: Int, videos: Int) -> String   // "10 photos", "2 photos + 2 videos", "1 photo"
        static func saving(_ i: Int, of n: Int) -> String { "saving \(i) of \(n)" }
        static func itemName(_ kind: String, _ i: Int, of n: Int) -> String { "\(kind) \(i) of \(n)" }   // "photo 3 of 10"
        static func notFetched(_ name: String, kept: Int) -> String { "\(name) couldn't be fetched: the link expired. the other \(kept) are saved." }
        static func tryItemAgain(_ name: String) -> String { "try \(name) again" }
        static let galleryChanged = "the post changed since. open it to pick again."
        static func photosTab(_ n: Int) -> String { n == 1 ? "photo" : "photos \(n)" }
        static let copyPhotoLink = "copy photo link", copyText = "copy text", toPhotos = "to photos"
        static let selectPhotos = "select photos", saveAllToPhotos = "save all to photos", copyAllLinks = "copy all links"
        static let deletePhoto = "delete this photo"
        static func deletePhotoTitle(_ i: Int) -> String { "delete photo \(i) for everyone?" }
        static let deletePhotoMessage = "its public link stops working. the other photos, the video and the webp stay."
        static func publicLinks(_ n: Int) -> String { "public · \(n) links" }
        static let privateNoLinks = "private · no links"
        // make a video
        static let eachPhoto = "each photo", between = "between", frame = "frame", sound = "sound"
        static let auto = "auto", cut = "cut", crossfade = "crossfade", asPosted = "as posted", setByYou = "set by you"
        static func autoWhy(words: Int, seconds: String) -> String { words == 0 ? "no text found" : "\(words) words read on this \(Copy.device) → \(seconds)" }
        static let soundNone = "none", soundOwn = "the videos' own", soundSaved = "from a saved video"
        static func tooLong(_ len: String) -> String { "too long: \(len). the server makes up to 3:00. shorten the slides or untick the long video." }
        static func making(_ pct: Int) -> String { "making the video · \(pct)%" }
        static let makeFailed = "couldn't make the video (the server's encoder stopped). the photos are untouched and your settings are kept."
        static func videoReady(_ len: String) -> String { "video ready · \(len)" }
        // share sheet
        static let checkingLink = "checking the link"
        static func wakingServer(_ s: Int) -> String { "waking the server · \(s) s" }
        static let saveEverythingNow = "save everything now", pick = "pick…", pickSub = "choose which to keep"
        static func shareVideoSub(_ len: String) -> String { "3 s a photo · crossfade · \(len)" }
        static let savingEverything = "saving everything to cobalt", pickLater = "open cobalt to pick later"
        static func savingPhotos(_ n: Int) -> String { n == 1 ? "saving 1 photo to cobalt" : "saving \(n) photos to cobalt" }
        static let makingVideoInCobalt = "making a video in cobalt"
        static let serverNoGallery = "this server can't save photo posts yet"
        static let serverNoGallerySub = "update the server, or open cobalt to save them to Photos."
        // library
        static let kindAll = "all", kindVideos = "videos", kindPhotos = "photos", kindGalleries = "galleries", kindWebps = "webps"
        static func galleryKind(_ n: Int) -> String { "gallery · \(n)" }
        static func nothingHere(_ what: String, kept: Bool) -> String { "no \(what)\(kept ? " kept on this \(Copy.device)" : "") yet." }
        // repost tools
        static let crop = "crop", saveCrop = "save crop", keepInCobalt = "keep in cobalt", deleteCrop = "delete this crop"
        static let fillCut = "cut to fit", fillBlur = "whole photo, blurred bars", fillBlurShort = "blurred bars"
        static func cropTab(_ aspect: String) -> String { "crop \(aspect)" }                      // "crop 9:16"
        static let cropFailed = "couldn't upload the crop. the photo is unchanged."
        static let cropIsNew = "a crop is a new file in this media (a tab); the photo stays as it was."
        static let repostFrame = "repost frame", saveThisOne = "save this one"
        static func saveAllFrames(_ n: Int) -> String { "all \(n)" }
        static func videosSkipped(_ n: Int) -> String { n == 1 ? "1 video skipped" : "\(n) videos skipped" }
        static let longImage = "long image", pdf = "pdf", onePerPage = "one a page", sixPerPage = "6 a page"
        static let makeAndShare = "make and share", replaceExport = "this replaces the one made before."
        static let exportFailed = "couldn't make that. nothing was changed."
    }
}
```

## 4. Pinned CobaltKit API (additive; UI lanes build against exactly this)

```swift
// Models/Wire.swift
public enum GalleryChoice: Sendable, Equatable, Codable {
    case all                               // "items": "all"
    case some([Int])                       // "items": [0, 3]  (picker indices, ascending, unique)
    case firstVideo                        // "items": "first-video"  (today's server behaviour)
}
public struct SlideshowPlan: Sendable, Equatable, Codable {
    public enum Frame: String, Sendable, Codable { case asPosted = "keep", story = "9:16", square = "1:1" }
    public enum Sound: String, Sendable, Codable { case none, own }
    public var items: [Int]                // picker / item indices in order
    public var seconds: [Double?]          // per item; nil for video/gif (own length)
    public var fade: Bool                  // crossfade 0.3 s
    public var frame: Frame
    public var sound: Sound
    public static func auto(for items: [GalleryItem], words: [Int?]) -> SlideshowPlan   // 6.2 rule; nil words = 3 s
    public var totalSeconds: Double { get }                                            // sum (videos: their length)
    public static let maxSeconds: Double = 180
}
public struct GalleryItem: Sendable, Equatable, Identifiable {
    public var id: Int                     // index in the post
    public var type: MediaType             // .photo / .video / .gif
    public var width: Int?, height: Int?, duration: Double?
    public var thumb: URL?                 // picker thumb or the photo itself (may expire)
}
extension Capabilities { public var gallery: Bool }       // features.gallery

// API/Client.swift (CobaltClient gains; HTTPCobaltClient, PreviewClient and the fakes implement)
func createStudio(url: URL, options: StudioCreateOptions) async throws -> StudioCreated   // options gain `items: GalleryChoice?`, `slideshow: SlideshowPlan?`
func retryItems(session: String, items: [Int]) async throws -> StudioCreated              // POST /studio/<sid>/items/retry
func makeSlideshow(session: String, plan: SlideshowPlan, focused: Bool) async throws -> RenderAccepted   // POST /studio/<sid>/slideshow
func deleteItem(_ itemID: String) async throws                                             // DELETE /library/items/<id>
func setPostVisibility(anchor itemID: String, public: Bool) async throws -> VisibilityResult  // PATCH …/visibility {"scope":"post"}

// Pipeline: a picker becomes `.gallery(items: [GalleryItem])` (replaces `.picker` when caps.gallery; plain cobalt keeps .picker)
extension Pipeline {
    public func saveGallery(_ choice: GalleryChoice) async        // one job in the line; progress "saving i of n"
    public func saveGalleryThenVideo(_ plan: SlideshowPlan) async // save all, then the slideshow job (focused)
}

// Store (Store/OfflineStore.swift, StoredMedia.swift): Record gains `itemIndex: Int?`, `role: Role?` (.item, .slideshow, .crop,
// .export) and `madeFrom: [Int]?`;
// decodeIfPresent; an original with itemIndex joins its media by sessionID (CONTRACT-MEDIA 1.2 rule 2), one per index.
extension StoredMedia {
    public var items: [StoredVideo]        // by itemIndex
    public var made: [StoredVideo]         // slideshows, crops, exports, oldest → newest
    public var isGallery: Bool { get }     // items.count > 1
    public var kind: MediaKind { get }     // .video, .photo, .gallery
}
public enum MediaKind: String, Sendable { case video, photo, gallery, webp }   // webp: a webp-only media

// Models/MediaItem.swift: Rendition.Kind gains `.item(index: Int, type: MediaType)`, `.made(number: Int)` (slideshows),
// `.crop(of: Int, spec: FrameSpec)` and `.export(ExportKind)`;
// MediaItem gains `items`, `made`, `kind`, `itemCount`, `missing: [Int]` (items the server reports failed).
extension AppModel {
    public func retryMissing(_ item: MediaItem) async throws
    public func makeSlideshow(_ item: MediaItem, plan: SlideshowPlan) async throws
    public func deleteItems(_ indices: [Int], of item: MediaItem) async throws    // the last one → deleteEverything (refused here)
    public func setPublic(_ on: Bool, for item: MediaItem) async throws           // scope post
    public func copyAllLinks(_ item: MediaItem) -> String                         // one per line, item order
    public func saveToPhotos(_ indices: [Int], of item: MediaItem) async throws
}

// Media/LiveTextReader.swift (new): VisionKit/Vision on device, `.fast` level.
public enum LiveTextReader { public static func words(in image: URL) async -> Int?; public static func text(in image: URL) async -> String? }

// Media/FrameRenderer.swift (new): Core Image + ImageIO, on device, pure function of (source, spec).
public struct FrameSpec: Sendable, Equatable, Codable {
    public enum Aspect: String, Sendable, Codable { case square = "1:1", portrait = "4:5", story = "9:16", classic = "3:4", free }
    public enum Fill: String, Sendable, Codable { case cut, blur }
    public var aspect: Aspect
    public var fill: Fill
    public var rect: CGRect?            // normalised 0-1 of the source; cut only (nil = centred, largest that fits)
}
public enum FrameRenderer {
    /// JPEG 0.9, sRGB, 1080 on the short side (never upscaled). Throws on an unreadable source.
    public static func render(_ source: URL, spec: FrameSpec, to: URL) async throws -> (width: Int, height: Int, bytes: Int64)
}
// Media/ExportRenderer.swift (new): CoreGraphics / PDFKit, on device.
public enum ExportKind: String, Sendable, Codable { case long, pdf }
public enum PDFLayout: String, Sendable, Codable { case one, six }
public enum ExportRenderer {
    public static func longImage(_ photos: [URL], to: URL) async throws -> (width: Int, height: Int, bytes: Int64)  // 30,000 px cap
    public static func pdf(_ photos: [URL], text: [String?], title: String, layout: PDFLayout, to: URL) async throws -> (pages: Int, bytes: Int64)
}
// API: CobaltClient gains
func uploadMade(item itemID: String, role: MadeRole, file: URL, contentType: String, name: String, spec: Data) async throws -> LibraryFile  // PUT /library/items/<id>/made
public enum MadeRole: String, Sendable, Codable { case crop, export }
extension AppModel {
    public func saveCrop(_ item: MediaItem, index: Int, spec: FrameSpec) async throws          // render → upload → store as a made record
    public func repostFrames(_ item: MediaItem, indices: [Int], spec: FrameSpec, to: RepostTarget) async throws -> Int   // .photos / .share; returns videos skipped
    public func makeExport(_ item: MediaItem, kind: ExportKind, layout: PDFLayout) async throws   // replaces the previous one of that kind
}
public enum RepostTarget: Sendable { case photos, share }

// MediaTitle: resolve(…) gains `handle: String?` (from LinkInfo); LinkInfo gains `handle` for x.com/<h>/status and tiktok.com/@<h>.
// Shortcuts/ShortcutActions.swift: SaveLinksIntent gains `galleries: CobaltGalleries` (.everything default, .firstVideo, .video);
// CobaltSave gains kind, itemCount, itemLinks, madeLinks; CobaltSaveKind gains .photos, .galleries.
```

## 5. UI behaviour (boards in section 12 are the source; each board says what it demonstrates)

- **Focus** (`FocusView`): `.gallery` shows the grid panel above the orbit (veiled), not the trim hero. After saving, the hero is the
  cover with two card edges and `open` (prominent) / `make a video` / `close`; a partial save shows the error line and `try photo
  7 again`.
- **Combine sheet** (`Screens/Combine/CombineSheet.swift`): `.sheet` large detent from the focus result, the detail's `more` and the
  video tab's empty state; preview uses the device's thumbs (or originals when kept) and the plan's timings (crossfade drawn as an
  opacity ramp); the timeline is a row of buttons sized by seconds, each VoiceOver-labelled "photo 3, 8.0 s".
- **Detail**: section 1.18-1.19; wide (iPad, Mac): the CONTRACT-MEDIA two-column layout, the strip under the hero, the actions in the
  form column.
- **Library**, **Orbit**: sections 1.20-1.21.
- **Share extension**: section 1.12; `SheetFitter` sets the height of the checking card, the choice sheet and the grid exactly.

## 6. The slideshow recipe (pinned for lane GS1; checked locally in `scratchpad/gallery/probe/`)

1. **Compose each still once** at the frame size (`W×H`): `[0:v]split=2[b][f];[b]scale=W:H:force_original_aspect_ratio=increase,
   crop=W:H,boxblur=24:2,eq=brightness=-0.08[bg];[f]scale=W:H:force_original_aspect_ratio=decrease[fg];[bg][fg]overlay=(W-w)/2:
   (H-h)/2,setsar=1` → one JPEG (`-frames:v 1 -q:v 2`). A still whose aspect equals the frame skips the blur.
2. **Sequence**: each still `-loop 1 -framerate 30 -t <seconds + 0.3 except the last>`; `format=yuv420p`; chained `xfade=transition=
   fade:duration=0.3:offset=<sum of previous seconds>` (or `concat` for cut); video items enter as their own decoded stream scaled
   and padded the same way (blurred fill), audio from them when `sound: own`, `anullsrc` for stills.
3. **Encode**: `mpdecimate=hi=64:lo=32:frac=0.33:max=15`, `-fps_mode vfr`, `libx264 -preset veryfast -tune stillimage -crf 20
   -pix_fmt yuv420p -movflags +faststart`. Without `max=15` the last slide's tail is dropped (measured: 40.83 s for 43 s); with it the
   output is within 0.05 s of the plan. Test: output duration = plan ± 0.1 s.
4. **Limits**: 2-20 items, total ≤ 180 s, output ≤ 200 MB (`MAX_SOURCE_BYTES`), a job timeout of 10 min; 1 GiB memory (stills are
   composed one at a time).
5. **Estimates the app shows** (labelled "about"): size 0.025 MB/s for stills and 0.25 MB/s for video at 1080×1350 (scaled by
   pixel count); server time 5 s + 0.45 s per second of stills + 2.5 s per second of video (container assumed 8× the local run).

## 7. Server

`deploy/cloudflare/APP-API-CONTRACT.md` **section 18** is the wire. In short: migration `0009_gallery.sql` (nullable columns
`media_items.item_index`, `role`, `made_from`, `made_spec`, `post_key`; `studio_sessions.item_count`, `items`;
`studio_renders.kind`, `plan`); `POST /studio` takes `items`, `item_count`, `slideshow`; photos stored as photos (the 0.04 s mp4 fix)
with posters; `POST /studio/<sid>/items/retry`; `POST /studio/<sid>/slideshow` (a line job, focused priority allowed); `PUT
/library/items/<id>/made` (crops and exports made on the device); `GET /library?v=3`; `DELETE /library/items/<id>` for one item or
made file; `PATCH …/visibility` with `"scope": "post"`; the helper's internal wire (18.7); `features.gallery`.

## 8. Lanes, waves, ownership

Server lanes **GS1** and **GS2** can be dispatched now: they touch none of the app files the CONTRACT-PARALLEL wave is editing, and
they build in parallel against the helper wire pinned in APP-API-CONTRACT 18.7 (GS2 fakes the helper). App lanes start only after
the CONTRACT-PARALLEL wave (L2 live, L3 shell, L4 home tray, L5 Shortcuts) **and** the library bug lane (owns
`apple/Cobalt/Screens/Library/**`) have landed and been gated.

| wave | lane | owns (writes only these) | done when |
|---|---|---|---|
| now | **GS1 · HELPER** (`sonnet-lane`) | 8.1 | 8.1's gates |
| now ‖ | **GS2 · API + 0009** (`sonnet-lane`) | 8.2 | 8.2's gates |
| after GS2 (optional) | GS3 · WEB (`sonnet-lane`) | `deploy/cloudflare/web/src/library/page.html` (+ generated), `deploy/cloudflare/web/src/index.ts`, `deploy/cloudflare/web/test/**` except what GS2 touched | gallery tiles with a count, per-item download, crop/export files listed; `npm test && npm run typecheck` in web |
| G0 (after the PARALLEL wave) | G0 · CORE (`sonnet-lane`) | `apple/CobaltKit/**` except `Share/**` and `Shortcuts/**`; `apple/Cobalt/Design/{Copy+Gallery,Symbols+Gallery}.swift`; `apple/project.yml` | section 4 compiles on iOS and macOS with every existing call site unchanged; section 9 CORE tests green |
| G1 | G1a · FOCUS + ORBIT | `apple/Cobalt/Screens/Home/**` except `MediaDetail.swift`, `Inspector.swift` | gates; previews of the A grid (10, 4, 1), saving, partial, gallery and photo planets, Reduce Motion |
| G1 ‖ | G1b · DETAIL + TOOLS | `apple/Cobalt/Screens/Detail/**`, `apple/Cobalt/Screens/Home/{MediaDetail,Inspector}.swift`, new `apple/Cobalt/Screens/Combine/**`, new `apple/Cobalt/Screens/Tools/**` (crop, repost frame, long image / pdf sheets) | gates; previews of every Gallery-Detail (B), Photo-Detail, Gallery-Combine and More-Ideas (repost, long image, pdf) state, failures included |
| G1 ‖ (after the library bug lane) | G1c · LIBRARY | `apple/Cobalt/Screens/Library/**` | gates; previews mosaic / table / empty with the gallery scenario |
| G1 ‖ | G1d · SHARE | `apple/CobaltShare/**`, `apple/CobaltKit/Sources/CobaltKit/Share/**`, `apple/CobaltKit/Tests/CobaltKitTests/InstantShare*` | the 700 ms / 8 s budgets on a fake clock; the sheet heights; one request per choice; the old-server card |
| G1 ‖ (after L5) | G1e · SHORTCUTS | `apple/Cobalt/Intents/**`, `apple/CobaltKit/Sources/CobaltKit/Shortcuts/**`, their tests | the `Galleries` parameter (default save everything; first-video while `features.gallery` is absent), `CobaltSave` additions, latest-saves kinds |
| G2 | V · verification (`sonnet-lane`) | none (evidence to a session path) | section 9 V checklist, pass/fail per line, every screenshot and log path |

Rules as CONTRACT.md 3: shared types only in CobaltKit; a UI lane that needs more API asks Fable; nobody commits or pushes. Not
touched by anyone here: upstream `api/` and `web/` outside `deploy/`, `apple/CobaltWidgets/**`.

### 8.1 Dispatch brief: GS1 · helper (paste as is)

> **Lane GS1 (helper) for cobalt photos and galleries.** Worktree `/Users/harmony/cobalt/.claude/worktrees/apple-app`. Read first:
> `apple/CONTRACT-GALLERY.md` sections 0 and 6, and `deploy/cloudflare/APP-API-CONTRACT.md` section 18, especially **18.7 (your
> wire, exact)**. Do not commit or push. Do not deploy.
>
> **You own only:** `deploy/cloudflare/api/helper/server.js`, `deploy/cloudflare/api/helper/lib.js`, `deploy/cloudflare/api/test/helper.test.ts`
> (and a new `deploy/cloudflare/api/test/helper-gallery.test.ts` if you prefer a separate file). Fixtures are generated at test
> time with the bundled ffmpeg into a temp dir; commit no binary fixtures. Everything under `deploy/cloudflare/api/src/**` belongs to
> lane GS2, running in parallel: do not edit it; if 18.7 is ambiguous, stop and report the question.
>
> **Build:**
> 1. `sniffType(head)` in `lib.js` (JPEG, PNG, WebP `RIFF????WEBP`, HEIC/HEIF ftyp brands `heic heix hevc mif1 msf1`, GIF as today) and use
>    it in the fetch job for every downloaded file: an image gets `contentType image/jpeg|png|webp|heic`, `ext jpg|png|webp|heic`,
>    `duration: null`, width/height from the probe; anything else keeps today's video path (`videoExt`). **This fixes the bug where a
>    single-photo link is stored as a 0.04 s `video/mp4`** (`server.js:412-430` probes a jpeg as a 1080×1350, 0.04 s video and
>    `videoExt` returns `mp4`).
> 2. The 1-item-picker rule: without `items`, a picker with exactly one item saves it whatever its type; 2+ items keep today's rule.
> 3. `POST /fetch` takes `items` (`"all"` | `"first-video"` | 1-20 unique ascending ints) and `item_count`; saves the chosen items
>    one after another in the same job, each sniffed, probed and (photos) given a 480 px JPEG thumb; per-item failures recorded, the job
>    fails only when all failed; `item_count` ≠ picker length → `error.studio.gallery_changed`. `GET /fetch/:id` gains `picker_count`,
>    `items`, `item`, `items_done`, `items_total`; `GET /fetch/:id/file?i=` and `GET /fetch/:id/thumb?i=`. Lead = first saved video,
>    else first saved item. Limits: 200 MB per item, 500 MB per job; `DELETE /fetch/:id` removes everything.
> 4. `POST /poster`: an image body is answered from frame 0 (no `-ss`). Today `posterTime(0.04)` = 0.004 s seeks past the only
>    frame and ffmpeg writes nothing (checked with ffmpeg 9.0.1: no output file) → `422 error.poster.failed`.
> 5. The slideshow routes of 18.7 (`PUT /slideshow/:id/inputs/:n`, `POST /slideshow/:id/start`, `GET /slideshow/:id`, `GET …/file`,
>    `DELETE`), holding the helper like an upload (the existing `busy()` rule, `server.js:178`), reaped after 5 min idle, 10 min job
>    timeout. Recipe exactly as CONTRACT-GALLERY section 6: compose each still once (blurred fill unless the aspect already matches),
>    `xfade` 0.3 s chain or `concat`, video inputs scaled/padded with the same fill (audio kept only with `sound: "own"`, `anullsrc`
>    under stills), `mpdecimate=hi=64:lo=32:frac=0.33:max=15`, `-fps_mode vfr`, `libx264 -preset veryfast -tune stillimage -crf 20
>    -pix_fmt yuv420p -movflags +faststart`. Progress `composing` (stills done / stills) then `encoding` (seconds from ffmpeg's
>    `-progress` / total). Write the argv builders as pure functions in `lib.js` (like `buildPosterArgs`) so tests assert them.
>
> **Tests (real ffmpeg where marked):** `sniffType` for each signature and a short/garbage head; **a single jpeg fetched through a
> `redirect` answer comes back `image/jpeg`, `jpg`, `duration: null` (regression for the 0.04 s mp4)**; a 1-item photo picker saves
> it; a 3-item picker with `items: "all"` where item 2 answers 403 → 2 done + 1 error, job done, lead correct; `items: [0,2]` fetches
> only those; `item_count` mismatch → `gallery_changed`; `"first-video"` = today; thumbs exist, are JPEG, longer side ≤ 480 (real
> ffmpeg); poster of a jpeg → 200 JPEG (real ffmpeg); slideshow (real ffmpeg, generated 1080×1350 and 1200×1200 stills, a 2 s
> generated video with a sine tone): duration = plan ± 0.1 s for fade and for cut; frame sizes for keep / 1080×1920 / 1080×1080; a
> 1:1 still in a 9:16 frame has non-black pixels in the bar area (the blur); `sound: "own"` keeps one audio stream, `none` has none;
> 429 while another job holds the helper; inputs over the cap → 413; start with a missing input → 409; reaper frees the helper.
> Existing helper tests stay green (change none of their expectations except where 18.7 says the behaviour changes).
>
> **Gates:** `cd deploy/cloudflare/api && npm test && npm run typecheck`. Report: files changed, test counts before/after, the
> slideshow durations and sizes your tests measured, and anything in 18.7 you could not do as written. Unverified (say so): that
> the container's `ffmpeg-static` has `xfade`, `mpdecimate`, `boxblur` (log `ffmpeg -filters` availability in a test if the
> static binary is what the tests run).

### 8.2 Dispatch brief: GS2 · API + migration 0009 (paste as is)

> **Lane GS2 (API) for cobalt photos and galleries.** Worktree `/Users/harmony/cobalt/.claude/worktrees/apple-app`. Read first:
> `apple/CONTRACT-GALLERY.md` sections 0, 1 and 7, and `deploy/cloudflare/APP-API-CONTRACT.md` section 18 (**your wire, exact**),
> plus 12, 13, 16 and 17 (the routes you extend). Do not commit, push, deploy or apply the migration remotely.
>
> **You own only:** `deploy/cloudflare/d1/migrations/0009_gallery.sql` (new, verbatim from 18.1);
> `deploy/cloudflare/api/src/{studio.ts,line.ts,app-routes.ts,gate.ts,library.ts,poster.ts,worker.ts,webp.ts,publish.ts}`;
> `deploy/cloudflare/api/test/**` **except** `helper.test.ts` / `helper-gallery.test.ts` (lane GS1's); the one `POST_KEY_SQL`
> constant in `deploy/cloudflare/web/src/library.ts` (line 101) and a test for it in `deploy/cloudflare/web/test/`;
> `deploy/cloudflare/README.md` (one line). The helper (`api/helper/**`) is GS1's, running in parallel: build against the internal
> wire in **18.7** with a fake helper in your tests; do not edit the helper. If 18 is ambiguous, stop and report the question.
>
> **Build (each item is a subsection of 18):**
> 1. Migration 0009 (18.1). Every copy of the post key gains `COALESCE(m.post_key, …)` (grep `POST_KEY_SQL` and
>    `substr(s.link, 8)` in `api/src` and `web/src`; `SESSION_POST_KEY_SQL` stays session-based).
> 2. `POST /studio` `items` / `item_count` / `slideshow` validation and passing them to the helper's `POST /fetch`; finalize stores
>    N item rows (`originals/<sid>-<nn>.<ext>`, `role 'item'`, `item_index`, `post_key`, thumb → poster URL), per-row public, the
>    session's `item_count` / `items` / lead `r2_key`; the content-type check keeps `image/*` (**the 0.04 s mp4 fix, server side:
>    `studio.ts:1989-1993` coerces every non-video type to `video/mp4`**); the adopt regex widening; `GET /studio/<sid>` additions;
>    `POST /studio/<sid>/items/retry` (18.2).
> 3. `isPosterType` takes images (18.2); image uploads get a poster.
> 4. `GET /library?v=3` and the legacy collapse (18.3).
> 5. `DELETE /library/items/<id>`; `PATCH …/visibility` `scope: "post"` (18.4).
> 6. `POST /studio/<sid>/slideshow`: validation, frame decision, line entry `kind: "slideshow"` (class rules of 17.2), render row
>    `kind 'slideshow'`, the pump starting it (stream inputs, start, poll, store, poster, `result:`), phases on `GET
>    /studio/<sid>/render/<job>`, failures (18.5). The share/Shortcuts `slideshow` on `POST /studio` enqueues it after the save.
> 7. `PUT /library/items/<id>/made` (18.6): gate (`sub === "made"`, `PUT` only), validation before the body, streamed R2 put,
>    the row, visibility, poster job, export replace.
> 8. `features.gallery: true` in `/capabilities` (18.8); the new error codes.
>
> **Tests (`node:sqlite`, real SQL, fake helper, fake R2):** migration applies on top of 0001-0008 and old queries still run; the
> post key with `post_key` set and NULL; `items` validation table (every bad shape → 400, nothing created); a 10-photo gallery →
> 10 rows, keys `-00…-09`, `post_key`, thumbs as posters, per-row public mirrors when `public: true`, lead `r2_key`; a 3-item save with
> one failed item → 2 rows, `items` JSON records the error, `GET /library?v=3` `items_failed: [1]`; `gallery_changed`; retry fetches
> only missing indices; **a single jpeg from the helper is stored as `image/jpeg`, `originals/<sid>.jpg`, `duration NULL`, with a
> poster (regression for the 0.04 s mp4)**; v=3 vs legacy: an old-build request (no `v`) sees one file for a gallery post, `v=2`
> too, `v=3` sees all items, slideshows, crops, exports in order with `kind: "gallery"`; delete one item (R2, mirror, poster refcount,
> purge), last item → 409, a webp → 409 `not_deletable`; post-scope visibility on 10 rows incl. one failing → 502 partial, retry → 200;
> slideshow: validation table, too long → 400, 1 item → 409, focused class 0 vs class 1 ordering with a waiting save, phases,
> result row (`role 'slideshow'`, `made_from`, `post_key`, visibility of the lead), helper error → render `error`, item missing in
> R2 → `error.studio.missing`; made: crop on a photo item → 201 row (`source 'made'`, `r2_key made/<id>.jpg`, `made_from`,
> `post_key`), crop on a video → 409 `not_photo`, bad content-type / spec > 512 B / over 50 MB → 400/413 before reading the body,
> export long then export long again → the first is deleted (`replaced`), export pdf alongside stays, a crop of an image upload
> (no session) groups into that upload's post in `GET /library`; gate: `PUT …/made` only, `DELETE` bare path only, other methods
> 404, keys as today; `features.gallery`; section 12's delete-the-post removes items and made rows; the web `POST_KEY_SQL` groups a
> made row with its post. Existing suites stay green.
>
> **Gates:** `cd deploy/cloudflare/api && npm test && npm run typecheck`; `cd deploy/cloudflare/web && npm test && npm run
> typecheck`; `cd deploy/cloudflare/api && cf deploy --dry-run` builds. Report: files changed, test counts before/after, every place
> 18 was unclear or you deviated (with why), and the dry-run result. The remote migration and deploy are the owner's.

## 9. Gates, tests, evidence

- **Gates**: CONTRACT.md 9's four commands; the API and web suites (8.1, 8.2); no `warning:` lines from `apple/`.
- **Server tests**: the lists in 8.1 and 8.2.
- **CORE tests**: `GalleryChoice`/`SlideshowPlan` encoding (`items: "all" | [..] | "first-video"`); `SlideshowPlan.auto` (0 words →
  3 s; 4 → 3 s; 18 → 5.6 s; 32 → 8 s; videos nil); `totalSeconds`; > 180 s refused; picker → `.gallery` when `caps.gallery`, `.picker`
  otherwise; a 1-item picker → single save; batch/Shortcut `items: "all"` only with `caps.gallery` (else no `items`: first video);
  store: items join one media by session, one original per index, `kind`, crops/exports as made records; legacy index decodes;
  `MediaItem.merge` with items, made, crops, exports, missing; `MediaTitle` handle rule (x, tiktok, instagram unchanged); Photos keys.
  **FrameRenderer** (rendered pixels from generated test images): 9:16 blur of a 4:5 source is 1080×1920 with non-black bar pixels;
  cut with a rect gives that region; a 600 px source is not upscaled; aspect `free` keeps the rect's shape. **ExportRenderer**: long
  image of 10 1080×1350 = 1080×13500; 30 photos are scaled to fit 30,000 px; videos skipped; PDF one a page = N pages with the photos'
  aspect, 6 a page = ceil(N/6) A4 pages, title metadata set, invisible text extractable with `PDFDocument.string` when given.
  `uploadMade` against `LoopbackServer`: query, headers, 201/400/409/413 mapping; `makeExport` replaces locally on `replaced`.
- **V checklist** (iPhone 17 Pro sim iOS 26.5, then the owner's phone; preview server first, a live server only after GS1/GS2 are
  deployed by the owner, on throwaway posts): 1 paste the Instagram carousel → grid → save all → one planet, one library tile, a
  folder in Files; 2 untick to 3 → 3 items; 3 the X tweet → 2×2 → `x · @ilokineedsleep`; 4 a single photo link → a jpg planet that
  opens the photo viewer (the 0.04 s mp4 bug gone); 5 make a video (auto, crossfade, as posted) → `video` tab, length = plan ± 0.1 s,
  public link plays in Safari; 6 a partial save (preview scenario) → try again; 7 share sheet: reel = notification only; carousel =
  choice sheet; screen recording of the cold-server card growing once; 8 Shortcuts Save links → 10 links; 9 an old build (1.6 IPA)
  against the new server lists the gallery as one file; 10 delete one photo, delete everything; 11 crop photo 3 to 9:16 blur → a
  `crop 9:16` tab, its public link opens a 1080×1920 JPEG, the file in the media's Files folder; 12 repost frame all 10 at 1:1 → 10
  new photos in Photos, nothing new in the library; 13 long image and pdf → two tabs, making the long image again replaces it, the
  PDF opens in Files and its text is searchable.

## 10. Risks and what is not verified

- Not measured: the container's encode time, the extension's resolve time and memory on a device, Live Text speed on 10 photos,
  sheet heights on a device (the boards' pt values are the mock's). The 8× container factor is an assumption.
- Instagram item links expire within hours; a gallery saved much later than it was resolved re-resolves server-side (it always
  does: the server resolves the link itself), so only the app's grid thumbnails can go blank.
- Storage: public by default mirrors every photo (twice the bytes of a photo; photos are small next to the 317 MB of video today).
- A post edited between the app's resolve and the server's (items added or removed) could shift indices: the server compares the
  count it sees with `item_count` sent by the client and answers `error.studio.gallery_changed` instead of saving the wrong items.
- `mpdecimate` on real video items keeps their motion frames, so mixed posts cost close to a normal encode; not measured.
- Upstream cobalt may change picker shapes; the design reads only `type`, `url`, `thumb`, which have been stable.

## 11. Owner questions

All answered 2026-10-06 (block at the top). Nothing open.

## 12. Boards (session scratchpad `gallery/project/`; generator `gallery/src/`, checks `gallery/validate.mjs`)

All iPhone (390×844 device in a 712×844 board with review controls); every interaction is listed on its board with the claim it
demonstrates; each has a reset and a dark toggle. No Instagram or X image is used: slides are neutral placeholders; slide 1's title
("What is JEV?") is the post's, the other word counts are stand-ins. `node validate.mjs`: 9 boards, 501 checks (structure, every
binding in every state reached, behaviour on a fake clock, text contrast in light and dark, every `var()` defined), 0 failures.
Screens rendered with headless Chrome through the test runtime; screenshots in `gallery/shots/`. Mac boards were not made.

| board | shows |
|---|---|
| `Gallery-Paste.dc.html` | paste → A / B / C choice; Instagram 10, X 4 (2×2), mixed, one photo, a reel; partial save + retry; server busy |
| `Gallery-Combine.dc.html` | make a video: live preview of the plan, timeline, per-slide length, auto rule, cut/crossfade, frame + blurred fill, sound, too long, line, failure, done |
| `Gallery-Detail.dc.html` | the gallery detail A / B / C; missing photo + retry; public switch; select + delete; delete one; delete everything |
| `Share-Gallery.dc.html` | share sheet: warm, cold (checking card grows once), X, reel, one photo, 8 s cap, older server; a timeline log with ms |
| `Photo-Detail.dc.html` | one photo: zoom, Live Text, crop as a new rendition (blur or cut), upload failure (v1 per owner decision 1) |
| `Library-Mixed.dc.html` | mosaic and table with photos and galleries; kind chips with counts; sort by kind; "on this iphone"; empty state |
| `Orbit-Photos.dc.html` | today (the 0.04 s mp4 planet, the carousel nowhere) vs after (photo and gallery planets, turning, Reduce Motion) |
| `More-Ideas.dc.html` | copy text (one photo, all photos), repost frame, long image / PDF (its notes predate owner decision 1: repost frame and long image / PDF are v1 now, and the PDF default is one a page, the board draws the 6-a-page layout) |
| `Shortcuts-Gallery.dc.html` | Save links with the Galleries parameter and its result; Get latest saves kinds |
