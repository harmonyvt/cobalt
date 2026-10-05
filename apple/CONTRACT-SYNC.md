# cobalt for apple: auto continue + photos album contract (owner request, 2026-10-04)

Owner (verbatim): "I want to automatically have continue in background when I share a link and I
have a timer to stay on the screen or something and also can the videos in cobalt automatically
sync to a photo album automatically please".

Additive to `CONTRACT.md`, `CONTRACT-LIVE.md`, `CONTRACT-ORBIT.md` and
`deploy/cloudflare/APP-API-CONTRACT.md` (one small server addendum, section 5 here). Code read on
2026-10-04 against the `apple-app` worktree. Marked **(owner)** where the owner asked for it,
**(Fable)** for Fable's pinned defaults, **(lane)** for calls made here and open to review.

## 0. Platform facts this rests on (sources in section 9)

- F1. PhotoKit album operations need **full** read-write access. Apple: with limited access "You
  can't create or fetch user albums"; add-only access means the app "may only add to the user's
  photo library". So: create album = `.readWrite` + `.authorized`; add a new asset = add-only, or
  read-write `.limited` / `.authorized`; put that asset in an album and find the album again on
  the next launch = read-write `.authorized` only. Read-write needs `NSPhotoLibraryUsageDescription`.
  Assets created with limited access are added to the owner's selection automatically.
- F2. `placeholderForCreatedAsset.localIdentifier` is available inside the change block at every
  access level. Fetching it later (to check that it still exists) needs read access.
- F3. A share extension may start a **background** `URLSession` task. The session must set
  `sharedContainerIdentifier` (the app group), or it is invalidated on creation (NSURLSession.h,
  iOS 27 SDK). The task outlives the extension. If the extension is not running when the task
  finishes, iOS launches the containing app in the background and delivers
  `handleEventsForBackgroundURLSession`. In SwiftUI that is
  `.backgroundTask(.urlSession(matching:))` (SwiftUI.swiftinterface, iOS 27 SDK). Only one process
  may use a background session at a time, so each extension run needs its own identifier.
- F4. Background sessions: a task the app creates **while it is in the background** is
  discretionary and is held back by the resume rate limiter. The delay doubles each time
  `nsurlsessiond` wakes the app and resets when the app comes to the front. A force-quit app is
  not relaunched for background session events. Tasks started from the foreground are not
  rate-limited.
- F5. `BGContinuedProcessingTaskRequest` is created "on behalf of the currently foregrounded
  app" (BGTaskRequest.h). In a share extension that is the host app (Photos, X…), not cobalt. It is
  not used for this feature.
- F6. `GET /studio/<sid>/source` needs no key (APP-API-CONTRACT 7) and answers
  `409 error.studio.not_ready` while the save is running (`studio-edge.ts`, `studioSource`). A
  background download cannot wait on its own. Section 5 adds a server-side wait.
- F7. Workers: "There is no hard limit on duration for HTTP-triggered Workers. As long as the client
  remains connected…" (Cloudflare limits page). A 90 s hold is allowed.
- F8. Animated WebP in Photos is **unverified**. A third-party support article says saved WebP
  files do not play in Photos, but that is not Apple's word. Gate G-W (section 8) decides it on
  the simulator.

Two gaps in today's code that this contract fixes:
- `ShareCore.dismiss()` (ShareModel.swift:209) calls `pipeline.cancel()`, and `cancelRunning()`
  cancels `keepRequest` (Pipeline.swift:243). Closing the sheet at "ready" therefore throws away
  the keep-on-device download that is still running.
- `resumeJob(.saving)` (PipelineFlows.swift:846) never calls `keepOriginalInBackground`. A
  share-sheet job taken over by the app never reaches the offline store, unless the trim's own
  frame read fetches a copy.

## 1. Decisions

1. **(owner, Fable) Link shares continue in the background by themselves.** A countdown runs on
   the sheet with a **stay** button. When the countdown ends the sheet calls
   `continueInBackground()` and closes. Hark and the Live Activity carry the run from there.
2. **(lane) When the countdown starts:** at the first moment the server holds the save. That is
   `canContinueInBackground` (session id known, state fetching/saving), and also
   `capabilities.finishesUnpolled`. A server without the sweep would lose an unpolled save, so
   such a server never gets a countdown. Before that point there is nothing to hand off.
