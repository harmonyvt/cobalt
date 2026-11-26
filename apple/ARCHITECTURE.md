# Apple app architecture: the main thread is display-only (8.17), and every thing has one owner (8.29)

House rules for the native app (`apple/`): iPhone, iPad and Mac, iOS 18 / macOS 15, Swift 6 strict concurrency,
SwiftUI with `@Observable`. They are short on purpose and each one is enforced by a test, an assertion or telemetry.
Humans and agents follow them the same way. `CONTRACT.md` still owns layout, copy and the CobaltKit API; this file
owns where work runs.

## Why

8.16 measured this on Harmony's iPhone:

| What | Measured | Cause |
| --- | --- | --- |
| `OfflineStore.reconciled` | 330 to 432 ms on main | disk scan and JSON index on the main actor |
| library first appearance | one 914 ms frame | SwiftUI layout of every row, `libraryRows` built in the view |
| detail zoom pop | 350 to 540 ms | the zoom transition on video posts tore the grid out of the stack |
| 7TV tab | 401 ms of hitches per second | emote decode and layout on main |
| PostHog session replay | crash on 3.97.0 | a third-party SDK with no wrapper between it and the app |

Every one of them is main-thread work that did not need to be there. The fix is a direction, not a patch list.

## The one-way flow

```
engines                 snapshots                     models                      views
actor / nonisolated  -> immutable, Sendable,      ->  @MainActor @Observable  ->  pure structs that draw
+ @concurrent funcs     Equatable values              only assign (when changed)  only what is visible
(disk, JSON, decode)    (built off main)              (no I/O, no decode)         (narrow inputs)
```

Data flows one way. Views send intents to models; models ask engines; engines answer with a new snapshot. Nothing on
the left of an arrow reads state on its right.

## Rule 1: no disk, JSON, decode or file coordination on the main thread

No `FileManager`, `Data(contentsOf:)`, `.write(to:)`, `JSONDecoder()`/`JSONEncoder()`, `NSFileCoordinator`,
`CGImageSource*`, `UIImage(data:)`/`NSImage(data:)` in a `@MainActor` type, an extension of one, or a View.

- Why: the 330 to 432 ms reconcile and the 7TV hitches above. A `fileExists` costs microseconds on a warm cache and
  tens of milliseconds when the phone is busy; a frame at 120 Hz is 8 ms.
- Enforced: `MainThreadLintTests` (CobaltKit tests) scans `apple/Cobalt` and `apple/CobaltKit/Sources` and fails on
  any new use. Engine entry points call `MainThreadGuard.assertOffMain()` (CobaltKit/Concurrency), which stops a debug
  build when called on main and is free in release.
- Exception: one line in `apple/main-thread-allowlist.txt`, `<path>: <trimmed line> # reason`. The list starts with
  the 8.17 baseline ("move off main") and must only shrink; the test also fails on entries that match nothing.

```swift
// don't: a model reads the disk
@MainActor @Observable final class ShelfModel {
    func load() { items = try! JSONDecoder().decode([Item].self, from: Data(contentsOf: url)) }
}
// do: the engine reads, the model assigns
actor ShelfEngine {
    func load() throws -> ShelfSnapshot {
        MainThreadGuard.assertOffMain()
        return ShelfSnapshot(items: try JSONDecoder().decode([Item].self, from: Data(contentsOf: url)))
    }
}
```

## Rule 2: engines publish snapshots, equality-gated

An engine owns its state and hands out a finished value: a `struct` that is `Sendable` and `Equatable`, with
everything the screen needs already computed (sorted, grouped, filtered). The model compares before it assigns, so an
unchanged snapshot never invalidates a view.

- Why: the 914 ms library frame. Every `@Observable` write re-evaluates every body that read the property, even when
  the value is the same.
- Enforced: review, plus `EngineClock` timing (below) shows an engine that publishes too often.
- Exception: none needed; a model that needs more is asking for a richer snapshot.

```swift
// don't
store.items = await engine.items()            // fires even when nothing changed
// do
let next = await engine.snapshot()
if next != snapshot { snapshot = next }
```

## Rule 3: views are pure, lazy and take narrow inputs

A View body only reads values and lays them out. Lists and grids are `Lazy*` or `List`. A row takes the values it
draws (`let item: RowValue`), not `AppModel` or a whole store, so a change elsewhere does not re-run it.

