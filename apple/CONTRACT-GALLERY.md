# cobalt for apple: photos first-class, galleries, and making things from them (owner request 2026-10-06, reworked 2026-10-07)

Owner (verbatim, 2026-10-06): "https://www.instagram.com/p/Ddy0-gpGg5U/ in cobalt this wouldnt be able to be downloaded and why?
and maybe we can have it be able to work with gallery insta like this post which gets all media and then I can combine it into one
video, select just one to save or like save all individually?"
Follow-ups (verbatim, same day): "I think we should support photos not just video and like the flows etc (think of more that i
might want)"; "for the share sheet if it needs to choose multi files or need guidance of what to do then it like shows the
sheet?"; "I want you to mock all this up firstly"; "It can also support x gallery
https://x.com/ilokineedsleep/status/2106850389551374806?s=20".

## Owner interview 2026-10-07 (supersedes the 2026-10-06 decisions wherever they conflict)

**What happened.** The owner tried 1.13 and called the gallery flow messy. Two concrete failures: (a) the share sheet could not
save an X photo gallery (the 1.13 extension sends no `items`, the server takes "first video, else gif, else fail" and answers
`error.webp.no_video`, section 0.2); (b) the in-app picker ("select what to save", a `save` button per item that writes to Photos, a
"saved to photos" bar, the footer "webp only appears on videos and gifs") is the wrong shape. Answers given in the interview (as
relayed by Fable; not verbatim):

1. **A gallery saves all into cobalt first**, from the share sheet or a paste: library + Files/Finder by the offline/folder rules
   (CONTRACT-OFFLINE). **Then** the owner chooses what to make. Nothing goes to Photos unless asked ("save to photos" stays a manual
   menu action). This replaces "grid, all ticked" as the first step.
2. **Share sheet, gallery → a compact choice sheet** (height fitted to its content, no empty space, no janky resizing): `save all` /
   `save + slideshow webp` / `save + gallery image`; then it finishes in the background with the existing notification. It must
   work without an app group (the extension resolves with the stored key, one server request per choice). A plain single
   video/photo stays notification-only.
3. **Combine makes three things**: a slideshow **webp** (animated), a slideshow **video** (mp4), and a **borderless gallery image**.
4. **Gallery image layout is picked each time**: one long vertical strip, a grid 2 or 3 across, or side by side (horizontal); no
   gaps, no borders.
5. **Slideshow timing: one slider for every photo** (default 2 s, 0.5 to 10 s); videos play their own length (inside the existing
   60 s video cap); crossfade on by default with a toggle.
6. **Length**: the slideshow webp is capped at 60 s total (the UI explains that longer needs the mp4); the mp4 goes up to 3:00.
7. **Reorder by drag** before combining; items can be unticked for the combine (all ticked by default).
8. **"Convert to webp" stays per video/gif item** (trim like today); photos stay photos.
9. **Results** (slideshow webp, slideshow mp4, gallery image) become tabs of the same media and sync to Files/Finder like other kept
   renditions.

**Calls made here to fit those answers (lane; open to review, each with the reason that would change it):**

- **R1. The gallery image is made on the server's helper, not on the device** (1.25). The share sheet has to ask for it and close
  with no app group: only the server can finish that work in the background. One renderer also means the share sheet, the app and a
  later Shortcut make the same picture. The app draws the preview from the same pinned geometry (6.4), so what the owner picks is
  what the server makes. Would change if the share sheet lost the gallery-image choice (then on-device would do).
- **R2. PDF moves to later; "long image" is the `strip` layout.** The interview lists three outputs and no PDF; a PDF needs its own
  sheet (one / six a page), a viewer tab and the Live Text layer, none of which the three outputs need. `PUT /library/items/<id>/made`
  with `role export` stays deployed and unused by the app until then. Would change if the owner asks for PDF back.
- **R3. A grid crops, the strip and side by side never do.** Grid cells take the post's most common shape; a photo of another shape is
  centre-cropped to its cell, and the combine sheet names which. Rows are balanced (10 in 3 across = 3+3+2+2) so there are no gaps; a
  shorter row's cells are wider, so a photo alone in a 2-across row is drawn up to 2× its own pixels (the sheet says so). The other
  choice (justified rows that keep every photo whole, rows of different heights) is the owner's to ask for (section 11).
- **R4. Videos and gifs are left out of a gallery image** (named on the sheet: "videos aren't in the image: 2 skipped"); a post
  needs 2 photos for one. A video's poster is not a photo of the post.
- **R5. One slider replaces the per-photo `auto` rule.** The Live Text word-count timing (old 1.15) is dropped; `LiveTextReader`
  stays for "copy text" only.
- **R6. The webp slideshow is encoded as a frame list, not a 15 fps video.** Each composed photo is one webp frame held for its
  seconds, each crossfade is 4 blended frames, video items are decoded at 15 fps; one `img2webp` run with today's forced keyframes
  (6.2). Measured on synthetic stills: the same file size as decoding a 15 fps render, half the encode time, and no 139 MB of
  temporary PNGs for 20 s (420 MB for 60 s) on the container's disk.
- **R7. A make chosen while the save is still running waits for it on the device** and is sent when the save is ready (the
  `saveGalleryThenMake` chain). The share sheet sends it with the save in one request (the server chains it).
