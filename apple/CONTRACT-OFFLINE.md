# cobalt for apple: offline media in the Files app (owner request, 2026-10-06)

Owner, verbatim: "I also need an offline property on media so can hold press or right click and it tries to save
it i am not sure if u can track the state of the photos in ios so maybe consider moving the offline folder to the
files folder in the thing please".

Facts this rests on (from Fable, not re-measured here): the owner's iPhone build is Feather-signed **without** the
app group, so the store root is the fallback (`AppGroup.RootKind.fallback`, the app's own Application Support);
iPhone 15 Pro Max on iOS 27.2; the photos album sync is on (default) and working; the Mac app is Developer-ID
signed, unsandboxed, and copies into `~/Movies/cobalt` with `FolderSync`.

Status: **decided, nothing built.** The diffs and API below are the proposal; lanes apply them. Line references were
read on 2026-10-06 from this worktree (`e64973603` plus the uncommitted Screens/** work of the sheet lane).

---

## 0. What exists today (read, not assumed)

- **One store, one hidden folder.** `OfflineStore` keeps every file under `<root>/files`, posters under
  `posters/`, flipbooks under `previews/`, transient downloads under `inbox/`, and `index.json`
  (`Store/OfflineStore.swift:106-127`). `root` is `AppGroup.directory("Videos")`, decided once per process
  (`Store/Settings.swift:69-76`, `:93-112`): the group container, else Application Support (the owner's phone).
  The share extension writes the same index under `NSFileCoordinator` (`OfflineStore.swift:1111-1141`).
- **"Offline" today is just "the record has a file".** `Record.fileName != nil` (`OfflineStore.swift:894-948`).
  There is no owner intent anywhere: the 5 GB LRU limit (`Store/StorageLimit.swift:20`) may take any file except
  the newest 12 media and in-process pins (`OfflineStore.swift:1042-1089`).
- **Phase 2 of the limit drops whole media** whose records are all file-less (`OfflineStore.swift:1067-1087`).
  Any new "kept elsewhere" location that leaves `fileName == nil` would be dropped by this rule. Decision 4 fixes it.
- **Removing.** `evict(_:)` ("remove offline copy", `OfflineStore.swift:694-708`) drops one file and keeps the
  record. `removeMedia(_:)` ("remove from this iphone", `:601-621`) drops every record. `clearAll()` (`:234-247`)
  drops everything. Turning "keep videos on this iphone" off asks, then `dropFilesKeepingPosters()`
  (`SettingsScreen.swift:45-50`, `OfflineStore.swift:670-682`).
- **Getting a file back.** `LibraryModel.redownload` (`Models/LibraryRedownload.swift:17-118`) runs in the
  foreground with `client.download`: studio source, then the first URL, then the keyed private copy
  `GET /library/items/<id>/file`. The detail's "on this iphone" section shows it as "download again"
  (`Screens/Detail/OfflineCopy.swift:18-117`).
- **Background downloads already exist** for share-sheet originals: `OriginalFetcher` + `PendingOriginals` over the
  `BackgroundTransport` seam (`Photos/OriginalFetcher.swift:1-460`), session `com.capybaraharmony.cobalt.bg.app`.
  It never reports bytes (its delegate has no `didWriteData`) and never resumes (no resume data). The app routes
  every `…cobalt.bg.` wake to it (`Models/AppModel.swift:313-323`, `Cobalt/App/CobaltApp.swift:155`).
- **The server routes are Range-aware but send no validator.** `libraryFile` (`deploy/cloudflare/api/src/app-routes.ts:771-776`)
  and `studioSource` (`studio-edge.ts:221-226`) send no `ETag` and no `Last-Modified`. URLSession only produces
  resume data when the response has one of them, so a dropped background download of a private original starts over.
- **Photos and the Mac folder are keyed by item, not by path.** `PhotosKey` (`Photos/PhotosLedger.swift:7-21`) is
  `s:<session>`, `r:<url>`, `w:<url>` or `i:<store id>`. `FolderLedger` uses the same keys. Moving a file changes
  neither ledger. Both read `StoredVideo.fileURL`.
- **Mac folder.** `FolderSync` (`Folder/FolderSync.swift`) copies each new store file once into `~/Movies/cobalt`
  (or a chosen folder kept as a bookmark). Done is forever, so a file deleted in Finder is never put back.
  **But deleting it in Finder frees nothing**, because the store keeps its own copy. Naming lives in
  `Folder/FolderNaming.swift` (`<title>.<ext>`, `<title> · webp <n>.webp`, ` (2)` on a clash).
- **Nothing is in Documents except debug dumps** (`HomeScreen.swift:968-992`, `OrbitGeometry.swift:1084,1381`,
  behind launch arguments). There is no `UIFileSharingEnabled` in `Config/Cobalt-Info.plist`.
- **Repo vs reported Mac signing.** `Config/Cobalt-macOS.entitlements` sets `com.apple.security.app-sandbox = true`.
  Fable reports the shipped Mac app as unsandboxed Developer ID. Not reconciled here (section 9).

---

## 1. Decisions

### The layout

1. **(lane) Layout (a): one copy, and the visible folder is where kept files live.** Reasons, strongest first:
   - **Deleting in Files has to free space.** If Files showed a mirror (b), the owner's main way to manage space
     would free nothing: the hidden copy stays and the device word "offline" means two things. Today's Mac
     `FolderSync` has exactly this flaw (section 0).
   - **Storage.** (b) doubles every kept video; with the photos album on, (b) makes it three copies.
   - **"Is it offline?" has one answer.** A kept file is a file in the folder, or not. The store re-reads the folder
     (decision 7) instead of keeping two copies in step.
   - **Robust to owner edits.** Renames and moves are followed by an id stored on the file itself (decision 6), so
     owner edits are routine, not corruption.
   - **Share extension.** It makes no difference. Without the app group (the owner's phone) the extension has its
     own store and cannot write the app's Documents in either layout. With the group it writes the hidden cache
     and the app moves the file in (decision 12).
   - **iCloud Drive: no.** "On My iPhone" is local. An iCloud Drive folder would add dataless placeholders and
     sync conflicts and would need an iCloud entitlement that Feather re-signing does not carry.
   - **Mac parity.** The same model with a different root (decision 15). The Mac's folder becomes the kept files,
     not a copy of them.

2. **(lane) The tree.** On iOS the visible root is the **app's `Documents/` itself**. Files already labels that folder
   "On My iPhone › cobalt", and a `Documents/cobalt` subfolder would read "cobalt › cobalt".
   ```
   <app container>/Documents/                  ← Files: On My iPhone › cobalt (UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace)
       instagram · DeHC9jcpfQW.mp4             ← kept files, friendly names (decision 8); the owner may add subfolders
       instagram · DeHC9jcpfQW · webp 1.webp
       .cobalt-<id>.part                       ← a copy in flight (hidden; Files hides dot files)
       .Trash/                                 ← Files' "recently deleted" for this location (owner's; never read as kept)
   <store root>/Videos/                        ← unchanged and hidden: AppGroup.directory("Videos")
       index.json  posters/  previews/  inbox/
       files/                                  ← the CACHE: files nobody asked to keep, and kept files waiting to move
   ```
   The index, posters, flipbooks, ledgers (`Sync/`), jobs and telemetry stay where they are. Debug dumps leave
   `Documents/` for `Library/Caches/debug/` (decision 16).

### The offline property

3. **(lane) Two tiers, one store. "Kept" is the owner's intent; "place" is where the file is.**
   - **kept** (`Record.keep == true`): the owner wants it on this device. Never evicted. It lives in the visible
     root when there is one; until it can move (an extension wrote it, a pipeline is reading it, the Mac in wave 1)
     it waits in `files/`, still kept.
   - **cache** (`keep` false or absent, file in `files/`): something a run needed or a save the owner did not ask to
     keep. The storage limit may take it.
   - **Record fields** (additive, optional, decoded with `decodeIfPresent`):
     `keep: Bool?`, `visiblePath: String?` (relative to the visible root, may contain the owner's subfolders),
     `givenName: String?` (the file name cobalt chose, for decision 8).
   - **Invariants**, held inside every coordinated write: `fileName` and `visiblePath` are never both set, and
     `visiblePath != nil` implies `keep == true`. A record with neither has no file here and keeps its poster and
     flipbook, as an evicted one does today.
   - **Per rendition, as the UI sees it** (`RenditionOffline`, section 5): `offline` (kept, file here), `cached`,
     `downloading(progress)`, `waiting` (queued, no network yet), `failed(reason)`, `none` (not here),
     `unavailable` (not here and no source to fetch it from).
   - **Per media** (`MediaOffline`): `all` when every rendition of the `MediaItem` (server-only webps included) is
     `offline`; `some` when at least one is; else `none`. Cached renditions do not count. The cache is invisible
     plumbing, and calling a file "offline" that may leave on its own would be a lie.

4. **(lane) Kept means never evicted. The storage limit becomes the cache limit.**
   - `enforce` (`OfflineStore.swift:1042`) only ever considers **cache** files: phase 1 skips `keep == true`; phase 2
     drops a media only when every record has `fileName == nil && visiblePath == nil && keep != true`. Without the
     second half, phase 2 would delete the poster and record of every kept media, the bug section 0 warns of.
   - Usage splits in two: `offlineUsage.offline` (kept files, wherever they wait) and `offlineUsage.cache`. The
     limit, `bytesToFree` and the progress bar use the cache figure only. `usage` (total) keeps its meaning for the
     callers that read it (`HomeScreen.swift:556`).
   - The "newest 12 media" protection stays for the cache. Default limit stays 5 GB, label "cache limit".
   - `clearAll()` leaves the UI. Its replacement `clearCache()` drops cache files only and keeps every record, poster
     and kept file.

5. **(lane; owner question 1) New saves are kept by default.** The existing toggle (`keepVideosOnDevice`, default on)
   is relabelled **"keep new saves offline"** and keeps its storage key, so the owner's current answer carries over.
   - **On:** every original and webp this device saves lands kept, in Files.
   - **Off:** originals are not downloaded (today's meaning). Webps and plain-cobalt saves, which runs always store,
     land in the cache.
   - **Turning it off deletes nothing.** The confirm and `dropFilesKeepingPosters()` go (`SettingsScreen.swift:45-50`).
     It is a policy for new saves; the owner removes existing files in Files or with "remove offline copy".
   - Consequence the owner must accept (question 1): kept files are not capped. Today's 5 GB cap only ever bounded
     the store's copy; with the photos album on, Photos already holds an uncapped second copy.

### Identity, Files edits, tracking

6. **(lane) Identity lives on the file: one extended attribute.** Name `com.capybaraharmony.cobalt.item`; value a small
   JSON, under 512 bytes: `{v:1, id, media, kind, session?, remote?, link?, created, title?}`. It is written
   **before** the file enters the visible root, so a file in the root without the attribute is never cobalt's.
   `rename(2)` keeps attributes, so renames and moves inside the root are followed. The payload lets a lost or
   rolled-back index rebuild a minimal record. What each owner edit means:

   | the owner, in Files | the scan finds | the store does |
   |---|---|---|
   | deletes a kept file | no file with that id under the root (`.Trash` is skipped) | `visiblePath = nil`, `keep = false`: **not offline**, never re-downloaded. The poster and record stay for now, but the media is a cache media from then on: like any evicted media, the limit's second pass may take its poster and record later (review fixes, below) |
   | restores it from recently deleted | the id again | adopts it: `visiblePath` = where it is, `keep = true` |
   | renames it, or moves it into a subfolder | the id at a new path | `visiblePath` follows; the media's title is not touched |
   | duplicates it | the id twice | the recorded path wins (else the first path in sorted order); the copy is left alone, and adopted later if the original goes |
   | moves it out (another app's folder, iCloud Drive) | no id under the root | as a delete |
   | edits it in place (size changes) | the id, a new size | `bytes` updated |
   | drops their own file in | a file with no attribute | **left alone**: never shown, moved or deleted (import is not in this pass) |
   | replaces a kept file with another of the same name | no matching id | the record is "not offline"; the new file is the owner's |
   | (index lost or rolled back) | an id with no record | a minimal record is rebuilt from the payload, origin `.adopted` |
   | (root unreadable: Mac folder on an unplugged disk) | nothing | **no change at all**: a missing root is never "every file deleted" |

7. **(lane) Tracking: rescan, never a live presenter.** The root is enumerated (recursive; skips hidden entries,
   `.Trash` and `.cobalt-*.part`; reads size and the attribute) and reconciled in one coordinated index write.
   - **When:** at launch (after the migration, section 2); on every `scenePhase == .active`, inside
     `AppModel.pickUpSharedJobs` right after `store.reload()` so Photos and the folder see the result; before any
     action on a kept file (remove, share, save to Photos, play from file); after a background-session wake.
   - **While cobalt is in front:** a `DispatchSource` on the root's descriptor (`.write`, the root only) triggers a
     debounced (0.5 s) rescan. That covers drag and drop beside cobalt on an iPad. A change inside a subfolder waits
     for the next foreground.
   - **Why not `NSFilePresenter`:** cobalt is suspended whenever the owner is in Files, and Apple's guidance is to
     remove presenters in the background, since coordination waits on them. The scan is cheap: hundreds of
     `stat` + `getxattr` calls, run off the main actor.
   - **Our own moves never race the scan.** Both run through one in-process async gate (`OfflineFolderGate`), and
     each move is ordered attribute → rename → index write. A crash at any point leaves a state the next scan
     settles (section 2.3).

8. **(lane) Names: `FolderNaming`, on both platforms.** `FolderNaming.fileName(for:in:)` decides the name;
   `FolderNaming.unique` settles clashes, compared case-insensitively. `givenName` records the result.
   **Renames in cobalt follow while the owner has not renamed the file:** `setTitle` renames every kept file whose
   current name still equals its `givenName` to the new `FolderNaming` name, then updates `givenName` and
   `visiblePath`. A file the owner renamed is never renamed again. This replaces `FolderNaming`'s "renames do not
   follow" rule only for the new model; Mac `FolderSync` keeps that rule until wave M retires it.

### Keep offline and remove offline copy

9. **(lane) "keep offline" downloads in a background `URLSession`, resumable, with progress.**
   - **Scope.** On a media it covers every rendition not yet `offline`, server-only webps included. On a detail tab it
     covers that rendition. A `cached` rendition only flips to kept and moves (no download).
   - **Sources, best first** (the first 404/409/410 moves to the next, as `sourceIsGone` does today,
     `LibraryRedownload.swift:78-89`):
     - **video:** the post's private copy `.libraryItem(id)` (keyed, durable, Range-aware, either visibility under
       CONTRACT-VISIBILITY decision 1); then the hosted file's URL `.open`; then `.studioSource(session)` (7 days);
       then the record's `remoteURL` `.open`.
     - **webp:** its public `url` `.open`; else `.libraryItem(file.id)` when `canToggleVisibility` (a webp switched
       private); else the record's `remoteURL`.
     - **No source and no file:** `unavailable`. The action is hidden (plain cobalt saves with no server copy).
   - **Engine.** `OfflineDownloads` (new, `Offline/`): its own ledger `Sync/offline-queue.json`
     (`CoordinatedFile`), its own background session `com.capybaraharmony.cobalt.bg.offline`, the existing
     `BackgroundTransport` seam extended with progress and resume data. `OriginalFetcher` is **not** touched.
     `AppModel.handleBackgroundDownloads` routes `…bg.offline` to the new engine and every other identifier to
     `originals` as today.
   - **Session config:** `isDiscretionary = false`, `sessionSendsLaunchEvents = true`, cellular and constrained
     networks allowed (the owner asked for it), `timeoutIntervalForResource = 24 h`, at most 2 connections per host
     (the rest show `waiting`). A keyed request carries the key header; the system keeps that request on disk while
     queued (accepted: the owner's key on the owner's phone). Started from the foreground, so never rate-limited
     (CONTRACT-SYNC F4).
   - **Progress:** `didWriteData` → a `Mutex` → `MainActor`, throttled to 4 Hz with the existing `Throttle`.
     Readable as `OfflineDownloads.states[key]` and a summary for Settings.
   - **Resume:** a failure that carries `NSURLSessionDownloadTaskResumeData` is saved to
     `Sync/offline-resume/<key>.data` and restarted with `downloadTask(withResumeData:)` on the next try. Needs the
     server's validator (section 6); until that deploys, a retry starts over, which is correct but slower.
   - **Failures:** 401/403 → `failed(.auth)` (no retry; the server card already says the key is wrong). ENOSPC →
     `failed(.full)` (no retry until the owner retries). Network → `waiting`, retried on the next foreground, up to
     5 tries, then `failed(.unreachable)`. All sources gone → `failed(.gone)`. Retry is the same "keep offline" action.
   - **Landing.** The delegate moves the file into `inbox/` synchronously; on the main actor it is `attach`ed to the
     existing record, or `add`ed when the media is post-only, with `keep: true`, which places it in the visible root
     at once.
     - A post-only media gets `sessionID = post.session?.id ?? post.id` (so `MediaItem.joins` is true),
       `link = post.link`, the webp's `remoteURL`, the custom title, and **`createdAt` = the server's**, so an old
       post does not jump to the front of the orbit.
   - **Not a new save:** every add from this engine has origin `.keepOffline`. `PhotosSync` and `FolderSync` mark its
     keys `skipped(preexisting)` and never copy it. Keeping an old library post offline on the iPad must not put it
     in Photos and from there, through iCloud Photos, on every device. The manual "save to photos" stays.
   - **Cancel:** "stop downloading" cancels the task, deletes the resume data and drops the queue entry. A media
     whose post-only download was cancelled has no local record (nothing was added).
   - **Replaces** `LibraryModel.redownload` and the "download again" button. `redownload` stays as a thin wrapper
     calling the engine, so `FocusAndRedownloadTests` keep their meaning.

10. **(lane) "remove offline copy" deletes the file and keeps the record.** Kept or cached, visible or hidden:
    the file goes (`removeItem`, not the trash), `keep = false`, poster and flipbook stay, the planet stays.
    - It is refused while the file is in use (`isInUse`; the button is hidden, as `OfflineHooks.evict` does today).
    - **The only copy is a different question.** When the rendition has a local file and nothing on the server
      (`!item.hasServerCopy` for the video; no `file`/`publicURL` for a webp), the confirm says it cannot come back
      (copy in section 3).
    - "remove from this iphone" (CONTRACT-MEDIA 1.12) keeps its meaning (records and planet go, files too, the
      visible ones included). "delete everything" also removes the visible files.

### Surfaces

11. **(lane) Where the property shows and is acted on.**
    - **Library tile, row and table line** (`LibraryTile`, `LibraryTable`, `LibraryParts`): a small badge in the
      existing badge slot: `all` filled, `some` outline, `downloading` a 14 pt determinate ring, `failed` an
      exclamation. `none` and `cached` show nothing, so the default stays quiet. The table gets an `offline` column
      on iPad and Mac (sortable as a rank all > some > none).
    - **Filter:** `LibraryShow.offline` ("offline") after "uploads". It passes `all` and `some`, and like every
      filter needs the whole library (`needsWholeLibrary`). Local-only media (no post) are still not library rows;
      they live in the orbit (unchanged).
    - **Context menu** (`LibraryMenuItems`, `LibraryMenus.swift:12-54`; long press on iOS, right click on the Mac):
      after "save to photos" / "save as…", exactly one of
      - "keep offline" (`none`/`some`, when a source exists),
      - "stop downloading" (downloading or waiting),
      - "remove offline copy" (`all`, or `some` with nothing left to fetch).

      When `some`, **both** "keep offline" (fetches the rest) and "remove offline copy" show. iOS adds
      "show in files" for a media with a kept file in the visible root (decision 11a).
    - **Detail, "on this iphone" section** (`OfflineCopy.swift`): the section becomes **one toggle "keep offline"**
      for the selected tab, with one status line under it: where it is and its size, progress, waiting, the failure
      and its retry, or "not on this iphone" when off. Toggling off asks the confirm of decision 10. The toggle is
      disabled (not hidden) when `unavailable`, with the line "nothing to download it from".
    - **Detail `more` menu** (`DetailMenu.swift:8-61`): "keep everything offline" when the media is `some`, placed
      after "show in finder" / "show in files". "remove from this iphone" stays.
    - **Orbit: unchanged.** Planets stay "local media by latest activity" (`HomeScreen.swift:198`): every media with
      a record, kept, cached or file-less. Keep-offline does not reorder it (`createdAt` = the server's). No planet
      badge: the type capsule is the planet's only badge (CONTRACT-MEDIA 7), and the orbit is not a manager.
    - **Settings, section "on this iphone"** (`SettingsScreen.swift:146-210`), in this order:
      - toggle "keep new saves offline";
      - row "offline", "24 videos · 3.1 GB", with "open in files" on iOS;
      - row "downloading", "2 left · 120 of 300 MB", with "stop all" (only while the queue has anything);
      - picker "cache limit";
      - row "cache", "3 videos · 210 MB of 5 GB", with its progress bar;
      - "clear cache" (destructive, confirm);
      - the footer.
    - 11a. **"open in files" / "show in files"** opens `shareddocuments://<percent-encoded path>` (the root, or the
      file's folder). Ship it only if gate G-O proves that URL opens Files at that folder on iOS 26/27; otherwise both
      rows are left out (the footer names the place).

12. **(lane) Share extension, both modes.** `OfflineStore` gets `visibleRoot: URL?`: `Documents` in the iOS **app**
    process, `nil` in every extension, `nil` on the Mac until wave M, injected in tests.
    - With `visibleRoot == nil`, `add(keep: true)` writes `files/` with `keep = true`. **Promotion** (move into the
      root) runs in the app on `reload()`.
    - Promotion skips records that are `isInUse`, and records of a session with a live `SharedJob` or a live
      `PendingOriginal`, so the extension's quick view never loses a path it holds.
    - **Extensions never touch `visiblePath`.** `reconciled()` checks `files/` and `posters/` only, and leaves
      `visiblePath` to the app's scan. In an extension `StoredVideo.fileURL` is `nil` for a record in the root (it
      cannot open the app's Documents) and `place` still says `.offline`.
    - Owner's phone (no group): the extension has its own store, as today; the app downloads the share's original
      from the server (`OriginalFetcher.discoverShares`) and it lands kept.

13. **(lane; owner question 2, decided by the owner 2026-10-06) Photos album: an optional extra, off by default
    for new saves ("Files only").** It reads `fileURL`, which now resolves into `Documents`; keys do not change;
    `shouldMoveFile = false` keeps Photos' own copy. Deleting in Files never touches Photos, and a Photos deletion
    never touches Files. Adds with origin `.keepOffline` or `.adopted` are skipped (decision 9).
    - `Settings.photosAlbumSync` reads **false** when unset. Only the owner's taps ever wrote the key, so "unset"
      means "never touched" and no migration is needed. An explicit on (`PhotosSync.enable()`) is respected, and
      so is an explicit off. Nothing already in the album is removed by this default.

14. **(lane) Backup.** Every file in either tier that has a server copy gets `isExcludedFromBackup = true` (the
    server is its backup; gigabytes of video must not fill the owner's iCloud backup). Files with no server copy
    (plain-cobalt saves, uploads whose server copy is gone) stay in backups. Set when a file lands or is adopted,
    and re-checked on the scan. Today nothing is excluded, so this only removes bytes from backups.

15. **(lane) Mac: same model, two waves.**
    - **Wave 1:** the Mac gets every surface (badge, filter, right-click, toggle, downloads, cache split) with
      `visibleRoot == nil`. **Keep means cache until wave M (review fix S3, decided by Fable):** `FolderSync`
      already copies each save to `~/Movies/cobalt`, so a "kept" hidden copy would be a second, uncapped duplicate.
      On the Mac `OfflineStore.canKeep` is false: `add`/`attach` store `keep = false` whatever the caller asked,
      `setKeep(true)` is a no-op, and the hidden `files/` stay under the 5 GB cache limit. `FolderSync` keeps
      copying exactly as today.
    - **Wave M** (later, own gate; **superseded by section 13, 2026-10-07**, which keeps the root and the adoption idea
      and replaces the details below): the Mac's visible root becomes the `FolderDestination` folder (default
      `~/Movies/cobalt`) and `FolderSync` retires.
      - Adoption migration: each `FolderLedger` `done` entry whose file is in the folder at its recorded size is
        tagged (decision 6), and its record is pointed at it with the hidden duplicate deleted. Space goes back
        to the owner.
      - Entries the owner deleted from the folder, and `skipped(preexisting)` ones (the owner said "only new
        ones"), stay **cache**. Anything never processed is kept and moved.
      - Choosing another folder moves the kept files with progress, each move safe through the same
        attribute-first order, and scans both roots until done.
      - The decision-6 rule "a root that cannot be read changes nothing" covers an unplugged disk.
      - The visible-folder model is the only way the Mac stops holding two copies, which is why wave M exists. It
        is separable because Mac `FolderSync` works today and the owner's request is about the iPhone.

16. **(lane) Debug dumps leave Documents.** The `-previewOrbit*` writers (`HomeScreen.swift:968-992`,
    `OrbitGeometry.swift:1084,1381`) write to `Library/Caches/debug/` instead, so Files shows only media. These
    files are dirty in the sheet lane, so this edit waits for it (section 7).

---

## 2. Migration (first launch of the new build; app process only)

### 2.1 What moves

Every record with `fileName != nil` whose file exists becomes **kept** and moves into the visible root, with
`origin .migrated` (Photos and the folder already know these keys). The owner's existing files are at most 5 GB by
construction, are what the owner thinks of as "offline", and are what the request asks to see in Files. File-less
records (evicted) stay file-less, uploads included. `inbox/`, posters, flipbooks and the index do not move. The
Mac (wave 1) and extensions skip it (`visibleRoot == nil`).

### 2.2 Per record, in this order (each step idempotent)

1. Write the attribute on `files/<fileName>` (decision 6).
2. Choose the name: `FolderNaming.fileName`, then `unique` against the root (case-insensitive).
3. `moveItem(files/<name> → Documents/<friendly>)`. The app-group container and the app container sit on one data
   volume, so this is a rename. If it fails with a cross-device error: copy to `Documents/.cobalt-<id>.part`,
   `F_FULLFSYNC`, compare size, rename to the final name, and only then delete the source.
4. One coordinated index write: `fileName = nil`, `visiblePath`, `givenName`, `keep = true`.
5. Set backup exclusion (decision 14).

Records go newest first, in batches of 20 per index write, off the main actor, behind `OfflineFolderGate`. A
record that is `isInUse` waits for the next `reload()`. Progress is not shown (renames are instant; telemetry
`offline migration` carries moved, failed and bytes).

### 2.3 Crash safety (why it never loses a file)

| crash after | on disk | next launch |
|---|---|---|
| step 1 | cache file carrying the attribute | step 2 onwards runs again |
| step 3 | file in Documents carrying the attribute; index still says `files/<name>` | `reconciled()` sets `fileName = nil` (missing); the scan finds the id in the root and adopts it, `keep = true` |
| step 3, copy path, before the rename | `.cobalt-<id>.part` and the source both present | `.part` files older than 1 h are deleted; the source is untouched and the record moves again |
| step 3, copy path, after the rename, before the source delete | both copies | the scan adopts the Documents one; `reconciled` keeps `fileName`, so the invariant check (both set) deletes the **cache** copy only after confirming the visible one's size |
| step 4 | done | nothing |

No source is deleted before its destination is whole. The migration has no "done" flag that could lie: it is
"move every kept-eligible cache file", re-evaluated on every launch, and finds nothing after the first. A marker
`Sync/offline.json {migratedAt, version: 1}` exists only for telemetry and for the Settings footnote.

### 2.4 Store-root changes and rollback

- **Fallback → app group** (a properly signed build later): `AppGroup.migrateFallback` moves `Videos/` as today.
  `visiblePath` is relative to Documents, which does not move. Nothing else to do.
- **Downgrade** (Feather installs an older build): the old build ignores the unknown keys and sees moved records as
  evicted (poster only, "download again"). Its next index write **drops** `keep`, `visiblePath` and `givenName`.
  On upgrade the scan re-adopts every tagged file by id, which is the reason the attribute exists. Files are never
  touched by the old build, which knows nothing of Documents.

### 2.5 Tests for it (section 8)

Fixtures for a 1.10 index (app-group root and fallback root, a mix of kept, evicted and missing files, webps, an
upload, a GIF proxy `-play.mp4`). Crash injection after every step through a `FileOps` seam. Second run is a no-op.
Downgrade round-trip.

---

## 3. Copy (lowercase, exact; new `Cobalt/Design/Copy+Offline.swift`; `\(Copy.device)` = iphone / ipad / mac)

| where | text |
|---|---|
| menu, detail, toggle | `keep offline` |
| menu (some offline) | `keep offline` (fetches the rest) |
| detail more menu (some) | `keep everything offline` |
| menu, settings | `stop downloading`, `stop all` |
| menu, toggle off | `remove offline copy` (existing `Copy.Offline.removeCopy`) |
| confirm (server has it) | title `remove the offline copy?` · message `the server keeps its copy. you can keep it offline again any time.` · `remove` / `keep` |
| confirm (only copy) | title `remove the only copy?` · message `this isn't on your server. once it's removed it can't be downloaded again.` · `remove` / `keep` |
| status: kept, iOS | `in the files app · 54 MB` |
| status: kept, Mac wave 1 | `on this mac · 54 MB` (wave M: `in ~/Movies/cobalt · 54 MB`, the display path) |
| status: cached | `in the cache · 54 MB · leaves when space runs low` |
| status: downloading | `downloading… 12 of 54 MB` (no total: `downloading… 12 MB`) |
| status: waiting | `waiting for the network` |
| status: failed | existing `Copy.Offline.failure`, plus `.auth`: `your key was refused. check it in settings.` and `.full`: `this \(device) is full.` |
| status: unavailable | `nothing to download it from` |
| status: none | existing `Copy.Offline.missing` (`not on this iphone`) |
| filter | `offline` |
| table column | `offline` |
| menu, iOS | `show in files` |
| settings toggle | `keep new saves offline` (replaces `Copy.keepVideos`) |
| settings rows | `offline` · `24 videos · 3.1 GB` · `open in files` · `downloading` · `2 left · 120 of 300 MB` · `cache limit` · `cache` · `3 videos · 210 MB of 5 GB` · `clear cache` |
| clear confirm | title `clear the cache?` · message `offline videos stay. the server keeps its copies.` · `clear` / `keep` |
| footer | `offline videos stay on this \(device) until you remove them, here or in files › on my \(device) › cobalt. the cache makes room by itself.` (Mac wave 1: drop the files clause) |
| accessibility (badge) | `offline`, `partly offline`, `downloading, 40 percent`, `couldn't download` |

Retired: `Copy.removeVideosTitle` / `removeVideosMessage` (the keep-off confirm), `Copy.Offline.downloadAgain`,
`Copy.Storage.clear*` (replaced by the cache wording), `Copy.Storage.limit` ("storage limit" → "cache limit").

## 4. SF Symbols (new `Cobalt/Design/Symbols+Offline.swift`; the U lane resolves each on iOS 26 and macOS 26 and swaps any that do not exist)

`offlineAll = "arrow.down.circle.fill"`, `offlineSome = "arrow.down.circle"`, `offlineFailed = "exclamationmark.circle"`,
`keepOffline = "arrow.down.circle"`, `stopDownloading = "stop.circle"`, `showInFiles = "folder"`,
`cache = "internaldrive"` (existing `Symbol.offlineOn`), `removeOffline` (existing `xmark.bin`).

---

## 5. Pinned CobaltKit API (additive; UI lanes build against exactly this)

```swift
// Store/StoredMedia.swift + Store/OfflineStore.swift  (K1)
extension StoredVideo {
    public enum Place: String, Sendable, Codable { case cache, offline }   // offline = in the visible root
    public var place: Place?          // nil: no file on this device
    public var keep: Bool             // the owner keeps it offline (never evicted)
    public var isOffline: Bool { get } // keep && place != nil
    // fileURL: unchanged meaning ("the file, if this process can open it"); now resolves either tier.
}
public enum AddOrigin: Sendable, Equatable { case save, keepOffline, adopted, migrated }
public struct OfflineUsage: Sendable, Equatable { public var offline: StorageUsage; public var cache: StorageUsage }
public struct OfflineScanReport: Sendable, Equatable {
    public var followed: Int, unkept: Int, adopted: Int, rebuilt: Int, untracked: Int, rootMissing: Bool
}
extension OfflineStore {
    public var visibleRoot: URL? { get }
    public var offlineUsage: OfflineUsage { get }                     // from the index, no disk I/O
    public func add(file: URL, kind: StoredVideo.Kind, media: MediaInfo, sessionID: String?, link: URL?,
                    remoteURL: URL?, move: Bool, publicURL: URL? = nil, mediaID: String? = nil,
                    clip: WebpClip? = nil, keep: Bool, createdAt: Date? = nil,
                    origin: AddOrigin = .save) async throws -> StoredVideo   // `keep` has no default: every caller decides
    public func attach(file: URL, to id: String, move: Bool, keep: Bool) async throws -> StoredVideo
    /// keep = true: flags the records and moves files that are here into the visible root; returns the ids with no
    /// file (the caller downloads them). keep = false on a record with a file = removeOfflineCopy.
    @discardableResult public func setKeep(_ keep: Bool, ids: [String]) async -> [String]
    @discardableResult public func removeOfflineCopy(_ id: String) async -> Bool   // `evict(_:)` stays as an alias
    @discardableResult public func scanVisibleRoot() async -> OfflineScanReport
    public func clearCache() async
    public func runMigrationIfNeeded() async                          // section 2; no-op without a visible root
    // onAdd becomes (StoredVideo, AddOrigin); PhotosSync / FolderSync skip .keepOffline, .adopted, .migrated
}

// Models/MediaItem.swift + Models/LibraryView.swift  (K2)
public enum MediaOffline: Sendable, Equatable, Comparable { case none, some, all }
extension MediaItem { public var offline: MediaOffline { get } }       // from renditions' `local`; cached ≠ offline
extension LibraryRow { public let offline: MediaOffline }               // set in init(item:)
extension LibraryShow { case offline }                                  // after .uploads; rawValue "offline"
extension LibrarySortKey { case offline }                               // table column

// Offline/OfflineDownloads.swift  (K2)
public enum OfflineFailure: Sendable, Equatable { case gone, unreachable, auth, full, other(Int) }
public enum RenditionOffline: Sendable, Equatable {
    case offline(bytes: Int64), cached(bytes: Int64), downloading(TransferProgress), waiting,
         failed(OfflineFailure), none, unavailable
}
public enum OfflineKey { public static func of(_ r: Rendition) -> String }   // "f:<server file id>", else "l:<record id>"
@MainActor @Observable public final class OfflineDownloads {
    public private(set) var states: [String: RenditionOffline]          // downloading / waiting / failed only
    public var summary: (left: Int, bytes: Int64, total: Int64?) { get }
    func handleWake(identifier: String) async
    func reconcile() async                                              // every foreground, after the scan
}
extension AppModel {
    public var offlineDownloads: OfflineDownloads { get }
    public func offlineState(of rendition: Rendition) -> RenditionOffline
    public func offlineState(of item: MediaItem) -> (offline: MediaOffline, downloading: TransferProgress?, failed: Bool)
    public func keepOffline(_ item: MediaItem, rendition: Rendition? = nil)            // nil = every rendition
    public func stopDownloading(_ item: MediaItem, rendition: Rendition? = nil)
    @discardableResult public func removeOfflineCopy(_ item: MediaItem, rendition: Rendition? = nil) async -> Bool
    public func isOnlyCopy(_ rendition: Rendition) -> Bool
    public func showInFilesURL(_ item: MediaItem?) -> URL?              // iOS; nil when gate G-O failed
}
// API/HTTPCobaltClient.swift  (K2): the background engine needs the request, not the download
public protocol RemoteFileRequests: Sendable { func urlRequest(for file: RemoteFile) throws -> URLRequest }
extension HTTPCobaltClient: RemoteFileRequests {}   // a client that does not conform (PreviewClient) → foreground `download`
```

Preview data (`Preview/*`, K2): `AppModel.preview(.offline)` with one media `all`, one `some` (video kept, webp
server-only), one downloading at 40 %, one `failed(.gone)`, one `unavailable` (a plain save with no server copy:
the only-copy confirm), and Settings numbers `24 videos · 3.1 GB`, cache `3 videos · 210 MB of 5 GB`.

---

## 6. Server addendum (S; additive; the owner deploys)

`libraryFile` (`app-routes.ts:771`) and `studioSource` (`studio-edge.ts:221`) add `etag` (R2 `httpEtag`) and
`last-modified` (R2 `uploaded`, as an HTTP date) to 200 and 206 responses and to HEAD. Without them URLSession never
produces resume data (section 0). Tests: both routes return both headers, unchanged across two requests, on full and
ranged reads. The public media domain (`media.capybaraharmony.com`, R2 custom domain) is expected to send both
already; gate S-1 checks it with `curl -I`. No D1 change.

---

## 7. Lanes, waves, ownership

Children never commit. Each wave is gated by Fable (build iOS + Mac, `swift test`, diff review) before the next.
The macOS sheet-dismissal lane owns the dirty Screens/** files (`AppShell`, `Buttons`, `HeroFullScreen`,
`FocusView`, `HomeScreen`, `Inspector`, `PickerSheet`). Nothing below edits them, except decision 16 (W3, after
that lane lands). The parallel-jobs design lane: no shared files expected. `PipelineFlows.swift` add sites get one
argument each (`keep:`), so whichever lane lands second rebases that file.

| wave | lane (agent) | owns | builds |
|---|---|---|---|
| W1 | **K1 store** (`sonnet-lane`) | `Store/OfflineStore.swift`, `Store/StoredMedia.swift`, new `Store/OfflineFolder.swift` (root, attribute, scan, gate), new `Store/OfflineMigration.swift`, `Store/Settings.swift` (doc comments only), `Folder/FolderNaming.swift` (case-insensitive `unique` only), the `keep:` argument at the add sites in `Pipeline/PipelineFlows.swift` and `Photos/OriginalFetcher.swift:253`, `Config/Cobalt-Info.plist` + `project.yml` (`UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`), tests `OfflineFolderTests`, `OfflineMigrationTests`, updates to `StorageLimitTests` / `EvictTests` | decisions 3, 4, 6, 7, 8, 10 (store half), 12, 14; section 2 |
| W1 | **S server** (`sonnet-quick`) | `deploy/cloudflare/api/src/app-routes.ts`, `studio-edge.ts`, their tests | section 6 |
| W2 | **K2 downloads + model** (`sonnet-lane`) | new `Offline/OfflineDownloads.swift`, `Offline/OfflineQueue.swift`, `Offline/OfflineTransport.swift` (own URLSession delegate with progress + resume data; does not edit `OriginalFetcher`), `Offline/OfflineSources.swift`; `Models/AppModel.swift` (wiring, wake routing), new `Models/AppModel+Offline.swift`, `Models/MediaItem.swift`, `Models/LibraryView.swift`, `Models/LibraryRedownload.swift` (wrapper), `API/HTTPCobaltClient.swift` (`RemoteFileRequests`), `Photos/PhotosSync.swift` + `Folder/FolderSync.swift` (origin skip only), `Preview/*`, tests `OfflineDownloadsTests` | decisions 5 (model), 9, 10 (model half), 11 (state), 13; section 5 |
| W2 | **U surfaces** (`sonnet-lane`), builds against section 5 + `preview(.offline)` | `Screens/Library/{LibraryMenus,LibraryTile,LibraryTable,LibraryParts}.swift`, `Screens/Detail/{OfflineCopy,DetailMenu}.swift`, `Screens/Settings/SettingsScreen.swift`, new `Design/Copy+Offline.swift`, new `Design/Symbols+Offline.swift`, `Design/Copy+Live.swift` (retirements) | decision 11, section 3, 4 |
| W3 | **V evidence** (`sonnet-lane`) | nothing in source; saves to the session scratchpad | section 8.3 |
| W3 | **R review** (`opus-lane`) | read-only | adversarial review of K1/K2 against decisions 4, 6, 7, 12 and section 2.3 |
| W3 | **U2 debug dumps** (`sonnet-quick`, after the sheet lane lands) | `HomeScreen.swift`, `OrbitGeometry.swift` (paths only) | decision 16 |
| M (later; see section 13.12) | **M Mac visible root** (`sonnet-lane`, with an opus review) | `Folder/*`, `Store/OfflineFolder.swift` (Mac root), `Screens/Settings/FolderSettingsSection.swift`, `Shared/ShowInFinderButton.swift` | decision 15 wave M |

K2 and U run in parallel against the pinned API. U uses the preview model only until K2 lands.

---

## 8. Tests, gates, evidence

### 8.1 CobaltKit (`cd apple/CobaltKit && swift test`; temp dirs, injected clock, a `FileOps` seam for crash injection)

- **Store:**
  - `add(keep: true)` with a visible root lands in the root, tagged, `fileName == nil`; without one it lands in
    `files/` kept, and `reload()` promotes it.
  - Promotion skips `isInUse` and live-share sessions.
  - Invariants hold after every public call (property check over random sequences).
  - `setKeep`, `removeOfflineCopy`, `clearCache` (kept files untouched).
- **Limit:**
  - Kept files are never evicted in phase 1 or 2, even far over the limit.
  - A media with one kept rendition is never dropped in phase 2.
  - `bytesToFree` counts cache only; `offlineUsage` equals the bytes on disk after a scan.
  - Two store instances (app + extension) adding concurrently keep the invariants.
- **Scan** (each row of decision 6's table is one test): delete, restore from a `.Trash` folder, rename, move into
  a subfolder, duplicate, move out, edit in place, untagged file, replaced file, lost index rebuilt from the
  payload, root missing (no change), `.part` and hidden entries ignored.
- **Rename-follow:** an untouched file follows `setTitle`, a renamed one does not, and a clash gets ` (2)`.
- **Migration:** section 2.5.
- **Downloads** (fake `BackgroundTransport`):
  - queue → progress → land kept in the root;
  - source fallback on 404/409/410;
  - 401 → `.auth` with no retry; ENOSPC → `.full`;
  - failure with resume data → restart uses it;
  - relaunch mid-download re-attaches to the live task (no duplicate);
  - cancel removes the entry and the resume data;
  - a post-only media lands joined to its post (`MediaItem.joins` true) with the server's `createdAt`;
  - origin `.keepOffline` is skipped by `PhotosSync` and `FolderSync`;
  - `handleBackgroundDownloads` routes `bg.offline` to the engine and `bg.app` / `bg.share.*` to `originals`.
- **Model:** `MediaItem.offline` for all / some / none / cached-only (none); `LibraryShow.offline`; sort by offline.

### 8.2 Builds

iOS simulator and macOS builds as `CLAUDE.md` gives them; the share extension builds (it links the store).

### 8.3 Runtime evidence (V; iOS 26.5 simulator, then the owner's phone; every screenshot and log path returned with a pass/fail list)

- **G-F:** the Files app shows On My iPhone › cobalt with friendly names after migrating a seeded 1.10 store
  (`DebugHooks` seed).
- **G-X:** rename and move a file in the simulator's Files app, then `xattr -l` on the simulator container from
  the Mac: the attribute survived, and cobalt follows after a foreground.
- **G-T:** delete in Files: where the file goes (`Documents/.Trash`?) and cobalt shows it not offline; restore it
  and cobalt shows it offline again.
- **G-O:** `shareddocuments://` opens Files at the folder (decides decision 11a).
- **G-D:** keep offline on a post-only media: the progress ring in the library, the toggle's progress line,
  background the app mid-download, the landing in Files. Airplane mode mid-download, then back: resumed, not
  restarted (needs S deployed: compare bytes in the log).
- **G-M:** on the Mac, right click → keep offline / stop downloading / remove offline copy; the filter; the
  Settings rows.
- **G-P:** with the photos album on, a new save still reaches the album once; a keep-offline download does not.
- **S-1:** `curl -I` on a public webp, a private `/library/items/<id>/file` and `/studio/<sid>/source`: `etag` and
  `last-modified` present (after the owner deploys).
- **Device (owner, Feather):** the folder appears in Files on the Feather-signed build, so Info.plist keys survive
  re-signing.

---

## 9. Risks and what is not verified here

- **Unverified platform behaviour** (each has a gate in 8.3):
  - extended attributes surviving Files-app renames and moves, and restore from recently deleted (G-X, G-T);
  - where Files puts a deletion for an app location (G-T);
  - the `shareddocuments://` scheme (G-O);
  - Feather keeping `UIFileSharingEnabled` (device);
  - the public R2 domain's validators (S-1).

  Nothing here was run.
- **Mac signing:** the repo's `Cobalt-macOS.entitlements` says sandboxed; the shipped app is reported unsandboxed.
  Wave 1 does not care (`visibleRoot == nil` on the Mac). Wave M does: a sandboxed app needs the bookmark path
  `FolderDestination` already has, or `com.apple.security.assets.movies.read-write`. Settle this before wave M.
- **Kept files are uncapped** (decision 5). A phone can fill. Mitigations: the Settings "offline" row with its size,
  Files' own sort by size, and Photos no longer the only place to see them. The owner decides (question 1).
- **The owner deletes a whole folder of kept files in Files:** every one becomes "not offline", by design. They
  return with "keep offline" (a download) or by restoring from recently deleted (re-adopted, no download).
- **Files' recently deleted holds space for 30 days** after a delete in Files; cobalt never empties it (the
  owner's trash).
- **A keyed URLRequest persisted by `nsurlsessiond`** while queued: accepted (owner's key, owner's phone).
- **An old build writing the index** drops the new fields; the scan re-adopts by attribute (2.4). If G-X shows
  attributes do NOT survive some Files operation, the fallback match is `givenName` + size, which is weaker and
  is said in the result.
- **`DispatchSource` sees only the root, not subfolders**; subfolder edits wait for the next foreground (accepted).

---

## 10. Owner questions (the defaults apply unless the owner says otherwise)

1. **New saves: kept offline automatically?** Default **yes**: every new save appears in Files › On My iPhone ›
   cobalt and stays until you delete it there or tap "remove offline copy"; the 5 GB limit then only applies to a
   small hidden cache. "No" means saves stay in the cache (and leave when it is full) and only what you mark "keep
   offline" goes to Files.
2. **Photos album: keep adding new saves to the "cobalt" album too?** **Decided by the owner, 2026-10-06: no, "Files
   only".** The album sync is off by default for new saves; a video you delete in Photos is never added again; an
   explicit on is respected and nothing is removed from the album. (Each kept video would take space twice, in Files
   and in Photos.)

---

## 11. Rough cost

| lane | size (incl. tests) | notes |
|---|---|---|
| K1 store + migration | ~1,100 lines (~500 tests) | the risky one: invariants, scan, crash order |
| S server | ~40 lines + ~60 test lines | owner deploys |
| K2 downloads + model | ~1,000 lines (~400 tests) | second `BackgroundTransport`, progress, resume |
| U surfaces | ~550 lines | menus, badge, filter, toggle, settings, copy |
| V + R | evidence + one review | simulator Files app is the main cost |
| M (later) | ~600 lines | FolderSync retirement + adoption |

Three gated waves for iPhone/iPad/Mac wave 1, roughly 5-7 lane-hours. Wave M is a separate ~2-3 lane-hours when
the owner wants it.

---

## 11a. Galleries (2026-10-07, dated note; `CONTRACT-GALLERY.md` 1.8 is the rule)

A kept gallery is a folder named by the media's title (`instagram · Ddy0-gpGg5U/`) holding its items (`01.jpg … 10.jpg`, a video item
`03.mp4`) and every file made from it on this device's account: `slideshow.webp`, `slideshow.mp4`, `gallery image · 3 across.jpg`,
`03 · webp 1.webp`, `03 · crop 9:16.jpg` (FolderNaming's ` 2` on a clash). Made files are kept renditions: "keep new saves offline"
keeps them, the cache limit never takes them, the folder's extended attribute follows a rename (decision 6). The Mac's `FolderSync`
writes the same tree under `~/Movies/cobalt`. Photos: still off by default; a gallery reaches Photos only through the owner's
`save to photos`.

## 12. Review fixes to wave 1 (2026-10-06, dated note)

An adversarial review of `8121f0659` proved data-loss and unbounded-growth bugs with throwaway tests; each is now a
regression test (`OfflineReviewFixTests.swift`, test names in brackets). All in `Store/**`.

- **B1 deletes went by the remembered path** [`OfflineDeleteIdentityTests`]. "Remove offline copy", "remove from
  this iphone", "delete everything" and the title-follow rename now re-read the record's path from the index inside
  the gate and require the file's tag id to equal the record id (`OfflineFolder.removeVisibleChecked`,
  `OfflineFolder.rename`). On a mismatch (or a missing file) one scan settles the paths and it is tried once more;
  a file at the path that still is not provably the record's is left alone, the call returns false (the record
  stays). A tag that cannot be read refuses as well.
- **B2 a case-only rename overwrote a distinct file on a case-sensitive volume** [`OfflineCaseOnlyRenameTests`,
  on a case-sensitive APFS disk image]. Renames are always exclusive (`RENAME_EXCL`); a case-only change that
  answers "exists" is renamed plainly only when the destination is the same file (device and inode), else the
  clash rule picks ` (2)`. The folder listing keeps case, so a distinct `Rome.mp4` is a clash.
- **S1 an undecodable index was overwritten by the launch scan** [`OfflineUndecodableIndexTests`]. "Exists but does
  not decode" is `IndexUnreadable`: `mutate` throws and writes nothing, the scan reports `indexUnreadable` and
  changes nothing, promotion moves nothing. The bytes are kept as `index.unreadable-<date>-<fingerprint>.json` beside
  the index (once per content) and one telemetry error is logged. A missing or empty index is still a fresh store.
  While it lasts, writes (a new save) fail rather than lose the old index: that is the point.
- **S2 an extension with no app group kept shares nobody could promote** [`OfflineUnpromotableStoreTests`]. A store
  takes a save as kept only when `canKeep`: the process has a visible root, or it is an extension whose store the
  app reads (app group). Otherwise `keep = false` (cache; the limit governs it), and `reload()` releases records an
  earlier build left kept there. `OfflineStore.shared()` makes the call from the process
  (`OfflineFolder.storeIsSharedWithApp()`); the initializer's `sharedWithApp` defaults to true, so stores built
  directly (tests, `Preview/*`) keep as before.
- **S3 the Mac until wave M** (see decision 15): the same rule, `canKeep == false` on macOS.
- **S4 an unreadable tag read as "no tag"** [`OfflineUnreadableTagTests`]. `XAttr.read` separates ENOATTR (untagged)
  from every other error; any other error aborts the scan as `rootMissing` and refuses a delete.
- **S5 remove against promotion** [`OfflineRemoveVersusPromotionTests`]. "Remove offline copy" now runs entirely
  inside the gate in both tiers; promotion's index write requires the record to still exist, still be `keep`, and
  still point at the file it moved (else the moved file goes back out).
- **S6 a Files duplicate resurrected removed media** [`OfflineRemovedMediaStaysRemovedTests`]. Ids cobalt removed
  (a delete by identity, never the owner's own delete in Files) are kept as tombstones, newest 500, in
  `<hidden root>/tombstones.json` (beside the index, not in `Sync/`, so they move with the store and exist where the
  index does). The conservative rule: a tagged file whose id is tombstoned and that no record points at is the
  owner's own file (counted `untracked`, never adopted, rebuilt, moved or deleted); it is **not** adopted as a new
  media (import is not in this pass, decision 6). Keeping the id again (promotion) lifts its tombstone. A delete in
  Files is not a tombstone: restoring from recently deleted still adopts.
- Nits: a record whose cache file is gone adopts the tagged visible copy; `setKeep` no longer traps on an index
  that names one id twice.
- **Not changed:** an extension's remove of a record whose file is in the visible folder still cannot delete that
  file (extensions never touch the root); the app's next scan sees the tagged file and, with no record, rebuilds it.

---

## 13. Wave M + Mac pull (2026-10-07, dated section; supersedes decision 15's wave M bullets and section 7's "M" row)

Owner, Mac app 1.14.1 on macOS 27: "the macos doesnt autosave like the ios version". Interview answers (Fable, 2026-10-07):
(1) Mac autosave means **pull everything I save anywhere**: a save made on the iPhone, from the share sheet, Shortcuts or
the web downloads into the Mac folder by itself, **for new saves from now on** (no backfill of the library);
(2) the Mac gets **the same keep-offline controls as the iPhone** (keep offline, stop downloading, remove offline copy,
show in Finder), and the Finder folder is where kept files live.

Status: **decided, nothing built.** Lanes apply it (13.12). Line references read 2026-10-07 from this worktree at
`a64bc4ff7` (clean apart from the untracked `mobile/`).

### 13.0 Facts this rests on (read or measured today, not assumed)

- **The shipped Mac app is unsandboxed and has no app group.** `codesign -d --entitlements -` on
  `/Applications/cobalt.app` (1.14.1) lists only `com.apple.security.personal-information.photos-library`. The repo's
  `Config/Cobalt-macOS.entitlements` (sandbox, group, user-selected files) is not what ships; the release re-sign is
  outside the repo. Consequence: `AppGroup.directory` falls back to Application Support **without a bundle folder**:
  the store is `~/Library/Application Support/Videos`, the ledgers `~/Library/Application Support/Sync`.
- **The owner's real folder** (`ls -la@`, `Sync/folder.json`, `Videos/index.json`, read only):
  - `~/Movies/cobalt` holds 7 entries: 5 `.mp4` and 1 `.webp` at the top, and the gallery folder
    `instagram · DeKlsGCGZmx/` (`01.jpg`, `02.mp4`) whose `com.capybaraharmony.cobalt.folder` attribute is the media id
    `f9cb8f6f-…`. No top-level file carries a cobalt tag (FolderSync never tagged files).
  - `folder.json` has one section (`default`, `/Users/harmony/Movies/cobalt`) with **8 `done` entries and nothing else**
    (no `skipped`, no `claimed`): keys `s:<session>` ×5, `w:https://media.capybaraharmony.com/RByDDgGWTN.webp`,
    `g:7mKytvtqJDuJtCIVxRA2jN:0`, `…:1`. Every entry's `file` exists at its recorded `bytes`.
  - `index.json` has **8 records, 1:1 with those keys**: 6 with `keep` absent (legacy, pre-offline) and 2 gallery items
    with `keep: false` (wave 1, `canKeep == false`). All 8 cache files exist in `Videos/files/` at the same sizes.
  - Folder files have the **same mtime as their cache file** (`copyItem` keeps it) and older than the entry's `at`.
  - The two gallery files carry `com.apple.metadata:com_apple_backup_excludeItem`: the store excluded its own copy from
    backup and `copyItem` carried the attribute into `~/Movies`, so **Time Machine skips them today** (a leak, fixed in 13.3).
  - `defaults read com.capybaraharmony.cobalt` has no `keepVideosOnDevice` and no `folderSync`: both read their defaults (on).
- **The legacy migration would duplicate the owner's folder.** `runMigrationIfNeeded` (`Store/OfflineMigration.swift:14-20`)
  flags every `keep == nil` record with a file as kept and moves it into the visible root. Given `~/Movies/cobalt` as the
  root, the 6 legacy records would be moved in **beside** the FolderSync copies as `instagram · DeGGagYNxfv (2).mp4` and so
  on. 13.3 forbids it on the Mac.
- **The scan already adopts by tag.** `OfflineFolder.reconcile` (`Store/OfflineFolder.swift:608-697`): a tagged file
  whose record has `visiblePath == nil` is adopted (`keep = true`, `visiblePath` set) and the record's cache copy is
  dropped after the index write when the sizes match (`:644`, deleted at `:727`). Adoption is "tag the right files, then
  scan", plus one index write for `givenName`.
- **The library page is ordered by each post's newest file**, newest first (`deploy/cloudflare/api/src/app-routes.ts:704-709`,
  `MAX(created_at) … ORDER BY latest DESC`); every live file of a post comes with it, each with its own `created_at`.
  So a webp made today from a month-old post brings that post to the top with one new file.
- **The Mac app quits when its window closes**: it is one `Window` scene (`Cobalt/App/CobaltApp.swift:165-168`).
- **The Mac already follows share-sheet sessions still running on the server** (`JobQueue.adoptRecentShares`,
  `Jobs/JobQueue.swift:902-914`, CONTRACT-PARALLEL 3.3); those land as local saves.

### 13.1 The Mac's visible root is the chosen folder

- **Root:** the `FolderDestination` folder: `~/Movies/cobalt` by default, or the folder the owner chose (the existing
  `FolderLedger.destination` record and its bookmark are honoured as they are). In the **Mac app process**
  `OfflineStore.visibleRoot` is that URL **whether or not it is reachable right now**: never nil, so `canKeep == true`
  for the life of the app. The Mac share extension (if one is built) keeps `visibleRoot == nil` and `canKeep == false`
  (no group: `storeIsSharedWithApp()` stays false).
- **Mode, injected, never `#if`:** `OfflineStore.init(…, rootMode: VisibleRootMode)` with
  `enum VisibleRootMode { case documents, macFolder }` (`.documents` default). `shared()` passes `.macFolder` on macOS.
  Every Mac-only rule below is keyed on `rootMode`, so CobaltKit tests (which run on a Mac host) exercise both modes.
- **The root can change at run time** (choose, reset, a bookmark that followed a moved folder):
  `visibleRoot` becomes `public private(set) var`, swapped only inside `OfflineFolderGate` by
  `setVisibleRoot(_:)`, which also restarts the watcher. iOS never calls it.
- **Access:** unsandboxed today, so plain paths work. The bookmark path stays (`.withSecurityScope`), so a future
  sandboxed build keeps working: the store holds one `FolderAccess` open for the process lifetime and swaps it with the
  root. A sandboxed build would also need `com.apple.security.assets.movies.read-write` for the default folder (not in
  the repo's entitlements; not needed for what ships).
- **Reachability is separate from the root:** `OfflineStore.rootState: RootState` (observable):
  `.ready`, `.unreachable(path)` (a chosen folder whose bookmark does not resolve or whose path is not a directory: an
  unplugged disk), `.notAllowed(path)` (cannot be created or written), `.wrongFolder(path)` (13.6). The default folder
  is re-created when missing (as `FolderDestination.open` does today); a chosen folder never is.
- **Folders refused when chosen:** anything inside iCloud Drive (`isUbiquitousItemKey`, or under
  `~/Library/Mobile Documents`): evicted placeholders and attribute sync would break identity. Copy in 13.10.

### 13.2 One copy: what the store does differently in `.macFolder` mode

1. **No legacy migration.** `runMigrationIfNeeded` returns at once in `.macFolder`. Its job on the Mac is done by the
   adoption (13.3), and every record the adoption leaves alone with `keep == nil` is written `keep = false` in the same
   pass (cache), so no later build or code path ever reads it as "legacy, keep it".
2. **Deleting a visible file goes to the Trash.** `OfflineFileOps` gains `removeVisible(_:)`: `.macFolder` →
   `FileManager.trashItem` (falls back to `removeItem` only when the volume has no Trash), `.documents` → `removeItem`
   (decision 10 unchanged on iOS). `OfflineFolder.deleteFile` (`:417-428`) calls it; cache, `.part` and poster deletes
   keep `remove`. "remove offline copy", "remove from this mac", "delete everything" and a remake's replace (13.7) all go
   through it. A file put back from the Trash carries a tombstoned id and is the owner's (review fix S6), not re-adopted.
3. **No backup exclusion in the Mac folder.** `excludeFromBackup` (`:491`, `:728`) runs only in `.documents`. The
   folder is the owner's and Time Machine is the owner's backup of it. (Hidden cache files may stay excluded.)
4. **Kept files are never evicted; the cache limit is the hidden `files/` only** (decision 4, unchanged). Default 5 GB,
   label "cache limit". On the Mac the cache holds files nobody asked to keep: saves while "keep new saves offline" is
   off, a run's working copies, files waiting to move while the folder is unreachable count as **kept** (not capped).
5. **Promotion into an unreachable root fails per file and retries.** `moveIn` never creates the root (the gallery
   subfolder is `createDirectory(withIntermediateDirectories: false)`), so a kept file waits in `files/`, kept, and
   `reload()` promotes it once `rootState == .ready`. Same volume (Application Support and `~/Movies` on the Data
   volume) is a rename; another volume takes the existing EXDEV copy path (`OfflineFolder.place`).
6. **Mac display:** `StoredVideo.fileURL` resolves against the current root as on iOS. Status line for a kept file:
   `in ~/Movies/cobalt · 54 MB` (the file's folder, display path), per section 3.

### 13.3 Adopting what FolderSync wrote (once per ledger section; nothing the owner touched is changed)

`FolderAdoption` (new, `Folder/FolderAdoption.swift`), run by `reload()` in `.macFolder` **before** the scan, inside
the gate, for the ledger section whose path is the current root (by `FolderDestination.canonical`). It reads
`folder.json` and **never writes it** (so a downgrade to 1.14.x finds its ledger intact and copies nothing again).

For every entry `(key, e)` of that section with `e.state == .done`, `e.file != nil`, `e.bytes != nil`:

| check, in order | fails → |
|---|---|
| exactly one record has `PhotosKey.of(record) == key` (several: the one whose cache file exists and matches `e.bytes`, else the oldest) | `noRecord`: the file is the owner's, untouched |
| the record has no `visiblePath` yet | already adopted: skip (idempotent) |
| `root/e.file` is a regular file (`lstat`, not a symlink), inside the root after resolving symlinks | `missing`: the owner deleted, moved or renamed it. Final |
| its size is `e.bytes` | `changed`: final |
| its tag is absent, or is this record's id (a crash after tagging) | `tagConflict`: final |
| identity: when the record's cache file exists, its bytes equal the folder file's (streamed compare); when it does not, the folder file's mtime is ≤ `e.at` + 120 s | `changed`: final |
| the record is not `isInUse` and its session is not held | `busy`: not final, next `reload()` |

Then, per batch of 20, in this order:
1. **Tag** the folder file with the record's `OfflineTag` (the only write to a file in the owner's folder), and on that
   same file only clear `isExcludedFromBackup` when it is set (cobalt leaked it there, 13.0).
2. **One coordinated index write:** `visiblePath = e.file`, `givenName = lastPathComponent(e.file)`, `keep = true`,
   `fileName = nil`; and in the same write every record of the section that stays as it was with `keep == nil` gets
   `keep = false` (13.2.1).
3. **Delete the cache copy** (`files/<old fileName>`) after the write, only if the folder file is still there at
   `e.bytes`.

No file in the root is moved, renamed, created or deleted by adoption; nothing outside the folder file's two
attributes changes. Gallery folders keep their name and their folder tag (it already equals the record's media id on
the owner's Mac). Adopted files are ordinary kept files from then on: they follow a cobalt rename while their name is
still `givenName` (decision 8), the cache limit never takes them, the scan follows the owner's renames.

**Other ledger states.** `skipped(preexisting)` and `skipped(gaveUp)`: the record stays cache (`keep = false`).
`claimed`, `failed`, and **no entry** while `folderSync` was on: FolderSync would have copied it next, so the record
becomes `keep = true` and promotion moves its cache file into the folder (the one case where adoption adds a file;
the owner's Mac has none). Entries of other sections (folders chosen earlier): untouched until that folder is the root
again (13.5).

**Crash safety.** After 1: the file is tagged, the index not written: the scan adopts it by tag (`reconcile`, with
`givenName` nil: it simply never follows a cobalt rename) and drops the cache copy when the sizes match. After 2: the
cache file is unreferenced; adoption's next run deletes `files/<name>` for any adopted record whose old name it
recorded in its marker before step 2. Nothing is ever deleted before the folder copy is proven whole.

**Marker:** `Sync/folder-adoption.json` `{sections: {<id>: {at, adopted, skipped: {reason: n}, pendingCache: [names]}}}`.
A section is complete when the root was `.ready` and every done entry reached a final outcome; until then adoption
runs on each `reload()`. Telemetry `folder adoption` carries the counts.

**The owner's Mac, predicted:** 8 of 8 adopted, 8 cache copies deleted (about 5 MB; on APFS the folder files were
`copyItem` clones of the cache files, so the space freed is **smaller than the logical size**, possibly near zero), 0
files added, 0 renamed. Not measured: it has not run.

**FolderSync retires.** `FolderSync.swift` and `FolderWorker.swift` are deleted; nothing copies any more.
`FolderLedger` keeps only what reads the ledger and records a chosen folder (`choose`, `refreshDestination`,
`ensureSection`, the readers); the claim/finish/fail/skip API goes with the worker. The `folderSync` defaults key is no
longer read (the owner never set it). `FolderNaming` stays (both platforms name kept files with it).

### 13.4 Root identity (a disk that is not the one we wrote to)

`FolderDestinationRecord` gains optional `volume: String?` (`volumeUUIDStringKey`) and `fileID: Int64?`
(`fileIdentifierKey`), written by `choose` and re-recorded after a successful scan. For a **chosen** folder, a
resolved root whose volume or file id differs from the record is `.wrongFolder`: nothing is scanned, adopted,
promoted or pulled, and Settings asks the owner to choose it again (choosing records the new identity). The default
folder carries no identity (it is in the home, and an owner who deletes it has deleted their files: the scan unkeeps
them, decision 6). A record from 1.14.x has neither field: the first successful `.ready` scan records them.

### 13.5 Choosing another folder

`MacFolder.chooseFolder(url)` prepares (bookmark, identity, iCloud refusal) without switching. When kept files are
in the current root and it is reachable, Settings asks `move the 24 offline files to <path>?` (`move` default,
`leave them`, cancel = no change):
- **move:** inside the gate, every kept record whose file is provably its own (tag == id) is moved with the existing
  `moveIn` order (tag, rename, or copy → full sync → size check → rename → only then delete the source), gallery
  folders re-made by tag in the new root, an index write per 20 updating `visiblePath`; then the root swaps and a scan
  runs. Empty cobalt gallery folders left behind go (`removeEmptyGalleryFolder`). Progress shows in Settings. A file
  that does not move stays in the old folder and is reported (`3 stayed in the old folder`): after the swap the scan
  marks it not offline; it is the owner's file there, still tagged, and adopted again if they drag it into the new one.
- **leave them:** the root swaps; the scan marks them not offline; nothing is downloaded again.
- A section of the ledger for the new folder (one FolderSync used before) is adopted per 13.3 on the swap.
"use ~/Movies/cobalt" is the same flow toward the default.

### 13.6 Unreachable folder (external disk unplugged)

`rootState != .ready` →
- scan, adoption, relocation: **no change at all** (decision 6, last row; `enumerate` returns nil);
- new saves and "keep offline": land kept in hidden `files/` and wait (13.2.5);
- **the pull pauses** (13.8): it does not enqueue new downloads, so weeks unplugged do not fill the internal disk;
- the UI: kept renditions still read `offline` (the owner keeps them; the disk will be back), the detail line says
  `on <path>, which isn't connected`, "show in Finder" is disabled with that line as its help, Settings shows the problem
  row. Playing such a file fails as a missing file does today.
`reload()` on every activation re-resolves; when `.ready` again, promotion moves what waited.

### 13.7 Made files that replace (R8) on both platforms

A remake's replace stays identity-based (`store.remove` by tag, `Pipeline/PipelineGallery.swift:595-627`) with one
data-safety rule, applied in the store so it holds everywhere: `OfflineStore.replaceMade(_ id:)` deletes the old kept
file only when its current name is still `givenName`. A file the owner renamed (or one adopted by crash recovery,
`givenName == nil`) is left in place **untagged** (it becomes the owner's), and only the record goes.
`PipelineGallery.finishMake` and the pull's landing (13.8) call `replaceMade` before the new file's `add`, so the new
file takes the free name (`slideshow.webp`, not `slideshow (2).webp`). Owner-initiated removes are unchanged.

### 13.8 The pull: saves made anywhere land in the Mac folder

**What "from now on" is.** `Sync/pull.json` (`PullLedger`, `CoordinatedFile`):
```
{ v: 1, enabledAt: Date?, watermark: Date?, lastCheck: Date?, problem: String?,
  done: { "<server file id>": { at: <file created_at>, state: "queued" | "skipped", why: String? } } }
```
- `enabledAt` is set to the device's `now` the first time the pull runs on a build with this section **and** "keep new
  saves offline" is on, and again whenever that toggle goes from off to on (a new baseline: saves made while it was off
  are not fetched). The owner's 70+ posts are all older than that moment, so none is downloaded.
- A **library file is a candidate** when all hold: `file.createdAt > enabledAt` (server time vs device time: a skew of
  seconds only matters for a file saved within seconds of turning it on); `done[file.id] == nil`; its rendition in the
  merged `MediaItem` (`MediaItem.merge(local:post:)`) has **no local record at all** (a record, with or without a file,
  means this Mac saved, kept, pulled or was told to forget it; the owner's "remove offline copy" and Finder deletes stand);
  its post's session is not held here (13.9); `OfflineSources.sources` is not empty.
- **Done is forever.** A candidate is written `done = queued` in the same step it is enqueued; it is never enqueued
  again, whatever happens to the file after (removed, cancelled with "stop downloading", deleted in Finder). A
  download that ends `failed(.gone)` is written `skipped`.

**What it pulls.** Every rendition kind the library lists: originals (`.libraryItem` keyed private route first,
either visibility), webps (public URL, else the private route), gallery items, made files (slideshow webp/mp4,
gallery image, crop), uploads. Jobs come from `OfflineSources.job(for:in:mediaBase:now:)` exactly as "keep offline"
builds them; they run on `OfflineDownloads` (background session `…bg.offline`, 2 connections, progress, resume data
when the server sends a validator: section 6, not confirmed deployed). `OfflineJob` gains `origin: String?`
(`"pulled"`); landing uses `AddOrigin.pulled` (new case), `keep: true`, the server's `createdAt` (a pulled save is new,
so it lands at the front of the orbit as a save made here does). `PhotosSync` already ignores every origin but
`.save` (`Photos/PhotosSync.swift:120`). A made file's landing calls `replaceMade` for older local records of the same
`madeKind` and media first (13.7).

**When it checks.** `SavePull.check()`: at launch and on every activation (end of `pickUpSharedJobs`, after
`offlineDownloads.reconcile()`), and every 5 minutes while the app runs (a main-actor `Timer`, tolerance 60 s; App Nap
may stretch it; no extra power assertion). One check at a time. **While cobalt is closed nothing checks**: the app
quits when its window closes (13.0) and there is no login item (owner question 1). A download already handed to the
background session keeps going in `nsurlsessiond` after the app quits and lands at the next launch
(`OfflineDownloads.reconcile`); this is unverified on macOS 27 (gate G-MB).

**How a check walks.** Page 1 with `limit=5`; posts arrive newest-file first. Stop at the first post whose newest file is
≤ `stopLine = max(enabledAt, watermark − 10 min)` (the overlap absorbs out-of-order inserts; `done` dedupes). While every
post on a page is newer, fetch the next page (`limit=30`, cursor), at most 10 pages per check. After a complete walk,
`watermark` = the newest `createdAt` seen, but never past the oldest candidate that was **deferred** (held); entries
in `done` older than `watermark − 1 day` are pruned. A quiet check is one request of 5 posts.

**When it does not run (`SavePull.Status.paused`):** `keepOff` ("keep new saves offline" off); `folderUnreachable`
(`rootState != .ready`); `auth` (a 401/403 from the library: no retry until the key changes or Settings is opened);
`noServer` (no key, or capabilities unknown). Network errors are not a pause: the next tick tries again.

**Platform:** `SavePull.isAvailable` is true in `.macFolder` only. The type is platform-neutral CobaltKit; no server
change (the routes stay platform-neutral for the later Android app).

### 13.9 Not pulling what this Mac saved itself

Three layers, in order:
1. **Held sessions are deferred, not decided:** `AppModel.holdsSession(_ sid:)` is true while a job of `queue` follows
   that session, a `SharedJob` of it is `saving`/`rendering`/`uploadInterrupted`, or `PendingOriginals` holds it (the
   predicate `OfflineStore.sessionIsHeld` already covers the last two). Covers the Mac's own runs and the share-sheet
   sessions it adopted (13.0) while they are in flight.
2. **A local record means "seen here"** (13.8): once this Mac's own save lands, the rendition has a local record and is
   never a candidate.
3. **Landing is idempotent:** `OfflineStore.add` folds a second file for the same session item, webp URL, gallery item
   or made row into the existing record and deletes the duplicate (`duplicateIndex`, `OfflineStore.swift:535-555`).
   Wasted bandwidth at worst, never two files.
Unverified: whether an **upload made on this Mac** (pasted file) records a `sessionID` that joins its library post. If
it does not, layer 2 misses it and the upload comes back as a second file. The P lane checks it and adds the test (13.13).

### 13.10 Settings, menus, copy (Mac; lowercase, exact)

**Settings, section "on this mac"** (the separate "folder" section goes), in this order:
- toggle `keep new saves offline` (the existing `keepVideosOnDevice`; turning it on rebaselines the pull);
- row `folder` · `~/Movies/cobalt`, with buttons `choose…`, `show in finder`, and `use ~/Movies/cobalt` when another is chosen;
- problem line (only when there is one): `this folder isn't connected. new saves wait on this mac until it's back.` /
  `cobalt can't write to this folder.` / `this isn't the folder cobalt was using. choose it again.` /
  `the disk is full.`;
- row `offline` · `24 files · 3.1 GB`;
- row `saves from other devices` · `checked 2 min ago` / `downloading 2` / `paused while keep new saves offline is off` /
  `paused until the folder is back` / `your key was refused. check it above.`;
- row `downloading` · `2 left · 120 of 300 MB` with `stop all` (while the queue has anything);
- picker `cache limit`; row `cache` · `3 files · 210 MB of 5 GB` with its bar; `clear cache`;
- footer: `offline files stay in this folder until you remove them, here or in finder. while cobalt is open, saves
  from your iphone, the share sheet, shortcuts and the web download here too. the cache makes room by itself.`
- choose dialog: title `move the 24 offline files to <path>?` · `move` / `leave them`; message `left behind, they stay in
  the old folder and aren't offline here any more.`; progress line `moving… 12 of 24`; refusal
  `pick a folder on this mac or an external disk. icloud drive folders can't hold offline files.`

**Menus:** the library's right click and the detail's `more` menu show exactly the iPhone's items (decision 11) with
`show in finder` where iOS has `show in files`: shown when any rendition is `offline`; selects those files in Finder
(the media's gallery folder for a gallery); disabled with help `on <path>, which isn't connected` when unreachable.
**Detail toggle line:** `in ~/Movies/cobalt · 54 MB` (the file's folder); waiting to move: `waiting for the folder ·
54 MB`. Remove confirms are section 3's, with `remove` meaning the Trash on the Mac: message for the server case
`it goes to the trash. the server keeps its copy.`
Retired: `Copy.Folder.*` except the strings reused above, the backfill offer (`existingRow`, `backfill*`), the
`save to a folder` toggle.

### 13.11 The iPhone (owner did not ask; note only)

The same `SavePull` works with `.documents`: the store and engine are shared and the iPhone already has the
background session. What would differ: checks only on foreground plus an opportunistic `BGAppRefreshTask`; the pull
should default to Wi-Fi only (`allowsExpensiveNetworkAccess = false` on its jobs) and to off, because kept files are
uncapped (question 1 of section 10) and a phone fills. Turning it on would be `SavePull.isAvailable` plus a toggle.

### 13.12 Lanes (sequential waves; disjoint ownership; children never commit)

| wave | lane (agent) | owns | builds |
|---|---|---|---|
| M1 | **MF folder = visible root** (`sonnet-lane`) | `Folder/**` (new `FolderAdoption.swift`, new `MacFolder.swift`, `FolderDestination.swift`, `FolderLedger.swift`, `FolderNaming.swift` docs; delete `FolderSync.swift`, `FolderWorker.swift`), `Store/OfflineFolder.swift`, `Store/OfflineStore.swift`, `Store/OfflineFolderStore.swift`, `Store/OfflineMigration.swift`, `Store/Settings.swift` (DEBUG override only), new `Offline/SavePull.swift` **stub with the 13.14 public API only**, `Pipeline/PipelineGallery.swift` (`replaceMade` call only), `Preview/*`, `Models/AppModel.swift` (`folderSync` → `macFolder` wiring only), compile shims in `Cobalt/Shared/ShowInFinderButton.swift`, `Cobalt/Screens/Settings/FolderSettingsSection.swift` + `FolderSettingsPreviews.swift`, `Cobalt/Screens/Home/GalleryFocus.swift` (path text only); tests: new `OwnerFolderFixture.swift`, `FolderAdoptionTests`, `MacFolderRootTests`, `ReplaceMadeTests`; delete `FolderSyncTests.swift` | 13.1-13.7 |
| M2 | **P pull** (`sonnet-lane`) | `Offline/SavePull.swift` (fills the stub), new `Offline/PullLedger.swift`, `Offline/OfflineDownloads.swift`, `Offline/OfflineSources.swift` (`OfflineJob.origin`), `Offline/OfflineQueue.swift`, `Models/AppModel.swift`, `Models/AppModel+Offline.swift`, `Store/OfflineFolder.swift` (`AddOrigin.pulled` only, if MF did not add it); tests `SavePullTests`, `PullLedgerTests`, additions to `OfflineDownloadsTests` | 13.8, 13.9 |
| M2 | **U Mac surfaces** (`sonnet-lane`), against 13.14 + previews | `Cobalt/Screens/Settings/SettingsScreen.swift`, `FolderSettingsSection.swift` + `FolderSettingsPreviews.swift` (fold into the storage section or delete), `Cobalt/Shared/ShowInFinderButton.swift`, `Cobalt/Screens/Detail/{OfflineCopy,DetailMenu}.swift`, `Cobalt/Screens/Library/LibraryMenus.swift`, `Cobalt/Screens/Home/GalleryFocus.swift`, `Cobalt/Design/{Copy+Offline,Copy+Folder,Symbols+Offline}.swift` | 13.10 |
| M3 | **R data-safety review** (`opus-lane`, read-only) | nothing | adversarial review of MF and P against 13.2-13.9, proving each finding with a throwaway test |
| M3 | **V evidence** (`sonnet-lane`) | nothing in source; scratchpad only | 13.13.3 |

Gates (Fable, between waves): iOS and macOS builds, `swift test`, diff review against ownership. **No lane launches a
wave-M build of the app against the real home** (`~/Movies/cobalt`, `~/Library/Application Support/{Videos,Sync}`):
MF adds a DEBUG-only launch argument `-cobaltSandboxRoot <dir>` that puts the store, the ledgers and the default folder
under `<dir>`. Before the owner installs the release, Fable copies (read only, `ditto`, attributes kept) the owner's
`~/Movies/cobalt`, `Videos/index.json` and `Sync/` into the scratchpad as the rollback record.

### 13.13 Tests

**13.13.1 The owner's folder as a fixture** (`OwnerFolderFixture`, temp dirs, `rootMode: .macFolder`): the real names,
keys, kinds, roles, media ids and the gallery folder's tag from 13.0, sizes scaled down; cache files at the same sizes
and mtimes; `folder.json` with the 8 `done` entries; 6 records `keep` absent and 2 `keep: false`; the two gallery files
carrying the backup-exclusion attribute. Plus:
- an **owner-added file** `holiday.mov` at the top (no tag, no ledger entry);
- an **owner-renamed file**: `x · 2107221792188231716.mp4` renamed to `my clip.mp4` (the ledger still names the old one).

Asserted after `reload()`:
- 7 records kept: `visiblePath` = the ledger path, `givenName` = its leaf, `fileName == nil`, tagged with the record id.
  Their 7 cache copies are gone; the renamed one's cache copy stays and its record reads `keep == false`.
- **The root is unchanged except attributes**: the same names, inodes, sizes and mtimes as before. No `(2)` file, no
  new file, no `.part` left. `holiday.mov` and `my clip.mp4` have byte-identical attribute lists.
- `folder.json` is byte-identical.
- Backup exclusion is cleared on the two adopted gallery files only.
- A second `reload()` changes nothing. `runMigrationIfNeeded` moves nothing.
- A new item `03.jpg` landing for that gallery goes into `instagram · DeKlsGCGZmx/` by its folder tag.
- `removeOfflineCopy` on an adopted file sends it to the Trash (a fake `removeVisible`) and tombstones the id.

**13.13.2 MF and P tests:**
- **Adoption, each row of 13.3:** same name and size but other bytes; other size; tagged with another id; cache evicted
  with mtime older vs newer than `e.at`; several records for one key; no record; `busy`; `skipped(preexisting)`; `claimed`
  and no-entry with `folderSync` on (moved in).
- **Adoption, crash** after each step (`OfflineFileOps.checkpoint`).
- **Root:** unreachable at launch (nothing changes; promotion waits; pull paused) and back; the default folder deleted
  (re-created, records unkept); `.wrongFolder` by volume and file id.
- **Relocation:** move and leave; a crash mid-move; one file that fails to move.
- **Replace:** `replaceMade` with an untouched file (Trash on the Mac) and a renamed one (untagged, kept).
- **Pull baseline:** 72 posts all older than `enabledAt` → 0 jobs, 1 request.
- **Pull candidates:** a new webp on an old post; a new gallery item and a made file (replace first); a private original
  (`.libraryItem` first); a local record with a file and without one (both not pulled); a held session deferred, then not
  pulled once its save lands.
- **Pull ledger:** done-forever after remove, cancel and Finder delete; `failed(.gone)` → `skipped`; the walk stops at
  the watermark (count requests) and paginates; prune.
- **Pull pauses:** keep off → no requests; toggling on rebaselines; root unreachable; 401.
- **Pull landing:** origin `.pulled`, kept, server `createdAt`; `PhotosSync` ignores it; an upload made on this Mac is
  not pulled back.

**13.13.3 Evidence (V, after R):** `swift test`; iOS and macOS builds; the DEBUG Mac app with `-cobaltSandboxRoot` on a
`ditto` copy of the owner's real folder and store: Settings "on this mac" screenshot, right click with the four
offline items, "show in finder" selecting the file, `xattr -l` and `ls -li` of the copy before and after (only tags and
the cleared exclusion differ). A pull with the preview/fake server (or the owner's server with the owner present). The
real `~/Movies/cobalt` listing before and after the run is identical (proof the sandbox held).
**G-MB:** quit the app mid-download, relaunch: landed, not restarted.

### 13.14 Pinned API (additive unless marked)

```swift
// Store (MF)
public enum VisibleRootMode: Sendable, Equatable { case documents, macFolder }
public enum RootState: Sendable, Equatable { case ready, unreachable(path: String), notAllowed(path: String), wrongFolder(path: String) }
extension AddOrigin { case pulled }                                     // a new case
extension OfflineStore {
    public private(set) var visibleRoot: URL?                           // was `let`
    public var rootState: RootState { get }                              // observable
    public var rootMode: VisibleRootMode { get }
    @discardableResult public func replaceMade(_ id: String) async -> Bool
}
protocol OfflineFileOps { func removeVisible(_ url: URL) throws }       // Trash in .macFolder

// Folder (MF) — replaces FolderSync for the UI
@MainActor @Observable public final class MacFolder {
    public enum Problem: Sendable, Equatable { case unreachable, notAllowed, wrongFolder, diskFull }
    public struct Status: Sendable, Equatable {
        public var available: Bool; public var path: String; public var isDefault: Bool
        public var problem: Problem?; public var adopting: Bool; public var moving: Moving?
    }
    public struct Moving: Sendable, Equatable { public var done: Int; public var total: Int }
    public enum ChooseOutcome: Sendable, Equatable { case chosen, askMove(count: Int), unchanged, refusedICloud, failed }
    public var status: Status { get }
    public var isAvailable: Bool { get }
    public func chooseFolder(_ url: URL) async -> ChooseOutcome
    public func resetToDefault() async -> ChooseOutcome
    public func answerMove(_ move: Bool?) async -> (moved: Int, stayed: Int)   // nil = cancel (no change)
    public func reveal(_ videos: [StoredVideo] = []) async                   // the files selected, else the folder
    public func displayFolder(of video: StoredVideo) -> String?             // "~/Movies/cobalt/instagram · DeKlsGCGZmx"
    public static func preview(_ status: Status) -> MacFolder
}
extension AppModel { public var macFolder: MacFolder { get } }           // `folderSync` is removed

// Offline (MF writes the stub, P fills it)
@MainActor @Observable public final class SavePull {
    public enum Paused: Sendable, Equatable { case keepOff, folderUnreachable, auth, noServer }
    public struct Status: Sendable, Equatable {
        public var available: Bool; public var lastChecked: Date?; public var paused: Paused?; public var pulling: Int
    }
    public var status: Status { get }
    public func check() async
    public static func preview(_ status: Status) -> SavePull
}
extension AppModel {
    public var savePull: SavePull { get }
    public func setKeepNewSaves(_ on: Bool)                              // writes the setting; on: rebaselines the pull
    func holdsSession(_ id: String) -> Bool
}
```

### 13.15 Owner question (the default applies unless the owner says otherwise)

1. **Should the Mac fetch new saves while cobalt is closed?** Default **no**: it fetches whenever cobalt is open,
   including with its window in the background, and catches up the moment it opens. "Yes" adds an `open at login`
   toggle (the app starts hidden at login and keeps checking every 5 minutes); it is a small addition, not built now.

Not questions (decided here, say so to the owner): remove on the Mac goes to the Trash; Time Machine now backs up the two
gallery files cobalt had hidden from it; moving to another folder asks to move the offline files.

### 13.16 Not verified

- Nothing in this section has run. The adoption counts in 13.3 are predicted from today's ledger and index.
- macOS background `URLSession` transfers surviving an app quit on macOS 27 (G-MB).
- `trashItem` on external and network volumes (13.2.2 falls back to delete).
- `fileIdentifierKey` stability across a reboot on external APFS/exFAT volumes (13.4; an exFAT disk may report none,
  then only the volume is checked).
- Whether an upload made on the Mac joins its post (13.9).
- Server validators for resume (section 6) are deployed: not checked today.
- The release signing process (which entitlements the re-sign keeps) lives outside the repo; 13.1 holds for both.
