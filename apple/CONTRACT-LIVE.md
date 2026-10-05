# cobalt for apple: addendum for Live Activities and the offline limit (pinned 2026-10-02)

An addendum to `apple/CONTRACT.md` (the app contract) and `deploy/cloudflare/APP-API-CONTRACT.md`
(the server contract, whose new **section 8** is the server half of this file). Same rules as
the app contract: lanes do not deviate; if something here is impossible, stop and report;
additive public API goes through Fable. Where this file and `CONTRACT.md` disagree, this file
wins, and each such place is named below.

Two owner features (settled, not reopened):

- **A. A Live Activity for every pipeline run**, started in the app or from the share sheet, on
  the Dynamic Island and the Lock Screen, updating in real time through the steps:
  fetch|upload, save (seconds, bytes), read, webp (decoded frames / total, packing), then done
  with the link or failed. The owner has a paid developer account and creates an APNs key at
  deploy time, so the server sends ActivityKit pushes, including push-to-start for share-sheet
  runs (an extension cannot call `Activity.request`).
- **B. Offline storage limit**: "keep videos on this iphone" stays on by default, capped at
  **5 GB** by default (owner-adjustable). When a new file arrives at the cap, the oldest offline
  data goes first. Settings shows usage, the limit, and a clear button.

Sequencing (Fable, 2026-10-02): the HIG pass and the confirmed review fixes are being built now
by their own UI and CORE lanes. **Nothing in this file re-assigns those fixes.** The Live and
storage lanes below start only after that wave has landed and passed its gates, because they
touch the same files (`PipelineFlows.swift`, `Settings.swift`, `OfflineStore.swift`,
`ShareViewController.swift`, `SettingsScreen.swift`).

## 0. Decisions in this addendum

Marked **(owner)** when the owner settled it, **(lane)** when made here and open to review.

1. **(lane) APNs is sent from the Durable Object with plain `fetch()`**, not from the container.
   Section 3.1 has the evidence and the fallback (a dumb HTTP/2 relay in the helper, built in the
   same wave, switched on by a text binding).
2. **(lane) Tokens and runs live in Durable Object storage. No D1 migration.** The DO is the
   only sender and already owns save and render state; the web Worker never needs them.
3. **(lane) One writer per step.** The server pushes the steps the server performs (fetch after
   the session exists, save, render, done, failed); the device writes the steps it performs
   (upload, read, ready). An app run writes its device steps locally with `Activity.update`; a
   share-sheet run relays them through the server. Nothing is ever written by both, so pushes
   and local updates can never flap.
4. **(lane) Content-state times are unix seconds as `Double`**, not `Date`. ActivityKit decodes
   the pushed `content-state` with a default `JSONDecoder`, whose `Date` is seconds since 2001;
   a plain number avoids that trap on both sides.
5. **(lane) Done dismisses after 15 minutes, failed after 5.** Terminal pushes carry a short
   alert (lights the Lock Screen and expands the island once), no sound.
6. **(lane) Push environment is detected on the device** (the provisioning profile's
   `aps-environment`), and the server retries once on the other APNs host when Apple answers
   `BadDeviceToken`, then remembers the right one.
7. **(lane) Storage limit values are decimal** (1, 2, 5, 10, 20 GB, no limit), like `Format`
   and the iOS storage screen. Eviction is **oldest added first** (not least recently viewed):
   the orbit shows the newest, the owner said "oldest", and LRU would need a write per view
   from two processes.
8. **(lane) Eviction drops the video file first and keeps its poster and record**, so the orbit
   and the library still show the item; only if posters alone exceed the cap do the oldest
   records go entirely. "clear" removes everything.
9. **(lane) The newest 12 entries are never evicted** (the orbit shows `latest(7)`), and
   deleting a file another process has open is safe on iOS (the open reader keeps the inode), so
   no cross-process pin protocol is needed.
10. **(owner, 2026-10-02) HIG pass**: section 1 records the navigation reversal.

## 1. HIG pass (recorded reversal; the detail lives in the in-flight UI lane's brief)

The owner, on the running Mac build: buttons inconsistent, timeline too short, sidebar should be
the native one, follow Apple's guidelines with cobalt flavour. **This reverses** the custom
80 pt sidebar and labelled sidebar of `CONTRACT.md` sections 1.8, 7 and 8 (`--sidebar-width`,
`#131313`, the filled `#e1e1e1` tab pill) and the `Fold`, `IPad` and `Mac` boards where they
conflict:

- iPhone and iPad: `TabView` with `.tabViewStyle(.sidebarAdaptable)` (tab bar when compact,
  native user-collapsible sidebar when regular).
- Mac: `NavigationSplitView` with a `List(selection:)` sidebar and a `Settings` scene (⌘,);
  settings is not a sidebar row on the Mac.