3. **(owner, 2026-10-04) What stops it:** stay; any other control (close counts as close, not
   stay); the run failing. The save finishing does NOT stop it (owner chose "close anyway"): the
   countdown keeps running through reading/ready, and when it ends the sheet closes the same way
   the close button does at that state, so a keep download still running is handed to the
   background download (decision 5 / the handoff), and the video still lands on the phone and in
   the album. If the save finished, `continueInBackground()` is not needed; the countdown calls
   the close path instead. Once stopped, the countdown never restarts in that sheet. "make webp"
   later does not start one either.
4. **(lane) File shares get no countdown.** The upload runs inside the extension
   (`runUpload`). Closing would kill it, and moving uploads to a background upload session is out
   of scope. Plain cobalt gets none either (no server session, the extension downloads the file
   itself), and neither does a picker post.
5. **(Fable + lane) Settings:** `continue in background automatically` is on by default. The wait
   is 3, 5 or 10 s, default 5. Both live in the app-group defaults, so the extension reads them.
   With VoiceOver or Switch Control running when the sheet opens, the wait is at least 10 s
   (WCAG 2.2.1, timing adjustable).
6. **(lane) What "the rest" does: the original lands on the phone by itself.** When the sheet
   closes for any reason (countdown, button, close, swipe) and all of the following hold, it
   **hands the original's download to a background URLSession**:
   - the run has a studio session;
   - "keep videos on this iphone" is on;
   - the store has no original for that session;
   - the run is not a "trim in cobalt" handoff (the app takes that run itself).

   The download is recorded in an app-group ledger (`PendingOriginals`). Then:
   - The extension starts the task **before** `completeRequest`, while it is still visible, so
     the task is not discretionary.
   - The URL is `/studio/<sid>/source?wait=90` (section 5). The server holds the request until
     the save is ready, then streams the file. One task, one wake.
   - When it finishes, iOS wakes the app in the background (F3). The app moves the file in,
     `store.add`s it (orbit), and runs the Photos sync (decision 9). This happens with the app
     closed but not force-quit.
   - **Safety net:** on every foreground, `pickUpSharedJobs` reconciles the ledger. Each entry
     that has not landed and has no live task is started again from the foreground. A server
     without `source_wait` gets no task at close if the save is not ready yet. The ledger
     entry waits for the foreground instead.
   - **Ruled out:** retries from a background wake beyond 2 per entry (F4 makes them slow and
     rate-limited); `BGContinuedProcessingTask` from the extension (F5); keeping the extension
     alive (it is torn down after `completeRequest`).
7. **(owner, Fable) A photos album, off until the owner turns it on.** The album is named `cobalt`.
   Turning the toggle on asks for **read-write** access. Per F1 there is no lesser access that puts
   videos in an album. Outcomes:

   | answer | mode | what happens |
   |---|---|---|
   | full access | album | assets go to the library and into "cobalt" |
   | limited | library only | assets go to the library (and the selection); settings say why there is no album |
   | read-write refused but add-only already granted | library only | same, add-only wording |
   | both refused | off | the toggle stays off; "photos access is off" and **open settings** |

   When access is upgraded later (the owner turns on full access in Settings), the next reconcile
   moves earlier library-only items into the album (decision 10), skipping assets that no longer
   exist. After a successful enable, the owner is asked once: "also add the N videos already in
   cobalt?" (**add N** / **only new ones**). N counts eligible items whose file is still on this
   phone. Items whose file was evicted are not counted. The prompt is not shown when N = 0.
8. **(lane) What is eligible:**
   - Originals in the offline store that came from a web link (`link != nil`) and whose file is on
     the phone. That covers link saves, plain-cobalt saves and picker videos.
   - Uploads never reach the store with a link. The app's own Photos/Files imports never reach the
     store at all. So media that came from the phone are never copied back into Photos.
   - **webps:** a separate toggle "include webps", off by default. Turning it on applies to webps
     kept from then on; existing webps are marked skipped, with no prompt.
   - The sync **requires "keep videos on this iphone"**, because the album is filled from the
     offline store. With keep off, the toggle is disabled with a footnote. If keep is turned off
     while sync is on, the sync pauses and shows "paused · keep videos is off".
9. **(lane) Where the sync runs: the app only.** It runs after every `OfflineStore.add` in the app
   process, on foreground (`pickUpSharedJobs`), and at the end of a background-session wake
   (decision 6). The share extension **never** syncs by itself. It may not have read-write
   access, and the album lookup is not worth its ~120 MB budget. Its manual "save to photos"
   still works (add-only) and is recorded in the ledger, so the app never adds that item again
   (the app later moves it into the album).
   Known gap, accepted: a clip whose original finished downloading inside the open sheet, after
   which the sheet closed and the app was not opened, reaches Photos at the next app foreground or
   the next background wake, not before.