- Why: the library appear frame was SwiftUI laying out every row because each row observed the whole model.
- Enforced: review; the lint test catches the I/O half. `FrameMonitor` and `frames` events show the cost.
- Exception: a root screen may read its own model; say so in a comment.

```swift
// don't
struct Row: View { @Environment(AppModel.self) var model; let id: String; ... }
// do
struct Row: View, Equatable { let title: String; let thumb: URL?; ... }
```

## Rule 4: one media pipeline

Every image, animated WebP, GIF and emote decode goes through the existing loaders: `ImageLoader` and
`FlipbookLoader` (`Cobalt/Screens/Home/Media.swift`), `LibraryPictureLoader` (`Screens/Library/LibraryMediaCache.swift`)
and `EmoteCache` (`CobaltKit/Media`). They are actors, decode off main, downsample to the size on screen and cache.

- Why: the 7TV hitch ratio. Each ad-hoc `UIImage(data:)` in a view decoded full size, on main, per appearance.
- Enforced: the lint test bans `CGImageSourceCreate`, `UIImage(data:)` and `NSImage(data:)` in main-thread code.
- Exception: an allowlist line with a reason; prefer adding a case to a loader.

```swift
// don't
Image(uiImage: UIImage(data: data)!)
// do
StillImage(url: url)   // ImageLoader decodes, downsamples and caches off main
```

## Rule 5: navigation is data, system transitions only on light content

Navigation state is a value (a path of ids) held by a model; views read it. The system zoom transition is only for
content that is cheap to tear down and rebuild. Video posts do not zoom: on iOS 26/27 the zoom pop left the grid out of
the navigation stack for 350 to 540 ms.

- Enforced: review; `hang_stack` events name the screen and breadcrumbs when a transition stalls.
- Exception: a new zoom source needs a measured `frames` event under 16 ms on the owner's phone.

```swift
// don't
.navigationTransition(.zoom(sourceID: post.id, in: ns))   // on every post
// do
.navigationTransition(post.isVideo ? .automatic : .zoom(sourceID: post.id, in: ns))
```

## Rule 6: third-party SDKs sit behind our own wrapper

PostHog (the only third-party package) is reached only through `Cobalt/App/Analytics.swift`. The wrapper throttles
what it sends, encodes off main and turns the SDK off when the server stops sending the project (the remote off
switch), without an app update.

- Why: the 3.97.0 replay crash. With a wrapper, a bad SDK release is one server switch and one version bump in
  `project.yml`, not a hunt through screens.
- Enforced: review; any other file that imports the SDK is sent back.
- Exception: none.

```swift
// don't
PostHogSDK.shared.capture("opened")      // in a view
// do
Analytics.event("opened")                // throttled, off when the server says off
```

## Rule 7: performance budgets are tests and telemetry

A budget nobody measures is a wish. These run on every build:

- `MainThreadLintTests`: no I/O, JSON or decode in main-thread code (rule 1).
- `MainThreadGuard.assertOffMain()` / `assertOnMain()`: debug traps at engine and UI boundaries.
- `HangSampler` debug alarm: every main-thread stall of 100 ms or more logs a `main thread stall` warning and an
  os_log fault (red in Console and Instruments). With analytics on, every build sends `hang_stack` with stacks
  sampled at 250 ms, 700 ms and 1.5 s.
- `FrameMonitor` `frames` events and MetricKit `daily_metrics`: hitch ratio per screen.
- `EngineClock`: how long each engine operation takes (below).

Budgets: a frame is 8 ms at 120 Hz; nothing on main may take 16 ms; no stall over 100 ms in a debug run of the
golden path (launch, library, open a post, back, 7TV tab).

- Exception: a known stall gets an issue and a line in the release notes, never a raised threshold.

## Telemetry in this architecture

Engines time themselves. Wrap the work in the shared helper `EngineClock` (`CobaltKit/Telemetry`):

```swift
let snapshot = try await EngineClock.measure("store.reconcile") {
    try reconcileIndex()                 // runs where the engine runs, never on main
}
```

`EngineClock.measure` emits an os_signpost interval (so Instruments shows the work by name) and adds the duration to
a per-minute aggregate: count, p50 and max per name. Once a minute the aggregate goes out as one `engine_ops`
analytics event, never one event per call. Events are encoded and queued off main; the main thread never builds a
payload. Names are `area.operation`, lowercase, stable (they are dashboard keys): `store.reconcile`, `library.rows`,
`emote.decode`.