- Kept: IBM Plex Mono, lowercase copy, monochrome tint, the orbit and the two white circles, the
  4-step rail, the filmstrip and bracket. The width tiers of `CONTRACT.md` section 7 still decide
  how the work card regroups inside the content column; they no longer decide navigation.

Nothing below depends on the HIG details beyond this: Live and storage UI go into the native
`Form` settings and use whatever button system that wave lands.

---

## 2. Live Activities: the model

### 2.1 Who writes which step

`run` is one lowercase UUID per pipeline run, shared by everything: the Live Activity, the
`SharedJob` (the share sheet's `ShareCore.jobID` becomes the pipeline's run id), and the server
record. Stages are those of `LiveContentState.Stage` (2.2).

| stage | performed by | app run, push mode | app run, local mode | share-sheet run |
|---|---|---|---|---|
| `fetching` before a session exists | device (`POST /`, `POST /studio`) | app, local (also the `Activity.request` content) | app, local | the registration's state (push-to-start) |
| `fetching` with a session (`waking`) | server | **server push** | app, local | **server push** |
| `uploading` | device | app, local | app, local | extension relays (`POST /live/runs/<run>/state`) |
| `saving` | server | **server push** | app, local | **server push** |
| `reading` | device (frames are read on the device, `CONTRACT.md` 1.4) | app, local | app, local | extension relays |
| `ready` (waiting on the trim) | device | app, local | app, local | extension relays; after "trim in cobalt" the app takes the run over (local) |
| `rendering` (decode, pack) | server | **server push** | app, local | **server push** |
| `done`, `failed` from save or render | server | **server push `end`** + app `end` with identical content | app, local `end` | **server push `end`** |
| `failed` on the device (no link, too large, upload failed) | device | app, local `end` | app, local `end` | extension relays `failed` (server pushes `end`) |

**Push mode** = `capabilities.livePush` is true, `LiveEnvironment.current` is not nil (a signed
build with `aps-environment`), the activity has an update token, and the last
`PUT /live/runs/<run>` reply said `pushing: true`. Anything else is **local mode**: the app
writes every stage itself while it runs, and the activity goes stale when the app is suspended
(2.6). A share-sheet run in local mode gets **no** activity (an extension cannot start one).

The app's `end` on a server-pushed terminal state is safe: both sides build the same content
from the same server answer (the parity fixture in 2.4 proves it), and a terminal state cannot
be overwritten by an older update.

### 2.2 The shared types (CobaltKit, `Sources/CobaltKit/Live/`, pinned)

`LiveContentState` and `LiveRunAttributes` compile on every platform (the macOS `swift test` run
covers them). `CobaltActivityAttributes` is iOS only. The JSON keys are the Swift property names
(camelCase) because ActivityKit decodes the pushed `content-state` and `attributes` by property
name: this is the one exception to the API's snake_case rule, and the client must encode these
two objects with a plain `JSONEncoder` (no key strategy). Absent optionals are **omitted**, never
`null`. `waking` and `packing` are always present.

```swift
public struct LiveContentState: Codable, Hashable, Sendable {
    public enum Stage: String, Codable, Sendable, CaseIterable {
        case fetching, uploading, saving, reading, ready, rendering, done, failed
    }
    public var stage: Stage
    public var rail: Int                 // highlighted cell 0...3 (fetch|upload, save, read, webp); done: 3
    public var since: Double             // unix seconds this stage began (drives the live timer text)
    public var waking: Bool              // fetching: the server is starting
    public var packing: Bool             // rendering: img2webp, no count exists
    public var bytes: Int64?             // uploading, saving: so far
    public var total: Int64?             // uploading, saving: total when known
    public var framesDone: Int?          // reading: developed (of 9); rendering: decoded frames
    public var framesTotal: Int?
    public var title: String?            // the clip's name once known
    public var duration: Double?         // the clip's length once known
    public var resultURL: String?        // done
    public var resultBytes: Int64?
    public var resultWidth: Int?
    public var resultHeight: Int?
    public var resultSeconds: Double?
    public var failure: String?          // failed: a PipelineFailure case name, below
    public var code: String?             // failed: the server's error code, when there is one
    public var isTerminal: Bool { get }  // done || failed
    public init(stage: Stage, rail: Int, since: Double, waking: Bool = false, packing: Bool = false)
    /// The fixture states of 2.4 by name, for the widget's previews.
    public static let samples: [String: LiveContentState]
}

public struct LiveRunAttributes: Codable, Hashable, Sendable {
    public var run: String               // lowercase UUID
    public var input: String             // "link" | "file"
    public var service: String           // LinkInfo.service ("instagram", "x"), "file" for files
    public var ref: String               // LinkInfo.ref, or the file name
    public var origin: String            // "app" | "share"
    public init(run: UUID, input: String, service: String, ref: String, origin: String)
}

#if os(iOS) && canImport(ActivityKit)
import ActivityKit
/// Same stored properties as LiveRunAttributes; the push-to-start `attributes-type` is this
/// type's name, exactly "CobaltActivityAttributes".
public struct CobaltActivityAttributes: ActivityAttributes, Hashable, Sendable {
    public typealias ContentState = LiveContentState
    public var run: String
    public var input: String
    public var service: String
    public var ref: String
    public var origin: String
    public init(_ a: LiveRunAttributes)
}
#endif

public enum LiveEnvironment: String, Sendable, Codable {
    case sandbox, production
    /// From the embedded provisioning profile's `Entitlements.aps-environment`
    /// ("development" → sandbox, "production" → production); a device build with no profile
    /// (TestFlight, App Store) → production; the simulator or an unsigned build → nil.
    public static var current: LiveEnvironment? { get }
}

/// For the Settings row.
public enum LiveStatus: Sendable, Equatable {
    case pushed        // the server keeps the island current while the app is closed
    case localOnly     // updates only while cobalt is open (no push from this server or build)
    case off           // turned off in ios settings (ActivityAuthorizationInfo)
    case unavailable   // macOS, or a device without Live Activities
}
```