10. **(owner, Fable) Once per item, durable.** Ledger `PhotosLedger` lives in the app group at
    `Sync/photos.json`, read and written under `NSFileCoordinator` like `SharedJobStore`.
    - **Key per item:**
      - original with a session: `s:<sessionID>`;
      - original without one but with `remoteURL` (picker item): `r:<remoteURL>`;
      - webp: `w:<remoteURL>`;
      - anything else: `i:<store id>`.

      The key does not depend on the index record, so eviction or the removal of a whole record
      never brings an item back. A refill (`attach`) has the same key.
    - **States:** `claimed(at, asset?)` → `done(asset?, inAlbum: true|false|gone)`;
      `failed(code, tries, at)`; `skipped(preexisting|gaveUp)`.
    - **Never twice.** Claim under coordination before `performChanges`. Inside the change block,
      write the placeholder's id into the claim, then commit, then mark done. A claim older than
      2 min is in doubt:
      - with read access, the asset exists → done; it is missing → retry;
      - add-only → done (never twice beats maybe-missing).
    - **Deleted in Photos is never re-added.** The ledger says done, and nothing ever re-checks
      in order to re-add.
    - The album repair (decision 7) adds `done(inAlbum: false)` assets to the album only when they
      still exist. Items the owner later removed from the album are never touched again.
    - **Eviction never touches Photos.** `shouldMoveFile = false` keeps Photos' own copy (as
      today). The offline-store limit deletes only cobalt's file.
    - **Album identity:** the album's `localIdentifier` is stored in the ledger. If it no longer
      resolves, a user album titled `cobalt` is reused (fetch by title). Only when neither exists
      is one created, and it receives new items only. If the owner renames the album, cobalt keeps
      using it.
11. **(lane) Edge cases:**
    - Out of space: `PHPhotosErrorNotEnoughSpace` 3305, or ENOSPC on the download. The entry stays
      waiting, the status reads "photos is full · N waiting", and it is retried on every
      foreground.
    - Other Photos errors are retried up to 3 times, then `skipped(gaveUp)`, counted as "N couldn't
      be added".
    - Library unavailable (3114/3142/3143, or writes while the phone is locked: unverified) → retry
      on foreground.
    - Low Power Mode: no special case. The work is owner-initiated and short, and the system
      decides background wakes.
    - Low Data Mode and cellular are allowed for the original's download, as the foreground keep
      download is today.
    - iCloud Photos: cobalt adds local files. "Optimize Storage" and upload are Photos' business.
    - Ledger entries older than 7 days (the session lifetime; the source answers 410) are dropped.
