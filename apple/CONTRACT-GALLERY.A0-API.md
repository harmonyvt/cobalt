# CONTRACT-GALLERY.A0-API: the CobaltKit surface lane A0 built (read this before A1-A6)

Written 2026-10-07 by lane A0 at the end of its run, against the `apple-app` worktree (code read and compiled, not remembered).
It is the **as-built** form of `CONTRACT-GALLERY.md` section 4: where this file and section 4 differ, this file is what compiles
(the differences are listed in "Deviations", at the end). Everything here is in `apple/CobaltKit` unless a path says otherwise.
Swift 6, strict concurrency. Nothing in `api/`, `web/` or `deploy/` was touched.

## 0. The six things every UI lane should know first

1. **A multi-item post on a server with `caps.gallery` is `Pipeline.state == .gallery(items:)`**, not `.picker`. There is no choice
   state: entering `.gallery` has already started the save of everything. `pipeline.galleryRun` (observable) says how far it is.
   Plain cobalt and a fork without `features.gallery` keep `.picker` and today's `PickerSheet` untouched.
2. **`.gallery` is the state for the whole life of the post** (saving, saved, making). It never becomes `.ready` or `.done`. Ask
   `pipeline.galleryRun?.phase` (`.saving | .saved | .failed(PipelineFailure)`) and `.make` for what is going on.
3. **Everything made from a post is a file of its own, never a number**: `MadeKind` (`slideshow(.webp)`, `slideshow(.mp4)`,
   `galleryImage(layout)`, `crop`) is the key. Making the same kind again replaces the old file (R8): the server deletes the old
   row, the app deletes the old record and its Files copy. Names and tabs never carry a number.
4. **Photos only on request.** A gallery's items and every made file are excluded from the album sync (`PhotosSync.isEligible`
   returns false for any record with a `role`). `save to photos` is `AppModel.saveToPhotos(_:)` / `saveToPhotos(_:of:)`.
5. **A kept gallery is a folder.** In Files (iOS) and in `~/Movies/cobalt` (Mac) its files sit in one folder named by the title.
   Naming and the folder rule live in `Folder/FolderNaming.swift` (internal; UI never builds names).
6. **A make is a job.** `AppModel.make(_:from:)` puts it in `JobQueue` (`JobQueue.addGallery`), focused priority on the server's
   line, never takes the focus, shows in the tray. A make asked while the save still runs is held and sent after it (R7).

## 1. Wire types (`Models/Gallery.swift`, `Models/GalleryWire.swift`, `Models/Wire.swift`, `Models/Library.swift`)