`failure` values are the `PipelineFailure` case names: `noLink`, `tooLarge`, `fetchFailed`,
`unsupported`, `serverBusy`, `renderBusy`, `renderLost`, `expired`, `keyMissing`, `keyInvalid`,
`unreachable`, `server`, plus any case the review-fix wave added (by its case name). The server
maps codes with a port of `ErrorMap.swift` (`mapFailure`); a code it cannot place is `server`.

Additive public API elsewhere (approved here):

```swift
extension Capabilities { public var livePush: Bool }        // features.live_activity_push; false when absent
extension AppModel { public var liveStatus: LiveStatus { get } }

public struct LiveRunRegistration: Sendable, Equatable {
    public var run: UUID
    public var environment: LiveEnvironment
    public var updateToken: String?      // lowercase hex
    public var session: String?
    public var start: Bool               // true: the server push-starts the activity (share sheet)
    public var attributes: LiveRunAttributes
    public var state: LiveContentState
}
public struct LiveRunReply: Sendable, Equatable { public var pushing: Bool; public var started: Bool }

// CobaltClient gains (HTTPCobaltClient implements; PreviewClient answers pushing: false, started: false):
func registerLiveStartToken(_ token: String, environment: LiveEnvironment) async throws   // PUT /live/start-token
func registerLiveRun(_ r: LiveRunRegistration) async throws -> LiveRunReply                // PUT /live/runs/<run>
func relayLiveState(run: UUID, _ state: LiveContentState) async throws                     // POST /live/runs/<run>/state
func endLiveRun(_ run: UUID) async throws                                                  // DELETE /live/runs/<run>
```

