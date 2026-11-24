# CONTRACT-PANE: the screen pane, everywhere (2026-11-23)

> **2026-11-25, compact width (apple 04-PHASE4).** The table below is the iPad's and the Mac's. On a compact width (the iPhone, a narrow iPad window) there is
> no `span`: `pane.span` is not drawn, and the pane stays a `.large` system sheet; a `.fullScreenCover` is never stacked over a
> sheet there. A post opened from the capture tab's recent saves or the library's grid is not opened in the pane at all: it is
> pushed on the tab's navigation stack as the same `MediaDetail` (`MediaDetailRoute`, `.mediaDetailDestination()`), whose actions
> are `PaneActionGrid` (shared with `PanePostPage` through `PostActionKit`, so no action is written twice). A sheet that has to
> follow another sheet waits for its dismissal through `PaneAfterDismiss` / `PresentationSettled` (the two 450 ms sleeps are gone).

Design (approved by Harmony): https://claude.ai/artifact/MPy1z28c1EuAUKjXmmeEdh ("Screen pane everywhere"). Harmony
picked approach 1, the screen pane, **on the left**, and asked for it to be "first class across all suitable surfaces,
not half baked". This contract is the build spec. Where it and the artifact differ, this file wins.

## 1. What it is

One panel per window that opens beside whatever tab you are on. It is always on the **leading (left) side**, on top in
the Duo's tall posture. It has four states:

| state    | Duo open wide              | Duo open tall          | Duo folded / iPhone         | iPad (no hinge)          | Mac                         |
|----------|----------------------------|------------------------|-----------------------------|--------------------------|-----------------------------|
| `hidden` | tab gets both screens      | same                   | tab only                    | tab only                 | tab only                    |
| `screen` | left screen, tab on right  | top screen, tab below  | system `.sheet` `.large`    | 440 pt leading column    | 400 pt column after sidebar |
| `span`   | media left, details right  | media top, details below | `.fullScreenCover`        | whole window, wide shape | whole detail area, wide shape |
| `bar`    | running item as a bar over the tab, above the tab bar (bottom of the detail area on the Mac) | | | | |

Rules:
- **Closing never stops anything.** The xmark, swipe down, Escape and the VoiceOver escape gesture hide the pane. An
  item that is still running (`keepsRunning`) goes to `bar`; anything else goes to `hidden`. Stopping is a control
  inside the page.
- **One pane per window.** Opening an item replaces the current one and keeps `screen` or `span` (from `hidden` or
  `bar` it opens at `screen`). Switching tabs keeps the pane as it is (a stream keeps playing on the left while you
  browse 7TV on the right).
- **Nothing sits on the hinge.** On a Duo the pane's edge is the hinge; no free widths, no drag-to-resize.
- **Postures keep everything:** folding, unfolding, rotating, Stage Manager or window resizing keep the item, the
  state, the playhead and the shelf card. Folded, `screen` becomes the sheet and `span` the cover; unfolding puts them
  back. A drag interrupted by a posture change settles on the nearest state, with a haptic on each snap.
- System moments are never the pane: sign-in (accounts, 7TV login), destructive confirms, alerts, the share sheet,
  the photo picker, file importers. They stay standard sheets/alerts.
- The editors (video editor, emote editor) and settings are not pane areas (see 6).

## 2. Model (CobaltKit, `Sources/CobaltKit/Pane/`, unit tested)

Pure and platform-free so `swift test` covers it.

