# Apple app architecture: the main thread is display-only (8.17)

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

## Adding code: a checklist

1. Does it touch disk, JSON or pixels? It goes in an engine (an actor, or `nonisolated` + `@concurrent`), starts with
   `MainThreadGuard.assertOffMain()` and is wrapped in `EngineClock.measure`.
2. Does it return data to the UI? As a `Sendable, Equatable` snapshot; the model assigns only when it changed.
3. Does a view need it? Pass the values the view draws, not the model.
4. Run `cd apple/CobaltKit && swift test --filter MainThreadLint`. If you moved work off main, delete its allowlist
   line; `UPDATE_MAIN_THREAD_ALLOWLIST=1` rewrites the list from the tree and keeps every reason.
