# cobalt for apple: paste anywhere, run several at once (design lane, 2026-10-06)

Owner (on the Mac): "I want to be able in the cobalt ui support pasting and being able to run things in parallel
mock this up with options please".

Additive to `CONTRACT.md`, `CONTRACT-ORBIT.md` (star, focus, progress card 2c), `CONTRACT-LIVE.md`,
`CONTRACT-SHARE-QUICK.md` section 9 (instant share) and `deploy/cloudflare/APP-API-CONTRACT.md` (section 17 is this
contract's server half). Code read on 2026-10-06 from the `apple-app` worktree, **including uncommitted edits of other
lanes** (line numbers are from that working tree; an offline-storage lane has `PipelineFlows.swift`, `OfflineStore.swift`
and `Settings.swift` dirty, so re-check the cited lines before editing).
**(lane)** marks a call made here and open to review; **(owner)** what the owner asked for or must decide.
Boards: `Parallel-{A,B,C,D}-*-{Mac,iPhone}.dc.html` (section 11). Nothing here is built yet; the Swift below is
the pinned shape for the implementation lanes, not code that exists.

## Owner decisions 2026-10-06 (and what they reverse)

1. **Option A, the tray.** As recommended (section 10). No reversal.
2. **Pasting several links stops at "saved"**: no automatic webps (section 14 question 1, default confirmed). No reversal.
3. **The server holds the line in v1.** Links waiting when the owner leaves cobalt finish with the app closed, and
   "2nd in line" counts every client (share sheet, the other device, the web studio, Shortcuts). The old section 7
   "optional v2" is now v1 and pinned as `APP-API-CONTRACT.md` section 17. This **reverses**:
   - decision 2.3 ("the server's one-at-a-time is a line on this device"): the device's line is now a **mirror** of the
     server's; the device line survives only as the fallback for a server without `features.line` (`LocalLine`, 3.2);
   - decision 2.5 ("no server change in v1") and the old section 7;
   - decision 2.10 / section 3.5: the `JobLedger` shrinks to the seconds between adding a job and the server's `201`
     (and to the fallback); a queued job has a server session from its first second;
   - section 3.4's "there is no server route to cancel": work still in the line can now be cancelled server-side;
   - section 6's "2 links are waiting for cobalt" local notification: with the server's line, one Hark summary when
     everything left behind is done (17.8) replaces it (the local one stays for the fallback);
   - section 3.1's "checking the link" step for every job: a batch, a drop of several links and a Shortcut send each
     link straight into the server's line (the server resolves it), so a link pasted a second before leaving is not lost
     (owner question 3 is the one consequence);
   - section 14 question 2's default ("not in v1");
   - `APP-API-CONTRACT.md` 14.1 item 2: a share-sheet save that finds the server busy now waits in the line, first in
     first out, up to 30 minutes, instead of retrying the helper every 2 s for 2 minutes (first to retry wins).
4. **New request**, verbatim: "I was also thinking it would be cool to have some uh, cobalt shortcuts um, for pasting
   links just and even uploading files that cobalt offers and I could use it in a shortcuts app please". Section 15
   (App Intents in the app itself: save links, upload files, make a webp, get the latest saves).
5. **(owner, 2026-10-06, `CONTRACT-GALLERY.md` owner decision 5) Galleries in a batch or a Shortcut save everything**, reversing
   question 3's "first video" default (section 14). Interim: until the gallery server (`APP-API-CONTRACT.md` section 18,
   `features.gallery`) is deployed, a batch and a Shortcut keep today's first-video behaviour; nothing in this file's lanes changes.

## 0. What the request means (interpretation, to confirm)

1. **Pasting**: paste a link straight into the window from anywhere (⌘V on the Mac and on an iPad keyboard,
   not only the round paste circle), several links in one paste, links and text dropped on the window (today
   only files), and never a paste that silently does nothing.
2. **Parallel**: start a save (or a webp) while another is still running, several jobs in flight with visible
   progress for each, each landing as its own planet, the focused planet never taken away by a background job,
   and the Live Activity summarising "3 running" instead of one activity per job.
3. **(owner, 2026-10-06) Shortcuts**: the same jobs started from the Shortcuts app, Siri or Spotlight, with values
   that the next Shortcuts action can use (section 15).

## 1. What exists today (facts)

| fact | where |
|---|---|
| ⌘V on the Mac is a menu command calling `pasteFromClipboard()`; on iPad a hidden keyboard-shortcut button | `Cobalt/App/CobaltApp.swift:167-170`, `Cobalt/App/AppShell.swift:300-306` |
| `pasteFromClipboard()` **returns silently** while anything runs (`guard pipelineIsFree`) | `AppShell.swift:16-17` (same for a dropped file, `:24`) |
| a paste takes only the first link (`LinkInfo.firstLink(in:)`) | `Pipeline.swift:386`, `Pipeline/LinkInfo.swift:24` |
| dropping is files only: a link dragged from Safari is refused | `AppShell.swift:87-88` (`urls.first(where: \.isFileURL)`) |
| one home `Pipeline`; a closed run with a render, a publish or the keep download in flight is carried on by a hidden `Pipeline` (`detach()`, `BackgroundRuns`); a save (fetching/saving/reading) is **not** detachable | `PipelineDetach.swift:12-26`, `BackgroundRuns.swift` |
| the server's helper does **one thing at a time** for saves, encodes, probes and posters | `deploy/cloudflare/api/helper/server.js:178` (`busy()`) |
| there is **one** Durable Object for every client (share sheet, app, web, Shortcuts) | `deploy/cloudflare/api/src/index.ts:331` (`getContainer(env.COBALT, "main")`) |
| `POST /studio` answers `429 error.studio.busy` while a save or an encode runs (unless `origin: "share"`); the app retries every 3 s for 60 s, then fails `serverBusy` | `api/src/studio.ts:764`, `PipelineFlows.swift:69-84` |
| `POST /studio/<sid>/render` answers `429 error.webp.busy` while a save runs; the app fails at once (`renderBusy`, "another webp is being made right now.") | `studio.ts:1617`, `API/ErrorMap.swift:28` |
| a share-origin save is never refused: it waits for the helper up to `BUSY_WAIT_MS` (120 s), retrying every 2 s (not first-in-first-out) | `studio.ts:40-41`, `studio.ts:1103-1114` |
| saves and renders finish with nobody polling (job sweep every 5 s while anything is pending); the Live Activity is one per run; the server caps 16 open live runs per key | APP-API-CONTRACT 6, `api/src/sweep.ts` (`SWEEP_DELAY_S`), `LiveActivityManager.swift:5`, APP-API-CONTRACT 8 |
| the relaunch pickup resumes **one** in-flight app job into the home pipeline | `Models/AppModel.swift:282` (`nextInFlightAppJob`) |
| an unknown save `step` or render `phase` from a newer server decodes as "not said" | `Models/Wire.swift:127`, `API/HTTPCobaltClient.swift:371` |
| telemetry categories are a closed list; an unknown `cat` is a `400` for the whole batch | `deploy/cloudflare/TELEMETRY-CONTRACT.md` section 1 |
| the app has **no App Intents** today (no `AppIntent`, `AppEntity` or `AppShortcutsProvider` in `apple/` outside these contracts); two signed macOS Shortcuts call the API directly with an embedded key | grep 2026-10-06; `deploy/cloudflare/shortcuts/README.md` |

So "parallel" is honestly two different things: **the network can run side by side** (checking a link with
cobalt, uploading bytes, downloading originals, reading frames) and **the server cannot** (one save or one encode
at a time). Firing several `POST /studio` today just buys `429`s and a `serverBusy` after a minute. With section 17
the server keeps the line itself, so the app (and a Shortcut, and the share sheet) hands work over and goes.

## 2. Decisions

1. **(owner) Option A, the tray** (section 10 has the four options, the reasoning and what would change it). The
   paste rules (section 4), the job model (section 3) and the Live Activity summary (section 6) are the same whichever
   option; only the job surface differs.
2. **(lane) N jobs, each a full `Pipeline`, one of them focused.** A new `JobQueue` (CobaltKit) owns every run of
   the app as a `Job` wrapping its own `Pipeline`; `AppModel.pipeline` becomes the focused job's pipeline (or an
   idle one). This generalises what `BackgroundRuns` already proves (several `Pipeline`s alive at once with their
   own `SharedJob`, Live run id and store pins) and removes the state copy of `adoptDetached`: closing the focus
   no longer moves a run into a new object, the job just stops being focused.