```swift
public enum PaneState: String, Codable, Sendable { case hidden, screen, span, bar }

public enum PaneItem: Hashable, Codable, Sendable {
    case post(String)            // media item id (library, home, links file, chat result)
    case peek(String)            // library hold-to-peek: same page, opened transiently, closes on release
    case selection               // library select actions page
    case save(String)            // a save run while it runs, then its result
    case link(String)            // share link (ShareSet) id
    case collection(String)
    case emote(String)           // 7TV emote id
    case emoteAddToSet(String)   // 7TV add-to-set flow for an emote id
    case reward(String), poolVideo(String)   // studio
    case stream(String)          // twitch channel login
    case booruPost(Int), booruFilters
    case swarm(String)           // swarm id (+ board)
    case name(String)            // search name id
    case job(String)             // queue job id
    public var keepsRunning: Bool { get }   // stream, save (until done), swarm (running), job (running), studio on air
}

public struct PaneRoute: Codable, Equatable, Sendable {      // what is saved per scene
    public var item: PaneItem?; public var state: PaneState; public var shelf: Int
}

/// The state machine. Every rule in 1 lives here, not in views.
public struct PaneMachine { func open(_:) ; func close(running:) ; func span() ; func unspan() ; func tapBar() }

/// Where the pane goes for a window, from facts only (tested with the Duo, iPhone, iPad and Mac sizes).
public enum PanePlacement: Equatable, Sendable {
    case twoScreens(axis: Axis, hinge: CGFloat)   // Duo open: wide (vertical hinge at x) or tall (horizontal at y)
    case column(width: CGFloat)                   // iPad / Mac / wide window without a hinge
    case compact                                  // one narrow screen: sheet + cover
    public static func resolve(size: CGSize, idiom: Idiom, displayFeatureFrame: CGRect?) -> PanePlacement
}
```