Reading it: PostHog project "capystore", events `engine_ops` (where time goes), `frames` (what the user felt),
`hang_stack` (what main was doing). A rising `engine_ops` p50 with flat `frames` is fine; a `hang_stack` whose top
frames are in an engine means rule 1 or 2 was broken.

## Who owns what: windows, lifecycle and memory (8.29)

The rules above decide where work runs. These decide who owns a thing and for how long. 8.27 crashed on every launch,
and #113 looped the Mac launch twice, for one reason: our code and SwiftUI both acted as owner of the same thing and
kept answering each other. The audit and explainer: `/mnt/project-files/lifecycle-audit/` (index.html, learn.html).

### Four lifetimes

Every piece of state belongs to exactly one:

| Lifetime | Lives as long as | Examples | Owner |
| --- | --- | --- | --- |
| process | the app runs | AppModel, engines, caches, the Twitch player, Live Activity managers | made once at launch; told about the app's state by `AppLifecycle` |
| window | one scene is connected | which sheet is open, the editor cover, the TV window | that window (SwiftUI), never the shared model |
| view | one view's identity | scroll physics, hover, an animation in flight | the view's `@State`; safe to lose |
| job | one save or render | a pipeline run, its Live Activity, its background download | the job; it ends itself |

What the owner chose (selection, an open sheet, a scroll target) is not view state: it lives in a model keyed by id,
because a fold, a split pane closing, rotation or a tab switch rebuilds views. iPad multi-window is off (no scene
manifest); per-window state is not built until it is wanted.

### Rule 8: SwiftUI owns windows

SwiftUI makes every scene, its delegate and its window. `CobaltAppDelegate` only does what SwiftUI has no API for:
notification taps, the TV screen (`windowExternalDisplayNonInteractive`, `TwitchTVSceneDelegate`), Mac quit and reopen.

- Why: 8.27 returned `connectingSceneSession.configuration` (which names SwiftUI's own scene delegate) and SwiftUI
  forwarded to itself until the stack ran out.
- Enforced: `LifecycleLintTests` rule `scene-config`, no allowlist escape; the TestFlight launch gate.
- Mac windows are found by `NSWindow.identifier` (`MacWindows`), never by title.

### Rule 9: one listener hears the OS

`AppLifecycle.shared` (CobaltKit/Lifecycle) is the only thing that watches the app's notifications (active, resign,
foreground, background, terminate, memory warning, thermal; on the Mac also hide/unhide). The app delegate starts it
before any window exists, so a background wake (a finished download, an intent) is heard too. Process objects conform to
`LifecycleAware` and register once with an order (telemetry, work, liveActivities, media, screens); caches conform to
`Purgeable` and give back memory on background and on a memory warning (never disk). What an event means is one pure
function, `LifecycleRules.apply`, with unit tests.

- Why: 37 places each read scenePhase or a notification, with mixed Will/Did names; the Live Activity resume ran twice;
  scenePhase never fires without a window and misses most Mac events; a memory warning freed nothing.
- Enforced: `LifecycleLintTests` rules `scenePhase` and `app-notification`, with `apple/lifecycle-allowlist.txt` (only
  shrinks).

```swift
// don't
@Environment(\.scenePhase) private var phase
NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, ...)
// do: a view
@Environment(\.lifecycle) private var lifecycle          // a LifecycleSnapshot value
.onChange(of: lifecycle.phase) { ... }
// do: a process object
AppLifecycle.shared.register(self, order: .work)          // func lifecycle(_ event:snapshot:)
AppLifecycle.shared.register(purgeable: self)             // func purge(_ level:)
```

### Rule 10: App and Scene bodies read nothing live

`App.body`, every `some Scene`, and `.commands` builders are part of SwiftUI's dependency graph. They read no
`@Observable` property and write no binding the system also writes (`MenuBarExtra(isInserted:)`). A menu item that
needs live state is a View inside the CommandGroup, observing in its own body. `AppLifecycle` is deliberately not
`@Observable`; the root window view copies its snapshots into the Environment (`publishesLifecycle()`).

- Why: both #113 loops (the menu bar switch written back during the update; `.commands` reading live state).
- Enforced: `LifecycleLintTests` rule `scene-body-read` (a heuristic, with the allowlist).

### Rule 11: `onChange(initial: true)` reads, it never clears