12. **(owner, Fable) The manual "save to photos" button** shows **in your cobalt album**
    (`photo.badge.checkmark`, done style, not tappable) when the run's item is `done(inAlbum:
    true)`. In library-only mode it shows **in your photos**. With full access, the existing
    check runs when the button is shown: if the asset is gone, the button is the normal "save to
    photos" again (a manual save is an explicit request and may add it again, recorded as a new
    asset). In album mode a manual save in the **app** goes into the album. In the extension it
    goes to the library (decision 9).
13. **(lane) Platforms:** iPhone and iPad. On the Mac `PhotosSync.Access == .unavailable` and the
    photos section is hidden. The Mac has no share sheet, and Mac photos sync is not requested.

## 2. Copy (lowercase, exact; `Cobalt/Design/Copy+Sync.swift`, compiled into app + share + widgets)

```swift
extension Copy {
    enum Sync {
        // settings · share sheet
        static let shareGroup = "share sheet"
        static let autoContinue = "continue in background automatically"
        static let wait = "wait"
        static func seconds(_ s: Int) -> String { "\(s) s" }
        static let autoContinueFooter = "after you share a link, the sheet waits this long, then closes and cobalt finishes on its own. tap stay to keep it open."
        // settings · photos
        static let photosGroup = "photos"
        static let albumToggle = "save to a photos album"
        static let includeWebps = "include webps"
        static let albumRow = "album"
        static let openSettings = "open settings"
        static func albumCount(_ n: Int) -> String { "\u{201C}cobalt\u{201D} · \(n) added" }
        static func adding(_ done: Int, of total: Int) -> String { "adding \(done) of \(total)" }
        static func waiting(_ n: Int) -> String { "\(n) waiting" }
        static let libraryLimited = "your library · limited access"
        static let libraryAddOnly = "your library · add-only access"
        static let accessOff = "photos access is off"
        static let paused = "paused · keep videos is off"
        static func outOfSpace(_ n: Int) -> String { "photos is full · \(n) waiting" }
        static func gaveUp(_ n: Int) -> String { n == 1 ? "1 couldn't be added" : "\(n) couldn't be added" }
        static let footerAlbum = "videos cobalt keeps on this iphone go into a \u{201C}cobalt\u{201D} album in photos, once each. deleting one here or in photos never adds it back."
        static let footerLimited = "with limited access cobalt can add to your library but not make an album. allow full access in settings to use the album."
        static let footerAddOnly = "cobalt can only add to your library. allow full access in settings to use the album."
        static let footerDenied = "cobalt can't add to photos. allow access in settings."
        static let footerNeedsKeep = "turn on keep videos on this iphone first: the album is filled from what cobalt keeps."
        static let webpStill = "photos shows a webp as a still picture; its link still plays."   // only if gate G-W says so
        static func backfillTitle(_ n: Int) -> String { n == 1 ? "also add the video already in cobalt?" : "also add the \(n) videos already in cobalt?" }
        static func backfillAdd(_ n: Int) -> String { "add \(n)" }
        static let backfillSkip = "only new ones"
        // the save-to-photos button
        static let inAlbum = "in your cobalt album"
        static let inLibrary = "in your photos"
    }
}
```

Share sheet (`ShareCopy`, in `CobaltShare/ShareParts.swift`):
`stay = "stay"`, `continuingIn(s) = "continuing in background in \(s) s"`,
`continuingAnnouncement(s) = "continuing in background in \(s) seconds. choose stay to keep this open."`.

Info.plist (through `project.yml`, app target only):
- `NSPhotoLibraryUsageDescription`: `cobalt keeps the videos it saves together in a “cobalt” album. it doesn't look through your other photos.`
- `PHPhotoLibraryPreventAutomaticLimitedAccessAlert`: `true`. cobalt never needs a selection, so
  the system's once-per-launch "select more photos" alert is noise.
- `NSPhotoLibraryAddUsageDescription` is unchanged in both targets.

## 3. SF Symbols (`Cobalt/Design/Symbols+Sync.swift`; all checked in the system's
`name_availability.plist`, every one iOS ≤ 17)

| use | symbol |
|---|---|
| album toggle | `photo.badge.plus` (17.0) |
| album status row | `photo.stack` (16.0) |
| in your cobalt album / in your photos | `photo.badge.checkmark` (17.0) |
| photos problem (out of space, gave up) | `photo.badge.exclamationmark` (18.0) |
| include webps | `sparkles` |
| open settings | `gearshape` |
| auto continue toggle | `moon.zzz` (same as `ShareSymbol.background`) |
| wait picker | `timer` |
| stay (share sheet) | `hand.raised` (`ShareSymbol.stay`) |

```swift
extension Symbol {
    enum Sync {
        static let album = "photo.badge.plus"
        static let albumStatus = "photo.stack"
        static let inPhotos = "photo.badge.checkmark"
        static let problem = "photo.badge.exclamationmark"
        static let webps = "sparkles"
        static let openSettings = "gearshape"
        static let autoContinue = "moon.zzz"
        static let wait = "timer"
    }
}
```

## 4. Pinned CobaltKit API (additive; UI lanes build against exactly this)