All four are keyed and follow the existing client rules (key only to `baseURL`'s host). Run ids
go into paths lowercased.

### 2.3 Building the state from the pipeline (CORE, pure, tested on macOS)

`LiveContentState.make(from:)` is an internal pure function of `(PipelineState, Pipeline
snapshot, previous LiveContentState?, now)`:

| `PipelineState` | stage | rail | fields |
|---|---|---|---|
| `.fetching(since, waking)` | fetching | 0 | `since`, `waking` |
| `.uploading(p)` | uploading | 0 | `bytes`, `total` |
| `.saving(bytes, total, since)` | saving | 1 | `bytes`, `total` (both omitted in the degraded case) |
| `.reading(d, of)` | reading | 2 | `framesDone`, `framesTotal` |
| `.ready`, `.image`, `.picker` | ready | 2 (`.picker`, `.image`: 0 / 3) | `duration` |
| `.rendering(.decoding(d, t))` | rendering | 3 | `framesDone`, `framesTotal` |
| `.rendering(.packing)` | rendering | 3 | `packing: true` |
| `.rendering(.working)` | rendering | 3 | none |
| `.done(r)` | done | 3 | `resultURL`, `resultBytes`, `resultWidth`, `resultHeight`, `resultSeconds` |
| `.savedLocally(v)` | done | 2 | `resultBytes` = `v.bytes` (plain cobalt; local mode only) |
| `.failed(f)` | failed | rail of the previous state | `failure`, `code` (from `.fetchFailed(code)` / `.server(code)`) |
| `.idle` | none: the activity is ended (`.immediate`) | | |

Merge rule (both sides): when `stage` changes, `bytes`, `total`, `framesDone`, `framesTotal`,
`packing` reset and `since` becomes now (except `fetching`, which keeps the run's start);
`title` and `duration` carry over and update when known. Equal states are never re-sent.

### 2.4 Parity fixture (both sides decode and build exactly these)

CORE writes `apple/CobaltKit/Tests/CobaltKitTests/Fixtures/live-states.json`; API writes a
byte-identical copy at `deploy/cloudflare/api/test/fixtures/live-states.json`. Swift decodes each
entry into `LiveContentState` and compares it with the builder's output for the matching
pipeline state; the TypeScript builder must produce each object (deep-equal, key order free)
from the matching server event. The gate runs `cmp` on the two files.

```json
{
  "fetching_waking": {"stage":"fetching","rail":0,"since":1790000000,"waking":true,"packing":false},
  "uploading": {"stage":"uploading","rail":0,"since":1790000001,"waking":false,"packing":false,"bytes":1200000,"total":18200000,"title":"IMG_0412.mov"},
  "saving_storing": {"stage":"saving","rail":1,"since":1790000003,"waking":false,"packing":false,"bytes":2100000,"total":4331778},
  "reading": {"stage":"reading","rail":2,"since":1790000005,"waking":false,"packing":false,"framesDone":4,"framesTotal":9,"title":"instagram_Dd7P496wolG","duration":14.77},
  "ready": {"stage":"ready","rail":2,"since":1790000007,"waking":false,"packing":false,"title":"instagram_Dd7P496wolG","duration":14.77},
  "decoding": {"stage":"rendering","rail":3,"since":1790000020,"waking":false,"packing":false,"framesDone":42,"framesTotal":150,"title":"instagram_Dd7P496wolG","duration":14.77},
  "packing": {"stage":"rendering","rail":3,"since":1790000020,"waking":false,"packing":true,"framesDone":150,"framesTotal":150,"title":"instagram_Dd7P496wolG","duration":14.77},
  "done": {"stage":"done","rail":3,"since":1790000043,"waking":false,"packing":false,"title":"instagram_Dd7P496wolG","duration":14.77,"resultURL":"https://media.capybaraharmony.com/PrEvIeW001.webp","resultBytes":4500000,"resultWidth":480,"resultHeight":854,"resultSeconds":10.1},
  "failed_render_lost": {"stage":"failed","rail":3,"since":1790000030,"waking":false,"packing":false,"title":"instagram_Dd7P496wolG","duration":14.77,"failure":"renderLost","code":"error.webp.job_lost"},
  "failed_fetch": {"stage":"failed","rail":0,"since":1790000002,"waking":false,"packing":false,"failure":"fetchFailed","code":"error.api.fetch.empty"}
}
```

### 2.5 LiveActivityManager and the driver (CORE, `Sources/CobaltKit/Live/`, iOS only except the builder)

Internal types; UI sees only `AppModel.liveStatus`, the shared types and the widget.

- **Start-token observation first.** `AppModel.live()` starts, before anything else, a task over
  `Activity<CobaltActivityAttributes>.pushToStartTokenUpdates` and also reads the current
  `pushToStartToken` on every foreground, registering any token it has not sent for this
  server and key (`registerLiveStartToken`, hex lowercase). Reason: a known iOS bug loses the
  start token on cold launch when the observer starts late (Apple Developer Forums thread 805324,
  FB21158660, open as of June 2026); starting any local activity regenerates it, and every app
  run starts one.
- **Push-started activities.** A task over `Activity<CobaltActivityAttributes>.activityUpdates`
  picks up activities the server started; for each, a task over `pushTokenUpdates` sends
  `registerLiveRun(start: false, updateToken: …)`. The same reconcile runs on every
  foreground over `Activity.activities`.
- **App runs.** The pipeline's central `setState` calls an internal `LiveSink` on
  `PipelineContext` (nil in previews and tests unless a fake is injected). The driver:
  - on the first state of a run: `Activity.request(attributes:content:pushType:)` with
    `pushType: .token` when `LiveEnvironment.current != nil` and `livePush`, else `nil`;
    `staleDate` now + 120 s; then `registerLiveRun(start: false, …)` with the update token as
    soon as `pushTokenUpdates` yields it, and again when `sessionID` becomes known (the server
    needs the session to map its events);
  - writes local updates per 2.1, at most 1 per second while only counters change, immediately on
    a stage change;
  - on a terminal state: `end(content, dismissalPolicy: .after(now + 15 min | 5 min))`;
  - on `begin` of a new run or `.idle`: ends the previous run's activity `.immediate` unless it is
    terminal (a finished one keeps its dismissal time), and calls `endLiveRun`.
- **Share-sheet runs** (`ShareCore`, iOS): when `livePush` is true and the extension can read the
  key, the first state calls `registerLiveRun(start: true, session: nil, state: fetching|uploading)`;
  the server push-starts the activity. It registers again with `session` when known, relays
  `uploading`/`reading`/`ready`/device `failed` states at most once per second, and calls
  `endLiveRun` when the sheet is dismissed without work continuing (`close()` → `.dismissed`).
  Closing mid-render (`.continuesInBackground`) and "trim in cobalt" leave the run alone; the
  app adopts `job.id` as the run id when it resumes the `SharedJob`.
- **While the app is backgrounded in local mode**, it asks for `beginBackgroundTask` while a run
  has server work in flight, so polling (and local updates) go on for the ~30 s iOS allows; after
  that the activity shows its stale state.
- **Orphans**: on launch and foreground, any `CobaltActivityAttributes` activity whose run is
  neither the home pipeline's run nor a known `SharedJob` with server work in flight is ended
  `.immediate`.

### 2.6 Degrading

| situation | behaviour |
|---|---|
| server without `live_activity_push` (plain cobalt, legacy fork, this fork before deploy or without APNs secrets) | local mode for app runs; no activity for share-sheet runs |
| unsigned build, simulator (`LiveEnvironment.current == nil`) | local mode; `Activity.request(pushType: nil)`; the Dynamic Island still shows in the iPhone 17 Pro simulator, so the widget is verifiable there |
| Live Activities off in iOS Settings | nothing is requested; Settings says "off in ios settings" |
| reply `pushing: false` (server's last APNs attempt failed for a non-token reason) | that run switches to local mode |
| push-started activity whose update token never reaches the app | it shows its start state, turns stale after 120 s ("waiting for cobalt…"), and the next foreground ends it. Plan B in 6 |
| macOS | no ActivityKit; `liveStatus == .unavailable` |

### 2.7 Widget extension `CobaltWidgets` (UI owns the views; CORE adds the target)

New target, iOS only, embedded in `Cobalt` with `platformFilter: iOS`:

| thing | value |
|---|---|
| target / bundle id | `CobaltWidgets`, `com.capybaraharmony.cobalt.widgets`, app-extension, iOS 18.0 |
| sources | `CobaltWidgets/**` + `Cobalt/Design/**` (tokens, font, copy, as the share extension) + `Cobalt/Resources/Fonts` (resources) |
| dependency | package `CobaltKit` |
| Info.plist (`Config/CobaltWidgets-Info.plist`, generated) | `NSExtension.NSExtensionPointIdentifier = com.apple.widgetkit-extension`; `UIAppFonts` = the three Plex Mono TTFs; `CFBundleDisplayName` cobalt |
| settings | `APPLICATION_EXTENSION_API_ONLY = YES`, `SKIP_INSTALL = YES`, `TARGETED_DEVICE_FAMILY = "1,2"`; no entitlements file |
| files | `CobaltWidgets/CobaltWidgetsBundle.swift` (`@main WidgetBundle` with one `CobaltLiveActivity`), `CobaltLiveActivity.swift` (`ActivityConfiguration(for: CobaltActivityAttributes.self)`), `LiveViews.swift` |

App target changes (CORE, `project.yml`): Info.plist `NSSupportsLiveActivities = true`,
`NSSupportsLiveActivitiesFrequentUpdates = true`; `Config/Cobalt-iOS.entitlements` gains
`aps-environment = development` (Xcode signs distribution builds with `production`; unsigned gate
builds ignore it). The share extension needs no new entitlement (it never touches ActivityKit).

Views (UI). Black background (`.activityBackgroundTint(.black)`,
`.activitySystemActionForegroundColor(.white)`), monochrome, Plex Mono via
`Font.custom(_:size:relativeTo:)` with the monospaced fallback, numbers with
`.contentTransition(.numericText())`, every timer `Text(timerInterval:)` /
`Text(Date(timeIntervalSince1970: since), style: .timer)` so seconds tick with no pushes.
Tapping opens `cobalt-apple://job/<run>` for `origin == "share"`, `cobalt-apple://open` otherwise
(`.widgetURL`). No buttons inside the activity (copying from an intent is unverified; the tap
opens the result).

| presentation | content |
|---|---|
| compact leading | the 4-cell rail as four 5 pt dots (past filled, current breathing, future outlined); done: all filled |
| compact trailing | the stage metric: `1.4 s` (fetching, saving degraded, packing, working), `4.3 MB` (saving, uploading), `42/150` (decoding), `4/9` (reading), `10.0 s` (ready: duration), `4.5 MB` (done), a 12 pt `exclamationmark` (failed) |
| minimal | a ring: determinate for bytes/frames, indeterminate otherwise; a check when done |
| expanded | leading: service + ref (`instagram · Dd7P496wolG`); trailing: the timer since the run started; center: the stage line (copy below) and its metric; bottom: the rail with labels ("fetch"/"upload", "save", "read", "webp") and, while decoding, a 3 pt bar `framesDone / framesTotal`; done: `480×854 · 10.1 s · 4.5 MB` and the URL without scheme |
| lock screen | the expanded layout in one 2-line card |
| stale (`context.isStale`, not terminal) | metric replaced by **new** "waiting for cobalt…" |

Copy (UI, `Copy.swift`, lowercase; **new** unless the app already has it): fetching "fetching from
\(service)" / "waking server"; uploading "uploading"; saving "saving privately"; reading "reading
the video"; ready **new** "ready to trim"; rendering "decoding frames" / "packing webp" / "making
webp"; done "webp ready"; failed: the existing failure text for `failure` (truncated to 2 lines).

### 2.8 Settings row (UI)

In the native settings `Form`, a row "live activity" with the value from `model.liveStatus`:
`.pushed` **new** "on", `.localOnly` **new** "only while cobalt is open", `.off` **new** "off in
ios settings", hidden when `.unavailable`. Footer **new** "every save and webp shows in the
dynamic island and on the lock screen."

---

## 3. Server side (summary; the contract is `APP-API-CONTRACT.md` section 8)

### 3.1 Where pushes are sent from: the Durable Object, with `fetch()`

APNs accepts only HTTP/2 with an ES256 JWT. Evidence that a **deployed** Worker's `fetch()`
reaches `api.push.apple.com` over HTTP/2:

- workerd issue #4841 (2025-08-20): APNs pushes via `fetch()` fail under local `wrangler dev`
  on macOS "but work correctly when deployed on production Cloudflare Workers"; no maintainer
  reply. https://github.com/cloudflare/workerd/issues/4841
- "Pushy" (codakuma.com, 2026-04-11): a working service that POSTs to
  `https://api.push.apple.com/3/device/<token>` straight from a Worker, JWT signed with Workers
  WebCrypto. https://codakuma.com/pushy/
- `cloudflare-apns2` (FiveSheepCo), a Workers-only APNs client.
  https://github.com/FiveSheepCo/cloudflare-apns2
- workerd issue #5266 asks for HTTP/2 in *local* development, implying production already
  negotiates it. https://github.com/cloudflare/workerd/issues/5266

**Confidence: medium-high.** Three independent working reports, no Cloudflare document that
promises it, and a Durable Object's outbound fetch is the same runtime path as a Worker's (not
separately confirmed). It cannot be proven before deploy: the tests can only fake the transport.

Why the DO and not the container: the DO is where every trigger happens (save steps, render
progress, the sweep), it holds the tokens, and it can push without waking a sleeping container
(registration, a share-sheet start before the container is up, an `end` after the 45 s sleep).
WebCrypto's ECDSA P-256 `sign` returns the raw `r‖s` 64 bytes that ES256 needs.

**Fallback if the live check fails** (the self-test in section 8 gets no JSON `reason` back from
Apple): flip the text binding `APNS_VIA` from `worker` to `helper` and redeploy. The DO still
signs the JWT and builds the request; the helper (`node:http2`) only relays it to the two Apple
hosts. No secret enters the container, so the env fingerprint and the 45 s sleep are untouched;
a push made while the container sleeps waits for the next wake (start pushes happen while a save
is waking it anyway). Both transports are built and tested in the same wave.

### 3.2 Triggers (detail in section 8)

Save progress set (`startFetch`, `pollFetch`, `finalize` storing, but not `probeStep`'s
reading), save `fail()`, render accepted (`render()`), render pending progress, render success
and error in `renderStatus()`, and the same transitions reached by the sweep. Session `ready`
pushes nothing (the device reads). While a run with an update token is waiting on a server job,
the sweep runs every **2 s** instead of 5 s, so a backgrounded app or closed share sheet still
sees decode progress every ~2 s.

---

## 4. Offline storage limit (CORE store and settings; UI screens)

### 4.1 Public API (additive, pinned)

```swift
public enum StorageLimit: String, Sendable, Codable, CaseIterable {
    case gb1, gb2, gb5, gb10, gb20, unlimited
    public var bytes: Int64? { get }        // 1_000_000_000 … 20_000_000_000; nil = no limit
}
extension Settings {
    public var storageLimit: StorageLimit   // .gb5; app-group defaults key "storageLimit"
}
extension OfflineStore {
    public var usage: StorageUsage { get }  // CHANGED: from the index, no disk I/O (see 4.2)
    public var limitBytes: Int64? { get }   // what the store enforces now
    public func setLimit(_ bytes: Int64?) async          // enforce at once (owner lowered it)
    public func bytesToFree(for limit: Int64?) -> Int64  // what setLimit would evict (the confirm)
    public func clearAll() async                         // files, posters and records
    /// Refills an evicted entry with a fresh download (library "save", local playback) and makes
    /// it the newest for eviction.
    public func attach(file: URL, to id: String, move: Bool) async throws -> StoredVideo
}
extension Format {
    public static func bytes(_ n: Int64) -> String       // CHANGED: ≥ 1e9 → "1.2 GB"; below unchanged
}
```

`StorageUsage` keeps `count` (entries that have a file) and `bytes` (files + posters).

### 4.2 Semantics

- **What counts**: every stored file (originals and webps) plus every poster. The inbox does
  not count (in-flight copies, purged after 24 h as today).
- **Index fields** (additive, optional, decode old indexes): `Record.addedAt: Date?` (nil →
  `createdAt`), `Record.posterBytes: Int64?` (nil → stat once on load, then stored). `usage`
  is the sum over records (`bytes` where `fileName != nil`, plus `posterBytes`), so the views
  that read it in `body` stop stat-ing every file.
- **Effective limit** is read from the app-group defaults key `storageLimit` **inside** every
  enforcement, so the app and the share extension always agree without wiring; `setLimit` writes
  through. `keepVideosOnDevice == false` keeps today's behaviour (no files at all).
- **Enforcement runs inside the same coordinated write as `add`** (`OfflineStore.mutate`, the
  `NSFileCoordinator` `.forMerging` write): insert the new record, compute usage over the merged
  index, choose victims, set their `fileName = nil`, write the index, and only **after** the
  coordinated write delete the victims' files (index first, files second: a concurrent reader
  never sees a record pointing at a deleted file). The same pass runs in `attach`, `setLimit`
  and once at app launch.
- **Victims, in order**: (1) files of entries ordered by `addedAt` ascending, skipping the
  newest **12** entries, the entry just added, and entries pinned in this process; (2) only if
  usage is still over the limit, whole records (poster + record) of file-less entries, oldest
  first, with the same exclusions. The new file is always kept, even alone over the limit.
- **In-process pins** (internal): the pipeline pins the entry it reads frames from or plays
  (`sourceInput` local, `stored`) for the run's lifetime. Cross-process: none needed (decision 9).
- **Evicted items**: the orbit shows the poster (it already falls back when there is no file);
  the library card plays the webp or streams the source; `LibraryModel.localCopy` downloads the
  server copy and `attach`es it to the existing record instead of creating a duplicate;
  `Pipeline.sourceInput` already falls back to the server's ranged source.
- **"clear"** removes all files, posters and records except entries pinned by a running run.

### 4.3 Settings (UI, native `Form`, lowercase; **new** unless noted)

Section "on this iphone" (device word per platform):

- toggle "keep videos on this iphone" (existing, with its existing confirm when turned off)
- picker (`.menu`) "storage limit": "1 GB", "2 GB", "5 GB", "10 GB", "20 GB", "no limit"
- "stored here": "13 videos · 2.1 GB of 5 GB" (no limit: "13 videos · 2.1 GB"), with a linear
  `ProgressView` under it
- choosing a limit below usage asks first (`confirmationDialog`): "this removes about 1.2 GB of
  the oldest videos from this iphone." "remove" (destructive) / "keep" (reverts the picker);
  1.2 GB = `bytesToFree(for:)`
- button "clear videos on this iphone" (`role: .destructive`) → `confirmationDialog`: "remove
  every video kept on this iphone? your server keeps its copies." "remove" / "keep"
- footer: "when it's full, the oldest videos leave this iphone first. the server keeps them,
  and they download again when you open them."

`Copy.storage` drops a trailing ".0" for GB the same way it does for MB ("5 GB").

### 4.4 Tests (CORE, `swift test`, temp dirs, injected clock)

Adds past the limit evict oldest files first; the newest 12 and the just-added entry survive;
posters-only phase; a single file over the limit is kept; `unlimited` never evicts; lowering the
limit evicts exactly `bytesToFree`; `clearAll`; `attach` refills a record and moves it to the
newest; old `index.json` without the new fields decodes; `usage` from the index equals the bytes
on disk after a reconcile; **two `OfflineStore` instances on one root** (the app and the
extension) adding concurrently from detached tasks end with usage ≤ limit, no lost records and
no record pointing at a missing file; `Format.bytes` at 999_999_999 / 1e9 / 5e9;
`StorageLimit.bytes`.

---

## 5. Lanes, waves, gates

Starts **after** the HIG + review-fix wave has landed and Fable has gated it.

| wave | lane | owns (writes only these) | done when |
|---|---|---|---|
| L0 | CORE | `apple/CobaltKit/**` (`Live/` types, client additions, `Capabilities.livePush`, `StorageLimit`, `Settings.storageLimit`, `OfflineStore` limit + 4.4 tests, `Format`, the parity fixture), `apple/project.yml`, `apple/Config/**` (widget Info.plist, `aps-environment`, app plist keys), placeholder `apple/CobaltWidgets/CobaltWidgetsBundle.swift` (one `ActivityConfiguration` with `Text("cobalt")` in every slot) | every public type of 2.2 and 4.1 compiles on iOS and macOS; the widget target builds and embeds; storage tests green |
| L0 (parallel) | API | `deploy/cloudflare/**` per `APP-API-CONTRACT.md` section 8 | api and web `npm test && npm run typecheck` green; fixture copy byte-identical |
| L1 | CORE | `apple/CobaltKit/**` (`LiveActivityManager`, driver, `LiveSink` in `setState`, `ShareCore` registration and relay, reconcile, background task), `apple/CobaltShare/ShareViewController.swift` (only if the share run needs a hook there) | gates green; builder and driver tests: the 2.1 writer table for push and local mode with a fake sink and fake client, throttle ≤ 1/s with immediate stage changes, end on terminal and on a new run |
| L1 (parallel) | UI | `apple/CobaltWidgets/**` (replaces the placeholder), `apple/Cobalt/**` (settings rows 2.8 and 4.3, copy), nothing in CobaltKit | gates green; `#Preview` for every presentation × every `LiveContentState.samples` entry, stale and not |
| L2 | Fable + a Sonnet verification lane | none | the checklist below, evidence saved to a session path |

Rules as `CONTRACT.md` section 3: shared types only in CobaltKit; UI asks Fable for missing API;
`project.yml` is CORE's; lanes never commit or push.

**Gates** (every lane, Fable reruns): the four commands of `CONTRACT.md` section 9 (the iOS build
now also builds and embeds `CobaltWidgets`; still no `warning:` lines from `apple/`), plus:

```sh
cmp apple/CobaltKit/Tests/CobaltKitTests/Fixtures/live-states.json \
    deploy/cloudflare/api/test/fixtures/live-states.json
plutil -lint apple/Config/*.plist apple/Config/*.entitlements
(cd deploy/cloudflare/api && npm test && npm run typecheck)
(cd deploy/cloudflare/web && npm test && npm run typecheck)
```

**L2 checklist**: iPhone 17 Pro simulator, unsigned, local mode: a `PreviewClient`-backed run and
a run against the deployed API show compact, minimal (two concurrent activities), expanded (long
press) and Lock Screen presentations for fetching → saving → reading → ready → decoding → packing
→ done, and a failed run; screenshots of each. Settings: storage rows, lowering the limit with the
confirm, clear. After the owner deploys with APNs secrets: `GET /live/selftest` answers
`apns_reason: "BadDeviceToken"`. On the owner's device (signed): an app run with the app
backgrounded mid-render keeps decoding counts moving; a share-sheet run push-starts and the sheet
closed mid-render still ends on "webp ready"; Workers Logs show `[live]` lines with no token or
JWT in them.

## 6. Risks and what is not verified

- **HTTP/2 from the DO to APNs**: medium-high confidence, unverifiable before deploy (3.1); the
  helper relay is the built-in fallback.
- **Update token after push-to-start**: Apple documents `input-push-token: 1` (iOS 18) as the
  flag for this flow and the token arriving through the app's `pushTokenUpdates`, but whether
  the app is reliably woken to send it is not confirmed (an Apple engineer would not say how the
  token is delivered, forum thread 798434). If the L2 device check shows share-sheet activities
  stuck on their start state, **Plan B**: iOS 18 broadcast channels (a channel per run created
  through Apple's channel management API, `input-push-channel` in the start payload, updates sent
  as broadcasts), which need no token from the app. It needs the Broadcast capability on the App
  ID and is a contained change inside `src/live.ts` and the start payload.
- **Push-to-start token lost on cold launch** (FB21158660): mitigated in 2.5, not eliminated; the
  first share-sheet run after a fresh install may get no activity until the app has run once.
- **APNs budget** for frequent updates is not published: counters go at priority 5 (at most one
  per second per run), stage changes and terminal pushes at priority 10, with
  `NSSupportsLiveActivitiesFrequentUpdates`. Throttling would show as late counters, not wrong
  ones.
- **Custom fonts inside a Live Activity** (`UIAppFonts` in the widget extension) are unverified;
  the monospaced fallback keeps it legible.
- **Whether a push-to-start payload needs an `alert`**: the start payload carries one (harmless
  either way, and it expands the island once while the sheet is open).
- **`cf deploy` with declared but missing secrets** is unverified for `cf` 1.0.0-beta.5: the API
  lane checks with `cf deploy --dry-run` and documents whether the three APNs secrets must exist
  before the first deploy of this wave.
- Not done here: Live Activities on macOS (none exist), App Intent buttons inside the activity,
  per-device keys management (one push-to-start token per API key, so one key per device).

## 7. Supersedes

`CONTRACT.md` section 11 listed Live Activities and widgets as out of scope: this addendum brings
in the Live Activity and its widget extension only (no home-screen widgets). `CONTRACT.md` 4.6
"There is no eviction" (the `OfflineStore` header comment) and `Format.bytes` "≥ 1e6" are replaced
by section 4. Sections 1.8, 7 and 8 navigation parts are replaced by section 1.