3. **(owner, reverses the lane's device line) The server holds the line** (`APP-API-CONTRACT.md` section 17, capability
   `features.line`). Every save and render the app asks for is sent with `"queue": true`: the server answers at once,
   either started or queued with its place (`queue_ahead`), and starts it when its turn comes whether or not anybody is
   polling. The app's line is a **mirror** (`ServerLine`): it shows the server's positions, never decides them. On a
   server without `features.line` the app keeps the device line of the first draft (`LocalLine`: first come first
   served on this device, the focused webp ahead of saves that have not started).
4. **(lane) The focused-webp rule survives, asked for explicitly.** A render the owner starts from the focused planet
   carries `"priority": "focused"` and goes ahead of every waiting **save** (behind earlier focused renders); nothing
   that runs is ever interrupted. Renders exist only for the focused job (5.3), so every render the app's screen starts
   carries it; a Shortcuts render does not (15.4). Why keep it: a pasted batch of 20 links would otherwise put a webp the
   owner is looking at 15 minutes away.
5. **(lane) The line is shown honestly**: "waiting for the server · 2nd in line" where the job running on the server is
   1st (`queue_ahead + 1`). Who is ahead comes from `GET /studio/line`: "after a share from your iphone", "after a save
   from your mac" (`key_name`), never a fake percentage or a guessed position.
6. **(lane) Focus rules (pinned, section 5).** Only two things focus a job: a single link (or file) added while
   nothing is focused and nothing runs, and the owner opening a job or planet. A job finishing in the background
   never moves the focus, the tab, a sheet or the scroll. A Shortcut never focuses.
7. **(lane) Paste never does nothing** (section 4): no link says so, one link starts at once, two or more get a
   short review with duplicates unticked. Dropped links and text count as a paste.
8. **(lane) One Live Activity per busy period** once two jobs are live (section 6); a single job keeps today's
   per-run activity, push mode included.
9. **(owner) A batch stops at "saved".** Webps are made one by one from focus.
10. **(lane) Persistence**: every job with a server session (all queued ones included) survives a relaunch through
    the existing `SharedJob` records (all of them now, not one); `GET /studio/line` restores their places. The
    `JobLedger` covers only jobs that have no session yet (section 3.5).
11. **(lane) Mac extras**: the Dock tile shows the live count (`NSApp.dockTile.badgeLabel`), and a
    `ProcessInfo.beginActivity(.userInitiated)` is held while jobs are live so App Nap does not stretch the
    polling clock.
12. **(lane) Leaving cobalt** with work on the server sends **one** `PUT /studio/line/notify`; the owner gets one Hark
    message when all of it is done (17.8), not one per link. Coming back sends `DELETE`.
13. **(lane) Shortcuts are App Intents in the main app**, one entry point (`JobQueue.add`), background by default
    (section 15).

## 3. Architecture

### 3.1 Job lifecycle (one `Pipeline` per job)

With `features.line` (the normal case):

```
add ─▶ checking the link (POST /, network, ≤ 3 at once)   ← only a single link added on a quiet screen (it may be a
        │ picker / image / local-processing: as today        picker the owner chooses from); every other add skips it
        ▼
      POST /studio {queue: true, public?}  (≤ 1 s; the 201 is the hand-over: from here the server owns it)
        ├─ queued: waiting for the server · 3rd in line        (polls: step "queued", queue_ahead)
        ▼
      downloading from <service> ─▶ saving to your library    (the server runs it, polled or not)
        ▼
      reading the video (frames, ≤ 2 at once)  + keep-original download (background URLSession, unchanged)
        ▼
      saved (lands as a planet)  ── focused & "convert to webp" ─▶ POST render {queue: true, priority: "focused"}
                                      ─▶ waiting · 2nd in line ─▶ making your webp ─▶ packing ─▶ webp ready
      failed (stays until try again / dismiss)       cancelled (gone; section 3.4)
```

A file upload is "uploading" first (≤ 2 at once, outside the line), sent with `?queue=1`: the server's answer carries a
session, queued or started, so there is no separate busy retry any more.

**(lane) Why a batch skips "checking the link"**: the check (`POST /`) is a round trip the app must be alive for, and the
owner leaves right after pasting. Sent straight to the line, the link is the server's within a second; the server's
helper resolves it the same way (`helper/lib.js:611-617`: a multi-item post gives its first video, a post with no video
fails with `error.webp.no_video`). Owner question 3.

Without `features.line` (fallback): exactly the first draft: checking, then "waiting for the server" in the device's
`LocalLine`, then `POST /studio` without `queue` (3 s / 10 min busy retry inside a held slot), and so on.

### 3.2 CobaltKit API (pinned)

```swift
// Jobs/JobQueue.swift (new). Owned by AppModel; the share extension has none.
@MainActor @Observable
public final class JobQueue {
    public private(set) var jobs: [Job]                  // oldest first; finished ones until cleared (24 h at most)
    public private(set) var focusedID: Job.ID?
    public var focused: Job? { get }
    public var live: [Job] { get }                       // in flight (checking … packing), queued on the server included
    public var alongside: [Job] { get }                  // the tray: live + failed + finished < 5 s ago, minus the focused one,
                                                         // ordered: on the server, network steps, line order, failed, finished
    public var summary: JobSummary { get }               // counts for the tray header, the Dock and the Live Activity
    public var lineMode: LineMode { get }                // .server (features.line) / .device (fallback)
    @discardableResult
    public func add(_ inputs: [JobInput], via: JobVia, options: JobOptions = .init()) -> [Job]   // the ONE entry point (paste,
                                                         // drop, circle, review, relaunch, share, shortcut); applies 5.1
    /// Until every job has a server session (queued or started) or failed, at most `timeout` seconds (Shortcuts, 15.3).
    public func accepted(_ ids: [Job.ID], timeout: Double) async -> [Job.ID: JobAcceptance]
    public func focus(_ id: Job.ID)                      // the owner opened it (row, card, planet)
    public func unfocus()                                // close: a live job keeps going alongside
    public func cancel(_ id: Job.ID) async               // 3.4
    public func retry(_ id: Job.ID)
    public func dismiss(_ id: Job.ID)
    public func clearFinished()
}
public struct Job: Identifiable {
    public let id: UUID                                  // == the pipeline's liveRunID (Live Activity, SharedJob, server run)
    public let pipeline: Pipeline
    public let origin: Origin                            // .app, .share (from GET /studio/recent), .relaunch, .shortcut
    public let addedAt: Date
    public enum Origin: Sendable { case app, share, relaunch, shortcut }
}
public enum JobInput: Sendable, Equatable {
    case link(URL)
    case file(URL, photosAssetID: String?)
    case shared(SharedJob)                               // follow a session someone else started (share sheet, relaunch)
}
public struct JobOptions: Sendable, Equatable {
    public var title: String? = nil                      // sent with the create (17.3 `title`); one-input adds only
    public var makePublic: Bool? = nil                   // nil = the app's "new saves public" setting (PipelineFlows `publicFlag`)
    public init(title: String? = nil, makePublic: Bool? = nil)
}
public enum JobAcceptance: Sendable, Equatable {
    case onServer(session: String, postKey: String, queued: Bool, ahead: Int?)   // postKey: the session id (link) or the upload's item id
    case failed(PipelineFailure)
    case stillLocal                                      // timed out before the 201 (still uploading, or no line on the server)
}
public enum JobVia: String, Sendable { case paste, drop, circle, review, relaunch, share, shortcut }
public enum LineMode: Sendable { case server, device }
public struct JobSummary: Sendable, Equatable { public var live, waiting, finished, failed: Int }

// Jobs/JobLine.swift (new, internal). What "waiting" means, behind one protocol.
@MainActor protocol JobLine: AnyObject {
    /// `.device`: returns when it is `job`'s turn (the first draft's acquire). `.server`: returns at once (the request
    /// itself carries `queue: true`). Throws CancellationError.
    func enter(_ job: UUID, kind: LineKind, priority: LinePriority) async throws
    func observe(_ job: UUID, queueAhead: Int?)          // from every poll answer (server mode); nil = it started
    func noteOnServer(_ job: UUID)                       // device mode: an upload's adopt or a resumed run holds the slot
    func release(_ job: UUID)
    func position(of job: UUID) -> LinePosition?
}
enum LineKind: Sendable { case save, render }
enum LinePriority: Int, Comparable, Sendable { case batch = 0, focused = 1 }
final class ServerLine: JobLine { /* mirror: positions from queue_ahead; who is ahead from GET /studio/line (3.3) */ }
final class LocalLine: JobLine  { /* the first draft's HelperLine, unchanged rules; also noteForeign(session:label:saving:) */ }

public enum LinePosition: Sendable, Equatable {
    case inLine(Int, behind: String?)                    // 2 = "2nd in line"; behind: "a share from your iphone" / "a save from your mac"
    case serverBusy(since: Date, label: String?)         // device mode only: a 429 for something not in this line
}

// Pipeline (additive): what the waiting looks like; nil when the run is not waiting.
extension Pipeline { public internal(set) var line: LinePosition? }

// Pipeline/LinkInfo.swift (additive): firstLink's rule for every link, repeats folded, at most `limit`.
extension LinkInfo { public static func allLinks(in text: String, limit: Int = 20) -> [URL] }
```