```swift
// Store/Settings.swift — app-group defaults, observable like the others
extension Settings {   // declared inside the class body (needs the macro's access/withMutation)
    public var autoContinue: Bool              // key "autoContinue", default true
    public var autoContinueSeconds: Int        // key "autoContinueSeconds", one of autoContinueChoices, junk → 5
    nonisolated public static let autoContinueChoices: [Int] = [3, 5, 10]
    public var photosAlbumSync: Bool           // key "photosAlbumSync", default false
    public var photosSyncWebps: Bool           // key "photosSyncWebps", default false
}

// Models/Server.swift
extension Capabilities { public var sourceWait: Bool }   // `features.source_wait`, false when absent

// Share/ShareModel.swift (iOS)
public enum AutoContinue: Sendable, Equatable {
    case off                                   // setting off, file share, plain cobalt, no unpolled finish
    case armed                                 // waiting for the server to hold the save
    case counting(endsAt: Date, seconds: Int)  // `seconds` = the wait in force (after the 10 s floor)
    case stopped(AutoContinueStop)
    case fired                                 // continueInBackground() was called by the countdown
}
public enum AutoContinueStop: Sendable, Equatable { case stay, interaction, failed }   // owner: saving finishing does not stop it
extension ShareModel {
    public var autoContinue: AutoContinue { get }
    public func stay()                         // the stay button
    public func noteInteraction()              // every other control on the sheet calls this first
}

// Pipeline
public enum PhotosPlacement: Sendable, Equatable { case none, inAlbum, inLibrary }
extension Pipeline { public var photosPlacement: PhotosPlacement { get } }   // the run's item, observable

// Photos/PhotosSync.swift (new folder Sources/CobaltKit/Photos/)
@MainActor @Observable
public final class PhotosSync {
    public enum Access: Sendable, Equatable { case unavailable, notAsked, album, libraryLimited, libraryAddOnly, denied }
    public enum Problem: Sendable, Equatable { case outOfSpace, libraryUnavailable }
    public struct Progress: Sendable, Equatable { public var done: Int; public var total: Int }
    public struct Status: Sendable, Equatable {
        public var access: Access
        public var enabled: Bool               // Settings.photosAlbumSync
        public var paused: Bool                // enabled, keepVideosOnDevice off
        public var added: Int
        public var waiting: Int
        public var gaveUp: Int
        public var progress: Progress?         // non-nil while adding
        public var problem: Problem?
    }
    public enum EnableOutcome: Sendable, Equatable { case on(existing: Int), refused }

    public private(set) var status: Status
    public var isAvailable: Bool { get }       // status.access != .unavailable
    public func enable() async -> EnableOutcome       // asks for read-write, turns the setting on unless refused
    public func includeExisting(_ include: Bool) async // the backfill answer
    public func disable()
    public func setIncludeWebps(_ on: Bool)            // marks existing webps skipped when turning on
    public func refresh() async                        // re-read access + ledger (foreground, back from Settings)
    public func reconcile() async
    public func placement(of video: StoredVideo) -> PhotosPlacement
    public static func preview(_ status: Status) -> PhotosSync   // no PhotoKit; for #Previews and preview models
}

// Models/AppModel.swift
extension AppModel {
    public let photosSync: PhotosSync          // stored; PhotosSync.preview(...) in AppModel.preview
    public func handleBackgroundDownloads(identifier: String) async
    nonisolated public static func ownsBackgroundSession(_ identifier: String) -> Bool   // prefix "com.capybaraharmony.cobalt.bg."
}
```

Internal to CORE (named so tests and reviews can find them; not used by UI lanes):
`PendingOriginals` (ledger, `Sync/originals.json`; states `queued`, `downloading(session, task,
since)`, `arrived(file)`, `stored(id)`, `failed(code, tries)`, `gone(code)`), `OriginalFetcher`
(the background-session delegate). Its seam is `BackgroundTransport` (fake in tests), with:
- identifiers `com.capybaraharmony.cobalt.bg.app` (app) and
  `com.capybaraharmony.cobalt.bg.share.<job uuid>` (each sheet);
- `sharedContainerIdentifier = AppGroup.id`, `isDiscretionary = false`,
  `sessionSendsLaunchEvents = true`;
- request timeout 120 s, resource timeout 15 min.

The delegate moves the file **inside** `didFinishDownloadingTo` into `store.inboxURL`, records
`arrived`, and only then calls `store.add`. Only a 200 is a video. The other answers:
- `409 error.studio.not_ready` → `queued`;
- 410 / 404 / 422 → `gone`;
- 5xx and network errors → `failed`, retried.

Other internals: `PhotosLedger`, and `PhotoLibrary` grown with album calls.
`PhotosSaver.save` returns the asset's `localIdentifier?`.

Wiring CORE does without UI lanes:
- `ShareModel.live` builds the countdown and the handoff.
- `ShareCore.continueInBackground()` and `dismiss()` hand the original off before
  `pipeline.cancel()`. `handOffToApp()` does not.
- `keepOriginalInBackground` does not start when the ledger already has a live entry for that
  session.
- `resumeJob(.saving)` starts the keep download after `develop` (gap 2).
- `AppModel.pickUpSharedJobs` reconciles in this order: handoff first, then `originals`, then
  `photosSync.refresh()` and `reconcile()`.
