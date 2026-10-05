# cobalt for apple: the quick share card (owner request, 2026-10-05)

Owner (on device, app sideloaded with Feather and a third-party signing certificate): "when using the share
sheet it should either show a live dynamic activity or something else, no full sheet, but i can click on the
live activity to view the process in the app".

Additive to `CONTRACT.md`, `CONTRACT-LIVE.md` (Live Activities), `CONTRACT-SYNC.md` (auto continue, the
background original) and `deploy/cloudflare/APP-API-CONTRACT.md` sections 8 and 9. Code read on 2026-10-05
against the `apple-app` worktree. **(lane)** marks a call made here and open to review; **(owner)** what the
owner asked for.

> **Status (2026-10-05, evening): sections 1 to 7 describe the quick card and its overlay, which the extension no longer
> presents. Section 9 is what ships: an INSTANT SHARE that shows nothing.** The card's logic (`ShareCore.quick`, `QuickCardView`,
> `QuickOverlay`) is kept compiling and tested, reachable only from previews and the debug harness (`{"quick": true}`); deleting it is the
> owner's call (section 9.9). The facts in section 0 (a share extension cannot start a Live Activity, APNs, the app group) still hold.

## 0. What is possible (sources in section 8)

- **F1. A share extension cannot start a Live Activity.** Apple, `Activity.request`: "Use this function to
  request and start a Live Activity from your app while it's in the foreground. Note that you can't do this
  while your app is in the background, unless you adopt AppIntents and start the Live Activity using a
  LiveActivityIntent." The error for the background case is `ActivityAuthorizationError.visibility` ("The app
  tried to start the Live Activity while it was in the background"). The iOS 27 SDK does not mark `request`
  unavailable to extensions, so it compiles there; it is refused at run time. A `LiveActivityIntent` runs in
  the app's process and is only performed by the system (a widget or Live Activity button, Shortcuts, Siri):
  the share extension has no API to perform one. Simulator probe from the real extension: section 7.
- **F2. The one route from the share sheet is APNs push-to-start** (iOS 17.2+): the app registers its
  `pushToStartToken` with the server, and the server pushes `event: start`. `ShareLiveRelay` already asks for
  it (`PUT /live/runs/<run>` with `start: true`) when `eligible`: a build with `aps-environment`, a server with
  `features.live_activity_push`, and a key the extension can read.