```swift
public enum GalleryChoice: Sendable, Equatable, Codable { case all; case some([Int]); case firstVideo }  // "all" | [0,3] | "first-video"

public struct GalleryItem: Sendable, Equatable, Identifiable {          // one item of a post
    public var id: Int                                                    // index in the post (0-based)
    public var type: MediaType                                            // .photo / .video / .gif
    public var width: Int?, height: Int?, duration: Double?, thumb: URL?
    public init(id:type:width:height:duration:thumb:); public init(_ picker: PickerItem)
    public var isPhoto: Bool, isMotion: Bool, size: CGSize?
}
extension MediaType { public init?(contentType: String?) }               // image/gif → .gif, image/* → .photo, video/* → .video

public struct SlideshowPlan: Sendable, Equatable, Codable {
    public enum Format: String { case webp, mp4 }
    public enum Frame: String { case asPosted = "keep", story = "9:16", square = "1:1" }
    public enum Sound: String { case none, own }
    public var format: Format; items: [Int]; photoSeconds: Double; fade: Bool; frame: Frame; sound: Sound
    public var quality: WebpQuality?; width: Int?                         // webp only (an mp4 init drops them; a webp drops sound)
    public init(format:items:photoSeconds: = 2, fade: = true, frame: = .asPosted, sound: = .none, quality: = nil, width: = nil)
    @MainActor public static func standard(_ format: Format, items: [Int], settings: Settings?) -> SlideshowPlan
    public func seconds(for items: [GalleryItem]) -> [Double?]            // the wire's `seconds`: photoSeconds, nil for a video/gif, in play order
    public func chosen(from items: [GalleryItem]) -> [GalleryItem]        // the plan's items, in play order
    public func length(of items: [GalleryItem]) -> Double                 // photos × photoSeconds + videos' lengths, rounded to 0.1
    public func motionLength(of items: [GalleryItem]) -> Double
    public func check(_ items: [GalleryItem]) -> SlideshowCheck
    public static let webpMaxSeconds = 60.0, mp4MaxSeconds = 180.0, motionMaxSeconds = 60.0   // 0.5 s of slack on each
    public static let secondsRange: ClosedRange<Double> = 0.5...10, secondsStep = 0.5, defaultPhotoSeconds = 2.0, crossfadeSeconds = 0.3
    public static func snapped(_ seconds: Double) -> Double               // the slider: 0.5 steps inside 0.5...10
}
public enum SlideshowCheck: Sendable, Equatable {
    case ok, tooFew                                                       // tooFew: < 2 chosen, a repeat, or an index the post lacks
    case tooLong(length: Double, cap: Double, fitSeconds: Double?)        // fitSeconds: the longest 0.5 s step that fits (nil: nothing does)
    case tooMuchVideo(Double)                                             // the videos and gifs alone > 60 s
    public var isOK: Bool
}

public enum GalleryLayout: String, Sendable, Codable, CaseIterable { case strip, grid2, grid3, row; public var label: String }  // "strip" "2 across" "3 across" "side by side"
public struct GalleryImagePlan: Sendable, Equatable, Codable {
    public var items: [Int]; public var layout: GalleryLayout
    public init(items: [Int], layout: GalleryLayout = .grid3)
    public func photos(in items: [GalleryItem]) -> (photos: [GalleryItem], skipped: Int)   // R4: videos and gifs are left out, counted
    public func isPossible(in items: [GalleryItem]) -> Bool               // 2+ photos
    public func photoOnly(in items: [GalleryItem]) -> GalleryImagePlan    // what goes on the wire
}
public enum GalleryMake: Sendable, Equatable { case slideshow(SlideshowPlan); case image(GalleryImagePlan); public var what: String; public var items: [Int] }

public enum GalleryRole: String, Sendable, Codable { case item, slideshow, crop, export }     // `role` on v3 library rows and store records
public enum MediaKind: String, Sendable, Codable { case video, photo, gallery, webp }
public struct MadeSpec: Sendable, Equatable { kind, layout, format, items, data }             // `made_spec`, read leniently
public enum MadeKind: Sendable, Equatable, Hashable {                                          // the key a remake replaces (R8)
    case slideshow(SlideshowPlan.Format), galleryImage(GalleryLayout), crop
    public init?(role: GalleryRole?, spec: MadeSpec?)                     // a slideshow row with no format counts as mp4; an `export` that is not a gallery image → nil
    public var tabName: String                                            // "slideshow webp" / "slideshow" / "gallery image · 3 across" / "crop"
}
```

`Models/GalleryWire.swift`:

```swift
public struct StudioCreateOptions: Sendable, Equatable {                  // everything POST /studio can carry
    public var makePublic: Bool?; queue: Bool; title: String?; origin: String?; notify: NotifyOptIn?
    public var items: GalleryChoice?; itemCount: Int?; slideshow: SlideshowPlan?; galleryImage: GalleryImagePlan?; itemInfo: [GalleryItem]
    public init(makePublic:queue:title:origin:notify:items:itemCount:slideshow:galleryImage:itemInfo:)   // all defaulted
}
public struct RenderAccepted: Sendable, Equatable { job: String; queued: Bool; queueAhead: Int? }
public enum MakePhase: String { case queued, uploading, composing, encoding }
public struct MadeResult: Sendable, Equatable { job; itemID: String?; url: URL?; bytes; width; height; seconds: Double?; format: SlideshowPlan.Format?; cropped: [Int]; upscaled: [Int]; replaced: [String] }
public enum MakeStatus: Sendable, Equatable { case pending(phase: MakePhase?, done: Int?, total: Int?, queueAhead: Int?); case success(MadeResult); case failed(code: String) }
public struct VisibilityResult: Sendable, Equatable { files: [LibraryFile]; cacheCleared: Bool?; remaining: [String] }
```