Wire and client (additive; the shapes are section 17's):

```swift
// Models/Wire.swift
public enum SaveStep: String { case fetching, reading, storing, queued }          // + queued
public enum RenderPhase: String { case fetching, decode, pack, queued }           // + queued
StudioSession.queueAhead: Int?                       // `queue_ahead`
StudioCreated.queued: Bool, .queueAhead: Int?        // POST /studio, the item studio route, the upload's session
RenderStatus.pending(phase:framesDone:framesTotal:queueAhead:)                    // + queueAhead
RenderRequest.queue: Bool?, .priority: String?       // "focused"
// Models/Server.swift: Capabilities.line: Bool (`features.line`), Limits.lineMax: Int (50), Limits.lineWait: TimeInterval (1800)
// API/Client.swift (CobaltClient, defaulted in the protocol extension so old fakes compile)
func createStudio(link: URL, public: Bool?, queue: Bool, title: String?) async throws -> StudioCreated
func openStudio(item id: String, queue: Bool) async throws -> StudioCreated
func upload(file:name:contentType:public:queue:title:progress:) async throws -> UploadedFile
func cancelQueued(session id: String) async throws -> QueueCancel                 // DELETE /studio/<id>/line
func cancelQueued(session id: String, job: String) async throws -> QueueCancel    // DELETE /studio/<id>/render/<job>
func line() async throws -> ServerLineSnapshot                                    // GET /studio/line
func setLineNotify() async throws -> Int                                          // PUT /studio/line/notify → watching
func cancelLineNotify() async throws                                              // DELETE /studio/line/notify
public enum QueueCancel: Sendable { case cancelled, started }                     // 200 / 409 error.studio.started
// PipelineFailure: + .lineFull (error.studio.line_full)
```

- **No new `PipelineState` case.** A queued or waiting save stays `.fetching(since:waking:)` and a waiting render
  `.rendering(.working(since:))`; `pipeline.line` says why. `ProgressStory` reads `line` first ("waiting for the
  server", detail from the position). The `switch s.step` in `pollSaving` (`PipelineFlows.swift:410-418`) gets a
  `.queued` case that sets `.fetching` plus `line = .inLine(queueAhead + 1, …)` through `observe`; the render poll
  (`:750-769`) does the same for `.pending(.queued, …)`.
- **Where the line is entered** (`PipelineFlows.swift`): `forkSave` (`:386`) calls `line.enter(.save, .batch)` before
  `openStudioRetrying` (`:69`); in server mode that call returns at once and `openStudioRetrying` sends `queue: true`
  (no busy loop: a queued create never answers `error.studio.busy`; `error.studio.line_full` fails `.lineFull`).
  `runRender` (`:711`) enters with `.focused` and builds `RenderRequest(queue: true, priority: "focused")` in server
  mode. `runUpload` (`:550`) sends `queue: true` (and `title` when the job has one); the "no session, retry through
  `openStudio(item:)`" branch (`:580-586`) stays for an old server. Device mode: the first draft (`acquire` before
  the POST, `release` in `defer`, 10 min busy ceiling while `.serverBusy`). `PipelineContext.line` is nil in the share
  extension.
- **`AppModel.pipeline`** becomes `queue.focused?.pipeline ?? idle` (a shared idle `Pipeline`), so the focus
  screens (HomeScreen, FocusView, Inspector, TitleSheet) keep reading `model.pipeline` unchanged.
  `pasteFromClipboard` / `importFile` stop checking `pipelineIsFree`.
- **`detach()`** stays for the share extension (`allowsDetach == false` keeps it a `reset()`); in the app,
  closing the focus is `queue.unfocus()`. `BackgroundRuns` folds into `JobQueue` (the queue keeps the grace,
  the "webp is ready" local notification when the app is not active, and `cancelAll` on a server change).
- **Concurrency caps (lane)**: link checks 3; uploads 2; frame reads 2; keep downloads: the system's background
  session as today; server mode has no cap on what is sent to the line beyond the server's `line_max` (50); device
  mode: line 1. Jobs beyond a cap wait silently in their current step (no extra copy).
- **`JobQueue.add` is the single entry point** for every source, Shortcuts included (15.3): an intent never creates
  work through the client directly.

### 3.3 The share sheet, other devices, and the server's line

On every foreground `pickUpSharedJobs` already asks `GET /studio/recent` (iOS, `OriginalFetcher.reconcile`).
Each share-origin session the queue does not know and that is still `saving` (queued ones included, `step:
"queued"`) becomes a `.shared` job (origin `.share`, never focused). A `ready` one is left to the existing original
download (it lands as a planet as today). The hand-off links (`cobalt-apple://session/<sid>`, `job/<id>`) focus that
job when the screen is quiet, else add it alongside (today they are ignored over a busy home: `AppModel.open`,
CONTRACT-SHARE-QUICK section 4). The new `cobalt-apple://jobs` (the Hark summary, 17.8) opens the tray (iPhone: the
pill's cards; Mac: the tray is already on screen).

**Server mode, who is ahead**: while one of this app's jobs is queued and the app is active, `ServerLine` reads
`GET /studio/line` every 3 s (one request for all jobs, not per job) and labels the jobs ahead: `running`/`entries`
with `origin: "share"` → "a share from your <key_name>", others not `mine` → "a save from your <key_name>" (`key_name`
null → "a save that isn't in this list"). The positions themselves come from each job's own poll (`queue_ahead`), so a
missed `/studio/line` read only loses the label. Device mode keeps the first draft's `noteForeign`.

### 3.4 Cancel, stop, try again (pinned)

| where the job is | x does | copy |
|---|---|---|
| checking the link, uploading, waiting in the device line | removed; the upload task is cancelled; nothing was saved | "cancelled <title>. nothing was saved." |
| queued on the server (server mode) | `DELETE /studio/<sid>/line` (a save) or `DELETE /studio/<sid>/render/<job>` (a webp); `cancelled` → removed | "cancelled <title>. nothing was saved." / "cancelled the webp." |
| …the cancel answers `started` (409: its turn came meanwhile), or on the server (saving, rendering, packing) | stop following; the server finishes what it started (it still lands in the library) | "stopped following <title>. the server finishes what it started, so it still shows up in your library." (a11y "stop <title>") |
| reading the video | stop reading; the save is done | "stopped. <title> is saved in your library." |
| failed | try again (same input, back of the line) / dismiss | the failure words of CONTRACT 5.1 |

A cancel that cannot reach the server (offline) keeps the job and says "couldn't cancel: the server didn't answer."
A running save or encode is never "cancelled": the server cannot stop one (17.7), so "stop" never pretends to.

### 3.5 Persistence across a relaunch

- **With a session** (queued, saving, rendering): the existing `SharedJob` record (`recordJob`) per job, written
  right after the `201`/`202` (a queued job is `.saving` or `.rendering(job:)`; no new stage). The pickup resumes
  **every** in-flight app job as a `.relaunch` job alongside (today: one, into the home pipeline,
  `AppModel.swift:267-288`); focus only per 5.1. In server mode one `GET /studio/line` restores their places at once.
- **No session yet** (between `add` and the server's answer; an upload in flight; every waiting job in device mode):
  `Jobs/JobLedger.swift` (new), a JSON file in Application Support (not the app group): `[{id, input: link | inbox
  file path + name + bytes + type, options, addedAt}]`, written on add, removed when the job gets its session or ends.
  On launch they go back in (server mode: sent to the line; device mode: back in line in their old order) and the tray
  says "3 links from last time are back in line." Entries older than 24 h are dropped (logged); a file whose inbox
  copy is gone is dropped with "the file for <name> is gone". **(lane, known gap)** a link whose `POST /studio` reached
  the server but whose `201` was lost is sent again unless `GET /studio/line` (mine, same `link`) already has it: a
  duplicate save is possible in that narrow case.
- Finished and failed jobs are not persisted (finished ones are planets; failures are retried by hand).

## 4. Paste (pinned)

1. **⌘V anywhere.** Mac: replace the `CommandGroup(after: .pasteboard)` ⌘V command with `onPasteCommand(of:
   [.fileURL, .url, .plainText])` on the window content, so ⌘V and Edit › Paste reach cobalt only when no text
   field takes them. **Risk found while reading (unverified):** today's menu command binds ⌘V globally; on the
   Mac it may swallow ⌘V in the "name it" sheet's `TextField` (`Shared/TitleSheet.swift:72`). iPad: the same
   through `pasteDestination(for:)` on the save tab; the hidden ⌘V button goes. The paste circle and the
   toolbar paste button keep reading `UIPasteboard`/`NSPasteboard` on tap (owner decision CONTRACT 1.11: the
   circle, with iOS's "allow paste" prompt). Whether `pasteDestination` avoids the iOS prompt for a keyboard ⌘V
   is to be checked in the first build.
2. **Several links**: `LinkInfo.allLinks(in:)`, the API's `extractFirstUrl` rule applied to every link, repeats
   folded, at most 20 per paste ("the first 20 of 34 links").
3. **No link**: "no link found in that text." (existing copy) as a status line; nothing queued.
4. **One link**: added at once (focus per 5.1). If that link is already a live job: "already saving that one."
5. **Two or more**: a review (Mac: a sheet on the window; iPhone: a bottom sheet at the medium detent): one row
   per link, ticked; a link the store or the loaded library already has is **unticked** with "already saved ·
   <when>"; a live one is "saving now" and cannot be ticked. "cancel" / "save N" (return / esc on a keyboard).
   Title previews are not possible before a save (cobalt's `POST /` gives a file name, the title comes from the
   session), so a row is `service · ref` (`LinkInfo`), honestly. "save N" sends all N to the server's line at once
   (server mode), so leaving right after loses nothing.
6. **Drop**: files (as today), web URLs and text with links, on the whole window: the same as 3 to 5; several
   files are several upload jobs.
7. **Not now (lane)**: a typed/editable link field (option D's) and a passive "link on the clipboard" hint on the
   circle (`UIPasteboard.hasURLs` does not prompt, but it is a nicety, not the request).

## 5. Focus (pinned)

1. Exactly one job may be focused. It becomes focused only when (a) a single link or file is added while no job
   is focused and none is live (today's experience exactly: star, morph, lift), (b) the owner opens it (a tray
   card, a list row, a planet), or (c) the existing "trim in cobalt" hand-off rule on a quiet screen.
2. A background job reaching "saved" or "webp ready" changes nothing on screen except its card and a planet
   popping into band 0 (the existing "arrives while the orbit is at rest" pop, `HomeScreen.swift:845-850`). VoiceOver
   hears "<title> saved." (polite). No toast in the app; the boards' toasts are review aids.
3. Trim, crop and "convert to webp" exist only for the focused job. A job that is unfocused at `.ready` keeps its
   trim and crop on its pipeline while it lives; it is "saved" in the tray and a planet in the orbit.
4. Closing the focus never throws work away: a live job keeps going alongside ("<title> keeps going alongside.").
5. The paste circle, ⌘V and drop all work during a focus (today they are ignored); what they add goes alongside.
6. A focused job that fails before it is saved shows today's failure capsule; "ok" dismisses the job.
7. iPhone: while a planet is in focus, the bottom belongs to it; the tray docks as a pill under the title
   ("2 running · 1 waiting"), tap to open its cards over the top of the screen.
8. **(lane) A job added by a Shortcut never focuses** (`via: .shortcut` counts as a batch), even on a quiet screen:
   the owner is in another app. Its "open cobalt" option (15.4) opens the tray, not the focus.

## 6. Live Activity, Continued Processing, Dock, leaving

- **One live job**: exactly today's per-run activity (push or local).
- **Two or more**: one activity for the busy period. The first job's activity is kept (no second
  `Activity.request`, so neither ActivityKit's per-app limit, whose number Apple does not document, nor the
  server's 16 open runs per key are touched). The app writes it locally (at most once a second in total) and the
  server registration of that run is deleted (`DELETE /live/runs/<run>`), so the server never pushes one run's
  content into the summary. It stays local until the period ends (no flip back to push).
- **Content** (additive optional fields on `LiveContentState`, lenient decoding already in place; the fixture
  `live-states.json` and the server's copy are unchanged): the lead job's stage, rail, bytes/frames and title
  (lead = the job running on the server, else the newest live one) plus `jobs: Int?` (live), `waiting: Int?`
  (queued on the server or in the device line). Widget: compact = the lead's step glyph + its circular progress + a
  count ("3"); Lock Screen and expanded = today's headline, detail, bar and stepper of the lead, then "+2 more · 1
  waiting for the server". The period ends when nothing is live: "3 saved · 1 webp" (done) or "2 saved · 1 couldn't
  be saved"; dismissal times as today (15 min done, 5 min failed). A Shortcut run with a system Live Activity of its
  own (15.2 `LongRunningIntent`) is not merged into this one.
- **Continued Processing (iOS)**: one `BGContinuedProcessingTask` per busy period instead of per pipeline
  (`ContinuedProcessing(home:)` → the queue), and **in server mode only while local work remains** (a link check, an
  upload, a frame read, a keep download): a job queued or running on the server needs no process to finish. Progress
  = (finished + the running job's fraction) / jobs, subtitle "3 saves · 1 waiting".
- **Leaving (server mode, `features.line` and `features.notify_bridge`)**: when the app leaves the foreground with any
  job on the server, one `PUT /studio/line/notify` (17.8), recorded in `NotifyBridge` as a new source `.line`; on the
  next foreground one `DELETE /studio/line/notify`. App jobs no longer get per-session `PUT /studio/<sid>/notify` on
  leaving (the summary covers them; a single job gets the same words as before, 17.8). Share-sheet saves keep their
  own opt-in. Jobs without a session when the app leaves (an upload mid-way) get the local notification "1 upload is
  waiting for cobalt" / "open cobalt to finish it." when Continued Processing is refused or expires.
- **Leaving (device mode)**: the first draft: "2 links are waiting for cobalt" / "open cobalt to finish them." for jobs
  in the device line; jobs with a session get the per-session opt-in as `detach()` does today.
- **Mac**: no Live Activities; the Dock badge shows the live count; nothing else. The Mac also sends the line opt-in
  when its last window closes or the app quits with jobs on the server.

## 7. Server (v1, pinned in `deploy/cloudflare/APP-API-CONTRACT.md` section 17)

Summary of what the app relies on (the section is authoritative):

- `features.line`; `limits.line_max` (50), `limits.line_wait_ms` (30 min).
- `"queue": true` on `POST /studio` and `POST /studio/<sid>/render`, `?queue=1` on `PUT /studio/upload` and
  `POST /library/items/<id>/studio`: never `429 busy`; `201`/`202` with `queued` and `queue_ahead`. `"priority":
  "focused"` on a render. `title` on `POST /studio` and `?title=` on the upload (15.2 rules). Line full: `429
  error.studio.line_full`.
- `GET /studio/<sid>`: `step: "queued"`, `queue_ahead` (the running job counts, so `queue_ahead + 1` is the place);
  render pending: `phase: "queued"`, `queue_ahead`. `GET /studio/recent` shows queued shares the same way.
- `GET /studio/line` (keyed): `running`, `entries` with `position`, `mine`, `origin`, `key_name`.
- The server starts the next job by itself (the sweep), whoever is polling; first in first out, focused renders
  ahead of saves; 30 min ceiling, then `error.studio.busy` / `error.webp.busy`.
- `DELETE /studio/<sid>/line`, `DELETE /studio/<sid>/render/<job>` (keyed, own sessions): `200 {cancelled: true}` or
  `409 error.studio.started`.
- `PUT|DELETE /studio/line/notify` (keyed): one Hark summary when everything this key had in flight is done, url
  `cobalt-apple://jobs`.
- Old clients, the web studio page, the macOS Shortcuts and the share sheet keep working unchanged.

## 8. Telemetry

Category `pipeline` (the server accepts no new category). Events, each with `concurrent` (live jobs) and `line`
(`server`|`device`) in `data`: `paste` {via, links, kept, duplicates}, `job added` {job, input:
link|file|share|relaunch, via, batch}, `job queued` {job, ahead} (server mode, from the 201), `job line` {job,
position, waitedMs} (when it starts), `job busy elsewhere` {job, waitedMs, label} (device mode), `job focus` {job,
why: auto|owner|handoff}, `job cancel` {job, phase, onServer, answer: cancelled|started|offline}, `job settled` {job,
outcome: saved|webp|failed|cancelled, totalMs, waitedMs}, `live summary` {jobs, waiting}, `line notify` {watching},
`shortcut run` {action: save|upload|webp|latest, inputs, accepted, failed, mode: background|foreground, waitedMs,
outcome}. Job ids are the run's UUID (already non-identifying); no links, titles or file names in telemetry, only
services.

## 9. Copy (lowercase; new unless marked)

| key | text |
|---|---|
| checking | checking the link |
| waiting | waiting for the server |
| line | 2nd in line / 3rd in line / 4th in line (the job on the server is 1st) |
| lineNext | · your webp goes next (a focused webp right behind the job on the server) |
| behindShare | · after a share from your iphone (`key_name`) |
| behindSave | · after a save from your mac (`key_name`); no name: · after a save that isn't in this list |
| busyElsewhere | device mode only: it's busy with a save that isn't in this list · 4 s |
| lineFull | cobalt's line is full (50). try again when a few have finished. |
| tray header | 2 running · 1 waiting / 1 finished |
| tray a11y | jobs running alongside; hide the jobs / show the jobs |
| saved card | saved · in the orbit and your library (button "open") |
| review title | 3 links on your clipboard / 3 links dropped |
| review note | links already saved are left out; tick them to save again. |
| review rows | new / already saved · <when> / saving now; buttons "cancel", "save 2", "nothing picked" |
| no link | no link found in that text. (existing) · nothing cobalt can save was dropped. |
| duplicate | already saving that one. |
| picker job | pick what to save (a single pasted multi-item post waits for the owner; tapping its card opens the picker as today) |
| alongside | saving 3 links alongside. / <title> keeps going alongside. |
| cancel / stop | see 3.4; a11y "cancel <title>", "stop <title>"; "couldn't cancel: the server didn't answer." |
| relaunch | 3 links from last time are back in line. |
| Live | +2 more · 1 waiting for the server / 3 saved · 1 webp / 2 saved · 1 couldn't be saved |
| leaving (device mode, or an upload mid-way) | 2 links are waiting for cobalt / open cobalt to finish them. · 1 upload is waiting for cobalt / open cobalt to finish it. |
| Hark summary (server, 17.8) | cobalt · done · 4 saved · 1 webp ready · 1 couldn't finish |
| progress words | unchanged: downloading from <service>, saving to your library, reading the video, making your webp, packing the webp |
| Shortcuts | section 15.6 |

## 10. The four options (boards in section 11)

| | A · tray (chosen) | B · stars | C · queue list | D · paste bar |
|---|---|---|---|---|
| pitch | glass stack of mini progress cards where you pasted: Mac top right under the paste button, iPhone above the circles; the focused job keeps the star and card | every job is a star: the focused one in the middle, the others smaller on a belt with a progress ring and their place in line; tap one for its card; they step aside into a row during a focus | one list of everything: Mac a "running" section in the sidebar (focused job marked "in focus", finished below with "clear"); iPhone a capsule that opens a sheet | paste-first: ⌘V / ⌘K / paste opens a bar listing every link found (duplicates unticked), return saves; the bar's lower half is the job list, closed it is a pill |
| legibility of N jobs | high: each card is the 2c story | low: tiny rings and labels over planets (the owner's 2c complaint, again) | high, and ordered | high while open; one more step to see |
| focus safety | Mac: beside the hero; iPhone: docks to a pill | stars move aside, but compete with the one star | untouched (lives in the sidebar/sheet) | the bar covers the hero while open |
| paste | shared rules | shared rules | shared rules | every paste previews, even one link (one more keystroke) |
| UI cost over the shared core (estimate) | S/M, ~350 lines: `JobTray`, `JobCard`, HomeScreen mount | L/XL, ~900+: multi-star drawing and hit testing in `OrbitGeometry`/`StarView`/HomeScreen, the aside row | M, ~500: a `List` section in the Mac sidebar beside tab selection, iPhone capsule + sheet | M/L, ~700: overlay bar with a multi-line field (pasted newlines must separate links), parsing preview, keyboard, iPhone top sheet |

Shared core for every option (estimate): queue, both lines, ledger, paste parsing and review, Live summary, continued
processing, telemetry, tests: roughly 2,000 to 2,400 lines with tests (the server mirror and its client routes add
about 200 over the first draft). Server section 17: roughly 900 to 1,200 lines with tests. Shortcuts (section 15):
roughly 700 to 900 lines with tests. Estimates are judgement, not measured.

**Why A.** It is the only option that is legible at a glance on both devices without a tap (B is not legible, C
and D hide behind a sidebar section or a sheet on iPhone), it puts each job where the paste came from (cause and
effect), it reuses the one progress story the owner already approved (2c) instead of inventing a second visual
language, it never covers the focused planet, and it is the cheapest over the shared core. **What would change
it:** batches of ten or more links as the normal case (C's list scales better; A collapses past five cards into
"+n more"), wanting the orbit itself to be the status display over legibility (B), or pasting long notes and
editing links before sending (D). A Mac-only variant that docks A's cards into the sidebar is a cheap swap later:
both use `JobCard`. The owner chose A on 2026-10-06.

## 11. Boards and how they were checked

`/private/tmp/claude-501/-Users-harmony-cobalt/6c326b60-4656-4804-967b-534a3f0bf81a/scratchpad/parallel/project/`
(no `canvas.json`; Fable merges): `Parallel-A-Tray-{Mac,iPhone}`, `Parallel-B-Stars-…`, `Parallel-C-Queue-…`,
`Parallel-D-Bar-…` (`.dc.html`) + `img/` (9 real stills copied from the library2 boards, 8 to 26 KB). The device
frames are exactly 1280×800 (Mac window) and 390×844 (iPhone); the review controls sit outside them (Mac boards
1280×960, iPhone boards 712×844). All eight run the same job model (generator `src/engine.js`, identical in each),
so options differ only in surface. Each board: clipboard control (one link, three links, no link), paste (⌘V on
the clicked Mac window too), drop, "Dd55fEyN1Yy fails", "server busy with a share", dark, reset.

`node validate.mjs` (fake clock): 8 boards, 791 checks, 0 failures: the skeleton (support.js head line, x-dc,
helmet, `Component extends DCLogic`), every tag closed, no emoji, no innerHTML, images present and ≤ 60 KB, every
binding resolving in 12 to 14 states per board, computed contrast ≥ 4.5:1 for text, captions and red on the
background and both glass tokens in light and dark, every `var()` defined in both themes, and the behaviours:
single paste takes the focus; three links → review of 3 with the saved one unticked → 2 jobs, focus unchanged;
"2nd in line"; convert while a save holds the server → "waiting for the server · 2nd in line · your webp goes
next", the save not pre-empted, the queued save moved to 3rd; cancel in line; background landing without
stealing the focus; close mid-render → the render listed in that option's surface; failure words and try
again/dismiss; foreign busy wording; stop on the server keeps the slot busy; no link; dark; ⌘V on the window;
reset; the clock cleared on unmount. Plus option-specific checks (tray folding and the iPhone pill, star selection
and the aside row, the C sheet and "finished", D's ⌘K, typed parsing, esc and pill). Rendered with the test-only
runtime (`test/support.js` from the library2 lane) and looked at in light and dark (A Mac and iPhone, B Mac, C Mac
and iPhone sheet, D Mac dark and iPhone).

Not verified: the real canvas runtime (only the test stand-in rendered them); B iPhone and A Mac dark were not
looked at; orbit motion is omitted on purpose (Orbit2-C has it); timings are slowed or shortened for reading
(real: fetch 1.5 s, save 0.9 s, render 23.5 s); Dd55fEyN1Yy's failure is simulated with the privatePost
scenario's code; the pasted links are PreviewData's, treated as not yet saved. **The boards predate the owner's
2026-10-06 decisions**: they model the device line (the server-held line looks the same in the tray, plus "after a
save from your mac"), and have no Shortcuts surface (section 15 has none to draw: Shortcuts is Apple's UI).

## 12. Lanes (Fable gates each wave)

**Preconditions.** The offline-storage lane is editing `apple/CobaltKit/Sources/CobaltKit/Store/**` (`OfflineStore.swift`,
`Settings.swift`, new `OfflineFolder*.swift`), `Pipeline/PipelineFlows.swift`, tests and `project.yml` (dirty on 2026-10-06).
**No app lane below starts until that lane has landed** (L1 owns `PipelineFlows.swift`; every lane reads `Settings`).
**S1 (server) touches only `deploy/cloudflare/**` and can start now** (nothing there is dirty). App lanes code against
section 17 through `PreviewClient`; they do not wait for S1's deploy, but the wave 3 evidence does.

| wave | lane | tier | owns (only these files) | done when |
|---|---|---|---|---|
| 0 (now) | S1 server line | sonnet-lane | `deploy/cloudflare/api/src/line.ts` (new), `src/studio.ts`, `src/webp.ts`, `src/notify.ts`, `src/gate.ts`, `src/worker.ts`, `src/app-routes.ts`; `api/test/line.test.ts`, `api/test/line-notify.test.ts` (new), `api/test/{gate,studio-gate,library,instant-share,studio,webp,notify}.test.ts` (only where section 17 changes an expectation); `deploy/cloudflare/README.md`; the status line of APP-API-CONTRACT 17 | APP-API-CONTRACT 17.11's tests; `npm test && npm run typecheck` green in `deploy/cloudflare/api` and `deploy/cloudflare/web`; every pre-17 test unchanged except where 17.1 says the behaviour changes (list them in the report) |
| 0 gate | S1 review | opus-lane | read-only | adversarial review of S1 against 17 (the two guards, the pump, ordering, exactly-once summary) before the owner deploys |
| 1 | L1 core | sonnet-lane | `CobaltKit/Jobs/` (new: `JobQueue.swift`, `JobLine.swift`, `ServerLine.swift`, `LocalLine.swift`, `JobLedger.swift`, `JobInput.swift`), `Pipeline/Pipeline.swift`, `PipelineFlows.swift`, `PipelineContext.swift`, `PipelineDetach.swift`, `PipelineTypes.swift`, `BackgroundRuns.swift`, `NotifyBridge.swift`, `LinkInfo.swift`, `Models/AppModel.swift`, `Models/Wire.swift`, `Models/Server.swift`, `API/Client.swift`, `API/HTTPCobaltClient.swift`, `API/ErrorMap.swift`, `Share/AppModel+RunLinks.swift`, `Preview/PreviewClient.swift` (a server-line scenario: queued, positions, `line`, cancel, line notify; a device-line busy-elsewhere scenario; a multi-link scenario), tests | 3.2 compiles on iOS and macOS; section 13's wave-1 tests green; `AppModel.pipeline` still drives today's single-run flow unchanged (existing tests untouched and green) |
| 2 | L2 live | sonnet-lane | `Live/LiveActivityManager.swift`, `Live/LiveContentState.swift`, `Live/LiveStateBuilder.swift`, `Background/ContinuedProcessing.swift`, `Telemetry/PipelineTelemetry.swift`, `CobaltWidgets/**` | summary rules of 6 with the fake ActivityKit adapter; widget previews for 1, 3 running, ended; continued processing only for local work in server mode |
| 2 | L3 paste + shell | sonnet-lane | `Cobalt/App/AppShell.swift`, `App/CobaltApp.swift` (also the one line `IntentDependencies.register(model)` in `init`, after `LaunchConfig.makeModel()`), `App/AppLinks.swift` (`cobalt-apple://jobs`), `App/ShellActions.swift`, `Shared/PasteReview.swift` (new), `Design/Copy+Jobs.swift` (new), `Design/Symbols.swift`, `App/DockBadge.swift` (new, macOS) | section 4 on Mac and iPhone; ⌘V in the title sheet's field still pastes text (the risk in 4.1); the jobs link opens the tray |
| 2 | L4 home (option A) | sonnet-lane | `Screens/Home/JobTray.swift`, `Screens/Home/JobCard.swift` (new), `Screens/Home/HomeScreen.swift`, `Screens/Home/FocusView.swift`, `Design/ProgressStory.swift`, `Design/ProgressViews.swift` | section 5 and the tray on Mac and iPhone, light and dark, Reduce Motion; "after a share from your iphone" from a preview `/studio/line` |
| 2 | L5 shortcuts | sonnet-lane | `Cobalt/Intents/**` (new: `SaveLinksIntent.swift`, `UploadFilesIntent.swift`, `MakeWebpIntent.swift`, `LatestSavesIntent.swift`, `CobaltSaveEntity.swift`, `CobaltShortcuts.swift`, `IntentDependencies.swift`, `IntentErrors.swift`), `CobaltKit/Sources/CobaltKit/Shortcuts/**` (new: `ShortcutActions.swift`, `ShortcutTypes.swift`), `CobaltKit/Tests/CobaltKitTests/ShortcutActionsTests.swift` (new), `Design/Copy+Shortcuts.swift` (new) | section 15 on iOS 27 and macOS 27 builds; the actions appear in the simulator's Shortcuts app; section 13's shortcut tests green |
| 3 | review | opus-lane | read-only | adversarial review of waves 1-2 against this file and APP-API-CONTRACT 17 |
| 3 | evidence | sonnet-quick | none (scratchpad only) | simulator + Mac screenshots of the board scenarios against the deployed server (after the owner deploys S1), the Shortcuts actions run from the Shortcuts app (background and "open cobalt"), paths + checklist |

Pinned between lanes: the 3.2 API (including `JobOptions`, `JobAcceptance`, `JobVia.shortcut`), section 17's wire,
`LinePosition` wording (copy 9), the additive `LiveContentState` fields (`jobs: Int?`, `waiting: Int?`),
`JobQueue.alongside` ordering, the `cobalt-apple://jobs` link, and `IntentDependencies.register(_ model: AppModel)`
(L5 writes it, L3 calls it).

Owner step between waves (not run by any lane): deploy S1 (APP-API-CONTRACT 17.12) after its review gate.

## 13. Tests

Server (wave 0): APP-API-CONTRACT 17.11.

App (waves 1 and 2):

- `LocalLineTests` (the first draft's `HelperLineTests`): FIFO; focused priority goes ahead of queued saves but never
  pre-empts the holder; `noteOnServer` blocks the next acquire; cancellation while waiting removes the job and wakes
  nobody wrongly; release by a cancelled holder; positions (holder = 1st, first waiting = 2nd); foreign notes.
- `ServerLineTests` (preview server): `enter` returns at once; a queued `201` gives `.inLine(queueAhead + 1)`; the
  position moves with each poll; `nil` when it starts; one `GET /studio/line` per 3 s for any number of queued jobs
  and none while nothing is queued or the app is inactive; labels from `origin`/`key_name`/`mine`; a failed
  `/studio/line` read keeps positions and drops labels.
- `JobQueueTests` (preview server, fake clock), run in **both line modes** where it applies: single paste on a quiet
  screen focuses and checks the link first; a batch never focuses and (server mode) sends `queue: true` without
  `POST /`; a background landing keeps `focusedID`; unfocus mid-render keeps the render and its `SharedJob`; cancel
  per 3.4 (device line: nothing sent; server: `DELETE …/line` → removed, `started` → "stopped following", offline →
  kept); retry goes to the back; `alongside` ordering; three links with one failing (privatePost code) leave the other
  two saved; device mode: a foreign `429` keeps a job waiting past 60 s and fails `serverBusy` after 10 min,
  `error.webp.busy` waits instead of failing; server mode: no `429` handling is reached, `line_full` fails `.lineFull`;
  a render from focus sends `priority: "focused"`; server change cancels all; `via: .shortcut` never focuses;
  `accepted(_:timeout:)` returns `onServer` with the post key (session id for a link, item id for an upload), `failed`,
  or `stillLocal` at the timeout.
- `LinkInfoAllLinksTests`: the API's rule per link, repeats folded, cap 20, `twitter` → `x`, trailing
  punctuation, links glued to text by a newline.
- `JobLedgerTests`: write on add, removal on session/end, relaunch order, 24 h expiry, missing inbox file, a re-send
  skipped when `/studio/line` already has the link.
- `RelaunchTests`: all in-flight `SharedJob`s (queued ones included) resume as jobs; positions from one
  `/studio/line`; none focused unless the screen is quiet and 5.1(c).
- `LineNotifyTests` (NotifyBridge): leaving with server jobs sends one `PUT /studio/line/notify` and no per-session
  PUT; foreground sends one `DELETE`; device mode keeps the first draft's per-session opt-ins; share-sheet opt-ins
  untouched.
- `LiveSummaryTests` (fake adapter): 1 job = per-run as today; second job keeps the first activity, deletes its
  server run, writes summary content ≤ 1/s; lead changes; `waiting` counts server-queued jobs; ends with the right
  final content; never two `request`s.
- `ContinuedQueueTests`: one task per busy period, progress monotonic; server mode submits none when every job is on
  the server; the upload leaving notification when refused.
- `ShortcutActionsTests` (L5, preview server): section 15.7.
- UI (L3/L4/L5): previews for the tray with 0/1/3/6 jobs, docked pill, review with duplicates, a queued job "after a
  share from your iphone"; `swift test`, iOS and macOS builds with no new warnings.

## 14. Owner questions (defaults in bold)

1. ~~Should each pasted link also become a webp?~~ **Answered 2026-10-06: stop at saved.**
2. ~~Should the server hold the line?~~ **Answered 2026-10-06: yes, in v1** (section 7, APP-API-CONTRACT 17).
3. **Reversed 2026-10-06: save everything** (owner decisions item 5; first video until `features.gallery`). Was: a post with several videos or photos, pasted **in a batch** or sent from a **Shortcut**, goes straight to the
   server, which saves its **first video** without asking (a single pasted link still opens the picker so you choose).
   OK? **Default: yes.** (Asking would mean the batch waits for you before it can be handed to the server.)
4. Do you want a Shortcuts action that hands back the **video file** itself (for a private save), not just its link?
   **Default: not in v1**: a public save's link already works in Shortcuts ("Get Contents of URL" downloads it), and a
   private original can be up to 200 MB to pull through a background action.

## 15. Shortcuts (owner request 2026-10-06)

### 15.1 Facts (code and platform, read 2026-10-06)

| fact | where |
|---|---|
| no App Intents exist in the app; the Mac has two signed Shortcuts that call the API with an embedded key (`cobalt studio`, `cobalt → webp`) | grep of `apple/`; `deploy/cloudflare/shortcuts/README.md` |
| the API key is a keychain item `kSecAttrAccessibleAfterFirstUnlock`, read by the app process | `CobaltKit/Store/Keychain.swift:146`, `Store/Settings.swift:346` |
| the model is built in `CobaltApp.init`, before any scene, so a background launch to run an intent has it | `Cobalt/App/CobaltApp.swift:80-93` |
| deployment target iOS 26.0 / macOS 26.0; the owner runs iOS 27.2; Xcode 27.0 (27A266a) | `apple/project.yml:11-13`; CONTRACT-SHARE-QUICK F4; `xcodebuild -version` |
| an intent from Siri, Shortcuts or any system surface "only has 30 seconds to finish" | WWDC26 session 345, "Discover new capabilities in the App Intents framework" |
| `LongRunningIntent` (refines `ProgressReportingIntent`) runs past it through `performBackgroundTask(options:operation:)` (+ `onCancel:` when also `CancellableIntent`); progress is required; the system shows the progress as a Live Activity with a stop button | iOS 27 SDK `AppIntents.swiftinterface:3603-3611` (`@available(anyAppleOS 27.0, *)`); WWDC26 345 |
| `supportedModes: IntentModes` (`.background`, `.foreground(.immediate | .dynamic | .deferred)`) replaces `openAppWhenRun` (deprecated 26.0); `continueInForeground(_ dialog:alwaysConfirm:)` throws when the system or the person declines; `systemContext.currentMode.canContinueInForeground` | SDK `:3100-3107`, `:3235`, `:3245-3292` (`anyAppleOS 26.0`); WWDC25 session 275 |
| `IntentFile`: `data` (reads the file into memory), `fileURL: URL?` (optional), `filename`, `type`, `removedOnCompletion`; `@Parameter(supportedContentTypes:)` | SDK `:9603-9640`, `:2576` |
| `AppDependencyManager.shared.add(dependency:)` (the dependency must be `Sendable`; `AppModel` is `@MainActor`) | SDK `:341-349` |
| App Intents need no entitlement and no app group (they run in the app's own process) | the API's design; no source contradicts it |

### 15.2 Decisions

1. **(lane) In the main app target, no extension.** `Cobalt/Intents/` holds thin `AppIntent` structs; the logic is
   `CobaltKit/Shortcuts/ShortcutActions.swift` (testable with `swift test`). The app process has the key, the store,
   `JobQueue` and the background URLSession; an App Intents extension would need the app group the sideloaded build
   does not have (the same reason the share sheet went instant, CONTRACT-SHARE-QUICK F7).
2. **(lane) One entry point.** Every action that creates work calls `JobQueue.add(_:via: .shortcut, options:)` and then
   `accepted(_:timeout:)`; the jobs are ordinary jobs (tray, Live summary, relaunch, cancel). Read-only actions call
   the client and the library model directly. `IntentDependencies.register(model)` adds the `AppModel` with
   `AppDependencyManager.shared.add`; intents read it through `@Dependency`.
3. **(lane) Background by default; the server's line is what makes it work.** With `features.line`, handing a link to
   the server takes about a second, so "Save link" finishes well inside 30 s and the save finishes on the server.
   Work that has to stay alive (an upload's bytes, waiting for a result) uses `LongRunningIntent` (iOS / macOS 27), so
   the system keeps the process and shows its own progress Live Activity with a stop button. Without `features.line`
   (an old server) an action that creates work asks to continue in the foreground (`continueInForeground`, the app's
   device line then runs it); declined → the error "this server can't keep a line. open cobalt to save."
4. **(lane) Authentication is the app's own**: the server URL and key in Settings / the keychain. Not signed in, an
   invalid key, an unreachable server: the action throws a plain error (15.6), nothing is queued. `authenticationPolicy`:
   `.alwaysAllowed` for the actions that create work (they reveal nothing), `.requiresAuthentication` for "Get latest
   saves" (titles and links of private saves on a locked phone).
5. **(lane) Being told when it's done**: when an action leaves work on the server and the app is not active, it sends
   `PUT /studio/line/notify` (17.8) itself, so a Shortcut run with cobalt closed ends in one Hark message. When the
   action waits for the result itself ("wait until saved", "Make webp") nothing is registered.
6. **(lane) Shortcut jobs never focus** (5.8) and render without `priority` (they are not on the owner's screen).
7. **(lane) iOS 26 builds**: the actions that need `LongRunningIntent` ("Upload files", "Make webp") are
   `@available(iOS 27, macOS 27, *)`; "Save links" and "Get latest saves" exist on 26 (their wait option is hidden
   there: `waitUntilSaved` is ignored below 27 and the action returns at once).

### 15.3 How an action runs (Save links, the common path)

1. Read the server and key (`AppModel`); none → `notSignedIn`. Refresh capabilities if older than 10 min (one
   `GET /capabilities`, 5 s cap); unreachable → `serverUnreachable`; `key: "invalid"` → `keyRefused`.
2. No `features.line` → step 3 of 15.2's fallback.
3. Parse: each input string through `LinkInfo.allLinks(in:)` (folded across inputs, at most 20); none and the input
   was empty → the clipboard (`UIPasteboard`/`NSPasteboard`); still none → `noLink`.
4. `queue.add(links.map(JobInput.link), via: .shortcut, options: JobOptions(title: links.count == 1 ? title : nil,
   makePublic: visibility.flag))` → `queue.accepted(ids, timeout: 20)`.
5. All `failed` → throw the first failure's words. Some failed → return the accepted ones with a dialog "saved 2 of 3
   links; 1 couldn't be sent: <reason>." `stillLocal` (not answered within 20 s) → returned as `state: queued` with
   no public link; the job keeps going in the app process as long as iOS lets it, and the ledger re-sends it on the
   next launch (3.5).
6. `waitUntilSaved` (27+): inside `performBackgroundTask`, poll each session (`?wait=1`, the existing pacer) until
   `ready` / `error`, `progress` = finished / total (queued ones count 0); then fill `publicLink` (needs the save to be
   public and its `public_url`). Without it: return at once and, if the app is not active, step 5 of 15.2.
7. `openCobalt`: after step 4, `continueInForeground(alwaysConfirm: false)` and open the tray
   (`cobalt-apple://jobs`); declined → carry on in the background (no error).

### 15.4 The actions (pinned)

| action (type) | parameters (Shortcuts labels) | returns | modes |
|---|---|---|---|
| **Save links** (`SaveLinksIntent`, iOS/macOS 26+) | `Links` `[String]` (a link, a URL, or text with links; empty = the clipboard), `Title` `String?` (used with exactly one link), `Visibility` `CobaltVisibility` (`app default` / `public` / `private`; default `app default` = Settings "new saves public"), `Wait until saved` `Bool` (default off; 27+), `Open cobalt` `Bool` (default off) | `[CobaltSave]` | `[.background, .foreground(.dynamic)]`; `LongRunningIntent` on 27+ (used only when waiting) |
| **Upload files** (`UploadFilesIntent`, 27+) | `Files` `[IntentFile]`, `supportedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie, .gif, .png, .jpeg, .heic, .webP]` (the server's upload types), `Title` (one file), `Visibility`, `Wait until saved` (default off) | `[CobaltSave]` | `[.background, .foreground(.dynamic)]`; always `LongRunningIntent` + `CancellableIntent` (the bytes go up inside `performBackgroundTask`, progress = bytes sent) |
| **Make webp** (`MakeWebpIntent`, 27+) | `Save` `CobaltSave?` (empty = the latest save with a video), `Start` `Double` seconds (default 0), `Length` `Double` (default the server's `max_webp_seconds`, clamped to the clip and to `min/max_webp_seconds`), `Size` `CobaltWebpSize` (320 / 480; default Settings) | `URL` (the webp's public link) | `[.background]`; `LongRunningIntent` + `CancellableIntent` (waits for the render: queued place, then frames, as progress) |
| **Get latest saves** (`LatestSavesIntent`, 26+) | `Count` `Int` 1…20 (default 1), `Kind` `CobaltSaveKind` (`anything` / `videos` / `webps`) | `[CobaltSave]` | `[.background]`; `.requiresAuthentication` |

Details:
- **Files**: `fileURL` when the system gives one (copied into the app's inbox, the same place a picked file goes, under
  coordinated access), else `data` written there (it is in memory then: refused above `limits.max_upload_bytes`, 100 MB,
  which the server refuses anyway). Over the limit → `tooLarge` before a byte is sent. Then `JobInput.file`; the upload
  sends `?queue=1` and `title`. The Photos asset id is unknown from Shortcuts (`photosAssetID: nil`).
- **Make webp** needs a session: the save's own if unexpired (`GET /library` v2 `session`), else `POST
  /library/items/<original id>/studio?queue=1` (5d). Render `{queue: true}` without `priority`, `notify` absent. The
  stop button (`onCancel`): still queued → `DELETE …/render/<job>`; started → the render finishes on the server and the
  action sends `PUT /studio/line/notify` so the owner still hears of it.
- **`CobaltSave`** (`AppEntity`, `CobaltSaveEntity.swift`): `id` = the post key (the session id for a saved link, the
  item id for an upload: both known from the create's answer, and equal to `GET /library`'s post `id`). Properties:
  `title` (custom title, else the file title), `link` (`URL?`, the page it came from), `service`, `state`
  (`CobaltSaveState`: `queued` / `saving` / `saved` / `failed`), `publicLink` (`URL?`, the original's public URL when
  public), `webpLinks` (`[URL]`, newest first), `duration` (`Double?`), `created` (`Date`). Display: title, subtitle
  "<service> · <state>". `CobaltSaveQuery: EntityQuery`: `entities(for:)` looks in the loaded library model, then
  `GET /studio/<id>` (a link save), then the first library page; `suggestedEntities()` is the first library page (20).
- **Not in v1 (lane)**: "Get file" (owner question 4); a "Cancel" action; a share-sheet entry of its own (the
  Shortcuts share sheet runs "Save links" with the shared input; the existing cobalt share extension is unchanged).

### 15.5 Siri, Spotlight, the Action button (`CobaltShortcuts: AppShortcutsProvider`)

| action | phrases (each contains the app name, as App Shortcuts require) | short title · symbol |
|---|---|---|
| Save links | "Save my copied link with \(.applicationName)", "Save a link in \(.applicationName)" | save link · `link` |
| Make webp | "Make a webp in \(.applicationName)", "Make a webp of my latest \(.applicationName) save" | make webp · `photo.stack` |
| Get latest saves | "Get my latest \(.applicationName) save", "What did I last save in \(.applicationName)" | latest save · `clock.arrow.circlepath` |

"Upload files" has no phrase (it needs a file); it is an action in Shortcuts and runs from any shortcut that passes
files. From Siri, "Save links" has no input and reads the clipboard (15.3 step 3). Make webp is 27+: if the
`AppShortcutsBuilder` will not take an `if #available` branch on a 26 deployment target, its phrases are left out
(the action stays in Shortcuts) **(unverified)**.

### 15.6 What the owner sees (copy, lowercase)

| case | what happens |
|---|---|
| links handed over | returns the saves; no dialog when all went; "saved 2 of 3 links; 1 couldn't be sent: <reason>." when some did not |
| cobalt closed, work left on the server | one Hark message when all of it is done (17.8): "done · 3 saved" |
| not signed in | error "open cobalt and add your server and key first." |
| key refused | error "cobalt's key was refused. check it in cobalt's settings." |
| server unreachable | error "cobalt's server didn't answer." (nothing queued) |
| old server (no line) and foreground declined | error "this server can't keep a line. open cobalt to save." |
| no link | error "no link found in that text." (existing copy) |
| line full | error "cobalt's line is full (50). try again when a few have finished." |
| file too large | error "that file is over the 100 MB limit." (existing copy) |
| stop button on a waiting action | queued work is cancelled ("cancelled. nothing was saved."); started work finishes on the server and is announced |
| Make webp failed | error with the render failure words of CONTRACT 5.1 |

### 15.7 Tests (`ShortcutActionsTests`, preview server, fake clock)

Link parsing (one URL, text with three links, a list of strings, repeats across inputs, the 20 cap, empty → clipboard,
no link); options (title only with one link; the three visibilities → `public` flag; `app default` follows Settings);
not signed in / key refused / unreachable / old server → the right error and nothing added; partial acceptance and
its dialog; `stillLocal` at the timeout; every job added with `via: .shortcut` and never focused; line notify sent only
when the app is not active and the action does not wait; wait-until-saved returns public links and reports monotonic
progress; upload: `fileURL` vs `data`, the size refusal before any request, `queue=1` and `title` on the request; Make
webp: default save = latest with a video, length clamp, size default, an expired session reopened with `queue=1`, the
cancel paths (queued → DELETE, started → line notify); entity mapping from a v2 library post and from a session;
`entities(for:)` lookup order.

### 15.8 Mac

The same four actions in the Mac app (App Intents exist on macOS 13+, `LongRunningIntent` and `supportedModes` on
macOS 26/27 per the SDK's `anyAppleOS` availability). The system launches cobalt to run them; whether it shows the
window for a background action is **unverified**. The signed Shortcuts in `deploy/cloudflare/shortcuts/` are not
changed and keep working without the app; with the app installed, "Save links" covers what `cobalt studio` does
(without opening the web studio page), so the owner may remove the old one.

### 15.9 Not verified (say so to the owner)

- **Whether a Feather-resigned build's actions appear in Shortcuts, Siri and Spotlight.** App Intents need no
  entitlement and the metadata (`Metadata.appintents`) is built into the `.app`, which re-signing does not change, so
  they should; no source was found either way (search 2026-10-06), and nothing was run on the owner's device. If
  Feather changes the bundle id on a reinstall, shortcuts the owner built against the old install's actions will need
  the action picked again.
- The 30 s limit's exact behaviour on macOS (Apple's statement is "any system surface"; `LongRunningIntent` lifts it
  "on platforms that impose it", per third-party summaries of the docs, not re-read here).
- Reading the clipboard from an intent running in the background on iOS (it may prompt, or be refused); the Siri
  phrase depends on it.
- Whether Shortcuts hands a Photos video to `IntentFile` with a `fileURL` (else it arrives as `data`, in memory).
- How `[String]` parameters coerce a single URL or a list from the share sheet in Shortcuts on iOS 27 (the existing
  Mac Shortcuts found "Get URLs from Input" unreliable on macOS 27; parsing text in the app avoids that action).
- `AppShortcutsBuilder` with an `if #available` branch (15.5).
- The `LongRunningIntent` Live Activity on a build without push entitlements (it is the system's, local; expected to
  work, not run).