- `OfflineStore.add` in the app process triggers a reconcile through an `onAdd` hook.
- `runSaveToPhotos` and `savePickerItems` record their keys.

## 5. Server addendum (APP-API-CONTRACT section 11, written by lane S)

- `GET /studio/<sid>/source?wait=N`, where N is clamped to 0..90 (absent or junk = 0, today's
  behaviour). While the row is `saving`, the Worker repeats the existing DO
  `advance?wait=min(25, remaining)` call and re-reads D1, until the row is no longer saving or the
  deadline passes. Then:
  - ready → exactly today's 200 or 206 response;
  - still saving → `409 error.studio.not_ready`;
  - the save failed → `422 {"status":"error","error":{"code":"<the session's error code>"}}`.

  HEAD ignores `wait`. No key, as before.
- `GET /capabilities` gains `features.source_wait: true`.
- Tests (injected `now`/`sleep`): wait=0 unchanged; saving→ready inside the wait serves the bytes;
  saving past the deadline → 409; failed → 422 with the code; the clamp; HEAD.
- Unverified until deployed: a 90 s hold through the Cloudflare edge to `nsurlsessiond` (F7 says
  the Worker may hold it). The app treats 409 as "try again on foreground", so a too-short hold
  costs delay, not data.

## 6. UI behaviour (lanes B and C)

**Share sheet (C).** While `autoContinue` is `.counting`, `continueBlock` becomes one row, laid out
with `ViewThatFits`: an HStack, falling back to a VStack with stay first.
- **stay** (`hand.raised`, `.cobaltSecondary(compact: true)`).
- **continue in background** (`moon.zzz`, `.cobaltSecondary()`). Its icon carries a draining
  ring (`Circle().trim`), driven by `TimelineView(.animation)` from `endsAt`.
- Under the row, the caption `continuingIn(remaining)` (whole seconds, rounded up) in place of
  today's note. The notify note returns after stay.

Accessibility and behaviour:
- Reduce Motion: no ring. The caption updates once a second (`TimelineView(.periodic(by: 1))`).
- VoiceOver: on entering `.counting`, post `continuingAnnouncement(seconds)` **once** and move
  `@AccessibilityFocusState` to stay. Stay has `.accessibilitySortPriority(1)`. The ring is
  hidden, and the button label never changes with the seconds.
- Every other button on the sheet calls `model.noteInteraction()` first.
- `.stopped` and `.off` show today's block unchanged.
- The ring and caption use `CobaltColor.text` / `.caption`. No new colours.

**Settings (B).** Two new `Section`s in `SettingsScreen`, in this order: server, making,
**share sheet**, on this iphone, **photos** (iOS, `photosSync.isAvailable`), live, feel.

Share sheet section:
- `Toggle` autoContinue (`moon.zzz`).
- `Picker(.menu)` "wait" (`timer`, values `seconds(3/5/10)`), disabled when the toggle is off.
- Footer `autoContinueFooter`.

Photos section:
- `Toggle` albumToggle (`photo.badge.plus`):
  - on → `enable()`; `.on(existing: n)` with n > 0 → `confirmationDialog(backfillTitle(n))`
    with `backfillAdd(n)` and `backfillSkip` (cancel role) → `includeExisting(_:)`;
  - `.refused` → the toggle snaps back;
  - off → `disable()`;
  - disabled with `footerNeedsKeep` when keep videos is off.
- When enabled: `Toggle` includeWebps (`sparkles`) → `setIncludeWebps`.
- `LabeledContent` albumRow (`photo.stack`), value by priority:
  `paused` › `accessOff` › `adding` › `outOfSpace` › `libraryLimited` / `libraryAddOnly` ›
  `albumCount` (+ `· waiting(n)` when > 0) › `gaveUp`.
- **open settings** (`gearshape`, `UIApplication.openSettingsURLString`) for limited / add-only /
  denied.
- Footer `footerAlbum` / `footerLimited` / `footerAddOnly` / `footerDenied`, and `webpStill` under
  include webps only if G-W says still.
- `.task` and the foreground both call `refresh()`.

**Save-to-photos button (B: FocusView, StudioCard; C: ShareRootView).** Order:
1. `photosPlacement == .inAlbum` → `inAlbum` + `photo.badge.checkmark`, done style, not tappable;
2. `.inLibrary` → `inLibrary`, same style;
3. otherwise today's states.