`Models/Wire.swift` additions: `StudioSession.itemCount: Int?` and `.items: [SessionItem]` (`SessionItem { i, type: MediaType?, status: .ready|.error, code }`);
`StudioCreated.make: StudioMake?` (`{job, kind}`, the share sheet's chained make); `RenderRequest.item: Int?` (18.13; nil sends nothing).

`Models/Library.swift` additions (all nil/empty from a server without `v=3`):
`LibraryFile.galleryRole: GalleryRole?`, `.itemIndex: Int?`, `.madeFrom: [String]`, `.madeSpec: MadeSpec?`, `.madeKind: MadeKind?`;
`LibraryPost.kind: MediaKind?`, `.itemCount: Int?`, `.itemsFailed: [Int]`.

`Capabilities.gallery` (`features.gallery`) and `.galleryMake` (`features.gallery_make`, only true when `gallery` is).

## 2. The client (`API/Client.swift`, `API/HTTPCobaltClient.swift`)

New `CobaltClient` requirements, each with a default that throws `PipelineFailure.unsupported` (or forwards), so every existing fake compiles:

```swift
func createStudio(url: URL, options: StudioCreateOptions) async throws -> StudioCreated        // POST /studio; plain options forward to the old call
func makeSlideshow(session: String, plan: SlideshowPlan, items: [GalleryItem], focused: Bool, notify: Bool) async throws -> RenderAccepted   // POST /studio/<sid>/slideshow (keyed)
func makeGalleryImage(session: String, plan: GalleryImagePlan, focused: Bool, notify: Bool) async throws -> RenderAccepted                   // POST /studio/<sid>/gallery-image (keyed)
func makeStatus(session: String, job: String, wait: Int) async throws -> MakeStatus            // GET /studio/<sid>/render/<job>
func retryItems(session: String, items: [Int]) async throws -> StudioCreated                   // POST /studio/<sid>/items/retry {items, queue: true}
func deleteItem(_ itemID: String) async throws                                                 // DELETE /library/items/<id>
func setPostVisibility(anchor itemID: String, public makePublic: Bool) async throws -> VisibilityResult   // PATCH …/visibility {public, scope: "post"}; a 502 partial is returned, not thrown
func library(cursor: String?, limit: Int, v3: Bool) async throws -> LibraryPage                // GET /library?v=3
```

Conveniences (extension): `makeSlideshow(session:plan:items:focused:)` and `makeGalleryImage(session:plan:focused:)` without `notify`.
`HTTPCobaltClient.shareSaveRequest(link:options:)` builds the share sheet's `POST /studio` (url, headers, body) from the same options for a
background `URLSession` (lane A4: `items: .all`, `itemCount`, `origin: "share"`, `notify`, plus `slideshow` or `galleryImage`; bodies of 18.12
are what the options produce, asserted in `GalleryWireTests`). `LibraryModel` and `PipelineContext.libraryPage(cursor:limit:)` ask for `v=3` when
`caps.gallery`, else `v=2` when `caps.visibility`, else the plain page. **`ShortcutActions*.swift` still call `library(…v2:)` (lane A6's files).**

## 3. Geometry and estimates (`Media/GalleryGeometry.swift`, `Media/MakeEstimate.swift`)

```swift
public struct GalleryCanvas { Cell { index, rect: CGRect, cropped: Bool, upscale: Double? }; width, height, cells, scaledToCap; croppedIndices, upscaledIndices, size }
public enum GalleryGeometry { static func layout(_ sizes: [CGSize], _ layout: GalleryLayout) throws -> GalleryCanvas   // throws GalleryGeometry.NeedsTwoPhotos under 2
                              static let maxLongSide = 30_000, maxPixels = 40_000_000 }
public enum MakeEstimate { static func webpBytes(_:plan:frame:), mp4Bytes(_:plan:frame:), jpegBytes(_ canvas:), serverSeconds(_ what: GalleryMake, items:)
                           static func frame(for plan: SlideshowPlan, items: [GalleryItem]) -> CGSize           // webp 320|480 wide at the aspect; mp4 1080 short side
                           static func canvas(for plan: GalleryImagePlan, items: [GalleryItem]) -> GalleryCanvas? }  // photos only, sizes from the items
```
`GalleryGeometry` returns exactly the 6.4 table (28 post × layout rows generated by *executing* `CONTRACT-GALLERY.model.js`,
`Tests/…/GalleryGeometryFixtures.swift`; `upscale` is rounded to 0.1 like the model, nil when ≤ 1.01). `MakeEstimate` repeats the model's rounding
(webp whole KB × 1000, mp4 0.1 MB, jpeg 0.1 MB); its numbers are asserted against the model's outputs.

## 4. The store (`Store/OfflineStore.swift`, `Store/StoredMedia.swift`)

`StoredVideo` gains `role: GalleryRole?`, `itemIndex: Int?`, `madeFrom: [Int]?`, `madeSpec: Data?`, `libraryID: String?` (the server's row, what a download
and a replace are keyed by) and `madeKind: MadeKind?`. A slideshow **webp** is `kind .webp, role .slideshow`; a slideshow mp4, a gallery image and a crop
are `kind .original` with their role. `OfflineStore.add(…)` takes the five as trailing parameters.

`StoredMedia` gains `items: [StoredVideo]` (a gallery's originals in post order), `made: [StoredVideo]` (oldest → newest), `isGallery` (2+ items),
`kind: MediaKind`, `made(_ kind: MadeKind)`. `original` is only ever the media's plain original; `webps` only webps of a video (role nil);
`renditions = [original] + items + made + webps`; `face` = newest animated webp (a slideshow webp counts), else newest made mp4, else first item.
The existing `StoredMedia(id:original:webps:)` init is unchanged (new parameters default).
Identity: an item is the same item by `(session, itemIndex)`, a made file by `(role, libraryID)`; a plain original is still one per media.

## 5. One media for the UI (`Models/MediaItem.swift`)

`Rendition.Kind` gains `.item(index:type:)`, `.slideshow(number:format:)`, `.galleryImage(layout:number:)`, `.crop(of: Int, spec: MadeSpec?)`
(**deviation**: `spec` is `MadeSpec?`, not `FrameSpec`, which arrives with A7). `number` is 1 unless an older server left several of one kind.
Rendition conveniences: `isItem`, `itemIndex`, `itemType`, `isMade`, `isAnimatedMade`, `madeKind`, `tabName` ("video", "webp 2", "photo 3", "slideshow webp",
"slideshow", "gallery image · 3 across", "crop"). Ids: items `"item:<index>"`, made files `"m:<library id>"` (else `"l:<record id>"`), the rest as before.
`MediaItem` gains `items`, `made`, `kind: MediaKind`, `itemCount`, `missing: [Int]` (the post's `items_failed` that no live item stands in for);
`video` is now `renditions.first { $0.kind == .video }` (a gallery has none), `webps` is webps of a video only, `face` follows 1.22.
Tab order of `renditions`: video, items, slideshow webp, slideshow mp4, gallery images, webps, crops (the order of 1.19).
`LibraryRow` gains `kind` and `itemCount`; `LibraryKindFilter { all, videos, photos, galleries, webps }` and `LibraryModel.kindFilter` (remembered as
`library.kind`) filter `AppModel.libraryRows`. **There is no kind *sort key*:** adding a `LibrarySortKey` case breaks the exhaustive switch in
`Cobalt/Design/Copy+Library.swift` (not A0's); lane A5 adds it with its copy.

## 6. The pipeline (`Pipeline/PipelineGallery.swift`, `Pipeline/PipelineFlows.swift`, `Pipeline/PipelineTypes.swift`)

```swift
PipelineState.gallery(items: [GalleryItem])                      // sizes, lengths and thumbs fill in when the library lists the post
extension Pipeline {
    public internal(set) var galleryRun: GalleryRun?             // @Observable
    public var galleryItems: [GalleryItem]; public var galleryProgress: (done: Int, total: Int)?
    public var galleryIsSettled: Bool                            // the save is over (saved or failed) and no make is in flight
    public func make(_ m: GalleryMake) async                     // held while the save runs (R7), else sent; returns as soon as it is handed over; one make at a time
}
public struct GalleryRun: Sendable, Equatable {
    public enum Phase { case saving, saved, failed(PipelineFailure) }
    public enum Make { case none, waiting(GalleryMake), sending(GalleryMake), queued(GalleryMake, ahead: Int),
                       making(GalleryMake, MakeProgress), done(GalleryMake, MadeResult), failed(GalleryMake, PipelineFailure)
                       // .request: the make in any state; .isActive: waiting/sending/queued/making }
    public struct MakeProgress { phase: MakePhase?; done: Int?; total: Int?; fraction: Double }   // 0...1 for the bar
    public var phase, total, done, failures: [Int: String]    // index → error code ("photo 7 couldn't be fetched")
    public var make: Make; public var isSaved: Bool; public var kept: Int
}
```
- **Save**: one create with `items: "all"` and the `item_count` the picker had (`gallery_changed` if the post changed); polls `GET /studio/<sid>`; `done` follows the
  server's byte counts until it is ready, then (with "keep new saves offline", default on) each item is downloaded from `GET /library/items/<id>/file` into the store, kept
  (`role .item`, `libraryID`), and counted. An item that fails on the server stays in `failures`; the others are saved. A save finishes as `phase == .saved` even with failures.
  **Not verified on a real server: the progress of the server phase is an estimate from `step_bytes / step_total`** (the server may report none; then `done` stays 0 until the items land).
- **Make**: sends `POST …/slideshow` or `…/gallery-image` (keyed; `queue: true`, `priority: "focused"` with the server's line), polls `makeStatus`, downloads the made file by its `item_id`,
  removes the replaced local record first (so the new file gets the name `slideshow.webp`, never `slideshow (2).webp`), stores it kept (`madeFrom`, `madeSpec`, `libraryID`), tells the
  library to re-read the post, and sets `make = .done(m, result)`. A failure sets `.failed(m, failure)` (the render-phase code, e.g. `.server(code: "render.error.webp.encode_failed")`; the photos and the plan are untouched, the next `make` is "try again").
- **Entry paths**: a pasted link (`runLink`: resolve → picker → `.gallery`), a batch or Shortcut (`skipsLinkCheck`: `forkSave(savesGalleries: true)`, no resolve; the server decides, a gallery found at the end continues as `.gallery`),
  a share-sheet job or relaunch (`resumeJob` `.saving`). A 1-item picker of a **photo** is a gallery of one (`total == 1`, stored as `role .item`, `StoredMedia.kind == .photo`); a 1-item picker of a video is today's `forkSave`.
- **`JobOptions.galleries: GalleryHandling?`** (`.saveAll` default, `.firstVideo`, `.slideshowWebp`, `.galleryImage(layout)`) is for lane A6: `.firstVideo` sends `items: "first-video"`; the two makes are built from what was saved
  (2 s a photo, crossfade, `standard` settings; a plan the caps refuse, or a gallery image with < 2 photos, is *not sent*: `galleryRun.make` reads `.failed(…)` with `error.webp.too_long` / `error.studio.too_few_photos` / `error.studio.not_gallery`).
- **Jobs** (`Jobs/JobQueue.swift`, `Jobs/JobInput.swift`): a `.gallery` job is live while it saves or a make is in flight (`Job.isLive`), finished when saved and idle, failed when `phase == .failed`; cancel on a queued make cancels only the make
  (`409 started` is followed, not detached); `JobQueue.addGallery(_ work: GalleryWork, session:items:media:link:mediaID:failures:) -> Job` (work `.make(GalleryMake)` / `.retry([Int])`) and `JobQueue.galleryJob(session:)`; `JobVia.make`.
  Detach (`Pipeline.detach()`) is not available for a gallery: it resets (the server finishes the save; the library has it). `AppModel.isBusy` ignores a saved gallery.

## 7. What the detail and the sheets call (`Models/AppModel+Gallery.swift`)

```swift
extension AppModel {
    public func galleryItems(of item: MediaItem) -> [GalleryItem]
    public func make(_ m: GalleryMake, from item: MediaItem) async throws          // validates the plan (SlideshowPlan.check / GalleryImagePlan.isPossible) before anything is sent
    public func retryMissing(_ item: MediaItem) async throws                         // the post's `missing` items, again
    public func deleteItems(_ indices: [Int], of item: MediaItem) async throws      // server then device; the last item is refused: .server(code: "error.library.last_item")
    public func deleteMade(_ rendition: Rendition, of item: MediaItem) async throws
    @discardableResult public func setPublic(_ on: Bool, for item: MediaItem) async throws -> VisibilityResult   // scope post; partial → applied, then .server(code: "error.library.partial")
    public func copyAllLinks(_ item: MediaItem) -> String                            // public links, items then made files, one a line; "" when private
    public func saveToPhotos(_ renditions: [Rendition], of item: MediaItem) async throws   // owner-asked only; records g:<sid>:<n> / m:<library id>
    public func photosPlacement(of rendition: Rendition, in item: MediaItem) -> PhotosPlacement
    @discardableResult public func makeWebp(for item: MediaItem, itemIndex index: Int) -> Bool   // a video/gif item's own webp (below); false for a photo
}
```
**`make a webp` of one item** (1.18): `AppModel.makeWebp(for:itemIndex:)` opens the focus on this media with the trim on that item:
`Pipeline.resume(session:media:item:localFile:libraryItem:)` reads the frames from the kept copy (else fetches the item into a temp file), `makeWebp()` then sends the
render with `item` (18.13) and the finished webp is stored as the media's own with `madeFrom: [index]` (a tab after the items; `03 · webp 1.webp` in its folder).
Errors: `.unsupported` (no `features.gallery` / `gallery_make`, or a rendition that is not a made file), `.expired` (the library lists no open session for the post: the server makes only while the session lives, ~7 days; there is **no reopen for a gallery**),
`.server(code: "error.webp.too_long" | "error.studio.not_gallery" | "error.studio.too_few_photos")` for a plan the caps refuse. `AppModel.make` hands a make to the job that already holds the post's session (a gallery just pasted) and otherwise starts its own job.
Title rule (1.6): `LinkInfo.ref` is now `@handle` for a link that names its author (`x.com/<handle>/status/…`, `tiktok.com/@user/…`), so titles read `x · @ilokineedsleep` and `instagram · Ddy0-gpGg5U`; `x.com/i/status/…` keeps its number.

## 8. Names and symbols for the screens

`Cobalt/Design/Copy+Gallery.swift` (`Copy.Gallery`, every string of contract section 3 with the bodies filled in, plus helpers `itemLabel`, `photoNames`, `length`, `size`, `times`, `shape`) and
`Cobalt/Design/Symbols+Gallery.swift` (`Symbol.Gallery`: photo, gallery, slideshowWebp, slideshowMp4, galleryImage, make, the four layouts, reorder, ticked, missing, retry …).
Disk names (`Folder/FolderNaming.swift`, internal): `01.jpg`, `03.mp4`, `slideshow.webp`, `slideshow.mp4`, `gallery image · 3 across.jpg`, `03 · webp 1.webp`, `03 · crop 9:16.jpg` in a folder named by the title;
the folder is found again by an extended attribute (`com.capybaraharmony.cobalt.folder` = media id), so the owner may rename it in Files. A kept single photo or video is still a flat file.

## 9. Previews and tests

`PreviewScenario` gains `galleryInstagram` (10 photos, `instagram.com/p/Ddy0-gpGg5U`), `galleryX` (4 photos, `x.com/ilokineedsleep/status/2106850389551374806`; sizes are the 6.4 stand-ins), `galleryMixed` (2 photos, a 12.4 s video, a 3.2 s gif),
`galleryOne` (one photo), `galleryPartial` (10 photos, item 7 fails until `retryItems`), `galleryNoMake` (`gallery` without `gallery_make`), `galleryMakeFails` (the first make fails `error.webp.encode_failed`, the second works).
All have `features.gallery`, `visibility`, `line`; the preview server holds the posts (`library(v3:)` lists them with items, made files, kind, counts), takes makes (validating the caps like the server), replaces per `MadeKind`, deletes items, switches the whole post, retries items.
The existing `.picker` scenario is the "server without galleries" preview. In a view, paste any link in a gallery scenario (`pasteText` falls through to the default reel link; the scenario decides what resolves).
Tests: `GalleryCoreTests`, `GalleryWireTests`, `GalleryFlowTests` (pipeline, jobs, store, folder, options) under `Tests/CobaltKitTests/`.

## 10. Outside A0's ownership (tiny, forced by the new enum cases; lanes A1 and A3 replace them)

- `Cobalt/Screens/Home/JobCard.swift`: `case .gallery:` in the exhaustive `switch p.state` (a minimal tray card). **A1 draws the real one.**
- `Cobalt/Screens/Detail/DetailNames.swift`: `case .item, .slideshow, .galleryImage, .crop` added to the two exhaustive `switch kind` (`tabName(of:)` returns `Rendition.tabName`, `line(_:in:)` uses the video meta). **A3 words them.**
- `Cobalt/Screens/Home/HomeScreen.swift`: `.gallery` added to `stage` (→ `.focus`) and `starCategory` (`.landed` when `galleryIsSettled`, else `.working`). **A1 owns the real screen.**
- `CobaltShare/ShareRootView.swift`: `.gallery` joins the `working` case of the card's `switch pipeline.state`. **Note for A4:** on a server with `features.gallery` the extension's pipeline now saves a gallery whole (it no longer reaches `.picker`) and, with "keep new saves offline", downloads its items into the extension's store; A4's compact sheet and its one-request-per-choice flow (`shareSaveRequest(link:options:)`) replace that.

## Deviations from CONTRACT-GALLERY.md section 4 (each with its reason)

1. `CobaltClient.makeSlideshow` takes `items: [GalleryItem]` (and `notify:`): the wire's `seconds` needs each item's type (`null` for a video or gif); the pinned signature cannot build it. `makeGalleryImage` keeps `(session:plan:focused:)` plus `notify:`.
2. `SlideshowPlan.standard` is `@MainActor` (it reads `Settings`, which is main-actor isolated).
3. `StudioCreateOptions` did not exist (the contract says "gain"): created here with the fields above; the old `createStudio(link:public:queue:title:)` is the plain case of it.
4. `Rendition.Kind.crop(of:spec:)` carries `MadeSpec?`, not `FrameSpec` (A7 owns `FrameSpec`).
5. `Pipeline.make(_:)` returns when the make is handed over, not when it finishes; completion is `galleryRun.make`.
6. `PipelineState.gallery` and the new `Rendition.Kind` cases exist, so four exhaustive switches outside A0's files had to learn them (section 10).
7. Added beyond section 4 because the lanes need them: `StoredVideo.libraryID`, `MadeKind`/`MadeSpec`, `GalleryRun`, `JobQueue.addGallery`, `JobOptions.galleries`, `LibraryKindFilter`, `LibraryRow.kind/itemCount`, `shareSaveRequest(link:options:)`, `AppModel.photosPlacement(of:in:)`, the `AppModel` gallery calls.
8. `LinkInfo.ref` changed for links that name an author (the handle rule); nothing else reads it as an identifier.

## Not verified (say so, do not assume)

- Nothing ran against the live server or a device. The server-side routes S1 is building were coded against 18.9-18.13 and the preview server, not against S1's output.
- Live Activity and continued-processing treatment of `.gallery` (a `.saving` / `.done` mapping, `isLiveInFlight == false`) is compiled and unit-reasoned, not seen.
- The Mac `FolderSync` copy places a gallery in a folder but does **not** replace an older made file on a remake (it lands as `slideshow (2).webp`); the iOS visible folder does replace. The folder is not renamed when the title changes (files inside follow).
- Server-phase progress of a gallery save ("saving 4 of 10" before the items land) is derived from `step_bytes`; whether the DO reports it for a gallery is unknown.
- A single photo reached by a direct image link (not a picker) on the `forkSave` path still goes through the video flow (`develop`); only pickers are galleries of one.