- **F3. Push-to-start cannot work for this owner today**, for three independent reasons:
  1. The server has no APNs key: `GET https://api.capybaraharmony.com/capabilities` answers
     `"live_activity_push": false` (read 2026-10-05). `ShareLiveRelay.eligible` is false, so it sends nothing.
  2. An APNs key belongs to one team and can push only to topics (bundle ids) of that team ("Use team-scoped
     keys ... for sending notifications to any topic in a team"; "You can't map a connection to APNs to multiple
     teams"). A build re-signed with a third-party certificate carries that certificate's team; the owner's key
     cannot push to its tokens.
  3. A third-party (usually wildcard) provisioning profile has no `aps-environment`: then the app gets no push
     tokens at all, `LiveEnvironment.current` reads nil (`LiveEnvironment.swift`), and the app stays in local
     mode. (Not verified on the owner's device: the profile Feather used was not inspected.)
- **F4. What the owner saw** (reconstructed; the device was not inspected): the full sheet with the progress
  card, then the 5 s countdown with "stay", then the sheet closing (CONTRACT-SYNC). No Live Activity: the relay
  was inert (F3.1). Then a Hark notification "… is saved · … open cobalt to make a webp", whose tap opens Hark,
  not cobalt: the server's Hark payload is `{title, body}` only. Telemetry (D1 `telemetry_events`, read
  2026-10-05) has one app-side `live activity started push:false` on the owner's iPhone16,2 / iOS 27.2 (build 4)
  and no `process: share` event since build 4 shipped (03:14 UTC).
- **F5. A share extension always presents its view controller, as a sheet the extension can shape.** It can
  set its own custom detent (`SheetFitter` already does), turn off dimming up to that detent
  (`largestUndimmedDetentIdentifier`) and hide the grabber. At a small detent on iOS 26+ the system sheet is an
  inset Liquid Glass card. Nothing documented lets an extension present without a sheet at all.
- **F6. The app can start the activity the moment it is opened** while the run is still on the server: on
  foreground `AppModel.pickUpSharedJobs` takes the share sheet's `SharedJob`, the home pipeline resumes it, and
  `LiveActivityManager` requests the activity on the first state (local mode). Already built; this lane makes its
  tap open the run (section 4).
- **F7. A build re-signed without the app group** (see `AppGroup.location`, `Store/Settings.swift`) cannot
  share the job record between the extension and the app. So every run link now also carries the run's studio
  session, which is enough for the app to follow the run by itself.

## 1. Decisions

1. **(lane) No Live Activity from the share sheet now.** F1 and F3 rule it out for this build and server. The
   card plus Hark plus the app's own activity on open is the best available today. Section 6 is the plan for
   the real thing.
2. **(owner, lane) The quick card is the default for links.** Sharing a link shows a small card instead of the
   full sheet: a ring, "saving to cobalt", the link (`instagram · Dd7P496wolG`), an expand control. It is the
   full-screen overlay of section 2a (blur, drop from the island, morph back into it); when the host still
   presents a sheet, the card is the system sheet at a fitted detent: no grabber, nothing dimmed.
3. **(lane) The card closes as soon as the server holds the save**: the first moment `canContinueInBackground`
   is true (a session exists, the state is fetching or saving, the server has a studio and
   `finishes_unpolled`). It shows "cobalt has it" with a check for **0.6 s** (`ShareCore.quickHold`), then calls
   `continueInBackground()`: the `SharedJob(.saving)` for the app, the Hark opt-in (`saved`, `failed`), the
   background original handoff (CONTRACT-SYNC decision 6), `completeRequest`. Measured in tests on the preview
   server: the time to the session plus 0.6 s.
4. **(lane) A save that finished before the hand-off** (the server had the link cached) takes the saved path:
   the same `SharedJob(.saving)` (the app's poll answers at once), the original handed off, and a local "your
   video is saved" notification from the extension (the server's "saved" moment passed before any opt-in).
5. **(lane) A failure keeps the card**: the reason (`Copy.failure`), **try again** (same link, still the card),
   **open cobalt**, and the close button. Nothing closes by itself after a failure.
6. **(lane) The full sheet takes over** for what the card cannot finish alone: a file share (its upload runs
   inside the extension), a picker post, an image, plain cobalt, a legacy fork, a server without
   `finishes_unpolled`. Also on request: the expand control (chevron, "show the full sheet") or a long press.
   Expanding never stops the run.
7. **(lane) No countdown in quick mode.** The card already hands off at the earliest moment; a card the owner
   expands is the owner choosing to look. `autoContinue` is `.off` for a quick sheet. The setting "show the
   full share sheet" brings back today's sheet with its countdown.
8. **(lane) The setting** `Settings.shareFullSheet` (app-group key `shareFullSheet`, default **false** = the
   card). Its Settings row is requested from the settings lane (requests R2).
9. **(lane) Every run link carries the session** (`?session=<sid>`, plus `&trim=1` for "trim in cobalt"):
   the share sheet's local notifications and its "open in cobalt". `saved` and `failed` notifications now open
   their run (`job/<id>`) instead of `open`; the app falls back to the save tab exactly as before when it has
   nothing to follow.
10. **(lane) A share-sheet run the app took over keeps `origin: "share"`** in its activity attributes, so the
    activity's tap opens `cobalt-apple://job/<run>` (the widget already maps share origin to the job link).
    The app's own runs stay `origin: "app"` (tap opens cobalt).

## 2a. The overlay: blur, drop from the island, morph back into it (owner, 2026-10-05, later the same day)

Owner, watching the first captures: "maybe the small sheet could come from the top so it blurs the screen and
then it morphs into the dynamic island?". Built that way; the compact sheet card stays as the fallback.

- **Presentation.** `ShareViewController` sets `modalPresentationStyle = .overFullScreen` (and
  `.crossDissolve`) in both initialisers, before the host presents it, unless "show the full share sheet" is on.
  Its view and the hosting view are clear. In `viewWillAppear`/`viewDidAppear` it checks whether it still ended
  up in a sheet (`sheetPresentationController`, or a `UISheetPresentationController` as its presentation
  controller); if so the root switches to the compact sheet card of section 1 and the fitter takes over
  (logged as `share presentation`). **Whether the system share host honours `.overFullScreen` on iOS 26/27 is
  only knowable on the real extension** (section 7 has what was and was not verified). Apple does not
  document it either way. Community practice since iOS 13 is that the host honours the principal view
  controller's `modalPresentationStyle` (apps set `.fullScreen` there to escape the sheet); `.overFullScreen`
  with a clear background is the same mechanism, unproven here until the real-extension check passes.
- **Sequence** (`CobaltShare/QuickOverlay.swift`): a full-screen `.regularMaterial` blur fades in (0.25 s);
  the card starts as a clear capsule at the Dynamic Island and springs down into a glass card under it (0.45 s,
  bounce 0.22). When the server holds the save the ring turns into the check; after a beat (0.35 s, and the
  card has been up at least 0.9 s so it is readable when the server answers at once) the card springs into a
  black capsule at the island's exact rect (0.5 s), the blur fades, and the capsule shrinks to 0.82 and fades
  into the island (0.25 s). Then the view calls `ShareModel.finishQuickHold()`, which hands the run off and
  completes the request while nothing is visible. `quickHoldSeconds = 4` is only the ceiling.
- **The island rect** (`IslandGeometry`): with a top safe-area inset of 51 pt or more (Dynamic Island iPhones,
  59 to 62 pt) a 126 x 37 pt capsule, 11 pt from the top, centred. Otherwise (notch, home button, iPad,
  landscape) a 96 x 28 pt pill centred in the top inset.
- **Failure:** no morph; the card grows to show the reason, try again, open cobalt and close; a tap on the
  blur outside the card closes. **Expanded** (asked, or a run only the sheet can finish): the full sheet's
  content in a bottom panel over the blur, as tall as it is (up to 88%); a tap on the blur closes.
- **Reduce Motion:** the card fades in and out; no drop, no morph.
- **What it is, honestly:** a visual hand-off. No Live Activity exists at that moment (section 0). The real
  activity starts when cobalt is opened while the save still runs (F6), and Hark says when it is done.

## 2. Flow

```
share a link ─▶ card: ring · "saving to cobalt" · instagram · Dd7P496wolG · [⌃]
   │  POST / → session (the server holds the save)
   ▼
card: ✓ "cobalt has it" · "we'll notify you when it's saved"      (0.6 s)
   │  SharedJob(.saving) · PUT /studio/<sid>/notify {saved, failed} · background original · completeRequest
   ▼
sheet gone ─▶ server finishes unpolled ─▶ Hark "… is saved"   (tap: Hark today; cobalt once R1 lands)
          └▶ the original downloads in the background, lands in the store and the album
open cobalt while it still runs ─▶ the app takes the job ─▶ Live Activity starts (island, lock screen)
tap the activity ─▶ cobalt-apple://job/<run> ─▶ the app is on that run
```

## 3. CobaltKit API (additive)

```swift
// Share/QuickShare.swift
public enum QuickShare: Sendable, Equatable {
    case off, working, holding, failed(PipelineFailure), expanded(QuickExpand)
    public var showsCard: Bool { get }
}
public enum QuickExpand: Sendable, Equatable { case asked, needsSheet }
extension Settings { public var shareFullSheet: Bool }          // key "shareFullSheet", default false

// Share/ShareModel.swift (iOS)
extension ShareModel {
    public var quick: QuickShare { get }
    public var quickTitle: String? { get }                        // "instagram · Dd7P496wolG"
    public func expand()                                          // the expand control, a long press
    public func retryQuick()                                      // the failed card's "try again"
    public func openCobalt() async                                // the failed card's "open cobalt"
    public var quickHoldSeconds: Double { get set }               // 0.6 s card; the overlay sets a 4 s ceiling
    public func finishQuickHold() async                           // the overlay's morph is over: hand off now
    public static func preview(_ scenario: PreviewScenario = .happy, quick: Bool = false) -> ShareModel
    public func previewQuick(_ state: QuickShare)                 // previews only
    #if DEBUG
    public static func debugPreview(_:quick:openApp:complete:) -> ShareModel   // simulator evidence
    #endif
}

// Share/AppModel+RunLinks.swift
extension AppModel {
    @discardableResult public func openRunLink(_ url: URL) -> Bool
    #if DEBUG
    public func debugUsePreviewServer(_ scenario: PreviewScenario)
    public func debugShareHandoff(link: URL) async -> SharedJob?
    public func debugSessionRunLink(link: URL) async -> URL?
    #endif
}
```

Internal: `ShareCore.quick`, `quickTask`, `openedAt`, `quickHold = 0.6`, `evaluateQuick()`, `expandQuick(_:)`,
`retryQuick()`, `openCobalt()`; `ShareCore.init(…, quick: Bool = false)` (the live factory passes
`!settings.shareFullSheet`; previews and the older tests build the full sheet). `Notifications.url(forJob:session:trim:)`,
`url(for:jobID:session:)`, `NotificationPosting.post(_:jobID:session:)` (default forwards to the old one).
`RunLink` parses `job/<uuid>[?session=&trim=1]` and `session/<sid>`. `LiveActivityManager.origin(of:)`.

## 4. Run links in the app (`AppModel.openRunLink`, called first by `handleAppLink`)

| link | the app |
|---|---|
| the home pipeline already follows that run (same run id or session, not idle) | save tab, nothing else |
| `job/<uuid>` with a job record (or `session/<sid>` matching one) | `open(job/<id>)` as before: taken over a quiet home screen (idle, failed, done, saved, image), never over a run in flight |
| no job record, link has a session, home screen quiet | the home pipeline follows the session as a share-sheet save (`SharedJob(.saving)` built in memory, `origin .shareExtension`); its activity starts with it |
| no job record and no session, or a busy home screen | save tab only |
| anything else (`open`, `library`, `copy`) | not a run link: `open(_:)` / the copy handler as before |

## 5. Copy (lowercase; `ShareCopy` in `CobaltShare/ShareParts.swift`)

| key | text |
|---|---|
| `quickSaving` | saving to cobalt |
| `quickChecking` | reading the link (under the title until the link is known) |
| `quickHeld` | cobalt has it |
| `quickNotify` | we'll notify you when it's saved (server has the notify bridge) |
| `quickOpenLater` | open cobalt to see it (no bridge) |
| `quickFailed` | couldn't save (the reason under it is `Copy.failure`) |
| `quickOpenCobalt` | open cobalt |
| `quickExpandA11y` | show the full sheet |

Symbols: `ShareSymbol.expand = "chevron.up"`, `ShareSymbol.failed = "exclamationmark"`, plus the existing
`Symbol.retry`, `Symbol.openApp`, `Symbol.checkmark`. VoiceOver: "cobalt has it. we'll notify you…" and
"couldn't save. <reason>" are announced once each; the ring is hidden; "show the full sheet" is also an
accessibility action on the card. Reduce Motion: the ring does not spin.

## 6. Later: a real Live Activity straight from the share sheet

Everything on the app and server side is built (CONTRACT-LIVE, APP-API-CONTRACT 8). What is missing is
signing and a key. In order:

1. **Sign with the owner's own team.** Either build and install from Xcode with the owner's team in
   `apple/Config/Local.xcconfig`, or give Feather the owner's own certificate (.p12) and a provisioning profile
   from the owner's account, not the third-party one.
2. **Register the App IDs in the owner's account** (Certificates, Identifiers & Profiles):
   `com.capybaraharmony.cobalt` with **Push Notifications** and **App Groups**
   (`group.com.capybaraharmony.cobalt`), `…cobalt.share` and `…cobalt.widgets` with App Groups. Keep the bundle
   ids unchanged in Feather (a renamed bundle id is a different APNs topic).
3. **Profiles that carry `aps-environment`**: a development profile (sandbox) for Xcode installs, or ad hoc /
   distribution (production) for Feather. Check the installed build: `LiveEnvironment.current` must not be nil;
   the Settings row "live activity" then reads "on" once the server pushes.
4. **Create an APNs key** (Keys, Apple Push Notifications service; team-scoped, or topic-scoped to
   `com.capybaraharmony.cobalt`). Note its Key ID and the Team ID; download the `.p8` once.
5. **Server secrets**: `APNS_KEY_P8` (the PEM as one JSON string with `\n`), `APNS_KEY_ID`, `APNS_TEAM_ID` in
   `~/.config/cobalt/secrets.json`; API deploy only (`prepare-git-info.sh`, `cf deploy --secrets-file …`).
6. **Check the transport**: `GET /live/selftest` with the device's key must answer
   `apns_reason: "BadDeviceToken"` (APP-API-CONTRACT 8.6). `InvalidProviderToken` = wrong key/team id;
   `TopicDisallowed` = the key cannot push to this bundle id; no reason = switch `APNS_VIA` to `helper`.
7. **Open cobalt once** after installing (the push-to-start token is registered from the app; a known iOS bug
   loses it on cold launch until an activity has run once, CONTRACT-LIVE 6).
8. **Then the card can show the island too.** With `live_activity_push: true` and an environment, the relay
   asks the server to push-start the activity as soon as the card opens; the card still closes on the hand-off.
   No app change is needed for that; re-check the duplicate rule (`endIfDuplicate`) on the device.

Risks carried over from CONTRACT-LIVE 6: HTTP/2 from the Durable Object to APNs, the update token after a
push-start, APNs budgets. All unverified until steps 1 to 6 are done.

## 7. Verification (2026-10-05)

Done (iPhone 17 Pro simulator, iOS 27.0, through the share harness, which hosts the same `ShareStageView`,
`QuickCardView`, `QuickOverlay` and `SheetFit.swift` the extension compiles, over `PreviewClient`):

- In-app `.overFullScreen` presentation gives `_UIOverFullscreenPresentationController`, no sheet, the view
  full screen with the island's 62 pt top inset; the blur, the drop from the island, the morph back into it and
  the completion after the merge are recorded in light and dark. Completion lands after "merged into island"
  (1.8 to 2.0 s after presentation on a heavily loaded host; the preview server answers at once, so that is the
  0.9 s minimum dwell plus the morph).
- Failure (private post) stays as the card with the reason, try again, open cobalt, close; light and dark.
- Expanded: the full sheet's content as a bottom panel over the blur.
- The compact-sheet fallback card in light and dark (first build). Dark showed the fixed caption grey
  unreadable on glass; the card now uses the hierarchical styles, re-captured legible.
- Gates: xcodegen; iOS build (`generic/platform=iOS Simulator`, `apple/.build/sq-ios`) and macOS build with no
  `warning:` from `apple/`; `swift test` green (679 tests; 24 new in `QuickShareTests.swift`).

Not verified (and why):

- **The real share extension** in a real host (Safari's share sheet): whether the host honours
  `.overFullScreen` and the clear background on iOS 26/27, and the probe of `Activity.request` from the
  extension (`ShareDebug.probeLiveActivity`, debug builds, `/tmp/cobalt-sq/share-debug.json`). The host Mac
  ran at a load average of 500 to 1000 for the whole session; the simulator's launch, open-URL and install
  calls hung for 10 to 25 minutes each, so the Safari share-sheet run could not be driven. Both outcomes are
  handled: the overlay when honoured, the compact sheet card when the host still presents a sheet.
- **The app taking over a running share job and starting its Live Activity** on the simulator (the debug
  links `cobalt-apple://debug/takeover` and `/sessionlink` exist for it). Covered by tests with a fake
  ActivityKit (`QuickLiveOriginTests`, `RunLinkOpenTests`), not by a screenshot of the island.
- Timings on a real device and real server, Hark's `url` (requests R1), the owner's sideloaded build's app
  group, keychain group and `aps-environment` (section 0, F3 and F7).

## 8. Sources

- Apple, `Activity.request(attributes:content:pushType:)`:
  https://developer.apple.com/documentation/activitykit/activity/request(attributes:content:pushtype:)
- Apple, `ActivityAuthorizationError.visibility`, `.unsupportedTarget`:
  https://developer.apple.com/documentation/activitykit/activityauthorizationerror
- Apple, "Starting and updating Live Activities with ActivityKit push notifications":
  https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications
- Apple, "Establishing a token-based connection to APNs" (team-scoped and topic-specific keys; one team per
  connection): https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns
- iOS 27 SDK `ActivityKit.swiftinterface` (Xcode 27.0, 27A266a), read 2026-10-05: no extension-unavailable
  attribute on `request`; `ActivityAuthorizationError` cases.
- Hark webhook fields (`url`: "Web URL, universal link, app deep link, or Shortcuts URL", opened on tap):
  https://hark.ryan.ceo/docs
- Live server capabilities, read 2026-10-05: https://api.capybaraharmony.com/capabilities
- Repo: `CobaltKit/Live/ShareLiveRelay.swift` (`eligible`), `Live/LiveEnvironment.swift`,
  `Models/AppModel.swift` (`pickUpSharedJobs`), `Store/Settings.swift` (`AppGroup.location`),
  `deploy/apple/README.md` ("Not verified here": entitlements re-mapped by Feather).

## 9. Instant share (owner, 2026-10-05, evening: "maybe we remove the share screen entirely with a notification")

Device facts that decided it (owner's iPhone, iOS 27.2, build 1.4, re-signed by Feather): the share host IGNORES the full-screen
overlay request, so the quick card rendered inside a grey system sheet; the expand arrow then showed the full sheet with a huge empty
grey area above the dark card. The app group is MISSING on that build (`AppGroup.location.kind == .fallback`), so the extension and the app
share no files, no defaults and maybe no keychain group. The server's container cold-starts ("waking the server, 6 s"). **(lane)** marks a
call made here and open to review; **(owner)** what the owner asked for.

### 9.1 What the owner sees

1. Share a link. The extension shows **nothing that waits**: no card, no countdown, no progress, no waiting for the save. The view is
   clear; the host's system sheet may still flash for as long as the request takes (section 9.3 says how long).
2. If notifications were already allowed (the extension never asks), a quiet local notification appears at once:
   **"saving to cobalt"** with `instagram · Dc2QA4ng-US` under it (passive, no sound; tapping it opens cobalt).
3. When the save is ready the server's Hark message says so (`APP-API-CONTRACT.md` section 9; tapping it opens cobalt on that run).
4. The video lands in the orbit and, when the album sync is on, in Photos, without anyone opening the app (app group builds: the
   system wakes the app) or the next time the app opens (every build).
5. If the save could not even be queued, the sheet shows a **one-line card** with "open cobalt" and close instead of completing silently.

The full sheet stays: the setting "show the full share sheet" (`Settings.shareFullSheet`, app-group defaults) turns the instant path
off, and a file share always gets it (its upload runs inside the extension). **(lane)** The setting reaches the extension only when the
app group exists; on the owner's current build the extension always takes the instant path.

### 9.2 The extension (`CobaltShare/ShareViewController.swift`, `CobaltKit/Share/InstantShare.swift`)

```
viewDidLoad ─▶ InstantShare.run(inputItems)
   │  read the link (URL attachment, URL in text, the item's own text; a link wins over a movie)
   │  no key for this server ──▶ .failed(.noKey)          no link ──▶ .failed(.noLink)      a movie only ──▶ .needsSheet
   │  POST /studio {url, public: true, origin: "share", notify: {on: [saved, failed], label: "<service> · <ref>"}}   (upload task, body from a file)
   │  local notification "saving to cobalt" (only when already allowed)
   ▼
.saved ─▶ completeRequest        .needsSheet ─▶ the full sheet        .failed ─▶ the one-line card (open cobalt · close)
```

- **Which key.** The same lookup as the app (`Settings.apiKey(in:forServer:)`, keychain, shared access group when the build has one).
  No key readable in the extension is `.failed(.noKey)` and the card says "cobalt can't find your key from here"; **nothing is queued**.
  Unverified on the owner's build: whether its keychain group survived the re-sign (if not, the instant path cannot work there and the
  owner has to use the full sheet setting or a build signed with their own team, section 6).
- **Two transports, chosen by `AppGroup.location.kind`** (`Background/InstantSave.swift`):
  - **background** (the app group exists): a background `URLSession` with `sharedContainerIdentifier`, identifier
    `com.capybaraharmony.cobalt.bg.save.<job uuid>` (under the prefix the app's `.backgroundTask(.urlSession)` already matches). The extension
    confirms the system holds the task (a round trip to the transfer daemon, at most 0.6 s) and completes. The task description is the
    link, so the app's wake knows what it was.
  - **foreground** (no app group): NSURLSession.h says a background session created in an extension without a valid shared container "is
    invalidated upon creation", so none can exist on the owner's build. The request goes through an ephemeral session and the extension
    waits for the server's answer (at most 10 s, then it completes anyway). The server keeps that short for a share (`SHARE_KICK_MS`,
    `APP-API-CONTRACT.md` 14.1: 1.2 s plus Worker and D1). **(lane) This is the one place "shows nothing that waits" is approximate:** the
    view is clear, but the host sheet can stay for about a second. A rejection (401, 5xx) or no connection is known here and shows the
    failure card; the background transport cannot know.
- **Time on screen.** Target under 300 ms on screen for the background transport (link read, one XPC round trip). Not measured on a
  device (section 9.8).
- **Sheet that hugs.** When the full sheet IS shown, `SheetFitter` now sets `preferredContentSize` as well as the detent, always, and
  the controller never asks for `.overFullScreen` any more. The grey area above the card was the overlay's blur drawn inside a sheet
  (the host ignored the overlay request and `sheetPresentationController` is not reachable from an extension's remote view, so the
  fallback detection never fired).

### 9.3 The server (`APP-API-CONTRACT.md` section 14; `features.create_notify`)

`POST /studio` takes `notify` (registered atomically with the session, same parser and storage as `PUT /studio/<sid>/notify`) and
`origin: "share"` (never refused as busy, answered within 1.2 s, remembered for 24 h). `GET /studio/recent` lists the key's share saves.
All additive; an older server ignores the new fields.

### 9.4 The app learns the session (`Photos/OriginalFetcher+Shares.swift`)

Two ways, both ending in one hand-off to the app's background download (`?wait=90`, `PendingOriginals`, the existing store and album code):

| way | when | needs |
|---|---|---|
| the system's wake | the extension's request finished while the app was not running (`.backgroundTask(.urlSession)` -> `handleBackgroundDownloads` -> `OriginalFetcher.handleWake`): the answer's session id | the app group; an app that was not force-quit |
| `GET /studio/recent` | every foreground (`pickUpSharedJobs` -> `OriginalFetcher.reconcile`) | a key; a server with `create_notify`; iOS only |

- **What is kept:** only with "keep videos on this iphone" on; one original per session (whatever the ledger or the store already has
  is left alone, so the wake, the foreground and the home pipeline never download twice); a failed session is skipped (Hark said so).
- **Name:** the session's title and size when the server has them (a ready session, or looked up when the file lands), else the link's last
  path segment.
- **A request that failed** (the wake saw a refusal or an error): a local notification, "cobalt couldn't start that save", with the link and
  the reason. No session exists, so the server cannot say it. A build with no app group learns it only from the foreground transport's card.
- **Housekeeping:** the request bodies the extension wrote (`Saves/*.json`) older than a day are deleted on foreground; the extension's
  "saving to cobalt" notifications are cleared when the app comes to the front.

### 9.5 Decisions

1. **(owner, lane)** The extension shows no card, no countdown and no progress. Sections 1 to 3, 6, 7 and 2a are superseded for the extension.
2. **(lane)** A link beats a movie when an app shares both (saving the link server-side is the point); a movie alone, or the setting, gets the
   full sheet.
3. **(lane)** `notify` is `saved` + `failed` and `public: true` always (the owner's "public by default"); a server without them ignores them.
4. **(lane)** A share is never refused as busy: it queues behind the running save (the server waits for the helper up to two minutes). Two quick
   shares both land.
5. **(lane)** No `SharedJob`, no Live Activity from the extension: it does not know the session when it completes. Opening the notification
   (`cobalt-apple://session/<sid>`) makes the app follow the run and start its activity, as before.
6. **(lane)** The recent list is polled only on foreground, once per `reconcile` (one small GET); no polling in the background.

### 9.6 Files

`CobaltKit`: `Background/InstantSave.swift` (seams, engine, transports), `Share/InstantShare.swift` (intake, `InstantShare.run`),
`Photos/OriginalFetcher+Shares.swift` (the app's half), `Photos/OriginalFetcher.swift` (seams, wake, reconcile), `Photos/BackgroundSessionID.swift`,
`Share/Notifications.swift` (the two notifications), `Share/ShareModel.swift` (`live` builds the full sheet only), `API/HTTPCobaltClient.swift`
(`shareSaveRequest`, `recentShares`, the flag), `Models/Server.swift` (`createNotify`). `CobaltShare`: `ShareViewController.swift`,
`InstantFailure.swift`, `SheetFit.swift`, `ShareParts.swift` (copy), `ShareDebug.swift`. Tests: `InstantShareTests.swift` (27), api
`test/instant-share.test.ts` (34).

### 9.7 Copy (lowercase)

`saving to cobalt` / `<service> · <ref>` (the notification); `cobalt couldn't start that save` + `<link> — <reason>` (the app's failure
notification); the card: `cobalt can't find your key from here`, `there's no link here that cobalt can save`, `couldn't start the save`,
`the server didn't accept your key`, `the server is busy, try again in a moment`, `the server isn't available right now`, `the server said
no`, `couldn't reach the server`; button `open cobalt`.

### 9.8 Verification (2026-10-05) and what is not verified

Done: api tests (real SQL, the real `StudioService` and `NotifyService`); CobaltKit unit tests with fake transports, plus the real
foreground transport against a loopback server (upload from a file, `Authorization`, JSON body, the answer read back); the app's wake and
foreground discovery against the ledger and the store.

Not verified (no device, and the simulator host was overloaded):
- **Everything about the real extension in a real host:** the time on screen, whether the host's sheet flashes, `preferredContentSize` honoured
  (or not) by the owner's iOS 27 host, the failure card's height in the host sheet.
- **A background URLSession started from a share extension that then completes**, and the system waking the app for it
  (`handleEventsForBackgroundURLSession`): only possible with the app group, which the owner's build lacks. Covered by the contract, not run.
- **The keychain group on the owner's build** (if the key is not readable from the extension, every share shows the "can't find your key" card).
- **The foreground transport after `completeRequest`:** the extension waits for the answer, so it does not depend on the process surviving
  completion, but the 10 s ceiling means a very slow server completes with the request unconfirmed (the app finds the session on the next
  foreground through `GET /studio/recent` if the server got it).
- A share while the server is cold: the 1.2 s cap and the sweep that starts the save were tested with fakes, not through the edge.

### 9.9 Left to the owner

The quick card and the overlay are dormant code (about 750 lines: `QuickCard.swift`, `QuickOverlay.swift`, `ShareCore+Quick.swift`, their tests).
They can be deleted, or kept for a future Live Activity route (section 6). A product call, not an engineering one.