**App hook (B, `CobaltApp.swift`, iOS only):**
`.backgroundTask(.urlSession(matching: AppModel.ownsBackgroundSession)) { id in await model.handleBackgroundDownloads(identifier: id) }`.

## 7. Lanes, waves, ownership

| wave | lane | owns (writes only these) | done when |
|---|---|---|---|
| W0 | A · CORE (`sonnet-lane`) | `apple/CobaltKit/**`, `apple/project.yml`, generated `apple/Config/*.plist`, `apple/Cobalt/Design/Copy+Sync.swift`, `apple/Cobalt/Design/Symbols+Sync.swift` (verbatim from 2 and 3) | every section 4 signature compiles on iOS and macOS; Settings keys real; the countdown in `ShareCore` real and tested; `PhotosSync.preview` real; engine bodies may be stubs |
| W0 ‖ | S · API (`sonnet-lane`) | `deploy/cloudflare/api/src/{studio-edge,worker,app-routes,studio}.ts`, `deploy/cloudflare/api/test/**`, `deploy/cloudflare/APP-API-CONTRACT.md` (new section 11), `deploy/cloudflare/README.md` (one line) | section 5 tests green; api `npm test && npm run typecheck`. Many of these files already have uncommitted changes from earlier lanes: edit on top, never revert |
| W1 | A · CORE (same lane, continued) | as W0 | the section 8 test list green |
| W1 ‖ | B · APP UI (`sonnet-lane`) | `apple/Cobalt/Screens/Settings/**`, `apple/Cobalt/Screens/Home/FocusView.swift`, `apple/Cobalt/Screens/Home/StudioCard.swift`, `apple/Cobalt/App/CobaltApp.swift` | gates; `#Preview`s of the settings section for every `Access` × enabled/paused/adding/outOfSpace/gaveUp, and the backfill dialog |
| W1 ‖ | C · SHARE UI (`sonnet-lane`) | `apple/CobaltShare/**` | gates; `#Preview`s: counting (5 s, Reduce Motion), stopped by stay, still counting at ready, in your cobalt album, in your photos |
| W2 | V · verification (`sonnet-lane`) | none (evidence to a session path) | section 8 checklist with screenshots and logs, pass/fail per line |

Rules as `CONTRACT.md` 3: shared types only in CobaltKit; a UI lane that needs more API asks
Fable; `project.yml` is CORE's; no lane commits or pushes.

## 8. Gates and evidence

**Gates** (every lane; Fable reruns): the four commands of `CONTRACT.md` section 9 (xcodegen; the
iOS build on iPhone 17 Pro / iOS 26.5; the macOS build; `cd apple/CobaltKit && swift test`), with
no `warning:` lines from `apple/`. Also `plutil -lint apple/Config/*.plist`, and for lane S
`cd deploy/cloudflare/api && npm test && npm run typecheck`.

**CORE tests** (macOS `swift test`, temp dirs, injected clock, fakes for PhotoKit and the
transport):
- **countdown:**
  - armed → counting only once the server holds the save and `finishesUnpolled` is set;
  - fires at N s exactly once, and calls `continueInBackground`;
  - stay, interaction and failed each stop it, for good; reaching reading/ready does NOT stop it, and firing at ready closes via the close path (keep download handed off);
  - setting off / file input / plain cobalt / picker → `.off`;
  - the 10 s floor.
- **handoff:**
  - continue during saving queues and starts a task (`source_wait` true), or only queues (false);
  - close at ready with the keep download running cancels it and queues the handoff;
  - original already stored → nothing; keep off → nothing; "trim in cobalt" → nothing.
- **fetcher:**
  - 200 → arrived → stored (also when a fresh process instance reads `arrived`);
  - 409 → queued, ≤ 2 background re-enqueues, foreground restarts;
  - 410/404/422 → gone; ENOSPC → failed, retried;
  - `keepOriginalInBackground` skipped while an entry is live; `resumeJob(.saving)` keeps the
    original.
- **photos:**
  - the key table; eligibility (link nil excluded, webps only when on, no file → waiting);
  - two `PhotosSync` instances over one ledger add once;
  - a claim in doubt → done or retry per access;
  - a deleted asset is not re-added; eviction and `clearAll` make no Photos calls;
  - the access mapping table (decision 7);
  - album by id, then by title, then created exactly once;
  - repair after an upgrade skips missing assets;
  - backfill add/skip; turning webps on marks existing ones skipped;
  - a manual save records its key, and app album mode puts it in the album;
  - 3305 → waiting + `.outOfSpace`; 3 failures → gaveUp; disable stops new adds.