- **R8. One of each, and making it again replaces it** (decided 2026-10-07 after the owner approved the boards, which never number
  a made file): a post holds at most one `slideshow webp`, one `slideshow` (mp4) and one `gallery image` per layout. Making the same
  output again (same format; for a gallery image the same layout) stores the new file first, then deletes the old one (row, R2
  object, mirror, poster, Files copy); the make button says so (`this replaces the slideshow webp you made before.`). Different
  layouts coexist (`gallery image · 3 across` and `gallery image · strip`). Names and tabs therefore never need a number. Would change
  if the owner wants to keep two versions (then FolderNaming's ` 2` and numbered tabs come back).

**Boards approved 2026-10-07.** The owner saw the four reworked boards (section 12) and answered "I like all of that": they are
approved as drawn, including the defaults they show: `3 across` preselected in the combine sheet's gallery image, the "drawn larger"
note, videos and gifs left out of a gallery image, fewer than 2 photos blocks it, and `seconds: null` for a video in a slideshow
request. R2, R3 and R4 are therefore decided (section 11 is closed); R8 was settled in the same pass.

**What this reverses** (each noted where it lived): decision 1.10 (paste choice screen A) → 1.10 below; the share sheet's `pick…`
grid and `make a video` row (old 1.12) → 1.12 below; the `auto` rule and per-photo lengths (old 1.15, owner decision 6) → 1.15;
"one long image / PDF export" (owner decision 1, old 1.25) → R2 and 1.25; `ExportRenderer` (old section 4) → removed.

## Owner decisions 2026-10-06 (kept for the record; status after the interview)

1. **First release = "core + repost tools".** *Partly superseded:* the core and the repost tools (crop, repost frame) stand; "one
   long image / PDF export" is replaced by the gallery image (R2). Crop and repost frame move to the last app wave (8).
2. **Paste choice screen: A**, the grid with every item ticked. *Superseded* by interview answer 1 (save all first).
3. **Gallery detail: B**, kind tabs + pager + thumbnail strip. *Stands.*
4. **Share sheet with no answer after 8 s: save everything.** *Stands.*
5. **Galleries in a pasted batch or a Shortcut: save everything.** *Stands.* From the interim server fix (S0, APP-API-CONTRACT
   18.9) it also holds for 1.13 clients on photo-only posts.
6. **Make-a-video defaults: auto length, crossfade, the post's own shape, no sound.** *Superseded* for length (one slider, 2 s);
   crossfade on, as posted and no sound stand.

**Status (2026-10-07): designed, boards approved by the owner; nothing of this rework is built.** The gallery server of 2026-10-06 (APP-API-CONTRACT 18.1-18.8) is
committed (`a43d88d4b`) and, per Fable, deployed; `features.gallery` turns on once the new helper answers. Lane **S0** (interim
server fix) is dispatchable now; **S1** (server makes) right after S0 is gated (they share two helper files); app lane **A0** can
start now (the paste/parallel feature is committed in 1.13, nothing else is in flight). Additive to `CONTRACT.md`,
`CONTRACT-MEDIA.md`, `CONTRACT-LIBRARY2.md`, `CONTRACT-VISIBILITY.md`, `CONTRACT-OFFLINE.md`, `CONTRACT-PARALLEL.md`,
`CONTRACT-SHARE-QUICK.md` and `deploy/cloudflare/APP-API-CONTRACT.md` **section 18** (18.9-18.13 added with this rework). Code read
2026-10-06/07 against the `apple-app` worktree at `f9c99be18`. **(owner)** = the owner asked; **(lane)** = a call made here.

## 0. Facts (read and run, not assumed)

### 0.1 Why that post could not be saved (2026-10-06, still true for the parts the server has not changed)

- **cobalt answers a picker.** `POST /` for `instagram.com/p/Ddy0-gpGg5U` returns `status: "picker"` with 10 items, all `photo`,
  no audio; for the X post `2106850389551374806`, `picker` with 4 `photo` items (resolved 2026-10-06 with `scratchpad/ig-probe.mjs`,
  no media downloaded). Photo-only carousels are normal on Instagram, X, TikTok photo posts.
- **The app's picker can only send photos to Photos.** `PipelineFlows.swift:753` `savePickerItems` downloads each item and calls
  `savePhoto`; `convertPickerItem` (`:793`) only takes video/gif. The sheet is `Cobalt/Shared/PickerContent.swift` (used by
  `Screens/Home/PickerSheet.swift` and the share extension's full sheet `CobaltShare/ShareRootView.swift`), copy in
  `Cobalt/Design/Copy.swift:231-245` ("select what to save", "webp only appears on videos and gifs. photos stay photos.").
- **The data model groups by session.** `GET /library` makes one post per post key (`app-routes.ts:440`), so N rows that share a
  session are one post with no new grouping code. Telemetry categories are a closed list (`TELEMETRY-CONTRACT.md:27`).

### 0.2 What the deployed gallery server does (read 2026-10-07 at `a43d88d4b`)

- **Without `items` a photo-only picker still fails.** `helper/lib.js:188-202` `selectPickerItems(entries, undefined)`: one entry →
  that entry; 2+ → first video, else first gif, else `error.webp.no_video`. `helper/server.js:582` takes the one-file path whenever
  `items` is absent. The 1.13 app sends `items` nowhere (no `GalleryChoice` or `first-video` in `apple/**`, grep 2026-10-07), so the
  share sheet, a batch paste and a Shortcut all fail a photo carousel exactly as the owner saw. With `items: "all"` the helper saves
  every item (`server.js:617-674`) and the Durable Object stores N rows when the answer carries an `items` list (`studio.ts:2379`
  → `finalizeItems`).
- **The webp encoder is ffmpeg → PNG frames → `img2webp`** with forced keyframes (`lib.js:470-612`; `Dockerfile` installs
  `libwebp-tools`). ffmpeg's `libwebp_anim` was dropped for ghosting (`deploy/cloudflare/README.md:287-291`), so whether the
  container's ffmpeg-static build has libwebp does not matter here (not checked). Webp widths `320 | 480`, 15 fps
  (`studio.ts:96-97`), quality `low|med|high` = img2webp `-q 65|75|85` (`lib.js:26`), output ≤ 25 MB (`lib.js:20`), clip ≤ 60 s
  (`lib.js:21`). `img2webp`'s `-d <ms>` is a per-frame option (its `-h`, libwebp 1.6.0 locally), so frames can have their own
  durations.
- **The slideshow is mp4 only.** `POST /studio/<sid>/slideshow` (`studio.ts:535-570`) takes `seconds` 1-15 per still
  (`s < 1` refused, `:548`); the helper re-checks 1-15 (`lib.js:902-930`); the frame is 1080 on the short side (`slideshowFrame`,
  `:575-594`); videos in a slideshow ≤ 60 s together (`MAX_SLIDESHOW_MOTION_SECONDS`, `lib.js:887`), total ≤ 180 s.
- **A render always reads the lead item.** `POST /studio/<sid>/render` has no item parameter; the source is the session's `r2_key`,
  the first video item, else item 0 (18.1). A second video in a gallery cannot be made into a webp today.
- **`features.gallery`** is advertised when the helper answers with `x-cobalt-helper: gallery=1` (`helper/server.js:129-130`,
  `studio.ts:812-836`).
- **Animated webp as a poster source:** the poster job runs ffmpeg on the file; ffmpeg 7.x is believed not to decode animated
  WebP (not checked on the container's build). The webp slideshow therefore gets its poster from its first composed frame (6.2),
  which does not depend on it.

### 0.3 Measured for this rework (local, M4 Pro, ffmpeg 9.0.1 + img2webp 1.6.0 from Homebrew; synthetic noisy 1080×1350 stills; one run each)

| what | result |
|---|---|
| slideshow webp, 10 photos, 2 s each, crossfade, 480×600, q75, **frame list** (R6): 10 stills + 9×4 fade frames | 46 frames, **1.76 MB**, 1.08 s img2webp, 20.000 s by the frame durations |
| same, **15 fps render** fed to img2webp (the alternative) | 300 frames, 1.79 MB, 2.14 s, **139 MB of PNG** on disk |
| share of the 1.76 MB | stills 306 KB (31 KB each), crossfades 1.45 MB (161 KB each) |
| gallery image `strip`, 10 photos, 1080×13500, ffmpeg `vstack`, `-q:v 3` | 5.4 MB, 0.42 s (0.37 MB per megapixel; noisy stills, real photos smaller) |
| gallery image `3 across`, 10 photos, 2160×5400 (a lone last row, before R3's balanced rows) | 1.97 MB, 0.29 s (0.17 MB per megapixel) |

So a webp's size follows its crossfades and videos, not the seconds a photo is held: 10 photos at 0.5 s and at 6 s are the same
file. The estimates the app shows (6.5) come from these rows and are labelled "about". Not measured: the container (an assumed 8×
slower `basic` instance), real photos, video items in a webp slideshow.

## 1. Decisions

### Model

1. **(owner, lane) Photos are first-class media.** A *media* (CONTRACT-MEDIA 1.1) is one source with **items** (1 to 20 originals in
   the source's order: photos, videos, gifs; a single video post is one video item, exactly today's media) and **made renditions**:
   webps of a video item (as today), **slideshows** (webp or mp4, 1.15), **gallery images** (1.25) and **crops** of a photo (1.23).
   Repost frames are made on demand and not kept (1.24). CONTRACT-MEDIA's "at most one video rendition" becomes "at most one
   original **per item**".
2. **(lane) A gallery is ONE media**: one paste, one share, one Shortcut run = one media, one planet, one library tile, one title,
   one public switch, one delete.
3. **(lane) Keyed off cobalt's answer, never the site.** `picker` with 2+ items → a gallery; one item (`redirect`, `tunnel`, or a
   1-item picker) → a single media.
4. **(lane) Server storage** as built (APP-API-CONTRACT 18.1-18.2): one studio session per save, N `media_items` rows (`role 'item'`,
   `item_index`, `post_key`), originals at `originals/<sid>-<nn>.<ext>`, photos keep their real type and get a 480 px thumb as poster,
   the session's `r2_key` names the lead item. Made rows: `role 'slideshow'` (mp4 or webp, 18.10), `role 'export'` with
   `made_spec.kind = "gallery"` (the gallery image, 18.11), `role 'crop'` (18.6).
5. **(lane) Old app builds** see one file per post (`GET /library` without `v=3`: the lead item and its webps). With S0 (18.9) a 1.13
   share of a photo carousel is stored as a gallery and 1.13 sees its first photo; the rest appear when the new build reads `v=3`.
6. **(lane) Titles** (`MediaTitle.resolve`): `service · @handle` when the link names an author, else `service · ref`; `twitter`
   displays as `x`. So **`x · @ilokineedsleep`** and **`instagram · Ddy0-gpGg5U`**. Items are `photo 3 of 10` in the UI and `03.jpg`
   on disk.
7. **(lane) Uploads.** A photo picked from Photos arrives as JPEG; each picked file is its own media (grouping several uploads into
   one gallery is later).
8. **(lane, owner answer 9) On this iPhone / Mac (CONTRACT-OFFLINE).** A kept single photo is a flat file (`IMG_2207.jpg`); a kept
   **gallery is a folder** named by the title (`instagram · Ddy0-gpGg5U/`) holding `01.jpg … 10.jpg` (a video item `03.mp4`), and
   its made files: `slideshow.webp`, `slideshow.mp4`, `gallery image · 3 across.jpg`, `03 · crop 9:16.jpg`, webps of a video item
   `03 · webp 1.webp` (webps of an item keep today's numbering). Made files never clash: a remake replaces its file (R8); FolderNaming's
   ` 2` only covers an owner's own file of the same name. The folder carries the media's extended attribute (OFFLINE
   decision 6). "keep new saves offline" (OFFLINE decision 5, default on) keeps every item and every made file the owner makes on
   this device. Mac: the same folder under `~/Movies/cobalt` (FolderSync). **Photos app: nothing unless asked** (owner answer 1):
   `save to photos` per photo, per selection, and `save all to photos` in the detail's `more`; made files also have `save to photos`.
   Ledger keys `g:<sid>:<n>` for items, `m:<item id>` for a made file.
9. **(lane) Telemetry** (no new category): in `pipeline`: `gallery saved` (`{items, photos, videos, failed}`), `make start|done|fail`
   (`{what: "webp"|"mp4"|"image", items, seconds, fade, frame, layout, code?}`); in `share`: `share choice`
   (`{waited_ms, choice: "all"|"webp"|"image", layout?}`).

### The flows

10. **(owner answer 1) Paste a gallery in the app: it saves everything, then asks what to make** (board `Gallery-Paste`). No choice
    screen first. The focus shows the gallery hero at once (the cover with two card edges and a count badge, the title, `saving 4 of
    10`), and under it a **make from it** row: `slideshow webp` · `slideshow mp4` · `gallery image` (each opens the combine sheet with
    that output chosen), then `open` (prominent once saved) and `done`. One job in the server's line (CONTRACT-PARALLEL), one
    planet. When it is saved: "saved to cobalt · Files › On My iPhone › cobalt › instagram · Ddy0-gpGg5U" and "not in Photos: save
    to photos is in more". A make chosen before the save ends waits for it (R7): the tray shows `slideshow webp · after the save · 6
    of 10`, then it runs (focused). A single photo saves as a photo (hero without the count, no make row); a single video is
    today's flow unchanged. Plain cobalt (no fork server, no `features.gallery`) keeps today's picker.
11. **(lane) Partial saves keep what they got.** An item that fails to download leaves the rest saved; the hero and the detail say
    "photo 7 couldn't be fetched: the link expired. the other 9 are saved." with `try photo 7 again` (re-resolves the post and fetches
    only that index, 18.2); a changed post answers `error.studio.gallery_changed` ("the post changed since. open it to pick again.").
12. **(owner answer 2) Share sheet: notification only, unless it is a gallery; then one compact sheet** (board `Share-Gallery`).
    The extension (app group or not) reads the link and sends `POST /` (cobalt's resolve, the stored key) **and** `GET
    /capabilities` together, as today's instant share does:
    - **one item** (any time): today's instant share: `POST /studio`, the local notification, close; nothing shown.
    - **a picker within 700 ms**: the **compact sheet** appears once, at its final height: a header (title, `10 photos` /
      `2 photos + 2 videos`, close), then three rows:
      1. `save all 10` (prominent; sub `into cobalt and Files`);
      2. `save + slideshow webp` (sub `2 s a photo · crossfade · about 20 s · about 1.8 MB`; with videos `videos play in full`);
      3. `save + gallery image` with four layout buttons inline (`strip` · `2 across` · `3 across` · `side by side`, each a glyph
         of the layout over its label); **tapping a layout is the choice**. Sub `no borders`; a mixed post `2 photos · 2 videos
         skipped`; fewer than 2 photos: the row is disabled with `needs 2 photos`.
      Each choice is **one request** (`POST /studio` with `items: "all"`, plus `slideshow` or `gallery_image`, 18.12), then the
      sheet closes with the local notification `saving 10 photos to cobalt` (`· making a slideshow webp` / `· making a gallery
      image`). The server's one Hark message finishes the story (`… · slideshow webp ready`, or what failed; 18.12).
    - **no answer at 700 ms**: the same sheet at the **same height** in its checking state: header `checking the link` (after
      2.5 s `waking the server · 4 s`) with the link's title; row 1 `save now` (live: `items: "all"`); rows 2-3 drawn as skeleton
      bars with no text. When the answer comes, a picker fills the rows in place (no height change); one item closes the sheet
      with `sent to cobalt`. **The sheet never changes height while it is open** (the owner's complaint).
    - **no answer at 8 s** (owner decision 4): `POST /studio {items: "all"}`, close, notification `saving everything to cobalt ·
      open cobalt to make something from it`.
    - **a server without `features.gallery`**: the same-height card `this server can't save photo posts yet` / `update the server,
      or open cobalt to save them to Photos.` with `open cobalt` and `close`. A server with `features.gallery` but without
      `features.gallery_make` (before S1 deploys): when that is known before the sheet first shows, rows 2-3 are not drawn and the
      sheet is the shorter one-row sheet from the start; when the sheet is already showing (checking state), rows 2-3 stay and
      are disabled with `this server can't make these yet`, so the height still never changes.
    - **Without an app group** (the owner's build) nothing is handed to the app: the server saves, makes and notifies; the app
      finds the post (and its made files) through `GET /studio/recent` and `GET /library?v=3` the next time it opens. The webp's
      quality and width are the extension's own settings defaults (`med`, 480) on that build, the app's settings on an app-group
      build.
    - Budgets pinned: 700 ms and 8 s. Not measured from the extension on a device.
13. **(owner, decision 5) Batch paste and Shortcuts save everything** (`items: "all"` with `features.gallery`; S0 makes the server do
    that for photo-only posts even without `items`). Shortcuts "Save links" gains `Galleries`: `save everything` (default) ·
    `first video only` · `save + slideshow webp` · `save + gallery image` (with a `Layout` parameter, default `3 across`, as the combine sheet). A gallery
    returns one `CobaltSave` with `kind` (`video|photo|gallery`), `itemCount`, `itemLinks` and `madeLinks`.
14. **(lane) Plain cobalt** (no fork server) keeps today's picker (save to Photos).

### Making things from a gallery (owner answers 3-7)

15. **(owner) The combine sheet makes a slideshow webp, a slideshow mp4, or a gallery image** (board `Gallery-Combine`), opened from
    the paste hero's make row, the detail's `more › make from this post`, and the empty state of a missing tab. One sheet:
    - **output**: segmented `slideshow webp` | `slideshow mp4` | `gallery image` (the entry point picks the first).
    - **items**: a strip of every item, all ticked. **Drag to reorder** (SwiftUI `onMove`/`draggable` on iOS and macOS); a selected
      tile also offers `move earlier` / `move later` (VoiceOver and keyboard). Tap the tick to leave an item out. At least 2 ticked
      (`tick at least 2`). The order and the ticks are exactly what is sent (`items` in play order).
    - **slideshow (webp and mp4)**: a live preview that plays the plan (crossfade as an opacity ramp), a proportional timeline,
      **one slider** `each photo 2.0 s` (0.5 to 10 s, 0.5 s steps, default 2.0 s), `videos play in full: 12.4 s + gif 3.2 s` (a gif
      plays once), `crossfade` toggle (default on, 0.3 s), `frame`: `as posted` (default) · `9:16` · `1:1` (an item of another shape
      sits on a blurred, darkened copy of itself), `sound` (mp4 only, only when a video is ticked): `none` (default) · `the videos'
      own`. Summary: `length 20.0 s · about 1.8 MB · about 25 s on the server` (6.5).
    - **caps** (`SlideshowPlan.check`): webp total ≤ **60 s**; mp4 total ≤ **3:00**; videos and gifs together ≤ 60 s in either. Over a
      cap the make button is disabled and a reason line offers the way out: webp `too long for a webp: 1:40. webps stop at 60 s; the
      mp4 can be up to 3:00.` with `use 6.0 s a photo` (the longest 0.5 s step that fits, when one does) and `make the mp4 instead`;
      mp4 `too long: 3:20. the server makes up to 3:00. untick some or shorten the photos.`; videos `the videos add up to 1:12. a
      slideshow can hold 60 s of video; untick one.`
    - **gallery image**: the four layouts as a picker with a mini diagram each (`strip`, `2 across`, `3 across`, `side by side`;
      `3 across` preselected, as the approved board); a
      preview drawn from `GalleryGeometry` (6.4) to scale (a tall strip scrolls inside the preview); meta `2160 × 4500 · jpeg · about
      2.9 MB`; `photos 2 and 3 are cropped to fit the 4:5 cells` when R3 crops; `photo 3 is drawn 2× its own pixels: it is alone in
      its row` when a cell is wider than its photo; `videos aren't in the image: 2 skipped`.
    - **make**: `make the slideshow webp` / `make the video` / `make the gallery image` → a line job with `priority: "focused"`
      (closing the sheet never stops it; the tray shows it) → `making the slideshow webp · 40%` → done: `added as a tab: slideshow
      webp` and `in Files: instagram · Ddy0-gpGg5U/slideshow.webp`, `make another`. Failure: `couldn't make the slideshow webp (the
      server's encoder stopped). the photos are untouched and your settings are kept.` + `try again`. When the post already has
      that output (same format, or the same layout), a line above the button reads `this replaces the slideshow webp you made
      before.` (R8).
16. **(lane) All three are server jobs in the line.** Slideshows (both formats) are the existing `slideshow` job with a `format`
    (18.10); the gallery image is a new `gallery_image` job (18.11). The Durable Object streams each chosen original from R2 into
    the helper, the helper renders, the DO stores the result as a made row of the same post (private original + public mirror per
    the post's visibility, a poster). Recipes in section 6.
17. **(lane) Cost** (0.3 and 6.5): a 10-photo webp slideshow is about 1.8 MB with crossfades and about 0.3 MB without; the mp4 of the
    same 20 s about 0.5 MB; a 10-photo strip about 4.4 MB. Server time is an assumption (container ≈ 8× the local run).

### Per item

18. **(owner answer 8) Convert to webp stays per video/gif item.** In the detail, a video or gif item has `make a webp`, which opens
    today's focus trim flow on **that item** (`POST /studio/<sid>/render` with `item`, 18.13). A photo has no webp button (the 1.13
    footer "webp only appears on videos and gifs" goes away because the button is not there). Webps of an item are tabs after the
    items (`webp 1`), as today.

### Presentation

19. **(owner decision 3) Detail: kind tabs + pager** (board `Gallery-Detail` of 2026-10-06, still current except its `more` list).
    Tabs: `photos 10` · `video` (a video item) · `slideshow webp` · `slideshow` · `gallery image · 3 across` · `webp 1` · `crop 9:16`
    (made renditions after the items, oldest first; never numbered, R8; webps of an item keep `webp 1…`). The photos tab: pager, `3 / 10`, thumbnail strip (a
    missing one red with `!`). One prominent button: `copy photo link` when public, `share` when private, `try again` on a missing
    photo; secondary `share` · `save to photos` · `copy text`. A `public · 12 links` switch for the whole media. `more`: rename ·
    **make from this post…** · select photos (share / save to photos / delete N) · save all to photos · copy all links · crop… ·
    repost frame… · delete this photo · delete everything. A made tab's `more`: save to photos · share · delete this file.
20. **(lane) One photo**: the same screen without the strip (zoom, `text` Live Text highlight and `copy text`, link, public switch,
    save to photos, share, `crop` (1.23)).
21. **(lane) Library** (board `Library-Mixed` of 2026-10-06, unchanged): one tile per media, a gallery tile with a stack + count
    badge, kind chips `all · videos · photos · galleries · webps`, kind sort, kind column.
22. **(lane) Orbit** (board `Orbit-Photos` of 2026-10-06, unchanged): photo planets, a gallery planet with a count that turns
    through its items in the front band. Face rule: newest webp (a slideshow webp counts), else newest made video, else item 0.

### Repost tools (owner decision 1; unchanged by the interview, moved to the last app wave)

23. **Crop a photo → a stored `crop` rendition** (on device, `FrameRenderer`, `PUT /library/items/<id>/made`, 18.6), as decided
    2026-10-06 (aspect `1:1 · 4:5 · 9:16 · 3:4 · free`, fill `cut` or `blur`, JPEG 0.9, 1080 short side, never upscaled).
24. **Repost frame → made on demand, not stored**: `9:16` / `1:1` / `4:5`, blurred bars or cut, to Photos or share (owner-asked
    Photos writes).
25. **Long image / PDF: replaced.** The long image is the gallery image's `strip` (made on the server, R1); PDF is later (R2).
26. **Posters**: the server makes a poster for a crop, a gallery image and a slideshow mp4; a slideshow webp's poster is its first
    frame, written by the helper (18.10).
27. **Shortcuts**: no new action; `CobaltSave.madeLinks` lists made files' public links (newest first).

## 2. Surface table

| surface | 1.13 today | after |
|---|---|---|
| paste a gallery (app) | "select what to save": per-item save to Photos | saves everything at once (one media, Files folder); then `slideshow webp` / `slideshow mp4` / `gallery image` |
| paste one photo | photo saved to Photos only (fork: stored as a photo by the 10-06 server) | a photo media, kept in Files |
| share sheet, one item | instant share | unchanged |
| share sheet, gallery | fails `no_video` on a photo-only post | compact one-height sheet: save all / + slideshow webp / + gallery image; one request; notification |
| batch paste, Shortcuts | fails `no_video` on a photo-only post | saves everything (S0 now for old clients; `items: "all"` from the new build) |
| combine | — (old plan: make a video, auto lengths) | webp ≤ 60 s, mp4 ≤ 3:00, gallery image in 4 layouts; reorder, untick, one slider |
| convert to webp | per picker item (a separate media) | per video/gif item, inside the gallery's media |
| results | — | tabs of the media; files in its Files/Finder folder |
| Photos app | where picker items went | only when asked (`save to photos`) |
| old builds 1.0-1.13 | — | a gallery appears as its lead item |

## 3. Copy (lowercase, exact; new `apple/Cobalt/Design/Copy+Gallery.swift`)

```swift
extension Copy {
    enum Gallery {
        // counts and names
        static func count(photos: Int, videos: Int) -> String   // "10 photos", "2 photos + 2 videos", "1 photo"
        static func itemName(_ kind: String, _ i: Int, of n: Int) -> String { "\(kind) \(i) of \(n)" }   // "photo 3 of 10"
        // paste: save all first
        static func saving(_ i: Int, of n: Int) -> String { "saving \(i) of \(n)" }
        static let makeFromIt = "make from it", makeFromThisPost = "make from this post…"
        static let slideshowWebp = "slideshow webp", slideshowMp4 = "slideshow mp4", galleryImage = "gallery image"
        static func afterTheSave(_ i: Int, of n: Int) -> String { "after the save · \(i) of \(n)" }
        static func savedTo(_ place: String) -> String { "saved to cobalt · \(place)" }   // "Files › On My iPhone › cobalt › <title>" / "~/Movies/cobalt/<title>"
        static let notInPhotos = "not in Photos: save to photos is in more"
        static func notFetched(_ name: String, kept: Int) -> String { "\(name) couldn't be fetched: the link expired. the other \(kept) are saved." }
        static func tryItemAgain(_ name: String) -> String { "try \(name) again" }
        static let galleryChanged = "the post changed since. open it to pick again."
        // combine
        static let eachPhoto = "each photo", crossfade = "crossfade", frame = "frame", sound = "sound"
        static let asPosted = "as posted", soundNone = "none", soundOwn = "the videos' own"
        static func videosInFull(_ list: String) -> String { "videos play in full: \(list)" }      // "12.4 s + gif 3.2 s"
        static let tickAtLeastTwo = "tick at least 2", moveEarlier = "move earlier", moveLater = "move later"
        static func summary(length: String, size: String, server: String) -> String { "length \(length) · about \(size) · about \(server) on the server" }
        static func webpTooLong(_ len: String) -> String { "too long for a webp: \(len). webps stop at 60 s; the mp4 can be up to 3:00." }
        static func usePerPhoto(_ s: String) -> String { "use \(s) a photo" }
        static let makeMp4Instead = "make the mp4 instead"
        static func mp4TooLong(_ len: String) -> String { "too long: \(len). the server makes up to 3:00. untick some or shorten the photos." }
        static func videosTooLong(_ len: String) -> String { "the videos add up to \(len). a slideshow can hold 60 s of video; untick one." }
        static let makeWebp = "make the slideshow webp", makeMp4 = "make the video", makeImage = "make the gallery image", makeAnother = "make another"
        static func making(_ what: String, _ pct: Int) -> String { "making the \(what) · \(pct)%" }
        static func makeFailed(_ what: String) -> String { "couldn't make the \(what) (the server's encoder stopped). the photos are untouched and your settings are kept." }
        static func addedAsTab(_ tab: String) -> String { "added as a tab: \(tab)" }
        static func replacesPrevious(_ what: String) -> String { "this replaces the \(what) you made before." }   // R8
        static func inFiles(_ path: String) -> String { "in Files: \(path)" }
        // gallery image
        static let layoutStrip = "strip", layoutGrid2 = "2 across", layoutGrid3 = "3 across", layoutRow = "side by side"
        static func imageMeta(_ w: Int, _ h: Int, _ size: String) -> String { "\(w) × \(h) · jpeg · about \(size)" }
        static func cropped(_ names: String, cell: String) -> String   // "photos 2 and 3 are cropped to fit the 4:5 cells"
        static func drawnLarger(_ name: String, _ x: String) -> String { "\(name) is drawn \(x) its own pixels: it is alone in its row" }
        static func videosSkipped(_ n: Int) -> String { n == 1 ? "videos aren't in the image: 1 skipped" : "videos aren't in the image: \(n) skipped" }
        static let needsTwoPhotos = "needs 2 photos"
        static func galleryImageTab(_ layout: String) -> String { "gallery image · \(layout)" }   // file: "gallery image · 3 across.jpg"
        // share sheet
        static func saveAll(_ n: Int) -> String { "save all \(n)" }
        static let intoCobaltAndFiles = "into cobalt and Files"
        static let saveAndWebp = "save + slideshow webp", saveAndImage = "save + gallery image", noBorders = "no borders"
        static func shareWebpSub(_ sec: String, _ len: String, _ size: String) -> String { "\(sec) a photo · crossfade · about \(len) · about \(size)" }
        static let videosPlayInFull = "videos play in full"
        static func photosAndSkipped(_ p: Int, _ v: Int) -> String   // "2 photos · 2 videos skipped"
        static let saveNow = "save now", checkingLink = "checking the link", sentToCobalt = "sent to cobalt"
        static func wakingServer(_ s: Int) -> String { "waking the server · \(s) s" }
        static func savingItems(_ n: Int, photosOnly: Bool) -> String   // "saving 10 photos to cobalt" / "saving 4 items to cobalt"
        static let andMakingWebp = " · making a slideshow webp", andMakingImage = " · making a gallery image"
        static let savingEverything = "saving everything to cobalt", makeLater = "open cobalt to make something from it"
        static let serverNoGallery = "this server can't save photo posts yet"
        static let serverNoGallerySub = "update the server, or open cobalt to save them to Photos."
        static let serverCantMake = "this server can't make these yet"
        // detail
        static func photosTab(_ n: Int) -> String { n == 1 ? "photo" : "photos \(n)" }
        static let copyPhotoLink = "copy photo link", copyText = "copy text", saveToPhotos = "save to photos"
        static let selectPhotos = "select photos", saveAllToPhotos = "save all to photos", copyAllLinks = "copy all links"
        static let makeAWebp = "make a webp", deletePhoto = "delete this photo", deleteFile = "delete this file"
        static func deletePhotoTitle(_ i: Int) -> String { "delete photo \(i) for everyone?" }
        static let deletePhotoMessage = "its public link stops working. the other photos and what you made stay."
        static func publicLinks(_ n: Int) -> String { "public · \(n) links" }
        static let privateNoLinks = "private · no links"
        // library (unchanged from 2026-10-06)
        static let kindAll = "all", kindVideos = "videos", kindPhotos = "photos", kindGalleries = "galleries", kindWebps = "webps"
        static func galleryKind(_ n: Int) -> String { "gallery · \(n)" }
        static func nothingHere(_ what: String, kept: Bool) -> String { "no \(what)\(kept ? " kept on this \(Copy.device)" : "") yet." }
        // repost tools (unchanged from 2026-10-06; wave A7)
        static let crop = "crop", saveCrop = "save crop", keepInCobalt = "keep in cobalt", deleteCrop = "delete this crop"
        static let fillCut = "cut to fit", fillBlur = "whole photo, blurred bars", fillBlurShort = "blurred bars"
        static func cropTab(_ aspect: String) -> String { "crop \(aspect)" }
        static let cropFailed = "couldn't upload the crop. the photo is unchanged."
        static let repostFrame = "repost frame", saveThisOne = "save this one"
        static func saveAllFrames(_ n: Int) -> String { "all \(n)" }
        static func videosSkippedFrames(_ n: Int) -> String { n == 1 ? "1 video skipped" : "\(n) videos skipped" }
    }
}
```

Server message texts (Hark, 18.12): `<label> · saved` (save only, today's), `<label> · slideshow webp ready`, `<label> · slideshow
ready`, `<label> · gallery image ready`, `<label> · saved 4 items. the slideshow webp would be 1:12 and webps stop at 60 s. open
cobalt to make the mp4.`, `<label> · saved 10 photos. the gallery image couldn't be made.`

## 4. Pinned CobaltKit API (additive; UI lanes build against exactly this)

```swift
// Models/Wire.swift
public enum GalleryChoice: Sendable, Equatable, Codable { case all; case some([Int]); case firstVideo }   // "all" | [0,3] | "first-video"
public struct GalleryItem: Sendable, Equatable, Identifiable {
    public var id: Int                     // index in the post
    public var type: MediaType             // .photo / .video / .gif
    public var width: Int?, height: Int?, duration: Double?
    public var thumb: URL?
}
public struct SlideshowPlan: Sendable, Equatable, Codable {
    public enum Format: String, Sendable, Codable { case webp, mp4 }
    public enum Frame: String, Sendable, Codable { case asPosted = "keep", story = "9:16", square = "1:1" }
    public enum Sound: String, Sendable, Codable { case none, own }
    public var format: Format
    public var items: [Int]                // play order, 2-20, unique
    public var photoSeconds: Double        // one value for every photo: 0.5...10, step 0.5 (default 2.0)
    public var fade: Bool                  // crossfade 0.3 s (default true)
    public var frame: Frame                // default .asPosted
    public var sound: Sound                // mp4 only; always .none for webp
    public var quality: WebpQuality?       // webp only (Settings.webpQuality)
    public var width: Int?                 // webp only (Settings.webpWidth: 320 | 480)
    public static func standard(_ format: Format, items: [Int], settings: Settings?) -> SlideshowPlan
    /// The wire's `seconds`: photoSeconds for a photo, nil (JSON `null`) for a video or gif (own length), in play order.
    /// Every request that carries a plan (combine, share sheet, Shortcuts) uses this; a photo-only post is all photoSeconds.
    public func seconds(for items: [GalleryItem]) -> [Double?]
    public func length(of items: [GalleryItem]) -> Double            // photos × photoSeconds + videos' lengths
    public func check(_ items: [GalleryItem]) -> SlideshowCheck
    public static let webpMaxSeconds = 60.0, mp4MaxSeconds = 180.0, motionMaxSeconds = 60.0
}
public enum SlideshowCheck: Sendable, Equatable {
    case ok, tooFew
    case tooLong(length: Double, cap: Double, fitSeconds: Double?)   // fitSeconds: the longest 0.5 s step that fits, if any
    case tooMuchVideo(Double)
}
public enum GalleryLayout: String, Sendable, Codable, CaseIterable { case strip, grid2, grid3, row }
public struct GalleryImagePlan: Sendable, Equatable, Codable { public var items: [Int]; public var layout: GalleryLayout }
// Media/GalleryGeometry.swift (new; the same function as the helper's galleryLayout, section 6.4; tests share its fixture table)
public struct GalleryCanvas: Sendable, Equatable {
    public struct Cell: Sendable, Equatable { public var index: Int; public var rect: CGRect; public var cropped: Bool; public var upscale: Double? }
    public var width: Int, height: Int, cells: [Cell], scaledToCap: Bool
}
public enum GalleryGeometry {
    public static func layout(_ sizes: [CGSize], _ layout: GalleryLayout) throws -> GalleryCanvas   // throws on < 2
    public static let maxLongSide = 30_000, maxPixels = 40_000_000
}
public enum MakeEstimate {   // section 6.5; every figure is "about"
    public static func webpBytes(_ items: [GalleryItem], plan: SlideshowPlan, frame: CGSize) -> Int64
    public static func mp4Bytes(_ items: [GalleryItem], plan: SlideshowPlan, frame: CGSize) -> Int64
    public static func jpegBytes(_ canvas: GalleryCanvas) -> Int64
    public static func serverSeconds(_ what: GalleryMake, items: [GalleryItem]) -> Double
}
public enum GalleryMake: Sendable, Equatable { case slideshow(SlideshowPlan); case image(GalleryImagePlan) }
extension Capabilities { public var gallery: Bool; public var galleryMake: Bool }   // features.gallery, features.gallery_make

// API/Client.swift (CobaltClient gains; HTTPCobaltClient, PreviewClient and the fakes implement)
func createStudio(url: URL, options: StudioCreateOptions) async throws -> StudioCreated
    // options gain `items: GalleryChoice?`, `itemCount: Int?`, `slideshow: SlideshowPlan?`, `galleryImage: GalleryImagePlan?`
func makeSlideshow(session: String, plan: SlideshowPlan, focused: Bool) async throws -> RenderAccepted      // POST /studio/<sid>/slideshow
func makeGalleryImage(session: String, plan: GalleryImagePlan, focused: Bool) async throws -> RenderAccepted // POST /studio/<sid>/gallery-image
func retryItems(session: String, items: [Int]) async throws -> StudioCreated                            // POST /studio/<sid>/items/retry
func deleteItem(_ itemID: String) async throws                                                          // DELETE /library/items/<id>
func setPostVisibility(anchor itemID: String, public: Bool) async throws -> VisibilityResult            // PATCH …/visibility {"scope":"post"}
// RenderRequest gains `item: Int?` (POST /studio/<sid>/render {"item": 3}; nil sends nothing = the lead)

// Pipeline: a picker becomes `.gallery(items: [GalleryItem])` when caps.gallery (plain cobalt keeps .picker). There is no choice
// state: entering .gallery starts the save of everything at once.
extension Pipeline {
    public var galleryProgress: (done: Int, total: Int)? { get }
    public func make(_ m: GalleryMake) async          // sent now if the save is ready, else after it (R7); focused priority
}

// Store: Record gains `itemIndex: Int?`, `role: Role?` (.item, .slideshow, .export, .crop), `madeFrom: [Int]?`, `madeSpec: Data?`
// (decodeIfPresent); an original with itemIndex joins its media by sessionID, one per index.
extension StoredMedia {
    public var items: [StoredVideo]; public var made: [StoredVideo]; public var isGallery: Bool { get }; public var kind: MediaKind { get }
}
public enum MediaKind: String, Sendable { case video, photo, gallery, webp }
// Models/MediaItem.swift: Rendition.Kind gains `.item(index: Int, type: MediaType)`, `.slideshow(number: Int, format: SlideshowPlan.Format)`,
// `.galleryImage(layout: GalleryLayout, number: Int)`, `.crop(of: Int, spec: FrameSpec)`; MediaItem gains `items`, `made`, `kind`,
// `itemCount`, `missing: [Int]`.
extension AppModel {
    public func retryMissing(_ item: MediaItem) async throws
    public func make(_ m: GalleryMake, from item: MediaItem) async throws
    public func deleteItems(_ indices: [Int], of item: MediaItem) async throws      // the last one is refused (delete everything)
    public func deleteMade(_ rendition: Rendition, of item: MediaItem) async throws
    public func setPublic(_ on: Bool, for item: MediaItem) async throws              // scope post
    public func copyAllLinks(_ item: MediaItem) -> String
    public func saveToPhotos(_ renditions: [Rendition], of item: MediaItem) async throws   // owner-asked only
}
// Folder/FolderNaming.swift: names of section 1.8 (items `01.jpg`, `slideshow.webp`, `slideshow.mp4`, `gallery image · 3 across.jpg`,
// `03 · webp 1.webp`, `03 · crop 9:16.jpg`; made files are replaced, never numbered, R8).
// Media/LiveTextReader.swift (copy text only), Media/FrameRenderer.swift + FrameSpec (crop, repost frame; wave A7) as 2026-10-06.
// Removed from the 2026-10-06 pin: SlideshowPlan.auto, the per-photo `seconds` array as a property, ExportRenderer, ExportKind,
// PDFLayout, MadeRole.export from the app (the server route stays), Pipeline.saveGallery(_:) / saveGalleryThenVideo(_:).
// Shortcuts/ShortcutActions.swift: SaveLinksIntent gains `galleries: CobaltGalleries` (.everything default, .firstVideo,
// .webp, .image) and `layout: GalleryLayout` (default .grid3); CobaltSave gains kind, itemCount, itemLinks, madeLinks.
```

## 5. UI behaviour (boards in section 12 are the source)

- **Focus** (`FocusView`): `.gallery` shows the gallery hero (not the trim hero, not a grid): cover with two card edges and the
  count, title, `saving i of n` with a bar, the `make from it` row (enabled from the start), `open` / `done`. A make tapped mid-save
  shows its chip `after the save · 6 of 10` in the tray. Partial save: the error line and `try photo 7 again`.
- **Combine sheet** (`Screens/Combine/CombineSheet.swift`): `.sheet` large detent on iPhone, a sheet window on Mac; the items strip
  uses `onMove`; the preview uses the device's thumbs (or originals when kept); the gallery-image preview draws
  `GalleryGeometry.layout` cells with each photo aspect-filled; the timeline is a row of buttons sized by seconds, VoiceOver
  "photo 3, 2.0 s".
- **Detail**: section 1.19-1.20; a video item's page has `make a webp`.
- **Share extension**: section 1.12; `SheetFitter` sets ONE height computed from the sheet's rows before it first shows (header
  + 3 rows + insets; the checking state reuses it); a single-item answer closes it.
- **Library, Orbit**: sections 1.21-1.22.

## 6. Recipes and geometry (pinned for lane S1; checked locally in the session scratchpad `gallery2/probe/` and `gallery2/model/`)

### 6.1 Slideshow mp4 (as built, one change)

As built at `a43d88d4b` (`lib.js:882-1236`): compose each still once at the frame size (blurred fill unless the aspect matches),
`xfade` 0.3 s chain or `concat`, video items fitted the same way, `mpdecimate=…:max=15` with the end mark, `-fps_mode vfr`,
`libx264 veryfast stillimage crf 20 -bf 0`, `+faststart`. **Change:** a still's seconds may be **0.5** to 15 (was 1 to 15), here
and in the Durable Object's plan check.

### 6.2 Slideshow webp (new, R6)

1. **Frame**: width = the plan's `width` (320 | 480; default 480), height = even(width / aspect), aspect from `frame` (`keep` =
   the most common item size, as 6.1; `9:16`; `1:1`). 10 photos 1080×1350 at 480 → 480×600.
2. **Compose each still once** at that size with `buildComposeArgs` (the same blurred fill), as JPEG.
3. **Frames** (one list, in play order; `fps` = 15, frame time `fd = round(1000 / fps)` = 67 ms, crossfade frames `k = 4`):
   - a still: one frame held `round(seconds × 1000) − (fade into it ? k·fd/2 : 0) − (fade out of it ? k·fd/2 : 0)` ms;
   - between two slides with `fade`: `k` frames of `fd` ms, blend `j/(k+1)` for `j = 1…k` of the outgoing and incoming picture
     (ffmpeg `blend=all_expr='A*(1-t)+B*t'` per frame, or `xfade` sampled at those offsets), using the still, or the video's
     last/first decoded frame;
   - a video or gif: decoded at 15 fps through `fillGraph` to PNG frames of `fd` ms each (a gif once), minus `k/2` frames at an end
     that has a crossfade.
   Total = the plan's length within one frame (67 ms). Worked example, 3 photos at 2 s with fade: still 1866 ms, 4 × 67, still
   1732 ms, 4 × 67, still 1866 ms = 6000 ms.
4. **Encode**: one `img2webp` run, cwd = the frames dir, `-loop 0 -lossy -q <65|75|85> -m 4 -kmin 3 -kmax 5` then per frame
   `-d <ms> <file>`, `-o out.webp` (the forced keyframes of today's encoder, README:287-291).
5. **Poster**: the first frame's JPEG, kept by the helper as `poster.jpg` (`GET /slideshow/:id/poster`).
6. **Limits**: total ≤ 60 s (+0.5 slack) → `error.webp.too_long`; videos ≤ 60 s (as 6.1); output ≤ 25 MB (`MAX_OUTPUT_BYTES`) →
   `error.webp.too_large`; one shared job budget (10 min, as 6.1); frames on disk deleted afterwards, success or failure.
7. **Test**: `parseWebp` duration = plan ± 70 ms; frame count = stills + k × fades + video frames; canvas = the frame.

### 6.3 Gallery image (new, R1)

1. Geometry from `galleryLayout(sizes, layout)` (6.4) with the probed sizes of the chosen photos, in the chosen order.
2. One ffmpeg run: per input `scale=w:h:flags=lanczos,setsar=1` (strip, row) or
   `scale=w:h:force_original_aspect_ratio=increase:flags=lanczos,crop=w:h,setsar=1` (grid cells); a grid joins each row with
   `hstack=inputs=k` (a single cell passes through) and the rows with `vstack=inputs=r`; strip `vstack`, row `hstack`; then
   `format=yuvj420p`; `-frames:v 1 -q:v 3 -f image2 -update 1`. Inputs are composed one row at a time if memory needs it (the lane
   decides; 1 GiB container).
3. Result `image/jpeg`; `GET /gallery/:id` done answers `{bytes, width, height, cropped: [n…], upscaled: [n…]}`.
4. Limits: 2-20 photos (no video, no gif: `400 error.webp.invalid_params`), long side ≤ 30,000 px and ≤ 40 MP (geometry scales
   down), output ≤ 50 MB → `error.webp.too_large`.

### 6.4 The geometry (one function; the helper's `galleryLayout` in JS and the app's `GalleryGeometry` in Swift)

The reference implementation is the session scratchpad's `gallery2/model/gallery-model.js` (`layout`); both ports must return the
same numbers as this table, which was generated by executing it:

- `even(n)` = floor to an even integer, at least 2.
- **strip**: W = even(min(1080, narrowest width)); each photo `h = even(round(W × h/w))`, stacked; no crop.
- **row**: H = even(min(1080, shortest height)); each photo `w = even(round(H × w/h))`, side by side; no crop.
- **grid N** (2 or 3): rows `r = ceil(n/N)`, `base = floor(n/r)`, the first `n − base·r` rows hold `base + 1`, the rest `base`
  (10 in 3 = 3+3+2+2). Canvas width W = even(min(2160, (photos in the fullest row) × narrowest width)). Cell aspect A = the most
  common `width×height` among the photos (ties: the first). A row of k: cells `even(W/k)` wide, the last takes the remainder; row
  height `even(round(cellWidth / A))`. Each photo covers its cell (scale up to cover, centre crop). `cropped` when the photo's
  aspect differs from its cell's by ≥ 0.4 %; `upscale` = max(cellW/w, cellH/h) when > 1.01.
- **caps**: if the long side > 30,000 or the area > 40 MP, the base size (W or H) is multiplied by
  `min(30000/long, sqrt(40e6/area))`, made even, and the layout is rebuilt (`scaledToCap`).

| photos | layout | canvas | rows | cropped | drawn larger | scaled to cap | about |
|---|---|---|---|---|---|---|---|
| ig10 (10 × 1080×1350) | strip | 1080×13500 | — | — | — | no | 4.4 MB |
| ig10 | grid2 | 2160×6750 | 2+2+2+2+2 | — | — | no | 4.4 MB |
| ig10 | grid3 | 2160×4500 | 3+3+2+2 | — | — | no | 2.9 MB |
| ig10 | row | 8640×1080 | — | — | — | no | 2.8 MB |
| x4 (1200×1500, 1500×1200, 1200×1200, 1200×1500) | strip | 1080×4644 | — | — | — | no | 1.5 MB |
| x4 | grid2 | 2160×2700 | 2+2 | 2, 3 | 2 (1.1×), 3 (1.1×) | no | 1.7 MB |
| x4 | grid3 | 2160×2700 | 2+2 | 2, 3 | 2 (1.1×), 3 (1.1×) | no | 1.7 MB |
| x4 | row | 4158×1080 | — | — | — | no | 1.3 MB |
| ig3 | strip | 1080×4050 | — | — | — | no | 1.3 MB |
| ig3 | grid2 | 2160×4050 | 2+1 | — | 3 (2×) | no | 2.6 MB |
| ig3 | grid3 | 2160×900 | 3 | — | — | no | 0.6 MB |
| ig3 | row | 2592×1080 | — | — | — | no | 0.8 MB |
| ig7 | grid2 | 2160×6750 | 2+2+2+1 | — | 7 (2×) | no | 4.4 MB |
| ig7 | grid3 | 2160×3600 | 3+2+2 | — | — | no | 2.3 MB |
| stories20 (20 × 1080×1920) | strip | 842×29920 | — | — | — | yes | 7.6 MB |
| stories20 | grid2 | 2120×18840 | 2 × 10 rows | — | — | yes | 12 MB |
| stories20 | grid3 | 2160×9600 | 3+3+3+3+3+3+2 | — | — | no | 6.2 MB |
| stories20 | row | 12160×1080 | — | — | — | no | 3.9 MB |
| small2 (640×800, 900×900) | strip | 640×1440 | — | — | — | no | 0.3 MB |
| small2 | grid2 | 1280×800 | 2 | 2 | — | no | 0.3 MB |
| small2 | grid3 | 1280×800 | 2 | 2 | — | no | 0.3 MB |
| small2 | row | 1440×800 | — | — | — | no | 0.3 MB |

Photo numbers are 1-based. The x4 sizes are stand-ins (the post's real sizes were not recorded). "about" = 0.3 MB per megapixel
(0.3).

### 6.5 Estimates the app shows (each labelled "about"; a frame-size factor scales the measured rows)

- **webp**: 31 KB a photo and 161 KB a crossfade at 480×600 (0.3), 132 KB a second of video at 480×560 (README's owner clip at q75);
  × (frame pixels / reference pixels); quality factor `low 0.7 · med 1 · high 1.5` (**assumed**, not measured).
- **mp4**: 0.025 MB a second of stills and 0.25 MB a second of video at 1080×1350, × frame pixels (2026-10-06 measurement).
- **jpeg**: 0.3 MB a megapixel.
- **server time** (container assumed 8× the local run): webp 5 s + 0.6 s a photo + 0.6 s a crossfade + 2.5 s a second of video;
  mp4 5 s + 0.45 s a second of stills + 2.5 s a second of video; gallery image 3 s + 0.3 s a photo.

## 7. Server

`deploy/cloudflare/APP-API-CONTRACT.md` section 18 is the wire: 18.1-18.8 as built; **18.9** the interim fix (S0); **18.10** the webp
slideshow and the 0.5 s minimum; **18.11** the gallery image; **18.12** the share sheet's one request and one message; **18.13**
`item` on renders; `features.gallery_make`.

## 8. Lanes, waves, ownership

| wave | lane | owns (writes only these) | done when |
|---|---|---|---|
| now | **S0 · interim fix** (`sonnet-lane`) | 8.1 | 8.1's gates |
| after S0 is gated | **S1 · server makes** (`sonnet-lane`) | 8.2 | 8.2's gates |
| now (‖ S0, S1) | **A0 · CORE** (`sonnet-lane`) | `apple/CobaltKit/**` except `Share/**`, `Shortcuts/**`; `apple/Cobalt/Design/{Copy+Gallery,Symbols+Gallery}.swift`; `apple/project.yml` | section 4 compiles on iOS and macOS with every existing call site unchanged; section 9 CORE tests green (incl. the 6.4 table) |
| after A0 | **A1 · FOCUS + ORBIT** (`sonnet-lane`) | `apple/Cobalt/Screens/Home/**` except `MediaDetail.swift`, `Inspector.swift` | gates; previews of the paste hero (ig 10, x 4, mixed, one photo, partial, make-after-save), gallery/photo planets, Reduce Motion |
| after A0 ‖ | **A2 · COMBINE** (`sonnet-lane`) | new `apple/Cobalt/Screens/Combine/**` | gates; previews of every Gallery-Combine state (three outputs, reorder, untick, caps and their ways out, layouts with crop/upscale notes, queued, making, done, failed) |
| after A0 ‖ | **A3 · DETAIL** (`sonnet-lane`) | `apple/Cobalt/Screens/Detail/**`, `apple/Cobalt/Screens/Home/{MediaDetail,Inspector}.swift` | gates; previews: photos tab, made tabs (webp slideshow plays, gallery image scrolls), per-item `make a webp`, missing item, save to photos, delete one |
| after A0 ‖ | **A4 · SHARE** (`sonnet-lane`) | `apple/CobaltShare/**`, `apple/CobaltKit/Sources/CobaltKit/Share/**`, `apple/CobaltKit/Tests/CobaltKitTests/InstantShare*` | 700 ms / 8 s on a fake clock; ONE sheet height in checking and choice; one request per choice with the 18.12 bodies; single item closes; old-server card |
| after A0 ‖ | **A5 · LIBRARY** (`sonnet-lane`) | `apple/Cobalt/Screens/Library/**` | gates; previews mosaic / table / empty with galleries and made files |
| after A0 ‖ | **A6 · SHORTCUTS** (`sonnet-lane`) | `apple/Cobalt/Intents/**`, `apple/CobaltKit/Sources/CobaltKit/Shortcuts/**`, their tests | `Galleries` + `Layout` parameters; `CobaltSave` additions; latest-saves kinds |
| after wave 2 | A7 · TOOLS (crop, repost frame) | new `apple/Cobalt/Screens/Tools/**` | as 2026-10-06's G1b tools part |
| last | **V · verification** (`sonnet-lane`) | none (evidence to a session path) | section 9 V checklist |

`apple/Cobalt/Shared/PickerContent.swift` and `Screens/Home/PickerSheet.swift` stay for plain cobalt; no lane deletes them in this
release (A1 stops routing galleries to them when `caps.gallery`). Rules as CONTRACT.md 3: shared types only in CobaltKit; a UI lane
that needs more API asks Fable; nobody commits or pushes. Not touched: upstream `api/` and `web/` outside `deploy/`,
`apple/CobaltWidgets/**`.

### 8.1 Dispatch brief: S0 · interim server fix (paste as is)

> **Lane S0 (interim server fix) for cobalt galleries.** Worktree `/Users/harmony/cobalt/.claude/worktrees/apple-app`. Read first:
> `deploy/cloudflare/APP-API-CONTRACT.md` **18.9 (your rule, exact)**, 18.2 and 18.7; `apple/CONTRACT-GALLERY.md` section 0.2. Do not
> commit, push or deploy.
>
> **Why:** the 1.13 app sends no `items`, so the deployed server answers a photo-only gallery (an X 4-photo post, an Instagram
> carousel) with `error.webp.no_video` from the share sheet, a batch paste and a Shortcut. From now on such a post is saved whole as a
> gallery, so 1.13's share sheet lands it in the library (1.13 sees its first photo; the new build sees all of it).
>
> **You own only:** `deploy/cloudflare/api/helper/lib.js` (`selectPickerItems` and a new exported `effectiveItems`, nothing else),
> `deploy/cloudflare/api/helper/server.js` (the fetch job's branch at `:582` only), new `deploy/cloudflare/api/test/helper-legacy-picker.test.ts`,
> new `deploy/cloudflare/api/test/gallery-legacy.test.ts`, and one line in `deploy/cloudflare/README.md` (the behaviour change).
> Everything else in `api/src/**` and the other tests is out of scope: the Durable Object already stores N rows whenever the helper's
> answer has an `items` list (`studio.ts:2379`); if a test shows it does not for a request without `items`, stop and report.
>
> **Build:** `effectiveItems(entries, items)` returns `items` unchanged when it is given (including `"first-video"`, which keeps
> failing a photo-only post: that is what it asks for), and when `items` is absent returns `"all"` exactly when the answer is a
> picker of 2+ entries none of which is `video` or `gif`; otherwise `undefined` (today). The fetch job uses it before
> `selectPickerItems` and before choosing the one-file branch, so such a post takes the several-items path and answers with
> `items` and `picker_count`. A picker of 21+ photos saves the first 20 (the `"all"` rule). Nothing else changes: a 1-item picker,
> a mixed post (first video), a plain link.
>
> **Tests:** unit table for `effectiveItems` and `selectPickerItems` (10 photos → all 10; 25 photos → 0-19; photo + video → [1];
> photo + gif → [1]; 1 photo → single path, no `items` list; plain answer → single; `"first-video"` on 4 photos → `no_video`;
> `"all"` and `[0,2]` unchanged); helper server test with stubbed cobalt and downloads: `POST /fetch` without `items` on a 4-photo
> picker → done with `items` of 4, `picker_count: 4`, lead = item 0 `image/jpeg`, a thumb per item; one item 403 → 3 done + 1 error,
> job done. API test (existing fakes, `node:sqlite`): `POST /studio {url}` (no `items`, `origin: "share"`, `notify` saved) on a
> 4-photo picker → 4 `role 'item'` rows, session `item_count` 4, `GET /library` (no `v`) shows ONE file (the first photo), `v=3`
> shows 4 with `kind: "gallery"`, exactly one `saved` notification. Every existing suite stays green.
>
> **Gates:** `cd deploy/cloudflare/api && npm test && npm run typecheck`. Report: files changed, test counts before/after, and what
> you could not verify (what 1.13 does with an image session it downloads; that is V's to check on a simulator). Deploy is the
> owner's (`prepare-git-info.sh`, `cf deploy`; the container image changes).

### 8.2 Dispatch brief: S1 · server makes (paste as is)

> **Lane S1 (server makes) for cobalt galleries.** Worktree `/Users/harmony/cobalt/.claude/worktrees/apple-app`. Starts after S0 is
> gated (it edits the same two helper files). Read first: `apple/CONTRACT-GALLERY.md` sections 0.2, 0.3, 1.12, 1.15-1.18, **6 (your
> recipes and geometry, exact)**, and `deploy/cloudflare/APP-API-CONTRACT.md` **18.10-18.13 (your wire, exact)** plus 17 (the line)
> and 18.5 (the slideshow you extend). The reference geometry is in this session's scratchpad `gallery2/model/gallery-model.js`
> (Fable will paste its path); port it to `helper/make.js` and assert the 6.4 table. Do not commit, push, deploy or apply anything
> remotely.
>
> **You own only:** `deploy/cloudflare/api/helper/{lib.js,server.js}` (the slideshow and new gallery parts), new
> `deploy/cloudflare/api/helper/make.js`, `deploy/cloudflare/api/src/{studio.ts,line.ts,app-routes.ts,gate.ts,library.ts,poster.ts,
> notify.ts,worker.ts}`, new tests `deploy/cloudflare/api/test/{make-webp,gallery-image,render-item,share-make,helper-make}.test.ts`,
> the fakes they need in `deploy/cloudflare/api/test/studio-fakes.ts` (additive), `deploy/cloudflare/README.md` (the make section).
>
> **Build:** (1) 18.10: `format: "webp"` with `quality`/`width` on `POST /studio/<sid>/slideshow` and on the helper's
> `/slideshow/:id/start`; the frame-list encoder of 6.2 (pure argv/plan builders in `make.js` like `buildSlideshowArgs`); 60 s cap;
> the poster from the first frame; the result row `image/webp`. Seconds minimum 0.5 in both the DO and the helper. (2) 18.11: `POST
> /studio/<sid>/gallery-image`, the line kind `gallery_image`, the helper's `/gallery/:id/*` routes (same hold/reap/busy rules as
> `/slideshow`), the 6.3 recipe from the 6.4 geometry, the result row (`role 'export'`, `made_spec.kind "gallery"`), replace per
> layout. Replace a slideshow per format (R8, 18.10; a row made before 18.10 counts as mp4). (3) 18.12: `slideshow.format` and `gallery_image` on `POST /studio`, chained after the save over the items that were saved,
> and the one-message notification rule. (4) 18.13: `item` on `POST /studio/<sid>/render`. (5) `features.gallery_make` (helper caps
> `gallery=1,make=1`).
>
> **Tests (real ffmpeg + img2webp where marked; skip with a logged reason when `img2webp` is absent):** webp plan builder: the 6.2
> worked example (1866/67×4/1732/…), cut vs fade, a video in the middle (frames at 15 fps, ends trimmed by 2 frames beside a fade);
> real encode of 3 generated stills + a 2 s generated video: duration = plan ± 70 ms (`parseWebp`), canvas 480×600 for 4:5 stills,
> frame count, `poster.jpg` exists; 60.6 s → `too_long`; 0.5 s photos accepted, 0.4 s refused (DO and helper); geometry: every row of
> the 6.4 table, cells tile the canvas exactly, even sizes; real gallery image for strip and grid3 (sizes, JPEG, crop list); DO:
> validation tables for both routes, line order (focused class 0), result rows, visibility of the post, poster jobs, replace per
> layout and per slideshow format (the old row's R2 object, mirror and poster go; `replaced` in the done answer), `seconds`
> shape (`null` for each video/gif, a number for each photo; anything else 400), a create with `slideshow.format "webp"` and one with `gallery_image` → save then make, one Hark message per 18.12 (the
> make's outcome; the save's failure), a make whose items partly failed uses the saved ones (fewer than 2 photos → the make ends
> `error.studio.too_few_photos`, the save stays); render with `item` of a second video item reads that item's `r2_key`, a photo item
> → 409 `error.studio.not_video`; `features.gallery_make` only when the helper says `make=1`. Every existing suite stays green.
>
> **Gates:** `cd deploy/cloudflare/api && npm test && npm run typecheck`; `cf deploy --dry-run` builds. Report: files changed, test
> counts before/after, the measured webp/jpeg durations and sizes, every place 6 or 18.10-18.13 was unclear or you deviated (and
> why). Unverified (say so): container speed, real photos, the Alpine `img2webp` version (log `img2webp -version` in the helper's
> startup line).

### 8.3 App lane briefs (dispatch after A0 is gated; A0 can go now)

Each brief is: "Lane <name> for cobalt galleries (owner interview 2026-10-07). Worktree `/Users/harmony/cobalt/.claude/worktrees/
apple-app`. Read `apple/CONTRACT-GALLERY.md` (the interview block, sections 1, 3, 4, 5 and your board in section 12) and
`apple/CONTRACT.md` 3 and 9. You own only <row of the table>. Build against the section 4 API exactly; if you need more, stop and ask
Fable. Gates: CONTRACT.md 9's four commands, no `warning:` lines from `apple/`. Do not commit or push." plus:

- **A0 · CORE**: section 4 in full (wire types and their JSON exactly as APP-API-CONTRACT 18.2/18.10-18.13; `GalleryGeometry` ported
  from section 6.4 (reference JS in the session scratchpad `gallery2/model/gallery-model.js` while it exists) and tested against every row of 6.4; `SlideshowPlan.check` against the caps and the fit
  rule; `MakeEstimate` against 6.5; client methods with `LoopbackServer` tests; the Pipeline's `.gallery` that saves all at once
  and `make` that waits for the save; store records, `MediaItem` renditions, `FolderNaming` names of 1.8; `Capabilities.galleryMake`;
  `PreviewClient` scenarios for every board state). Copy and symbols files.
- **A1 · FOCUS + ORBIT**: 1.10-1.11 and 5 (board `Gallery-Paste`), 1.22 (board `Orbit-Photos` of 2026-10-06). Galleries never reach
  `PickerSheet` when `caps.gallery`.
- **A2 · COMBINE**: 1.15 and 5 (board `Gallery-Combine`, and `Gallery-Image` for the preview geometry).
- **A3 · DETAIL**: 1.18-1.20 and the tabs of 1.19 (board `Gallery-Detail` of 2026-10-06; its `more` list is replaced by 1.19's).
- **A4 · SHARE**: 1.12 (board `Share-Gallery`); the request bodies of APP-API-CONTRACT 18.12; works with the fallback store (no app
  group): nothing written for the app to pick up.
- **A5 · LIBRARY**, **A6 · SHORTCUTS**: 1.21 and 1.13 (boards `Library-Mixed` and `Shortcuts-Gallery` of 2026-10-06; Shortcuts'
  `make a video` option becomes `save + slideshow webp` / `save + gallery image` with `Layout`).

## 9. Gates, tests, evidence

- **Gates**: CONTRACT.md 9's four commands; the API suite (8.1, 8.2).
- **CORE tests**: `GalleryChoice` encoding; `SlideshowPlan` JSON (`seconds` array from `photoSeconds`, `null` for videos, `format`,
  `quality`/`width` only for webp); `check` (60 s webp, 180 s mp4, 60 s videos, `fitSeconds` 1.5 for 20 photos + a 25 s video, nil
  when nothing fits); `GalleryGeometry` = the 6.4 table, cells tile exactly, throws under 2; picker → `.gallery` with `caps.gallery`,
  `.picker` otherwise; `.gallery` starts the save of `"all"` with no choice; `make` before the save ends is sent after it, once;
  store: items join one media by session, made records by role, `kind`; `FolderNaming` names of 1.8 (a remake replaces the file, R8); `MediaTitle`
  handle rule; `RenderRequest.item` encoding.
- **V checklist** (iPhone 17 Pro sim iOS 26.5, then the owner's phone; preview server first, the live server only after S0/S1 are
  deployed by the owner, on throwaway posts): 1 the 1.13 build shares the X 4-photo post after S0 → it lands in the library (record
  what 1.13 shows for the image session); 2 the new build: paste the Instagram carousel → saving 1..10 → one planet, a Files folder
  with 01-10.jpg, nothing new in Photos; 3 tap `slideshow webp` mid-save → it runs after the save; result tab plays; `slideshow.webp`
  in the folder; 4 combine: reorder (drag) and untick → the request's `items` order; webp at 10 s a photo → the 60 s message and
  `use 6.0 s a photo`; the mp4 at 3:00 works; 5 gallery image 3 across → 2160×4500 JPEG, its tab and file; strip of a 20-story post
  → scaled to 30,000 px; 6 share sheet: reel = notification only; carousel = the compact sheet; screen recording of the cold-server
  sheet showing it never changes height; each choice → one request, one final notification; 7 a second video item → `make a webp`
  renders that item; 8 Shortcuts Save links with `save + gallery image`; 9 `save to photos` from the detail is the only way a photo
  reaches Photos.

## 10. Risks and what is not verified

- Not measured: the container's encode times (the 8× factor is an assumption), real photos (all sizes in 0.3 are synthetic noisy
  stills, which overstate JPEG and webp sizes), the extension's resolve time and sheet height on a device, webp quality factors.
- Not checked: whether 1.13 can draw an image session it downloads after S0 (old builds were designed to see "the lead item"; a
  photo lead was accepted as "no worse than failing" on 2026-10-06); whether ffmpeg 7.0.2 in the container decodes animated webp
  (irrelevant to the design: the poster comes from the helper).
- A crossfade is ~5× the bytes of a held photo in a webp; with videos a 60 s webp can approach the 25 MB cap (60 s of video at 480
  px ≈ 7.9 MB by 6.5; not measured).
- A gallery image of 20 tall photos is scaled to the caps; 40 MP in one ffmpeg graph on a 1 GiB container is not measured.
- Instagram item links expire within hours; the server re-resolves the post itself for a save or a retry.

## 11. Owner questions

All closed 2026-10-07 by the owner's approval of the boards ("I like all of that"): grid cells of one shape with centre crops (R3),
videos left out of a gallery image (R4), PDF later (R2). Remaking an output replaces it (R8, decided in the same pass to match the
boards' unnumbered names). Nothing open.

## 12. Boards (written 2026-10-07 to the session scratchpad `gallery2/boards/project/`, merged into the canvas by Fable, approved by the owner)

All iPhone (390×844 device in a 712×844 board with review controls), each with a reset and a dark toggle; every interaction is
listed on its board with the claim it demonstrates; the shared numbers come from `gallery2/model/gallery-model.js` inlined
verbatim. Slides are neutral placeholders. Checkers (plain node, the boards' own logic on a stub runtime: every binding in every
state reached, each claim asserted behaviourally, reset, `var()` coverage and text contrast in both themes; Gallery-Image also every
geometry row of 6.4): `gallery2/boards/check-b1.mjs` 9562 checks and `check-b2.mjs` 60148 checks, 0 failures each (re-run by this
lane). Not rendered in the canvas runtime by this lane.

| board | shows |
|---|---|
| `Gallery-Paste.dc.html` (reworked) | paste → saves everything at once → make from it; a make tapped mid-save waits; Files, not Photos; partial + retry; one photo; reel unchanged; 1.13 today for comparison |
| `Gallery-Combine.dc.html` (reworked) | slideshow webp / mp4 / gallery image; drag to reorder, untick; one slider; crossfade; caps with their ways out; size follows crossfades not seconds; queued, making, done, failed |
| `Share-Gallery.dc.html` (reworked) | the compact sheet: one height in checking and choice; three choices; layouts inline; one request each; final notification; 8 s; older server |
| `Gallery-Image.dc.html` (new) | the four layouts drawn from the shared geometry for six posts; cells, crops, drawn-larger, caps; the helper's filter graph |
| `Gallery-Detail`, `Photo-Detail`, `Library-Mixed`, `Orbit-Photos`, `Shortcuts-Gallery`, `More-Ideas` (2026-10-06, unchanged) | still current except: Gallery-Detail's `more` list (1.19 replaces it), More-Ideas' long image / PDF (R2), Shortcuts' `make a video` option (1.13) |
