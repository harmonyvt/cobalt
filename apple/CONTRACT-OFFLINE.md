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
   | deletes a kept file | no file with that id under the root (`.Trash` is skipped) | `visiblePath = nil`, `keep = false`: **not offline**, poster and record stay, never re-downloaded |
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

13. **(lane; owner question 2) Photos album: unchanged, an optional extra, still on by default.** It reads
    `fileURL`, which now resolves into `Documents`; keys do not change; `shouldMoveFile = false` keeps Photos' own
    copy. Deleting in Files never touches Photos, and a Photos deletion never touches Files. The only change: adds
    with origin `.keepOffline` or `.adopted` are skipped (decision 9). Whether to keep it on now that Files is home
    is the owner's call.

14. **(lane) Backup.** Every file in either tier that has a server copy gets `isExcludedFromBackup = true` (the
    server is its backup; gigabytes of video must not fill the owner's iCloud backup). Files with no server copy
    (plain-cobalt saves, uploads whose server copy is gone) stay in backups. Set when a file lands or is adopted,
    and re-checked on the scan. Today nothing is excluded, so this only removes bytes from backups.

15. **(lane) Mac: same model, two waves.**
    - **Wave 1:** the Mac gets every surface (badge, filter, right-click, toggle, downloads, cache split) with
      `visibleRoot == nil`, so kept files stay in the hidden `files/`. `FolderSync` keeps copying exactly as today.
    - **Wave M** (later, own gate): the Mac's visible root becomes the `FolderDestination` folder (default
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
| M (later) | **M Mac visible root** (`sonnet-lane`, with an opus review) | `Folder/*`, `Store/OfflineFolder.swift` (Mac root), `Screens/Settings/FolderSettingsSection.swift`, `Shared/ShowInFinderButton.swift` | decision 15 wave M |

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
2. **Photos album: keep adding new saves to the "cobalt" album too?** Default **yes, unchanged** (it works; a video
   you delete in Photos is never added again). Each kept video then takes space twice (Files and Photos). "No" turns
   the album off; what is already in Photos stays there.

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