**V checklist** (iPhone 17 Pro simulator, iOS 26.5; save every screenshot and log):
1. Settings: both new sections in each access state. Use `xcrun simctl privacy booted grant|revoke
   photos` / `photos-add` for `com.capybaraharmony.cobalt`. Include the backfill dialog and the
   needs-keep footnote.
2. Album: with full access, the preview pipeline (`-previewClip`) lands clips. Photos.app ›
   Albums shows "cobalt" with them. Relaunch: no duplicate album and no duplicate assets. Clear
   the offline store: the assets stay in Photos. Delete one in Photos and reconcile: it is not
   re-added.
3. Limited access: assets go to the library and the status reads "your library · limited
   access". Upgrade to full: the repair moves them into the album.
4. **G-W:** sync one animated webp. Take two Photos.app screenshots 0.5 s apart at the same zoom.
   If the frames are identical, ship `webpStill`; otherwise drop it. Also record whether
   `PHAssetCreationRequest` accepted the `.webp` at all. If it refused, the include-webps toggle
   is removed (tell Fable).
5. Share sheet: the real extension from Safari's share sheet on a link, with the live server and
   the owner's key if present on the sim; otherwise the `#Preview` screenshots. Capture the
   countdown at 5/3/1 s, stay, Reduce Motion, and the sheet closing at 0. Then: the ledger shows
   the entry, the app at foreground lands the original in the orbit and the album.
6. Background session on the simulator: only that a task started by the extension completes
   while the app is in front, and is delivered and stored. **Not verifiable on the simulator:**
   the app being launched in the background for an extension's session after the extension is
   gone, the rate limiter, Photos writes while the phone is locked.

**Owner device checklist** (signed build; Fable hands it over): share a link and let the countdown
run; lock the phone; within a minute the clip is in the "cobalt" album without cobalt being opened
(not force-quit). Repeat with a long save (> 90 s): the clip arrives on the next cobalt open at the
latest. With Low Power Mode on, the same.

## 9. Sources

- Apple, "Delivering an Enhanced Privacy Experience in Your Photos App" (limited: "can't create or
  fetch user albums"; usage-description keys): https://developer.apple.com/documentation/photokit/delivering-an-enhanced-privacy-experience-in-your-photos-app
- Apple, `PHAccessLevel.addOnly`: https://developer.apple.com/documentation/photos/phaccesslevel/addonly
- Apple Developer Forums 661196 (add-only then album calls trigger the read-write prompt) and
  658114 (error 46104 creating an album after add-only, iOS 14): https://developer.apple.com/forums/thread/661196 ,
  https://developer.apple.com/forums/thread/658114
- Apple, App Extension Programming Guide, "Performing Uploads and Downloads": https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html
- iOS 27 SDK headers read 2026-10-04: `NSURLSession.h` (`sharedContainerIdentifier`,
  `sessionSendsLaunchEvents`, `discretionary`), `BGTaskRequest.h` / `BGTaskScheduler.h`
  (continued processing on behalf of the foregrounded app; extensions), `PHError.h` (3305 etc.),
  `PHAssetCollectionChangeRequest.h`, `SwiftUI.swiftinterface` (`BackgroundTask.urlSession(matching:)`)
- Quinn (Apple DTS), "NSURLSession's Resume Rate Limiter": https://developer.apple.com/forums/thread/14854 ;
  "iOS Background Execution Limits" (force quit): https://developer.apple.com/forums/thread/685525
- Cloudflare Workers limits (HTTP duration): https://developers.cloudflare.com/workers/platform/limits/
- WebP in Photos (third party, unconfirmed): https://imgplay.zendesk.com/hc/en-us/articles/4405513834265-The-saved-WebP-file-is-not-playing-in-the-Photos-app

## 10. Owner decisions (2026-10-04)

1. **A save that finishes before the timer ends: close anyway** (owner). Unless the owner tapped
   stay or touched the sheet, it closes when the timer ends; the background download finishes the
   video. (Supersedes Fable's stay-on-the-clip default; decision 3 is amended.)
2. **Full photo access for the album: yes** (owner). The prompt says cobalt only uses it for the
   album; limited / add-only grants fall back to the library as in decision 7.