A handler that runs on `initial` runs again whenever SwiftUI re-creates the view. It may load or sync, never reset owner
state; clearing happens only when the value it depends on really changed (compare old and new).

- Why: closing the iPad split pane cleared the library selection and its "…" menu.
- Enforced: `LifecycleLintTests` rule `initial-clear`; `CobaltUITests` (rotate, background and back, pane) in the gate.

### Rule 12: heavy things are pooled

Video players come from `PlayerPool` (a cap on decoders playing at once, paused on background, idle ones freed on a
memory warning). The Twitch web view stops in the background unless the TV window shows it, and is released after
idle minutes. Anything that decodes animation stops in `deinit` too, not only in `onDisappear`.

### Rule 13: prove it by running it

`deploy/apple/testflight.sh` runs `deploy/apple/launch-gate.sh` before every upload: the release build on an iOS 27
simulator (or the Mac app) must still be alive after 15 s and must have written `Caches/launch-ok` (`LaunchMarker`, when
the first window appears), then `deploy/apple/layout-checks.sh` runs the UI checks. `--no-launch-gate` skips it, loudly.

### Prompting with it

Say where a new piece lives: "it lives for the window" (or the process, a view, a job); "it hears the app state from the
listener"; "it takes a player from the pool".

## Adaptive layout, iPhone Duo & Liquid Glass

The app runs on iPhone, iPad, Mac, and **iPhone Duo** (Outer display, Inner Flat, Tabletop folded, Book folded; iOS 27.1+).
These rules ensure every new screen automatically adapts across size classes, vertical-rail toolbars, center folds, and
Liquid Glass without screen-by-screen heroics.

### Rule 14: two size classes, never `userInterfaceIdiom` or orientation locks

Layout branches on `@Environment(\.horizontalSizeClass)` (`.compact` vs `.regular`) and measured view width, never on
`UIDevice.current.userInterfaceIdiom`, fixed orientation locks (`supportedInterfaceOrientations`), or hardware hinge
angles. Never force `.tabBarMinimizeBehavior(.never)` on a `TabView`—the system manages tab minimization and vertical-rail
placement on iPhone Duo.

- Why: iPhone Duo transitions live between `.compact` (Outer) and `.regular` (Inner) while running; idiom checks freeze
  unfolded views in phone chrome, and locking the tab bar collides with the iOS 27.1 trailing Vertical Controls side rail.
- Enforced: `DuoDesignLintTests` rules `[idiom-lock]`, `[tab-bar-lock]`, and `[orientation-lock]` (with
  `apple/duo-design-allowlist.txt` only for non-layout copy/hardware metadata).

```swift
// don't
if UIDevice.current.userInterfaceIdiom == .phone { compactBody }
TabView { ... }.tabBarMinimizeBehavior(.never)
// do
@Environment(\.horizontalSizeClass) private var sizeClass
if sizeClass == .compact { compactBody } else { regularBody }
```

### Rule 15: every toolbar button carries an SF Symbol and survival priority

On iPhone Duo (Outer display and Inner landscape), iOS 27.1 relocates toolbars onto a trailing vertical rail that renders
icons (with titles as tooltips and overflow menu rows) and collapses items bottom-to-top when space tightens.

- Every button inside `ToolbarItem` / `ToolbarItemGroup` MUST provide a `Label(title, systemImage:)`,
  `Button(title, systemImage:)`, or `DuoToolbarButton(title:systemImage:)` — never a text-only `Button("Done")`.
- Mark essential navigation/commit actions (Close, Done, Cancel, Edit, Activity pill) with `.duoVisibilityPriority(.high)`
  and route secondary overflow actions into `DuoOverflowToolbarMenu`.
- Balance toolbar items vs. tabs on the vertical rail with `.duoToolbarCompression(.prefersToolbarItems)` on detail/editor
  screens.
- Place floating bottom banners/buttons with `.safeAreaInset(edge: .bottom)` rather than hardcoded `.padding(.bottom, N)`
  so they automatically clear asymmetric vertical-rail safe areas.
- Enforced: `DuoDesignLintTests` rule `[text-only-toolbar]` (no allowlist escape).

### Rule 16: fold-aware split workspaces (`DuoSplit`) and media HUDs (`DuoMediaOverlay`)

Use `Cobalt/Design/DuoLayout.swift` primitives instead of fixed-width `HStack` splits or ad-hoc `ZStack` media overlays:

