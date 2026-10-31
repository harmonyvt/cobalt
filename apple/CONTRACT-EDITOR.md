# capystore for apple: the editor (owner request 2026-10-20, plan approved the same day)

The app half of `deploy/cloudflare/APP-API-CONTRACT.md` section 31 (read 31.2 to 31.6 first: the timeline, its timing, its
geometry and the order of operations are pinned there and this file builds the same picture on the device). Owner, 2026-10-20: "a
new editor experience for mobile and Mac ... recreating Premiere Pro. Combine videos, crop videos, shrink the start and end time,
speed up videos, overlay videos, and then Cloudflare would process those videos. And there'll be new videos." Approved boards
(session scratchpad `editor/project/`): `Main.dc.html` (**Mac A**: Mac and iPad), `PhoneA.dc.html` (**iPhone A**),
`PhoneTrim.dc.html` (iPhone A's crop, speed and trim sheet). `MacFocus`, `MacStory`, `PhoneB`, `PhoneC` were rejected.

Lanes build to exactly this. If something here is impossible, stop and report instead of improvising.

## 0. Settled (the owner's plan; not reopened)

- v1: main track of library videos (add, drag to reorder, trim in/out, split at the playhead, crop per clip with free, 9:16, 1:1, 4:5,
  16:9, speed 0.25x to 4x with pitch kept, volume and mute per clip); one overlay track (a video, GIF or photo with start, length,
  position, size, opacity, volume); canvas 9:16, 1:1 or 16:9, up to 1080p, 30 or 60 fps; H.264 MP4.
- Projects live on the server (open on iPhone, continue on Mac). A render keeps going with the app closed; the result is a new,
  **private** library item with a poster; it shows in the Queue while it renders; the owner is told when it is done.
- Not v1 (no control, no field): text, transitions, keyframes, filters, a music track, more overlay tracks, 4K, rotate/flip, speed
  ramps. Limits: ≤ 10 min, ≤ 50 clips.
- Entry: library select videos → `edit`; an `edits` shelf in the library lists saved projects. iPad uses the Mac layout. Copy is
  lowercase; the app is "capystore".

## 1. Decisions made in this contract (not the owner's; flagged for review)

1. **Main track takes videos only; GIFs and photos go on the overlay.** The plan's main track is "library clips" and its overlay is
   "a video, GIF or photo". AVFoundation cannot put a GIF or a still in a composition track, so keeping them overlay-only keeps the
   preview honest. Picking photos or GIFs with `edit` says they were left out (copy `leftOut`).
2. **Crop and fit are two rows.** The Mac board's crop row reads `fill · 9:16 · 1:1 · free`; the plan lists free, 9:16, 1:1, 4:5,
   16:9, and the server needs fit vs fill. So: crop `full · free · 9:16 · 1:1 · 4:5 · 16:9` and below it `fill · fit`
   (default `fill`, as the board shows selected).
3. **A GIF overlay loops** for as long as the overlay stays up; a photo holds. A video overlay has no speed control.
4. **Overlay audio starts muted** (`muted: true`, volume 1): an overlay rarely wants its own sound over the main track.
5. **Notification = Hark**, not APNs: the server has no alert push (section 8 is Live Activities only). The app sends
   `notify: true` with every render when `features.notify_bridge`; the message opens the queue.
6. **The Mac editor is its own window** (`Window("editor", id: "editor")`, one at a time); iPad and iPhone present it full screen.
   The Mac A board is a whole 1280×800 window and its keyboard shortcuts need a window of their own.
7. **Autosave, no save button**: 1 s after the last change; conflicts are settled by `base_revision` (31.12).
8. **No undo in v1** (not on the plan's list). Delete of a clip is one key; see owner question 1.
9. Copy and symbol files live in `apple/Cobalt/Design/` (house location), owned by lane 5.

## 2. Files and lanes (exactly the plan's split; lanes never commit or push)

| lane | owns (new) | must also touch (existing; only what is named) |
|---|---|---|
| 4 kit (sonnet) | `apple/CobaltKit/Sources/CobaltKit/Editor/**`, `apple/CobaltKit/Tests/CobaltKitTests/Editor*Tests.swift` | `Models/Server.swift` (`editor` flag, three limits), `API/HTTPCobaltClient.swift` (decode those four values; the calls themselves go in `Editor/HTTPCobaltClient+Editor.swift`), `Preview/PreviewClient.swift` (one stored `editorState` and its seed), `Models/AppModel.swift` (the `PreviewScenario` cases of 3.8, `public let editor: EditorStore`, its init line, `editor.capabilitiesChanged()` in `apply`), `Models/QueueWire.swift` (`edits`), `Jobs/UnifiedQueue.swift` (the merge of section 6), `Models/AppModel+Queue.swift` (open and cancel for `.edit`) |
| 5 mac + ipad (sonnet) | `apple/Cobalt/Screens/Editor/**` except `Phone/` (the shared timeline views included), `apple/Cobalt/Design/Copy+Editor.swift`, `apple/Cobalt/Design/Symbols+Editor.swift` | `Screens/Library/LibrarySelectPill.swift` (one `EditPicksButton(...)` in the action row), `Screens/Library/LibraryShelves.swift` (one `LibraryEditsShelf(...)` line and one `||` in `hasContent`), `App/AppShell.swift` (one `.modifier(EditorPresenter(model:))`), `App/CobaltApp.swift` (macOS: one `EditorWindow(model:)` scene in `body`), `Screens/Queue/QueueScreen.swift` (the row for `.edit`) |
| 6 iphone (sonnet) | `apple/Cobalt/Screens/Editor/Phone/**` | none |

The plan said lane 4 owns only `Editor/`: the capability flag, the preview scenarios, the store on `AppModel` and the queue merge
cannot be reached from a new folder alone, hence the short list above. Lane 4 lands first (or together with 5 and 6): adding
`QueueItem.Kind.edit` breaks `QueueScreen`'s exhaustive switch until lane 5 adds the row.

## 3. CobaltKit public API (pinned; lanes 5 and 6 build against exactly this)

### 3.1 The timeline (`Editor/EditTimeline.swift`), byte for byte section 31.2

```swift
public struct EditTimeline: Sendable, Equatable, Codable {
    public var version: Int                 // 1
    public var canvas: EditCanvas
    public var main: [EditClip]
    public var overlay: [EditOverlay]
    public static func new(canvas: EditCanvas, main: [EditClip]) -> EditTimeline   // version 1, overlay []
}
public struct EditCanvas: Sendable, Equatable, Codable {
    public var w: Int, h: Int, fps: Int
    public enum Shape: String, Sendable, CaseIterable { case story = "9:16", square = "1:1", wide = "16:9" }
    public enum Resolution: Int, Sendable, CaseIterable { case p720 = 720, p1080 = 1080 }   // the short side
    public init(shape: Shape, resolution: Resolution, fps: Int)   // 9:16 1080 → 1080×1920, 16:9 720 → 1280×720, …
    public var shape: Shape { get }  public var resolution: Resolution { get }
    public static func forFirstVideo(width: Int, height: Int) -> EditCanvas   // 31.2.1: h > 1.1w → story; w > 1.1h → wide; else square; 1080, 30
    public static let fpsChoices = [30, 60]
}
public struct EditClip: Sendable, Equatable, Codable, Identifiable {
    public var id: String                   // "c" + 8 base62 (EditID.mint())
    public var item: String                 // library file id (16 base62)
    public var `in`: Double, out: Double    // source seconds
    public var speed: Double                // 0.25...4, step 0.05
    public var crop: EditCrop?              // nil = whole frame (omitted from the JSON)
    public var fit: EditFit                 // .fill
    public var volume: Double               // 0...1
    public var muted: Bool
    public static func added(item: String, duration: Double) -> EditClip   // 31.2.1 defaults
}
public struct EditCrop: Sendable, Equatable, Codable {
    public enum Aspect: String, Sendable, Codable, CaseIterable { case free, story = "9:16", square = "1:1", portrait = "4:5", wide = "16:9" }
    public var aspect: Aspect
    public var x: Double, y: Double, w: Double, h: Double   // fractions of the DISPLAY frame
    /// The largest centred rectangle of `aspect` in a source of this display size (free = the whole frame).
    public static func centred(_ aspect: Aspect, display: CGSize) -> EditCrop
}
public enum EditFit: String, Sendable, Codable, CaseIterable { case fill, fit }
public struct EditOverlay: Sendable, Equatable, Codable, Identifiable {
    public var id: String, item: String
    public var at: Double                   // output seconds
    public var `in`: Double, out: Double    // video: source seconds; gif/photo: 0 and the length
    public var frame: EditFrame
    public var opacity: Double              // 0.1...1
    public var volume: Double
    public var muted: Bool                  // true by default
    public static func added(item: String, kind: EditSourceKind, duration: Double?, at: Double, remaining: Double) -> EditOverlay
}
public struct EditFrame: Sendable, Equatable, Codable { public var x: Double, y: Double, w: Double }   // canvas fractions

public enum EditJSON {
    /// Canonical bytes (31.2): values rounded (times 0.001, speed to 0.05 then 2 decimals, volume/opacity 0.01, fractions 0.0001),
    /// `JSONEncoder` with `.sortedKeys`, no whitespace, nil `crop` omitted.
    public static func encode(_ t: EditTimeline) throws -> Data
    public static func decode(_ data: Data) throws -> EditTimeline
    public static func rounded(_ t: EditTimeline) -> EditTimeline
}
public enum EditID { public static func mint() -> String }   // "c" + 8 base62, unique enough within one timeline
```

Test: `EditJSON.encode(decode(fixture))` equals the fixture bytes for `deploy/cloudflare/editor/helper/test/fixtures/timeline-beach.json`
(copied into `Tests/CobaltKitTests/Fixtures/Editor/` by lane 4, with the timing and geometry fixtures).

### 3.2 Timing, geometry, validation (`Editor/EditTiming.swift`, `EditGeometry.swift`, `EditValidation.swift`)

```swift
public enum EditMath { static func roundHalfUp(_ x: Double) -> Int   // Int(floor(x + 0.5 + 1e-9))
                       static func evenNearest(_ x: Double) -> Int; static func evenFloor(_ x: Double) -> Int }
public struct EditTiming: Sendable, Equatable {       // 31.4, the same numbers as timeline.js `timing`
    public struct Clip { id: String; start: Int; frames: Int; speed: Double; samples: Int }   // speed = effective speed s_i
    public var fps: Int; frames: Int; seconds: Double; main: [Clip]; overlay: [Clip]
    public init(_ t: EditTimeline)
    public func time(ofFrame k: Int) -> Double      // k / fps
    public func frame(at seconds: Double) -> Int    // roundHalfUp(seconds × fps), clamped to 0...frames-1
    public func clip(atFrame k: Int) -> (index: Int, offset: Int)?
    public func sourceTime(clip i: Int, offset k: Int, in t: EditTimeline) -> Double   // in_i + k / fps × s_i
}
public enum EditGeometry {                            // 31.6, integer pixels
    public struct Main: Sendable, Equatable { crop: PixelRect; scaled: PixelSize; place: PixelPoint }
    public static func main(display: PixelSize, crop: EditCrop?, fit: EditFit, canvas: EditCanvas) -> Main?   // nil: crop < 64 px
    public static func overlay(display: PixelSize, frame: EditFrame, canvas: EditCanvas) -> PixelRect
    public static func overlayHeightFraction(display: PixelSize, frame: EditFrame, canvas: EditCanvas) -> Double   // h of 31.2
    public static func clampInside(_ frame: EditFrame, display: PixelSize, canvas: EditCanvas) -> EditFrame
    public static func cropPixels(_ crop: EditCrop, display: PixelSize) -> PixelRect?   // section 10 cropToPixels
}
public struct PixelSize: Sendable, Equatable { w: Int; h: Int }  // PixelPoint { x, y }, PixelRect { x, y, w, h }
public enum EditProblem: Sendable, Equatable {        // the server's codes and paths (31.12), same rules as parseTimeline/checkSources
    case canvas, empty, tooManyClips, tooLong, range(path: String), overlayOverlap(path: String), overlayPastEnd(path: String),
         sourceMissing([String]), notVideo([String]), unsupportedSource([String]), pastSourceEnd(path: String)
    public var code: String { get }   // "error.edit.range", …
    public var path: String? { get }
}
public enum EditValidation { public static func check(_ t: EditTimeline, sources: [String: EditSource]) -> [EditProblem] }   // [] = ok
```

### 3.3 The preview composition (`Editor/EditComposition.swift`, `EditCompositor.swift`)

```swift
public struct EditPlayable: @unchecked Sendable {
    public let composition: AVComposition
    public let videoComposition: AVVideoComposition   // renderSize W×H, frameDuration 1/fps, customVideoCompositorClass EditCompositor,
                                                      // colorPrimaries/transfer/YCbCr matrix = ITU-R 709 (SDR, as the server)
    public let audioMix: AVAudioMix
    public let timing: EditTiming
    public func playerItem() -> AVPlayerItem          // audioTimePitchAlgorithm = .spectral, videoComposition, audioMix set
}
public enum EditComposition {
    /// Builds exactly 31.5: main clips back to back on one video and one audio track, each inserted from `in` to `out` and scaled
    /// with `scaleTimeRange` to frames_i / fps; each video overlay on a second video track (+ audio track) at ostart / fps; GIFs and
    /// photos have no track (the compositor draws them). Sources without an audio track get none (silence). Throws `EditError.source`
    /// for a clip whose file is not ready.
    public static func build(_ t: EditTimeline, assets: [String: EditSourceAsset]) async throws -> EditPlayable
}
public final class EditCompositor: NSObject, AVVideoCompositing { }   // per frame: 31.5's steps with Core Image, geometry from EditGeometry
public enum EditSourceAsset: @unchecked Sendable {
    case video(AVURLAsset, display: PixelSize, hasAudio: Bool)
    case gif(frames: [CGImage], delays: [Double], display: PixelSize)   // decoded once with ImageIO; looped (31.5)
    case photo(CGImage, display: PixelSize)                             // EXIF orientation applied
}
```

The compositor draws, per output frame: black canvas → the main clip's frame (preferredTransform, crop, scale with Lanczos, place) →
the overlay's frame at its rect with alpha × opacity. The instructions carry the timeline and timing; `requiredSourceTrackIDs` are
the tracks active in that range. Parity with the server is lane 8's check (31.5 "Parity").

### 3.4 Sources on the device (`Editor/EditSourceCache.swift`)

```swift
public actor EditSourceCache {
    /// A local file for the library file: the offline store's copy when it is kept on this device, else a download through
    /// `client.download(.libraryItem(id:), to:)` into Caches/editor/<id>.<ext>. Least recently used files go past 2 GB.
    public func asset(for source: EditSource) async throws -> EditSourceAsset
    public func progress(for id: String) -> Double?    // 0...1 while downloading
    public func cancelAll()
}
```

### 3.5 Server shapes and calls

```swift
extension Capabilities {                    // Models/Server.swift (lane 4's short list)
    public var editor: Bool                 // features.editor
}
extension Capabilities.Limits { public var editMaxSeconds: Double /* 600 */; public var editMaxClips: Int /* 50 */; public var editMaxProjects: Int /* 200 */ }

public enum EditSourceKind: String, Sendable, Codable { case video, gif, photo, unsupported }
public struct EditSource: Sendable, Equatable, Identifiable { id, name, kind, contentType?, width?, height?, duration?, bytes?, posterURL?, available }
public struct EditProject: Sendable, Equatable, Identifiable {
    id, title, revision: Int, timeline: EditTimeline?  /* nil in a summary */, canvas: EditCanvas, duration: Double, clipCount: Int,
    coverURL: URL?, createdAt: Date, updatedAt: Date, render: EditRender?
}
public struct EditRender: Sendable, Equatable, Identifiable {
    public enum Status: String, Sendable { case queued, preparing, rendering, finishing, done, error, cancelled }
    id, projectID, revision, title, status, queueAhead: Int?, progress: Double?, secondsDone: Double?, secondsTotal: Double,
    error: String?, itemID: String?, posterURL: URL?, bytes: Int64?, width: Int?, height: Int?, duration: Double?,
    cancelRequested: Bool, createdAt: Date, startedAt: Date?, finishedAt: Date?
    public var isActive: Bool { get }       // queued, preparing, rendering, finishing
}
public enum EditError: Error, Sendable, Equatable {
    case off, notFound, conflict(EditProject), tooMany, queueFull, finished, tooLarge,
         invalid(EditProblem), offline, unavailable, other(String)
    public init(code: String, path: String?, items: [String], project: EditProject?)   // error.edit.* → case
}

/// The editor's routes (31.12). `HTTPCobaltClient` and `PreviewClient` conform (in Editor/); `EditorStore` reaches it as
/// `ctx.client as? EditorClient` and treats a client that is not one like `features.editor` false.
public protocol EditorClient: Sendable {
    func editProjects() async throws -> [EditProject]                                                        // GET /edits
    func createEditProject(title: String?, timeline: EditTimeline) async throws -> EditProject               // POST /edits
    func editProject(id: String) async throws -> (EditProject, [String: EditSource])                       // GET /edits/<id>
    func saveEditProject(id: String, timeline: EditTimeline, baseRevision: Int, title: String?) async throws -> EditProject   // PUT
    func renameEditProject(id: String, title: String) async throws -> EditProject                           // PATCH
    func deleteEditProject(id: String) async throws                                                         // DELETE
    func renderEdit(id: String, revision: Int, notify: Bool) async throws -> EditRender                     // POST …/render
    func editRenders(limit: Int) async throws -> [EditRender]                                              // GET /edits/renders
    func editRender(id: String) async throws -> EditRender                                                 // GET /edits/renders/<rid>
    func cancelEditRender(id: String) async throws -> EditRender                                           // DELETE /edits/renders/<rid>
}
```

All throw `EditError` for the server's refusals (`409 error.edit.conflict` → `.conflict(project)` with the server's current
project).

### 3.6 Stores (`Editor/EditorStore.swift`, `Editor/EditSession.swift`)

```swift
@MainActor @Observable public final class EditorStore {        // AppModel.editor
    public enum ListState: Equatable { case idle, loading, loaded, failed(EditError) }
    public private(set) var projects: [EditProject]           // summaries, newest updated first
    public private(set) var listState: ListState
    public private(set) var renders: [EditRender]             // this key's recent renders (list + the ones this device started)
    public var session: EditSession?                          // the open project; the presenters show the editor while non-nil
    public var isAvailable: Bool { get }                      // capabilities.editor and the client is an EditorClient
    public func refresh() async                               // GET /edits (+ GET /edits/renders?limit=20)
    /// `edit` in the library: the picks' videos in tap order (each post's original video; a gallery's video items in item order),
    /// a new project (31.2.1), then opens it. Returns what was left out (photos, gifs, posts with no server copy).
    public func create(from picks: [MediaItem]) async throws(EditError) -> EditLeftOut
    public func open(_ projectID: String) async throws(EditError)
    public func close() async -> Bool                          // flushes the autosave (≤ 3 s); false = unsaved changes remain
    public func rename(_ projectID: String, to title: String) async throws(EditError)
    public func delete(_ projectID: String) async throws(EditError)
    public func cancel(render id: String) async throws(EditError)
    public func render(_ id: String) -> EditRender?
    func capabilitiesChanged()
}
public struct EditLeftOut: Sendable, Equatable { public var photosAndGifs: Int; public var notOnServer: Int }

@MainActor @Observable public final class EditSession {
    public enum Tool: String, CaseIterable { case select, blade, crop }
    public enum SaveState: Equatable { case saved, saving, unsaved, failed(EditError), conflict(EditProject) }
    public enum Selection: Equatable { case none, main(String), overlay(String) }   // clip ids
    public private(set) var project: EditProject
    public private(set) var timeline: EditTimeline          // every edit goes through the methods below (validated, rounded)
    public private(set) var sources: [String: EditSource]
    public private(set) var timing: EditTiming
    public private(set) var problems: [EditProblem]
    public private(set) var saveState: SaveState
    public private(set) var loadingSources: [String: Double] // file id → download progress
    public var selection: Selection
    public var tool: Tool
    public let player: AVPlayer                              // rebuilt (EditComposition) 150 ms after the timeline settles; keeps the playhead
    public private(set) var playhead: Int                    // output frame
    public private(set) var isPlaying: Bool
    public private(set) var activeRender: EditRender?        // the newest render of this project
    // transport
    public func play(); func pause(); func togglePlay(); func seek(frame: Int); func step(frames: Int); func shuttle(_ rate: Double)
    // main track
    public func add(_ files: [EditSource], at index: Int?)   // videos only; nil = the end
    public func move(clip id: String, to index: Int)
    public func trim(clip id: String, in: Double?, out: Double?)          // source seconds, clamped to 0...duration and 0.1 s minimum
    public func setIn(atPlayheadFor id: String); func setOut(atPlayheadFor id: String)   // I and O
    public func splitAtPlayhead()                            // splits the main clip under the playhead (both halves keep every setting)
    public func split(clip id: String, atFrame k: Int)
    public func remove(_ selection: Selection)
    public func setSpeed(_ speed: Double, clip id: String)
    public func setCrop(_ crop: EditCrop?, clip id: String)
    public func setFit(_ fit: EditFit, clip id: String)
    public func setVolume(_ v: Double, clip id: String); func setMuted(_ m: Bool, clip id: String)
    // overlay
    public func addOverlay(_ file: EditSource, atFrame k: Int?)          // nil = the playhead; refuses (returns false) when it would overlap
    public func moveOverlay(id: String, toFrame k: Int)                  // clamped between its neighbours and the end
    public func setOverlayLength(id: String, seconds: Double)
    public func trimOverlay(id: String, in: Double?, out: Double?)       // video overlays
    public func setOverlayFrame(id: String, _ frame: EditFrame)          // clamped inside the canvas
    public func setOverlayOpacity(id: String, _ v: Double); func setOverlayVolume(id: String, _ v: Double); func setOverlayMuted(id: String, _ m: Bool)
    // canvas, title, render
    public func setCanvas(_ c: EditCanvas)
    public func rename(_ title: String)
    public func render() async throws(EditError) -> EditRender           // saves first (flush), then POST …/render with notify = notifyBridge
    public func resolveConflict(keepMine: Bool) async                    // keep mine: PUT with the server's revision; theirs: reload
    public func retrySave() async
}
```

Rules the views rely on: autosave runs 1 s after the last change (one PUT in flight; a change during it queues the next); `saved` shows
only when the server has the current revision; a `409` becomes `.conflict(serverProject)` and stops autosave until resolved; offline
or `503` → `.failed`, retried at 2, 5, 10, 30 s while the editor is open. Render progress for `activeRender` is polled every 3 s while
the editor is open and the app is active, else follows `EditorStore`'s queue polling (section 6).

### 3.7 Queue (`Models/QueueWire.swift`, `Jobs/UnifiedQueue.swift`)

```swift
extension QueueSnapshot { public var edits: [EditRender]? }     // `edits` (31.13); nil = absent, null or malformed
// isActive also true while any edit render isActive
extension QueueItem.Kind { case edit(EditRender) }              // a new case
extension QueueDestination { case edit(projectID: String) }     // a new case; `.media(itemID)` opens a done render's video
```

### 3.8 Previews (`Editor/PreviewEditor.swift`, `Editor/PreviewEditorMedia.swift`)

- `PreviewScenario` gains `editorEmpty`, `editorRendering`, `editorRenderFails`, `editorConflict`, `editorFail`. `.happy` and
  `.renditions` have `features.editor` and two projects: **"beach day edit"** (9:16, 1080p · 30: main `pier.mp4` 0:00-0:12,
  `surf.mp4` 0:02-0:08.75 at 1.5×, `sunset.mov` with a 9:16 crop, `friends.mp4`; overlay `dance.gif` at 0:03 for 3 s at
  `x 0.6 y 0.05 w 0.35`; 0:26, 4 clips + 1 overlay, the Mac A board) and **"cat compilation"** (16:9, 720p · 60, 6 clips, a finished
  render with a poster). `.editorEmpty`: no projects. `.editorRendering`: rendering "beach day edit" moves queued → preparing →
  rendering 0-100 % → done in about 20 s (scaled by `timeScale`), then a new private library item appears. `.editorRenderFails`: the
  render ends `error.edit.render_failed` at 60 %. `.editorConflict`: the first save answers `409` with revision + 1 and a different
  title ("beach day (iphone)"). `.editorFail`: `GET /edits` answers 503.
- The preview sources are real local files: `PreviewEditorMedia` writes small H.264 clips with `AVAssetWriter` once per run into a
  temp folder (the board colours `#3b5b73`, `#6d4f3a`, `#3f6b4f`, `#6b3f4a`, a frame counter and a 1 kHz tone, the board durations,
  one of them 1080×1920 with a 90° rotation flag, one without audio), a 12-frame GIF and a PNG, so the composition and the compositor
  run in previews and tests with no network.
- `AppModel.previewEditor(_ scenario: PreviewScenario = .happy, open: String? = nil) -> AppModel` opens a project directly (the
  screens' `#Preview`s use it). A `-previewEditor <scenario>` launch argument (debug builds) is read by lane 5's `EditorPresenter`
  itself, not by `DebugHooks.swift`.

## 4. Screens

### 4.1 Entry points

- **Library select** (`LibrarySelectPill`): with `model.editor.isAvailable`, the action row gets `edit` (`EditPicksButton`, lane 5;
  `Symbol.Editor.edit`) after `make link`/`collection` and before `share`. On iPhone the three existing buttons already fill the
  row, so `edit` is icon-only there (`labelStyle(.iconOnly)`, label still read by VoiceOver) and titled elsewhere. Enabled when at
  least one pick has a video on the server; the pill's line then reads `editLine`. Tap: `editor.create(from:)` → the editor opens on
  the new project; a spinner on the button while it creates (`creating`); failure → the pill's line shows `couldntCreate`. Photos,
  GIFs and posts with no server copy are left out with `leftOut(n)` shown in the editor's first toast.
- **Edits shelf** (`LibraryEditsShelf`, lane 5, inside `LibraryShelves`): shown when `isAvailable` and `projects` is not empty, while
  not selecting or searching (the shelves' rule), above the links. Header `edits` + count; cards newest first (all of them, scrolling):
  cover (the first clip's poster, canvas-shaped, 9:16 cards 96 pt tall), title (one line), `0:26 · 4 clips`, `edited 2 h ago`, and a
  badge for the newest render: `rendering 40%` / `waiting` / `rendered` / `render failed`. Tap opens; context menu: `open`,
  `rename…`, `delete…` (confirm `deleteTitle` / `deleteBody`, destructive `delete`). The library refreshes the store when it appears
  and on pull to refresh.
- A Hark message opens the queue (`cobalt-apple://jobs`); the edit's row there opens the video or the project (section 6).

### 4.2 Presentation and layout choice

- `EditorPresenter` (AppShell modifier): while `editor.session != nil`, iOS shows `EditorRoot` in a `fullScreenCover`; macOS opens the
  `editor` window (`openWindow(id: "editor")`) and the window's content is `EditorRoot`; closing the window calls `editor.close()`.
- `EditorRoot` picks **`EditorScreen`** (lane 5, Mac A) on macOS and on iPad when the width is ≥ 900 pt and the size class is
  regular, else **`EditorPhoneScreen`** (lane 6). Rotating or resizing across 900 pt switches layouts and keeps the session.
- Close: `close` (iOS) / the window's close (Mac) → `editor.close()`; if it returns false: `closeUnsavedTitle` / `closeUnsavedBody`,
  `keepEditing` (cancel) and `closeAnyway` (destructive). A running render never blocks closing (`closeRendering` toast once).

### 4.3 Mac and iPad: `EditorScreen` (Mac A board; lane 5)

Grid: top bar 48 pt; middle = library bin 236 pt | preview | inspector 272 pt; timeline 268 pt (resizable by its top edge, 180-480).
Colours from `Cobalt/Design` tokens; selection blue `#2f8af9` (`CobaltColor.linkBlue`); overlay amber `#f5a524` is
`EditorColor.overlay` in lane 5's own `Screens/Editor/EditorColors.swift` (`Tokens.swift` is not touched).

- **Top bar**: title (click to rename inline: return saves, esc cancels; empty reverts); the save line (`saveLine(state, clips,
  duration)`: `saved · 4 clips · 0:26`, `saving…`, `not saved · retrying`, `changed on another device`); tools segmented `select` ·
  `blade` · `crop` (V, B, C); divider; canvas menu (`9:16`, `1:1`, `16:9`); quality menu (`1080p · 30`, `1080p · 60`, `720p · 30`,
  `720p · 60`); `render` (primary; while a render of this project runs it reads `rendering 40%` and opens the render popover).
- **Library bin**: `library`, hint `drag in`; search field `search the library` (filters the loaded library by title, the same local
  filter as the library tab); a 2-column grid of the library's videos, GIFs and photos (posters; badge `0:12`, `gif`, `photo`). Drag a
  video onto the main track (insertion point shown as a blue bar) or a video/GIF/photo onto the overlay lane; double-click (Mac) or
  tap `+` on the tile (iPad) appends a video to the main track, puts a GIF/photo on the overlay at the playhead. Unsupported files
  (webm, mkv, heic, webp) are dimmed with the badge `can't edit`; a drop of one shows `cantEdit`. Empty library: `binEmpty`.
- **Preview**: the canvas at its aspect, as large as fits, black around it; the overlay drawn with an amber outline when selected:
  drag inside to move, drag the corner handles to resize (aspect kept), both clamped inside the canvas; with the `crop` tool and a
  main clip selected the preview shows that clip's source with the crop frame (corner and edge handles, drag inside to move, aspect
  locked unless `free`, dimmed outside) and `done` / `reset` buttons under it. While sources download: the canvas shows
  `loadingSources(pct)`; a missing source shows `missingClip` over its frames. Transport under it: current `0:09.0`, `back one frame`,
  play/pause, `forward one frame`, total `0:26.0`.
- **Inspector** (selection-driven):
  - main clip: `clip 2` + `surf.mp4 · 1080×1920`; **trim** `in` / `out` fields (editable `m:ss.cc`, ↑/↓ = one frame, ⇧ = 1 s);
    **speed** segmented `0.5×` `1×` `1.5×` `2×` + a log slider 0.25×-4× (step 0.05) and `becomes(4.5)` `· pitch kept`;
    **crop** segmented `full` `free` `9:16` `1:1` `4:5` `16:9` (3 × 2), `edit crop` (switches to the crop tool), then **fit**
    segmented `fill` `fit`; **volume** slider 0-100 % with a mute toggle; `split at playhead`, `delete clip` (destructive).
  - overlay: `overlay` + `dance.gif · 480×480`; **start** and **length** fields; for a video **trim** `in`/`out`; **position**
    `x`/`y` (percent of the canvas) and **size** (percent of the canvas width) fields; **opacity** slider 10-100 %; **volume** slider
    and mute (video only; GIF and photo show `no sound`); `delete overlay`.
  - nothing selected: `nothingSelected` and the project summary (canvas, quality, length, clip count).
- **Timeline**: track headers `overlay`, `main`, `audio`; zoom `−` `+` (and pinch on a trackpad / ⌘= ⌘−); a ruler in `m:ss`
  with ticks chosen for the zoom; clips as rounded blocks with their poster filmstrip, name and badges (`1.5×`, `crop`, `fit`,
  muted speaker); the selected clip has a blue ring and blue trim handles at both ends; overlay clips are amber-outlined on the
  overlay lane; the audio lane shows each main clip's level as a bar (muted clips hatched, overlay audio drawn thin on top when on); the
  playhead is a blue line with a head on the ruler (drag the head or click the ruler to seek). Interactions: click selects, click
  empty deselects; drag a clip's body to reorder (main) or move in time (overlay, snapping to clip edges and the playhead within 6
  pt); drag a handle to trim (the preview shows the edge frame while dragging); with `blade`, click a main clip to split it there.
  Over-limit (`too long`, `too many clips`) shows a red bar at the end of the main track and the problem's line in the top bar.

### 4.4 iPhone (and narrow iPad): `EditorPhoneScreen` (iPhone A board; lane 6)

- **Header**: `close` (pill), title (tap: rename alert), `render` (primary pill; `rendering 40%` while one runs).
- **Preview**: canvas-shaped, 360 pt tall on a 390 × 844 screen (scales with height); tap to play/pause; with an overlay selected,
  drag it to move and pinch to resize.
- Under it: `0:09.0 / 0:26.0`, play/pause, and the hint `pinch to zoom` (shown until the first pinch, then hidden for good:
  `@AppStorage("editor.pinchHintSeen")`).
- **Timeline** (150 pt): a fixed white centre playhead; the tracks scroll under it (scrolling scrubs, with a light haptic on clip
  edges); overlay lane above the main lane (amber), main clips with names and a `· 1.5×` suffix; the selected clip has blue trim
  handles (drag to trim; 44 pt hit areas); long-press then drag to reorder (the clip lifts, others make room); pinch to zoom; tap to
  select, tap empty to deselect; `+` at the right (`add a clip`) opens the add sheet (the bin of 4.3 as a sheet, `add` per tile,
  `done`).
- **Tool tray**: `trim`, `split`, `crop`, `speed`, `overlay`, `volume` (icon over label, 56 pt). `trim`, `crop`, `speed` open the clip
  sheet (4.5) on that section; `split` splits at the playhead (disabled with `nothingToSplit` when the playhead is on an edge or the
  selection is an overlay); `overlay`: with an overlay selected it opens the overlay sheet (4.5), else the add sheet in overlay mode
  (videos, GIFs, photos; adds at the playhead); `volume` opens a small sheet: slider, mute, `done`. Tools that need a main clip select
  the clip under the playhead when nothing is selected.
- The settings the Mac puts in menus (canvas, quality) are in the title's menu: tap-and-hold the title, or the `…` that appears
  next to it: `canvas` (9:16, 1:1, 16:9), `quality` (four), `rename…`, `delete edit…`.

### 4.5 iPhone sheets (iPhone A crop + speed + trim board; lane 6)

- **Clip sheet**: header `cancel` · `surf · clip 2` · `done` (changes apply live to the preview; `cancel` restores the clip as it was
  when the sheet opened). The source frame at the playhead fills the top with the crop frame (pinch and drag; corner marks), dimmed
  outside. Sections: **crop** + hint `pinch and drag the frame`, segmented `full` `free` `9:16` `1:1` `4:5` `16:9` and `fill`/`fit`
  under it; **speed** with the value on the right (`1.5×`), a log slider with marks `0.25×` `0.5×` `1×` `2×` `4×` (snaps to 0.05, a
  detent at 1×) and `becomes(4.5)` `· pitch kept`; **trim**: a filmstrip with the outside dimmed and a blue frame, handles at both ends,
  `in 0:02.0` / `out 0:08.75` under it. Opened from `trim`/`crop`/`speed` it scrolls to that section; `.presentationDetents([.large])`.
- **Overlay sheet**: header `cancel` · `overlay` · `done`; **length** (stepper and slider, 0.1 s to the rest of the timeline),
  **size** slider (5-100 % of the width), **opacity** slider (10-100 %), **volume** + mute (video only), `delete overlay`. Position is
  set by dragging on the preview above the sheet (medium detent keeps it visible).

### 4.6 Rendering

- `render` → a confirm card (popover on Mac/iPad, sheet on iPhone): `renderTitle`, the summary `renderSummary(w, h, fps, duration)`
  (`1080×1920 · 30 fps · 0:26`), `renderNote` ("the finished video goes to your library as private."), `render` / `cancel`.
  Disabled with the first problem's copy when `problems` is not empty, `renderOffline` when offline.
- After `render`: the button shows the progress (`waiting · 1 ahead`, `preparing`, `rendering 40%`, `finishing`); the popover/sheet
  shows the same with `cancel render` (confirm `cancelRenderTitle`). Done: toast `rendered` with `open` (opens the video's detail in
  the library: closes the editor on iPhone first; on Mac selects the library tab in the main window). Failed: `renderFailed(reason)`
  with `try again`. Editing after a render starts is fine: the render keeps the revision it started with (`renderingOlder` in the
  popover when the project changed since).
- Closing the editor during a render: toast `closeRendering` once; the render stays in the queue.

### 4.7 States

- Opening: `openingProject` (skeleton timeline, disabled tools) until `GET /edits/<id>` answers; failure → `couldntOpen` with
  `try again` and `close`; `404` → `projectGone` and the session closes.
- Sources: per clip download progress on its timeline block (a thin bar) and the canvas line `loadingSources(pct)`; a source that
  cannot be fetched → `sourceFailed` on that clip with `try again`; a deleted source → `missingClip` (the clip stays, rendering is
  disabled until it is removed: `removeMissing`).
- Save: 3.6's states, shown in the top bar (Mac/iPad) or under the title (iPhone); `.conflict` shows a banner `conflictTitle` /
  `conflictBody` with `useTheirs` and `keepMine`.
- Feature gone (`features.editor` turns false while open): the editor closes with `editorOff`.
- Shelf: hidden while loading or empty; a failed refresh keeps the last list (no banner).

### 4.8 Keyboard (Mac, and iPad with a keyboard; `EditorScreen` only)

| key | does |
|---|---|
| space | play / pause |
| J / K / L | play backwards (when the item can; else jump back 1 s) / pause / play forwards; L or J again doubles the rate up to 4× |
| ← / → | one frame back / forward; ⇧← / ⇧→ one second |
| I / O | set the selected main clip's in / out at the playhead |
| ⌘B | split at the playhead |
| ⌫ / ⌦ | delete the selection |
| V / B / C | select / blade / crop tool |
| ⌘= / ⌘− | zoom the timeline in / out |
| ⌘↩ | render (opens the confirm) |
| esc | leave the crop tool, else deselect |
| ⌘W | close the editor window (Mac) |

Shortcuts are scoped to the editor window/screen (`.keyboardShortcut` on its controls, named in their `.help`); there is no new menu
(`CobaltApp.swift` gets only the window).

## 5. Copy (`apple/Cobalt/Design/Copy+Editor.swift`, lowercase, exact; lane 5 writes it, lane 6 uses it)

```swift
extension Copy {
    enum Editor {
        static let title = "editor", edit = "edit", edits = "edits", untitled = "untitled edit"
        // library entry
        static let editLine = "edit the picked videos together"
        static let editNoVideo = "pick at least one video to edit"
        static let creating = "making the edit…"
        static let couldntCreate = "couldn't start the edit. try again."
        static func leftOut(_ n: Int) -> String { n == 1 ? "1 photo or gif left out · add it on the overlay" : "\(n) photos and gifs left out · add them on the overlay" }
        static func notOnServer(_ n: Int) -> String { n == 1 ? "1 pick isn't on the server, so it's left out" : "\(n) picks aren't on the server, so they're left out" }
        // shelf
        static func clipsLine(_ duration: String, _ clips: Int) -> String { "\(duration) · \(clips) clip\(clips == 1 ? "" : "s")" }
        static func editedAgo(_ ago: String) -> String { "edited \(ago)" }
        static let badgeWaiting = "waiting", badgeRendered = "rendered", badgeFailed = "render failed"
        static func badgeRendering(_ pct: Int) -> String { "rendering \(pct)%" }
        static let open = "open", rename = "rename…", delete = "delete…", deleteEdit = "delete edit…"
        static let deleteTitle = "delete this edit?"
        static let deleteBody = "videos you rendered from it stay in your library."
        static let deleteConfirm = "delete"
        static let renameTitle = "rename edit", renamePlaceholder = "name"
        // top bar
        static let close = "close", render = "render"
        static let toolSelect = "select", toolBlade = "blade", toolCrop = "crop"
        static let canvas = "canvas", quality = "quality"
        static func qualityLabel(_ p: Int, _ fps: Int) -> String { "\(p)p · \(fps)" }       // "1080p · 30"
        static func saveSaved(clips: Int, duration: String) -> String { "saved · \(clips) clip\(clips == 1 ? "" : "s") · \(duration)" }
        static let saveSaving = "saving…", saveRetrying = "not saved · retrying", saveConflict = "changed on another device"
        // bin
        static let library = "library", dragIn = "drag in", searchLibrary = "search the library"
        static let badgeGif = "gif", badgePhoto = "photo", cantEditBadge = "can't edit"
        static let cantEdit = "the editor takes mp4 and mov videos, gifs, jpgs and pngs."
        static let binEmpty = "nothing in your library yet. save something first."
        static let add = "add", addClip = "add a clip", addOverlay = "add an overlay", done = "done", cancel = "cancel"
        // preview and transport
        static let backOneFrame = "back one frame", forwardOneFrame = "forward one frame", play = "play", pause = "pause"
        static let pinchToZoom = "pinch to zoom"
        static func loadingSources(_ pct: Int) -> String { "getting your clips · \(pct)%" }
        static let missingClip = "this clip was deleted from your library"
        static let sourceFailed = "couldn't get this clip", tryAgain = "try again", removeMissing = "remove the missing clips to render"
        static let cropDone = "done", cropReset = "reset"
        // inspector
        static func clipN(_ n: Int) -> String { "clip \(n)" }
        static func fileLine(_ name: String, _ w: Int, _ h: Int) -> String { "\(name) · \(w)×\(h)" }
        static let trim = "trim", trimIn = "in", trimOut = "out", speed = "speed", crop = "crop", fit = "fit", volume = "volume"
        static let cropFull = "full", cropFree = "free", fitFill = "fill", fitFit = "fit", editCrop = "edit crop"
        static func speedValue(_ s: Double) -> String { "\(trimmedNumber(s))×" }                  // "1.5×", "0.25×", "2×"
        static func becomes(_ seconds: Double) -> String { "clip becomes \(trimmedNumber(seconds, places: 1))s" }   // "clip becomes 4.5s"
        static let pitchKept = "pitch kept"
        static let mute = "mute", unmute = "unmute", muted = "muted", noSound = "no sound"
        static let splitAtPlayhead = "split at playhead", deleteClip = "delete clip", deleteOverlay = "delete overlay"
        static let overlay = "overlay", start = "start", length = "length", position = "position", size = "size", opacity = "opacity"
        static let nothingSelected = "select a clip to change it"
        static func summary(canvas: String, quality: String, duration: String, clips: Int) -> String { "\(canvas) · \(quality) · \(duration) · \(clips) clip\(clips == 1 ? "" : "s")" }
        // timeline
        static let trackOverlay = "overlay", trackMain = "main", trackAudio = "audio", zoomIn = "zoom in", zoomOut = "zoom out"
        // iPhone tools and sheets
        static let toolTrim = "trim", toolSplit = "split", toolSpeed = "speed", toolOverlay = "overlay", toolVolume = "volume"
        static let nothingToSplit = "move the playhead into a clip to split it"
        static let pinchAndDrag = "pinch and drag the frame"
        static func sheetTitle(_ name: String, _ n: Int) -> String { "\(name) · clip \(n)" }    // "surf · clip 2"
        static func inAt(_ t: String) -> String { "in \(t)" }; static func outAt(_ t: String) -> String { "out \(t)" }
        // problems (EditProblem → words; also the server's codes)
        static func problem(_ p: EditProblem) -> String   // table below
        // render
        static let renderTitle = "render this edit"
        static func renderSummary(w: Int, h: Int, fps: Int, duration: String) -> String { "\(w)×\(h) · \(fps) fps · \(duration)" }
        static let renderNote = "the finished video goes to your library as private."
        static let renderOffline = "can't reach the server"
        static func waitingAhead(_ n: Int) -> String { n == 0 ? "waiting · next" : "waiting · \(n) ahead" }
        static let preparing = "preparing", finishing = "finishing"
        static func rendering(_ pct: Int) -> String { "rendering \(pct)%" }
        static let cancelRender = "cancel render", cancelRenderTitle = "cancel this render?", keepRendering = "keep rendering"
        static let rendered = "rendered · it's in your library", openVideo = "open"
        static func renderFailed(_ reason: String) -> String { "couldn't render — \(reason)" }
        static let renderingOlder = "this render is of an earlier version"
        static let closeRendering = "it keeps rendering on the server. it shows up in your library when it's done."
        // open, save, close
        static let openingProject = "opening the edit…"
        static let couldntOpen = "couldn't open this edit", projectGone = "this edit was deleted"
        static let closeUnsavedTitle = "close without saving?"
        static let closeUnsavedBody = "your last changes aren't on the server yet."
        static let keepEditing = "keep editing", closeAnyway = "close anyway"
        static let conflictTitle = "this edit changed on another device"
        static let conflictBody = "keep yours to replace it, or use theirs to drop your changes since."
        static let useTheirs = "use theirs", keepMine = "keep mine"
        static let editorOff = "the editor is off on this server"
        static let tooManyProjects = "you have 200 edits. delete some to make another."
        static let queueFull = "the server has 20 renders waiting. try again when some finish."
        // queue
        static func queueTitle(_ title: String) -> String { "render · \(title)" }
        static func queueDone(_ duration: String, _ size: String) -> String { "video · \(duration) · \(size) · private" }
        static let openEdit = "open edit"
        // accessibility
        static func a11yClip(n: Int, name: String, seconds: Double, speed: Double, cropped: Bool, muted: Bool, selected: Bool) -> String
            // "clip 2, surf, 4.5 seconds, 1.5 times speed, cropped, muted, selected" (parts left out when default)
        static func a11yOverlay(name: String, start: Double, seconds: Double, selected: Bool) -> String
            // "overlay, dance, from 3 seconds for 3 seconds, selected"
        static let a11yMoveEarlier = "move earlier", a11yMoveLater = "move later"
        static let a11yTrimStart = "start", a11yTrimEnd = "end", a11yPlayhead = "playhead"
        static func a11yPlayheadValue(_ t: String, of total: String) -> String { "\(t) of \(total)" }
    }
}
```

`trimmedNumber` is a private helper in the same file (at most 2 decimals, no trailing zeros). Durations use the house `Format`
(`0:26`, `0:09.0` with tenths in the transport and inspector, `1:02:03` never: the limit is 10 min).

**Problems** (`Copy.Editor.problem`):

| `EditProblem` / code | words |
|---|---|
| `canvas` | `pick a canvas: 9:16, 1:1 or 16:9` |
| `empty` | `add at least one video` |
| `tooManyClips` | `50 clips at most · remove some` |
| `tooLong` | `10 minutes at most · it's <m:ss>` |
| `range` | `<clip n>: a setting is out of range` (the field named from `path`: `speed`, `trim`, `crop`, `volume`, `position`, `size`, `opacity`) |
| `overlayOverlap` | `two overlays overlap · move one` |
| `overlayPastEnd` | `an overlay runs past the end` |
| `sourceMissing` | `a clip was deleted from your library` |
| `notVideo` | `only videos go on the main track` |
| `unsupportedSource` | `the editor can't use one of these files` |
| `pastSourceEnd` | `<clip n> ends after its video does` |

Render failure reasons (`renderFailed(reason)`): `render_failed` "the video couldn't be made", `timeout` "it took too long",
`source_missing` "a clip was deleted from the library", `lost` "the server restarted", `too_large` "the video was too big", `storage`
"the server couldn't store it", anything else "something went wrong" (the same words as the Hark message, 31.11).

## 6. Queue (`QueueScreen`, `UnifiedQueue`)

- **Source of rows**: `QueueSnapshot.edits` (server, every device's renders) merged with `EditorStore.renders` (this device's, fresher
  while the editor polls), by render id, newest `updated` wins.
- **Sections**: `queued` → **waiting** (`waitingAhead(n)`); `preparing`/`rendering`/`finishing` → **now** (progress bar from
  `progress`, `rendering 40%`); `done` within 30 min → **recently finished** (`queueDone(duration, size)`, poster thumbnail);
  `error` within 30 min → **failed** (`renderFailed(reason)`); `cancelled` is not shown.
- Row: poster (the project cover until the result's poster exists), `queueTitle(title)`, the line above. **Actions**: `cancel`
  (queued and running; confirm `cancelRenderTitle`) → `cancelEditRender`; `open`: done → the video (`QueueDestination.media(itemID)`,
  library detail), otherwise → the project (`QueueDestination.edit(projectID)`, opens the editor); `try again` (failed) → opens the
  project with the render confirm up; `dismiss` (finished/failed) hides it locally.
- `badgeCount` and `isActive` count active renders, so the 5 s polling (CONTRACT.md 12) runs while one renders.
- VoiceOver: one element per row with the actions as accessibility actions (as the other rows).

## 7. Symbols (`apple/Cobalt/Design/Symbols+Editor.swift`, `extension Symbol { enum Editor }`; SF Symbols 5 names)

`edit` `film.stack`; `render` `sparkles.rectangle.stack`; `toolSelect` `cursorarrow`; `toolBlade` `scissors`; `toolCrop` `crop`;
`trim` `arrow.left.and.right`; `split` `scissors`; `speed` `gauge.with.dots.needle.67percent`; `overlay` `square.on.square`;
`volume` `speaker.wave.2`; `muted` `speaker.slash`; `add` `plus`; `play` `play.fill`; `pause` `pause.fill`; `back` `backward.frame`;
`forward` `forward.frame`; `zoomIn` `plus.magnifyingglass`; `zoomOut` `minus.magnifyingglass`; `canvas` `aspectratio`; `quality`
`rectangle.badge.checkmark`; `missing` `exclamationmark.triangle`; `fit` `arrow.down.right.and.arrow.up.left`;
`fill` `arrow.up.left.and.arrow.down.right`. Lane 5 checks each in the SF Symbols app for iOS 18 / macOS 15 and swaps any that do not
exist for the nearest one, noting it in its report.

## 8. Accessibility and motion

- Every control has a label from the copy table; icon-only buttons too (`play`, `back one frame`, `add a clip`, tools).
- Timeline clips are accessibility elements with `a11yClip` / `a11yOverlay` labels and custom actions: `move earlier`, `move later`,
  `split at playhead`, `delete clip`, `trim` (opens the sheet / focuses the inspector), `select`. Trim handles are adjustable
  elements (`start` / `end`; increment/decrement = one frame, value = the time). The playhead is adjustable (`playhead`, value
  `a11yPlayheadValue`, increment/decrement one second). The preview's overlay is adjustable for size and has actions `move left`,
  `move right`, `move up`, `move down` (5 % of the canvas).
- Dynamic Type: the inspector, sheets, shelf and confirm card scale; the timeline's clip names cap at `.large` and truncate.
- Reduce Motion: clip reorder and lift use crossfades; no zoom animation on the timeline. Reduce Transparency: the bin and inspector
  use solid `CobaltColor.elevated` backgrounds.
- Colour is never the only signal: the selected clip has handles and a ring, overlays have the overlay lane and a label, muted clips a
  speaker-slash icon, the render state words.
- Haptics (Settings › haptics, iPhone): selection on clip select, light impact on split and on snapping, success on render done.
- Motion tokens: `Motion.rows` for clip insert/remove/reorder, `Motion.card` for sheets and the confirm card.

## 9. Gates and tests

Every app lane runs `apple/CONTRACT.md` section 9's gates (xcodegen, iOS and macOS builds without warnings from `apple/`, `swift
test`). Lane 4's `swift test` covers at least: the canonical JSON round trip of the fixture; `EditTiming` and `EditGeometry` against
the shared fixtures (31.4, 31.6); `EditValidation` for every problem with the server's paths; decoding of every shape with and without
optional fields; `EditError` mapping of every code; `EditSession` edits (add, move, trim clamps, split keeps settings, speed snapping,
crop presets, overlay clamp and overlap refusal, canvas change keeps overlays inside); autosave debounce, in-flight queuing, conflict
and retry against `PreviewClient` with an injected clock; `EditorStore.create(from:)` (videos kept in tap order, photos/GIFs left
out); `EditComposition.build` on the generated preview media (duration = N/F exactly, track count, the compositor's frame at three
times matches `EditGeometry` within 1 px); the queue merge (sections, de-duplication, actions). Lanes 5 and 6: `#Preview`s for every
screen in every `editor*` scenario plus `.happy`, compact and regular, light and dark. Lane 8 (runtime): the Mac and iPhone editors on
`AppModel.previewEditor(.editorRendering)`, screenshots of each state in 4.7, and the parity check of 31.5 against a real server
render once the API is deployed.

## 10. Decided defaults (main thread, 2026-10-20; the owner can still change them)

1. **Undo: in v1.** `EditSession` keeps an undo and a redo stack of whole `EditTimeline` snapshots (at most 100; a drag or a
   slider gesture is one step, recorded when it ends; a save never clears the stacks; opening a project starts them empty).
   Public: `canUndo`, `canRedo`, `undo()`, `redo()`. Mac and iPad: ⌘Z and ⇧⌘Z (Edit menu), iPhone: an undo and a redo button
   in the top bar beside close (copy `Copy.Editor.undo` = "undo", `redo` = "redo"). Local only: nothing on the server changes.
2. **Photos and GIFs stay overlay-only in v1** (a photo held on the main track is a later feature).
3. **Push: Hark, as every other job.** No APNs alert-push work in v1.

## 11. Live Activities for renders (addendum, 2026-10-23)

A render this iPhone sees running gets a Live Activity of its own (`EditLiveManager`, `CobaltEditActivityAttributes`; server
half: `deploy/cloudflare/APP-API-CONTRACT.md` section 32). It starts from any copy of a running render the app reads while in
front (the session's render polls, the render list, the queue's snapshot), at most one per render, never for a render older
than 6 hours or one whose activity already ended; an older copy never moves it backwards. It ends with the render: done
dismisses after 15 minutes, failed after 5, cancelled at once. With `features.edit_live_push` and a signed build its update
token goes to `PUT /live/edits/<rid>`, and the server keeps it current with the app closed.

Copy (widget, lowercase): queued `waiting to render` / `1 render ahead` / `N renders ahead`; preparing `sending the clips`;
rendering `rendering`; finishing `saving the video`; done `video ready` with `m:ss · w×h · size`; failed `couldn't render` with
the reason; cancelled `cancelled`; stale `waiting for capystore…`. Compact island: a film mark and the percent (`next` / `+N`
while queued); minimal: a progress ring. A tap opens the queue (`cobalt-apple://jobs`).

## 12. Layers, images, emotes and cutouts (addendum, 2026-10-31; server half: `deploy/cloudflare/APP-API-CONTRACT.md` section 39)

Mockup: https://claude.ai/artifact/VqimMVfpEKT12kxKEkLhqb. Everything below shows only on a server that sends
`limits.edit_overlay_tracks` > 1 (layers, webp sources) and `features.cutout` (cutouts); an older server keeps one overlay
lane and no cutout button.

- **Model** (CobaltKit): `EditOverlay.track` 0...7, left out of the JSON at 0. `EditValidation` checks overlap per layer (and
  still that `overlay` is sorted by `at`) and `overlay[i].track` range. `EditTimeline.overlayDrawOrder` = layer, then list
  order. `EditSession.overlayTrackLimit` (the capability, 1 when absent); `addOverlay(_:atFrame:track:)` takes the lowest
  free layer when `track` is nil; `moveOverlay(id:toFrame:track:)` stays between its own layer's neighbours, or goes in the
  gap at the frame on another layer; `setOverlayTrack` refuses a busy layer; `normalized` keeps ties in their order.
- **Preview**: one video track and one audio track per layer (track ids `3 + 2L` / `4 + 2L`); an instruction lists every
  overlay that is up and the compositor draws them in `overlayDrawOrder`. Animated webps and APNGs decode with ImageIO and
  loop like a gif (a delay of 10 ms or less is 100 ms, as the render).
- **Timeline**: Mac and iPad: one lane per layer (headers `L1`..., highest on top) plus an empty lane above for a new layer;
  several lanes share about two lanes' height (22 pt at least). Drop on a lane = that layer (else the lowest free one).
  iPhone: three layer lanes at most above the main lane, `+N more` / `fewer layers`. Dragging an overlay up or down moves it
  a layer; a busy layer keeps it where it is. VoiceOver actions `up a layer`, `down a layer`.
- **Bin and add sheet**: shelves `all` (Mac/iPad) / `videos` / `images` / `emotes` (library files with source `emote`). A
  webp counts as a photo. A picture's context menu has `remove background`.
- **Inspector / overlay sheet**: `layer N` with down and up, and `remove background` for a photo or gif overlay (the cutout
  then replaces the overlay's picture: same place, width, time and layer).
- **Cutout sheet** (`EditorCutoutSheet`): the picture on a checkerboard with a live preview on a 640 px copy (hold for the
  original), `auto` / `white` / `colour` (starts at the commonest edge colour; tap the picture to pick), tolerance,
  `only from the edges` (keeps white eyes), `soften edges`, `trim to the subject`, `cut out and place`. `CutoutMaker` makes
  it on the device (Vision `VNGenerateForegroundInstanceMaskRequest` for auto, the server's flood fill for white/colour),
  uploads the PNG (`content-type: image/png`), and falls back to the server's own cutout (`features.cutout_auto`) when the
  picture is not on the device or Vision finds no subject.
- Tests: `EditorLayersTests.swift` (JSON, validation, draw order, stacking pixels, session placement, capability) and
  `CutoutMakerTests.swift` (flood fill, edges only, trim, empty, colour picking).
