# cobalt for apple: the quick share card (owner request, 2026-10-05)

Owner (on device, app sideloaded with Feather and a third-party signing certificate): "when using the share
sheet it should either show a live dynamic activity or something else, no full sheet, but i can click on the
live activity to view the process in the app".

Additive to `CONTRACT.md`, `CONTRACT-LIVE.md` (Live Activities), `CONTRACT-SYNC.md` (auto continue, the
background original) and `deploy/cloudflare/APP-API-CONTRACT.md` sections 8 and 9. Code read on 2026-10-05
against the `apple-app` worktree. **(lane)** marks a call made here and open to review; **(owner)** what the
owner asked for.

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