- **Two-pane workspaces** (Inspector, Detail, Stage, 7TV, Emote Editor, Crop, Swarm Agent): use `DuoSplit(ratio:)`, which
  wraps SwiftUI's `ArrangementView(.split)` on iOS/macOS 27.1+ and falls back to `horizontalSizeClass` on 26.
- **Full-screen media + HUD** (Full-screen Photo/Video/WebP, Stream, SkyMap): use `DuoMediaOverlay(edge:)`, which wraps
  `ArrangementView(.overlay)` on 27.1+ and exposes `isSeparated` (`\.duoOverlaySeparated` / `overlayArrangementZIndex == 0`)
  so controls float in Clear Liquid Glass when flat and dock onto the adjacent display half when bent.
- **Hard constraint**: never place `TabView` or `NavigationSplitView` inside `ArrangementView`, `DuoSplit`, or
  `DuoMediaOverlay`, and never nest them inside `ScrollView`, `List`, or `Grid`.
- **Custom canvases**: read `DuoReservedRegions.readCompat(from: proxy)` (`.division` / `.occlusion`) and pass
  `activeDivision` into `PanePlacement.resolve` or `DuoDivisionSplit.resolve`.
- Enforced: `DuoDesignLintTests` rule `[arrangement-nesting]` (no allowlist escape).

### Rule 17: even column grids across the center fold (`DuoAdaptiveGrid` / `DuoGrid`)

Any multi-column grid that appears in `.regular` width (or on Mac) MUST snap to an **even** column count (`2, 4, 6, ...`)
so no tile straddles the center fold crease when the display is unfolded or bent in Book mode.

- Use `DuoAdaptiveGrid(minItemWidth:spacing:)` instead of raw `LazyVGrid(columns: [GridItem(.adaptive(...))])`.
- Use `MasonryPlan.duoColumns(..., isRegular:)` for masonry layouts and `DuoGrid.fixedGridItems(compact:regular:sizeClass:)`
  for fixed grids. Never hardcode odd counts (`count: 3`, `count: 5`) in `LazyVGrid`.
- Enforced: `DuoDesignLintTests` rule `[odd-grid-columns]` (no allowlist escape) and `DuoGridTests`.

### Rule 18: Clear Liquid Glass over media, never opaque slabs behind glass

- Over photos, videos, live streams, and full-bleed canvases, use `Cobalt/Design/MediaGlass.swift`:
  `.mediaGlassCapsule()`, `.mediaGlassCircle()`, `.mediaGlassRounded()`, grouped in `MediaGlassGroup` (`GlassEffectContainer`)
  with a subtle `MediaEdgeVignette` behind edge controls and `Metrics.hit` (44 pt) touch targets.
- Never place an opaque `.background(Color..., in: ...)` directly behind `.glassEffect(...)`—it defeats Liquid Glass
  refraction and contrast adaptation.
- Enforced: `DuoDesignLintTests` rule `[opaque-glass-backing]`.

## Adding code: a checklist

1. Does it touch disk, JSON or pixels? It goes in an engine (an actor, or `nonisolated` + `@concurrent`), starts with
   `MainThreadGuard.assertOffMain()` and is wrapped in `EngineClock.measure`.
2. Does it return data to the UI? As a `Sendable, Equatable` snapshot; the model assigns only when it changed.
3. Does a view need it? Pass the values the view draws, not the model.
4. Does it outlive a view, react to the app's state, or hold memory? Name its lifetime, register it with `AppLifecycle`,
   take players from the pool (rules 8 to 12).
5. Does it add a toolbar item, grid, two-pane split, or media overlay? Use `DuoToolbarButton` + `.duoVisibilityPriority`,
   `DuoAdaptiveGrid`, `DuoSplit` / `DuoMediaOverlay`, and `MediaGlassGroup` / `.mediaGlass*` (rules 14 to 18); branch on
   `horizontalSizeClass`, never `userInterfaceIdiom`.
6. Run `cd apple/CobaltKit && swift test` (covers `MainThreadLint`, `LifecycleLint`, `DuoDesignLint`, and `DuoGridTests`).
   If you moved work off main or cleaned a baseline entry, delete its allowlist line; `UPDATE_MAIN_THREAD_ALLOWLIST=1`,
   `UPDATE_LIFECYCLE_ALLOWLIST=1`, and `UPDATE_DUO_DESIGN_ALLOWLIST=1` rewrite each list from the tree while keeping reasons.