`resolve` rules: a reported display feature (hinge) wins. Without one, until iOS exposes the Duo's hinge: phone idiom
and width >= 700 and height >= 560 is `twoScreens(.vertical, width/2)` (an iPhone in landscape, 874 x 402 or 956 x 440, stays `compact`); phone idiom, width >= 600 and height > width is
`twoScreens(.horizontal, height/2)`; pad or mac and width >= 900 is `column(440 / 400)`; else `compact`. Keep this the
only place that knows device sizes (today's `Spread.minWidth` checks die with the old code).

## 3. App side (`apple/Cobalt/Pane/`, new folder)

- `Pane` (`@MainActor @Observable`), one per scene, injected with `.environment(pane)`; wraps `PaneMachine`, saves
  `PaneRoute` with `@SceneStorage("pane")`, logs `Analytics.event("pane.state", …)` on every state change (state,
  item kind, placement), and a `Breadcrumbs.add("pane.<state>")`.
- `PaneHost` wraps the whole tab content (inside the `TabView`/`PhoneTabs`/Mac detail) and lays out `PanePlacement`:
  two screens (pane leading/top, a hairline on the hinge), column (pane leading, hairline divider), compact (sheet with
  `.presentationDetents([.large])` + drag indicator, or `fullScreenCover` for span). The pane slides in from the leading
  edge with `Motion` spring; under Reduce Motion it cross-fades. The bar uses `tabViewBottomAccessory` on iOS 26+
  (`#available`), a `safeAreaInset(edge: .bottom)` capsule otherwise and on the Mac.
- `PaneDestination`: maps each `PaneItem` to its page view (area lanes register here). A page can push sub-pages inside
  the pane's own `NavigationStack` (filters, add to set).
- Accessibility: the pane is a labelled container ("pane, <title>"); not modal in `screen`, modal
  (`.accessibilityAddTraits(.isModal)`) in `span`; reading order pane first. `accessibilityAction(.escape)` closes.
- Keyboard: Escape closes, ⌘⇧F span/unspan, ⌘[ / ⌘] shelf back/next. Hover names on icon buttons (Mac and iPad).
- Drag and drop: pages expose their item as `Transferable` (post, emote, file); areas already accepting drops keep
  them. A drag held over a hidden pane's leading edge for 0.6 s peeks the pane open at `screen`.
- Deep links (`AppLinks`) and Shortcuts that open a single item now call `pane.open(...)` instead of pushing.

## 4. The content primitive: `PanePage` (`apple/Cobalt/Pane/PanePage.swift`)

```swift
PanePage(title:, subtitle:, actions: [PaneAction] /* <= 2 icon buttons */) {
    hero      // media: bleeds under the header (tall), left half (wide), its own screen (split)
} controls: {
    // the one thing you do: transport, live controls, progress + stop, PaneActionGrid, or a form
} body: {
    // optional scrolling content (a link's files, a swarm board, booru tags); omitted for simple items
} shelf: {
    PaneCard("transcript") { … }; PaneCard("links") { … }
}
```

- The header is drawn by the pane, never by the page: span button leading, context label centred, `more` and the xmark
  trailing, 44 pt glass circles (`CloseButton` style, top-right closes per house style). Pages never draw a close.
- `@Environment(\.paneShape)`: `.tall`, `.wide`, `.split(.media | .details)`, `.bar`. The page arranges the same slots per
  shape; the bar is title + subtitle + thumb + one control + hairline progress.
- `PaneActionGrid`: **a 2×2 grid of big buttons** (Harmony, artifact comment 2026-11-23): each about 96 pt tall, large
  icon top-leading, bold label bottom-leading, filled `CobaltColor` glass. Up to 4 actions; more go in `more`.
- Shelf: paged one card at a time with dots in `.tall`/`.wide`, stacked on the details screen in `.split`.
- Dynamic Type: title wraps to 2 lines; at accessibility sizes the action grid becomes a list and the hero shrinks.
- Loading shows a placeholder in the page's own shape; a deleted item shows a one-line gone state with one action
  (close); offline keeps what is loaded and dims actions that need the server.
- Copy in `Design/Copy+Pane.swift`, symbols in `Symbol.Pane`, lowercase house style.

## 5. Areas (what opens in the pane)

| area | item(s) | span shows | bar | replaces today's |
|---|---|---|---|---|
| library | `post`, `peek`, `selection` | the post across both screens | no | on the iPhone and a folded Duo too (Harmony, 2026-11-23: pane everywhere; the zoom push goes, a hold previews and opens the pane on release) · `LibraryInspector` (`.inspector`), `library-peek` pane, select pill pane, `LibrarySelectPill` spreadSheets |
| home (save) | `post`, `save` | post | save while running | `.inspector` `InspectorColumn` |
| links | `link`, `collection` | gallery files across both | no | `DetailSplit` in LinksScreen |
| 7tv | `emote`, `emoteAddToSet` | emote + variants | no | `spreadSheet` add-to-set (login stays a sheet) |
| studio | `reward`, `poolVideo` | canvas preview + controls | while on air | (new) |
| twitch | `stream` (player in hero, chat on the shelf / details screen) | player left, chat right | keeps playing | TwitchWatchView taking over the tab; the channel list stays the tab's main view |
| booru | `booruPost`, `booruFilters` | the picture | no | `spreadSheet` post + filters |
| chat | `post` for anything the AI made (videos, renders, posts) | the made thing | while a chat job runs | `DetailSplit` in ChatScreen: the thread list pushes the conversation in the tab's own stack; the conversation is never the pane |
| swarms | `swarm` | results grid + messages | while running | `DetailSplit` in SwarmsScreen |
| names | `name` | n/a | no | push to NameEditorScreen |
| queue | `job` | n/a | while running | the queue sheet's job rows |

Not pane areas: video editor and emote editor (full-screen tasks, `EditorPresenter` stays), settings (standard list),
sign-in/confirms/share/photo picker (system).

## 6. What gets deleted

`Screens/Duo/SidePanel.swift`, `Screens/Duo/SpreadPane.swift` (SpreadPaneHost, spreadSheet, SpreadColumns,
SpreadPaneColumn, SpreadPaneView, SpreadTopRow, panelClose, panelDrawsOwnClose, SheetOrPaneDismiss's pane half),
`DetailSplit`, `LibraryInspector`, the home `.inspector`, `Spread.minWidth`/`isSpread` checks, `hingeEdge`. `HingeSeam`'s
job light moves into `PaneHost`'s hinge hairline. Nothing may keep calling the old API when the work is done
(`grep -r "spreadSheet\|SpreadPane\|DetailSplit\|panelClose\|isSpread" apple/` is empty).

## 7. Gates

- `cd apple/CobaltKit && swift test` green (new `PaneMachineTests`, `PanePlacementTests`, `PaneRouteCodingTests`),
  except the known flaky tests listed in project memory.
- iOS and Mac builds (CLAUDE.md commands) green with no new warnings in `Pane/`.
- UI test `PaneTests` (CobaltUITests): on an iPad simulator in landscape (column), iPhone (compact) and the Mac, for
  library, links, booru, swarms and twitch: open, span, unspan, close; a running item closes to the bar and the bar
  reopens it; relaunch restores the pane. Screenshots of each to `apple/.build/pane-shots/`.
- `grep` in 6 is empty.
- Previews: `#Preview` for `PanePage` in every shape and for each area's page, on `PreviewClient` data.
