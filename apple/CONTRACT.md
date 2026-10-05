# cobalt for apple: app contract (pinned 2026-10-02)

One multiplatform SwiftUI app (iPhone, iPad, Mac; native macOS SwiftUI, not Catalyst) plus an
iOS share extension, for the owner's private cobalt fork. Lanes CORE and UI build against this
file in parallel; Lane API builds `deploy/cloudflare/APP-API-CONTRACT.md` (the server half).
Do not deviate. If something here is impossible, stop and report instead of improvising.
Additive changes to the public API go through the main thread (Fable), never lane to lane.

Design source: `apple/mockup/*.dc.html` (+ `canvas.json`), the approved boards, published as
https://claude.ai/artifact/XaMAQRWSyFnBGRpXwywuvF (version 8). Each board's `class Component`
script is the behaviour spec; its markup and CSS are the visual spec. Real data in the
boards came from the owner's live library and is reused below.

## 0. Settled product decisions (owner's; not reopened here)

- Home is an **orbit** of the latest videos kept on the device, slowly circling; only the ~3
  nearest the front play (pool of 3 players, short local loops), the rest show a still; the
  orbit stops under Reduce Motion and Low Power Mode. Below it two white circles: **paste**
  and **file**. **No text field anywhere.** The owner never types links.
- Every input runs **one pipeline**: fetch|upload → save → read → webp, on a 4-step rail. The
  tapped circle opens into the work card. Clips over 10 s are not an error: the trim bracket
  starts on the first 10 s and rubber-bands with a haptic tick past 10 s. "save to photos" and
  "host original" sit beside "make webp". Multi-item posts show a picker sheet.
- Library: one card per post, pills for what exists, one card open at a time, per-file
  actions, delete only `.webp` files (`DELETE /media/<name>`), hosted mp4 says "delete on web".
- Share extension: same steps in a compact sheet; ≤10 s clips finish there; >10 s hands off to
  the app on the trim; closing mid-render keeps it going and the app picks the job up.
- Settings: server URL (default `https://api.capybaraharmony.com`), API key in the Keychain
  (sent as `Authorization: Api-Key <key>`), detected server kind, keep videos on device (on) +
  storage used, webp quality, haptics, motion follows Reduce Motion.
- Visual language from cobalt web (`web/src/app.css`): IBM Plex Mono, all-lowercase copy,
  monochrome tokens, radius 11, error red, springs with bounce, `sensoryFeedback`.
- Upstream compatible: works against plain cobalt (detect; save through `POST /`; webp, studio
  and library hide). Nothing under `api/` changes.

## 1. Decisions made in this contract (not the owner's; flagged for review)

1. ~~Deployment targets iOS 18.0 / macOS 15.0~~ **Superseded 2026-10-02: iOS 26.0 / macOS 26.0**
   (owner asked for Liquid Glass; single-owner app, owner's devices are current). Swift 6 language
   mode, Xcode 27 (installed: Xcode 27.0, Swift 6.4, XcodeGen 2.46). Also superseded the same day
   by the owner's HIG pass: native `TabView(.sidebarAdaptable)` on iOS/iPadOS and
   `NavigationSplitView` + a `Settings` scene on Mac replace the custom 80 pt sidebar/tab bar;
   Liquid Glass (`.glass`/`.glassProminent`, `GlassEffectContainer`, `glassEffectID` for the
   circle → work card morph) on the controls layer, content stays solid.
2. **One multiplatform app target** (`supportedDestinations: [iOS, macOS]`), not two targets.
3. **On this fork the paste circle calls `POST /` first**, then `POST /studio`. That is the
   only way to see a multi-item post before the server saves its first video (the helper picks
   the first video of a picker silently, `helper/lib.js:518`). Cost: one extra cobalt resolve
   (~1 s) per paste. A picker item turned into a webp is downloaded by the app and uploaded
   with `PUT /studio/upload` (no backend change needed for that).
4. **"read" runs on the device**: once the server says `ready`, the app builds the 9-frame
   filmstrip with AVFoundation from `GET /studio/<sid>/source` (Range) or the local file, so
   the frame count is real. The mockup line "frames appear as the server reads them." becomes
   **"frames appear as the video is read."** (it would otherwise be untrue).
5. **Settings uses paste, not typing**, for the server URL too ("paste server url", "reset").
6. **The file circle is hidden on plain cobalt and on a legacy fork** (no upload route); the
   library tab is hidden when the server has no library.
7. **Post-close banner becomes a local notification.** A closed share extension cannot draw
   over another app, so "cobalt is still making your webp" is a local notification posted at
   close; "your webp is ready" needs push (out of scope) and shows when the app is next
   opened. **Owner decided (2026-10-02): full alerts.** The app asks for normal notification
   permission (`.alert, .sound, .badge`) on first launch, not provisional.
8. **Layout tiers**: compact < 600 pt (tab bar), regular 600-999 pt (cobalt's 80 pt sidebar,
   preview beside trim; the Fold board), wide ≥ 1000 pt (labelled sidebar + list/detail
   library + inspector column; the iPad and Mac boards).
9. **Done result joins the orbit as a webp item** (played with ImageIO's animated WebP
   support), as the mockup's `added` item carries the trim length.
10. Fonts are registered at runtime (`CTFontManagerRegisterFontsForURL`), with a fallback to
    the system monospaced font, so missing font files never block a build. **Owner approved
    (2026-10-02)** downloading IBM Plex Mono Regular/Medium/SemiBold TTF + OFL.txt from IBM's
    official github.com/IBM/plex release (Lane UI, wave 1).
11. **Owner decided (2026-10-02): the paste control stays the custom white circle** (reads
    `UIPasteboard` / `NSPasteboard`), accepting iOS's "allow paste" prompt until the owner sets
    cobalt to Allow once in Settings. Not Apple's `PasteButton`.

## 2. Layout, targets, identifiers

```
apple/
  .gitignore                 Cobalt.xcodeproj/  .build/  Config/Local.xcconfig  xcuserdata/  *.xcuserstate
  CONTRACT.md                this file
  project.yml                XcodeGen spec (CORE)
  Config/                    (CORE) Signing.xcconfig, Local.xcconfig.example, *.entitlements,
                             Cobalt-Info.plist, CobaltShare-Info.plist (generated by xcodegen from project.yml, committed)
  CobaltKit/                 local Swift package (CORE)
    Package.swift            swift-tools-version 6.0; platforms .iOS(.v18), .macOS(.v15);
                             product library "CobaltKit"; testTarget "CobaltKitTests"; no dependencies
    Sources/CobaltKit/       Models/ API/ Pipeline/ Store/ Share/ Preview/ Media/ Format/
    Tests/CobaltKitTests/    Swift Testing (`import Testing`)
  Cobalt/                    app target sources (UI): App/ Design/ Shared/ Screens/ Resources/
    Resources/Fonts/         IBMPlexMono-Regular.ttf, -Medium.ttf, -SemiBold.ttf, OFL.txt
    Resources/Assets.xcassets  AppIcon, AccentColor (#e1e1e1 dark / #000 light)
  CobaltShare/               iOS share extension
    ShareViewController.swift   (CORE) principal class, hosts ShareRootView
    ShareRootView.swift         (UI)
  mockup/                    the approved boards (read-only)
```

| thing | value |
|---|---|
| project / scheme | `Cobalt.xcodeproj` (generated, gitignored) / scheme `Cobalt` |
| app target | `Cobalt`, type application, `supportedDestinations: [iOS, macOS]`, product name `cobalt` (display name `cobalt`) |
| app bundle id | `com.capybaraharmony.cobalt` |
| extension target | `CobaltShare`, type app-extension, platform iOS, embedded in `Cobalt` with `platformFilter: ios` |
| extension bundle id | `com.capybaraharmony.cobalt.share` |
| app group | `group.com.capybaraharmony.cobalt` (both targets) |
| keychain access group | `$(AppIdentifierPrefix)com.capybaraharmony.cobalt` (both targets) |
| URL scheme | `cobalt-apple` (app only): `cobalt-apple://job/<uuid>`, `cobalt-apple://open` |
| deployment | iOS 18.0, macOS 15.0 |
| Swift | `SWIFT_VERSION = 6.0` (strict concurrency is implied), `@Observable`, no third-party dependencies |
| extension sources | `CobaltShare/**` + `Cobalt/Design/**` + `Cobalt/Shared/**` (so the share sheet reuses the app's design system and step views) |
| extension activation | `NSExtensionActivationSupportsWebURLWithMaxCount = 1`, `NSExtensionActivationSupportsMovieWithMaxCount = 1`, `NSExtensionActivationSupportsText = true` (shared text with a link in it) |
| Info.plist keys (app) | `NSPhotoLibraryAddUsageDescription` = "cobalt saves videos you choose to your photos.", `NSAppTransportSecurity.NSAllowsLocalNetworking = true` (plain cobalt on the LAN), `CFBundleURLTypes` (`cobalt-apple`), `UILaunchScreen` = {} , `LSApplicationCategoryType` = `public.app-category.utilities` |
| Info.plist keys (extension) | `NSExtension` (point `com.apple.share-services`, principal class `$(PRODUCT_MODULE_NAME).ShareViewController`), `NSPhotoLibraryAddUsageDescription` (same text) |
| macOS entitlements | app sandbox, `network.client`, `files.user-selected.read-write`, `personal-information.photos-library`, the app group, keychain group |

**Signing.** Nothing in git names a team. `Config/Signing.xcconfig` (committed) sets
`CODE_SIGN_STYLE = Automatic`, `DEVELOPMENT_TEAM =` (empty) and ends with
`#include? "Local.xcconfig"`; the owner copies `Local.xcconfig.example` to `Local.xcconfig`
(gitignored) and puts `DEVELOPMENT_TEAM = <team id>` there for device builds. Simulator and
macOS gate builds pass `CODE_SIGNING_ALLOWED=NO` (no team, no profiles). Unsigned builds have
no app-group or keychain-group entitlements at run time, so every store falls back
(section 4.6) and the share handoff only works in a signed build.

## 3. Waves and file ownership

| wave | lane | owns (writes only these) | done when |
|---|---|---|---|
| 0 (foundation) | CORE | `apple/project.yml`, `apple/Config/**`, `apple/.gitignore`, `apple/CobaltKit/**` with the **whole public API of section 4 compiling** and `PreviewClient` + `Pipeline` + `LibraryModel` + `AppModel.preview` working end to end against preview data; **placeholders** `apple/Cobalt/App/CobaltApp.swift`, `apple/Cobalt/Design/Placeholder.swift`, `apple/Cobalt/Shared/Placeholder.swift`, `apple/CobaltShare/ShareRootView.swift`, `apple/CobaltShare/ShareViewController.swift` | all section 9 gates green |
| 0 (parallel) | API | `deploy/cloudflare/**` per the API contract | `npm test && npm run typecheck` green in api and web |
| 1 | CORE | `apple/CobaltKit/**` (real `HTTPCobaltClient`, stores, share inbox, tests), `apple/project.yml`, `apple/Config/**`, `apple/CobaltShare/ShareViewController.swift` | gates green; `swift test` covers section 9's list |
| 1 | UI | `apple/Cobalt/**` (replaces the placeholders; design system, screens, fonts, assets), `apple/CobaltShare/ShareRootView.swift` | gates green; every screen previews against `AppModel.preview(...)` for every scenario |
| 2 | Fable + a Sonnet verification lane | integration against the deployed API, simulator and Mac runtime evidence | checklist in section 9 |

Rules: shared types live **only** in CobaltKit; UI never edits CobaltKit (missing API → ask
Fable). CORE never edits `apple/Cobalt/**` after wave 0. `project.yml` is CORE's: UI asks for
resource or plist changes. All user-facing strings live in UI (`apple/Cobalt/Design/Copy.swift`);
CobaltKit exposes enums and numbers, never copy. Lanes never commit or push.

## 4. CobaltKit public API (pinned)

Everything below is `public`. Names and signatures are exact; CORE may add `internal` code
freely and may add public **conformances** (`Hashable`, `CustomStringConvertible`), nothing else
without Fable. `@MainActor` classes are `@Observable` and Sendable by isolation.

### 4.1 Server, capabilities, errors

```swift
public enum ServerKind: String, Sendable, Codable, Equatable {
    case fork, legacyFork, plainCobalt, notCobalt, unreachable
}
public enum KeyState: String, Sendable, Codable, Equatable { case valid, invalid, missing, unknown }

public struct Capabilities: Sendable, Codable, Equatable {
    public struct Limits: Sendable, Codable, Equatable {
        public var maxWebpSeconds: Double      // 10
        public var minWebpSeconds: Double      // 0.5
        public var webpWidths: [Int]           // [320, 480]
        public var renderFPS: Int              // 15
        public var maxUploadBytes: Int64       // 100_000_000
        public var maxSourceBytes: Int64       // 209_715_200
        public var sessionTTL: TimeInterval    // 604_800
        public static let fork: Limits
    }
    public var kind: ServerKind
    public var cobaltVersion: String?          // "11.7.1"
    public var studio: Bool                    // render webps, host originals
    public var upload: Bool                    // file circle
    public var library: Bool                   // library tab
    public var saveProgress: Bool              // session `step` fields
    public var renderProgress: Bool            // render `phase`/frame fields
    public var finishesUnpolled: Bool          // server sweep (share-sheet close is safe)
    public var limits: Limits
    public var mediaBaseURL: URL?
    public var key: KeyState
    public var keyName: String?
    public static let unknown: Capabilities    // kind .unreachable, all features false
}

public enum CobaltError: Error, Sendable, Equatable {
    case api(code: String, httpStatus: Int)    // {"status":"error","error":{"code"}} and cobalt's own
    case network(URLError.Code)
    case invalidResponse(httpStatus: Int)
    case noAPIKey
    case tooLarge(limit: Int64)
    case cancelled
}
```

Detection is exactly the 3-step algorithm in `APP-API-CONTRACT.md` section 1 (no redirects on
step 1; `GET /`; then the 22-zero session probe). `capabilities()` never throws: failures are
`.unreachable` / `.notCobalt`. Plain cobalt: `studio/upload/library/...` false,
`limits.maxUploadBytes` 0, `key` `.unknown` (learned later from `POST /` errors).

### 4.2 Wire models

JSON uses `convertFromSnakeCase`; `*_at` fields are ms since epoch → `Date`. Every field the
API marks nullable is optional here; **every field added by the API contract is optional**,
so an older server decodes.

```swift
public enum MediaType: String, Sendable, Codable { case photo, video, gif }
public struct PickerItem: Sendable, Equatable, Identifiable {
    public var id: Int                         // index in cobalt's picker array
    public var type: MediaType
    public var url: URL
    public var thumb: URL?
    public var canWebp: Bool { get }           // type != .photo
}
public enum CobaltResult: Sendable, Equatable {    // POST /
    case file(url: URL, filename: String?)     // "tunnel" | "redirect"
    case picker(items: [PickerItem], audio: URL?)
    case localProcessing                       // not supported by the app
}

public enum SessionStatus: String, Sendable, Codable { case saving, ready, error }
public enum SaveStep: String, Sendable, Codable { case fetching, reading, storing }
public struct StudioRender: Sendable, Codable, Equatable, Identifiable {
    public var id: String; public var url: URL; public var start: Double; public var length: Double
    public var width: Int?; public var quality: String?; public var bytes: Int64?; public var createdAt: Date
}
public struct StudioSession: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var status: SessionStatus
    public var link: String?                   // a page URL, or "upload:<item id>"
    public var service: String?
    public var title: String?
    public var duration: Double?
    public var width: Int?
    public var height: Int?
    public var bytes: Int64?
    public var createdAt: Date
    public var expiresAt: Date
    public var errorCode: String?              // from "error": {"code"}
    public var renders: [StudioRender]
    public var step: SaveStep?                 // new; nil = server does not say
    public var stepBytes: Int64?
    public var stepTotal: Int64?
    public var waking: Bool?
}
public struct StudioCreated: Sendable, Equatable { public var id: String; public var pageURL: URL? }
public struct UploadResult: Sendable, Equatable {
    public var sessionID: String?              // nil for images, or when studioError is set
    public var item: LibraryFile
    public var studioErrorCode: String?
}
public enum WebpQuality: String, Sendable, Codable, CaseIterable { case low, med, high }
public struct RenderRequest: Sendable, Equatable {
    public var start: Double; public var length: Double; public var width: Int; public var quality: WebpQuality
}
public enum RenderPhase: String, Sendable, Codable { case fetching, decode, pack }
public struct WebpResult: Sendable, Codable, Equatable {
    public var job: String; public var url: URL; public var bytes: Int64
    public var width: Int; public var height: Int; public var seconds: Double
}
public enum RenderStatus: Sendable, Equatable {
    case pending(phase: RenderPhase?, framesDone: Int?, framesTotal: Int?)
    case success(WebpResult)
    case failed(code: String)                  // {"status":"error"} with HTTP 200 = the job ended
}
public struct HostedFile: Sendable, Equatable { public var url: URL; public var bytes: Int64?; public var contentType: String?; public var itemID: String? }

public struct LibraryFile: Sendable, Codable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Codable { case `public`, `private` }
    public enum Source: String, Sendable, Codable { case webp, studio, host, upload, saved }
    public enum Role: Sendable, Equatable { case webp, hostedLink, privateCopy }
    public var id: String; public var kind: Kind; public var source: Source; public var name: String
    public var url: URL?; public var contentType: String?; public var bytes: Int64?
    public var width: Int?; public var height: Int?; public var duration: Double?
    public var createdAt: Date; public var mediaName: String?; public var deletable: Bool
    public var role: Role { get }              // private → privateCopy; public image/webp → webp; other public → hostedLink
}
public struct LibrarySession: Sendable, Codable, Equatable {
    public var id: String; public var status: SessionStatus; public var expiresAt: Date; public var sourceURL: URL
}
public enum LibraryPill: Sendable, Equatable, CaseIterable { case webp, mp4Link, privateCopy }
public struct LibraryPost: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var service: String?; public var link: URL?; public var title: String?
    public var duration: Double?; public var width: Int?; public var height: Int?
    public var createdAt: Date; public var session: LibrarySession?; public var files: [LibraryFile]
    public var ref: String? { get }            // LinkInfo(link).ref
    public var pills: [LibraryPill] { get }    // unique roles present, order webp, mp4Link, privateCopy
}
public struct LibraryPage: Sendable, Equatable {
    public var posts: [LibraryPost]; public var postCount: Int; public var fileCount: Int
    public var publicBytes: Int64; public var privateBytes: Int64; public var next: String?
}
```

### 4.3 Client

```swift
public struct TransferProgress: Sendable, Equatable { public var bytes: Int64; public var total: Int64? }

public enum RemoteFile: Sendable, Equatable {
    case open(URL)                 // tunnel, redirect, picker item, public media: never sent the key
    case studioSource(session: String)
    case libraryItem(id: String)   // keyed
}

public protocol CobaltClient: Sendable {
    var baseURL: URL { get }
    func capabilities() async -> Capabilities
    func resolve(_ link: URL) async throws -> CobaltResult                         // POST /
    func createStudio(link: URL) async throws -> StudioCreated                    // POST /studio
    func upload(file: URL, name: String, contentType: String,
                progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> UploadResult  // PUT /studio/upload
    func session(_ id: String, wait: Int) async throws -> StudioSession          // GET /studio/<id>?wait=
    func sourceURL(session id: String) -> URL                                     // GET /studio/<id>/source (no key)
    func render(session id: String, _ request: RenderRequest) async throws -> String   // job id
    func renderStatus(session id: String, job: String, wait: Int) async throws -> RenderStatus
    func publish(session id: String) async throws -> HostedFile                  // POST /studio/<id>/publish
    func publish(item id: String) async throws -> HostedFile                     // POST /library/items/<id>/publish
    func openStudio(item id: String) async throws -> StudioCreated               // POST /library/items/<id>/studio
    func library(cursor: String?, limit: Int) async throws -> LibraryPage        // GET /library
    func deleteMedia(name: String) async throws                                   // DELETE /media/<name>
    func download(_ file: RemoteFile, to destination: URL,
                  progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> URL
}

public struct HTTPCobaltClient: CobaltClient {
    public init(baseURL: URL, apiKey: @escaping @Sendable () -> String?, session: URLSession = .shared)
}
public struct PreviewClient: CobaltClient {
    public init(scenario: PreviewScenario = .happy, timeScale: Double = 1)   // 1 = the mockup lab's timings
}
```

Client rules (CORE): the `Authorization` header is attached **only** to keyed routes and **only**
when the request host equals `baseURL`'s host (never to tunnels, media or redirects); `Accept:
application/json` everywhere; long polls use a request timeout of `wait + 15` s; `POST /` body is
`{"url": "<link>"}` and nothing else (server defaults); a missing key on a keyed route throws
`.noAPIKey` before any request.

### 4.4 The pipeline

```swift
public struct LinkInfo: Sendable, Equatable {
    public init?(_ url: URL)
    public var url: URL
    public var service: String     // host's second-level label; "twitter" shows as "x"
    public var ref: String         // last non-empty path component
    public static func firstLink(in text: String) -> URL?   // same rule as worker.ts extractFirstUrl
}
public struct MediaInfo: Sendable, Equatable, Codable {
    public var name: String; public var duration: Double?; public var width: Int?; public var height: Int?
    public var bytes: Int64?; public var isImage: Bool
}
public enum PipelineInput: Sendable, Equatable {
    case link(LinkInfo)
    case file(name: String, bytes: Int64, contentType: String)
}
public struct TrimRange: Sendable, Equatable, Codable {
    public var start: Double; public var end: Double
    public var length: Double { get }
}
public enum TrimHandle: Sendable { case start, end, span }
public enum RenderProgress: Sendable, Equatable {
    case decoding(done: Int, total: Int)       // real counts from the server
    case packing(since: Date)                  // open-ended, breathes
    case working(since: Date)                  // server sends no counts (degraded) or not started yet
}
public enum PipelineFailure: Sendable, Equatable, Error {
    case noLink                    // pasteboard had no http(s) link
    case tooLarge(limit: Int64)    // file over the upload limit (checked before uploading)
    case fetchFailed(code: String) // cobalt couldn't fetch (error.api.fetch.*, content.*, link.*)
    case unsupported               // local-processing, or a type the server refuses
    case serverBusy                // error.studio.busy after the pipeline's own retries (60 s)
    case renderBusy                // error.webp.busy (keeps the trim)
    case renderLost                // error.webp.job_lost (keeps the trim)
    case expired                   // error.studio.expired
    case keyMissing, keyInvalid    // error.api.auth.key.*
    case unreachable
    case server(code: String)      // anything else
    public var keepsTrim: Bool { get }   // renderBusy, renderLost, and server errors during rendering
}
public enum PipelineState: Sendable, Equatable {
    case idle
    case fetching(since: Date, waking: Bool)
    case uploading(TransferProgress)
    case saving(bytes: Int64?, total: Int64?, since: Date)   // bytes nil = degraded "saving"
    case reading(developed: Int, of: Int)
    case picker(items: [PickerItem])
    case image(MediaInfo)
    case ready
    case rendering(RenderProgress)
    case done(WebpResult)
    case savedLocally(StoredVideo)             // plain cobalt end state
    case failed(PipelineFailure)
}
public struct Rail: Sendable, Equatable {
    public enum Step: Sendable, Equatable { case fetch, upload, save, read, webp, host }
    public var steps: [Step]                   // fork: 4 cells; plain cobalt: [.fetch, .save, .read]
    public var index: Int                      // highlighted cell
    public var finished: Bool                  // .done: every cell "past"
}
public enum PickerAction: Sendable { case save, webp }
public enum ActionStatus: Sendable, Equatable { case idle, working, done, failed(PipelineFailure) }
public struct Frame: @unchecked Sendable, Equatable { public let index: Int; public let image: CGImage }

@MainActor @Observable
public final class Pipeline: Identifiable {
    public nonisolated let id: UUID
    public static let frameCount: Int          // 9
    public private(set) var state: PipelineState
    public private(set) var input: PipelineInput?
    public private(set) var media: MediaInfo?
    public private(set) var rail: Rail
    public private(set) var frames: [Frame?]   // frameCount slots, nil = not developed yet
    public private(set) var trim: TrimRange
    public private(set) var trimOverLimit: Bool        // dragging past the limit: bracket turns red
    public private(set) var limitHits: Int             // +1 per hit; drive .sensoryFeedback
    public private(set) var photos: ActionStatus       // "save to photos"
    public private(set) var hosting: ActionStatus      // "host original" / "host as-is"
    public private(set) var hostedURL: URL?
    public private(set) var sessionID: String?
    public private(set) var result: WebpResult?
    public private(set) var stored: StoredVideo?        // the local original, once downloaded
    public var maxClipSeconds: Double { get }           // capabilities.limits.maxWebpSeconds
    public var litFrames: Set<Int> { get }              // frames inside the bracket already decoded (render lights)

    public func start(pastedText: String?)              // → .failed(.noLink) when there is no link
    public func start(link: URL)
    public func start(file: URL)                        // security-scoped; copied into the store inbox first
    public func resume(_ job: SharedJob)                // share-sheet handoff / app relaunch
    public func resume(session id: String, media: MediaInfo?)   // library "trim a new webp"
    public func choose(_ item: PickerItem, _ action: PickerAction)
    public func saveAllPickerItemsToPhotos()
    public func dragTrim(_ handle: TrimHandle, to seconds: Double)   // absolute seconds; rubber band
    public func endTrimDrag()                                         // springs back inside the limit
    public func nudgeTrim(_ handle: TrimHandle, by seconds: Double)   // ±0.1 for arrow keys / I-O
    public func makeWebp()
    public func backToTrim()
    public func saveToPhotos()
    public func hostOriginal()                          // also "host as-is" for an image
    public func copyResultLink()
    public func cancel()                                // stop polling and transfers; server work continues
    public func reset()                                 // cancel + back to .idle
}
```

Trim math (pinned from `Main.dc.html` `moveDrag`/`endDrag`/`nudge`; CORE unit-tests these exact
cases). D = duration, L = `maxClipSeconds`, minimum length 0.5 s.
- `.start` to t: `a = clamp(t, 0, b - 0.5)`; if `b - a > L`: `a = b - L - (b - a - L) * 0.25`, over.
- `.end` to t: `b = clamp(t, a + 0.5, D)`; if `b - a > L`: `b = a + L + (b - a - L) * 0.25`, over.
- `.span` to t: `a = clamp(t, 0, D - len)`, `b = a + len`.
- `limitHits += 1` when `trimOverLimit` turns true, and on a nudge that hits the limit.
- `endTrimDrag`: if over, the moved handle snaps to exactly L from the other; over = false.
- On `.ready`: `trim = 0...min(D, L)`. A known duration ≤ L means the whole clip fits.

### 4.5 Server → state mapping (CORE implements; UI only renders `state`)

Fork, pasted link:
1. `start` → `.fetching(since: now, waking: false)`; `POST /`. `waking` turns true when the
   outstanding `POST /` or `POST /studio` has taken > 1.5 s, or a session poll says `waking`.
2. `POST /` → `picker` → `.picker`. `error` → `.failed` (codes below). `local-processing` →
   `.failed(.unsupported)`. `tunnel`/`redirect` → `POST /studio {url}` → poll
   `GET /studio/<sid>?wait=1` until not saving:
   - `step == .fetching` → `.fetching(since, waking: session.waking ?? waking)`
   - `step == .reading | .storing` → `.saving(bytes: stepBytes, total: stepTotal, since)`
   - `step == nil` while saving → `.saving(bytes: nil, total: nil, since)` (degraded: "saving")
   - `ready` → `media` from the session → `.reading(0, 9)`; frames from `sourceURL` (AVURLAsset,
     Range) arrive in order; after the 9th plus 250 ms → `.ready`. In parallel, when "keep
     videos on device" is on, download `.studioSource` into the store (does not block `.ready`).
   - `error` → `.failed(map(code))`.
   - `POST /studio` 429 `error.studio.busy` → retry every 3 s for 60 s, then `.failed(.serverBusy)`.
3. `makeWebp()` → `POST .../render` with `trim`, settings' width and quality →
   `.rendering(.working(since: now))`; poll `?wait=1`: `pending(decode, d, t)` →
   `.decoding(d, t)`; `pending(pack, ...)` → `.packing(since: first pack)`; pending with no phase
   → `.working`. `success` → download the webp into the store (orbit) → `.done(result)`.
   429 `error.webp.busy` → `.failed(.renderBusy)`; `error.webp.job_lost` → `.failed(.renderLost)`;
   both keep `trim`, and `makeWebp()` from `.failed` retries.
4. `hostOriginal()` → `publish(session:)` → copy the URL → `hosting = .done`, `hostedURL`.

Fork, file (`start(file:)`): over `limits.maxUploadBytes` → `.failed(.tooLarge)` with no
request. Else `.uploading(progress)` from `PUT /studio/upload` → on 201: `.saving(bytes: total,
total: total, since)` held ≥ 0.6 s so the stored count reads → video with `sessionID`: poll the
session (its `reading` step) while frames come from the **local** file → both done → `.ready`.
Image → `.image(media)`; `hostOriginal()` uses `publish(item:)`. Video with `studioErrorCode` →
`openStudio(item:)` with the same 3 s/60 s busy retry.

Picker: `choose(item, .save)` downloads the item (`.open`) and saves it to Photos (and the
store). `choose(item, .webp)` (fork only, `item.canWebp`) downloads it, then continues exactly as
`start(file:)` from `.uploading`.

Plain cobalt (no studio): `POST /` → `tunnel`/`redirect` → `.fetching` until the response, then
download to the store as `.saving(bytes, total, since)` (total nil when no content-length) →
`.reading` from the local file → `.savedLocally(video)`. Picker items save only. Rail
`[.fetch, .save, .read]`.

Legacy fork (studio, nothing new): as the fork, but no `step` (degraded "saving"), no render
counts (`.working`), no upload (file circle hidden), no library.

Error code map (`error.*` → `PipelineFailure`): `api.fetch.*`, `api.content.*`, `api.link.*`,
`webp.no_video`, `webp.bad_source`, `webp.download_failed` → `.fetchFailed(code)`;
`api.auth.key.missing` → `.keyMissing`; `api.auth.key.invalid|not_api_key|not_found` →
`.keyInvalid` (and `AppModel` marks the key invalid); `studio.busy` → retry then `.serverBusy`;
`webp.busy` → `.renderBusy`; `webp.job_lost`, `studio.save_lost` → `.renderLost` (rendering)
or `.server(code)` (saving); `studio.expired` → `.expired`; `library.too_large`,
`studio.too_large`, `webp.too_large` → `.tooLarge`; `webp.unsupported`, `library.unsupported`,
`studio.not_video` → `.unsupported`; URLError → `.unreachable`; anything else `.server(code)`.

### 4.6 Stores, settings, keychain

```swift
public struct StoredVideo: Sendable, Codable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Codable { case original, webp }
    public var id: String
    public var kind: Kind
    public var fileURL: URL?        // nil when only the poster is kept
    public var posterURL: URL?      // JPEG, 360 px long edge
    public var name: String
    public var duration: Double?; public var width: Int?; public var height: Int?
    public var bytes: Int64
    public var sessionID: String?; public var link: URL?; public var remoteURL: URL?
    public var createdAt: Date
}
public struct StorageUsage: Sendable, Equatable { public var count: Int; public var bytes: Int64 }

@MainActor @Observable
public final class OfflineStore {
    public init(root: URL)
    public static func shared() -> OfflineStore      // <app group>/Videos, else Application Support/Videos
    public private(set) var videos: [StoredVideo]    // newest first
    public var usage: StorageUsage { get }           // files actually on disk
    public func latest(_ n: Int) -> [StoredVideo]
    public func add(file: URL, kind: StoredVideo.Kind, media: MediaInfo, sessionID: String?,
                    link: URL?, remoteURL: URL?, move: Bool) async throws -> StoredVideo
    public func inboxURL(for name: String) -> URL    // where start(file:) / the extension copy incoming files
    public func remove(_ id: String) async
    public func dropFilesKeepingPosters() async      // "keep videos on this iphone" turned off
    public func reload() async                       // re-read the index (the extension may have written)
}

public struct SharedJob: Sendable, Codable, Equatable, Identifiable {
    public enum Origin: String, Sendable, Codable { case app, shareExtension }
    public enum Stage: Sendable, Codable, Equatable {
        case saving, uploadInterrupted(localFile: URL), ready, rendering(job: String),
             done(WebpResult), failed(code: String)
    }
    public var id: UUID
    public var origin: Origin
    public var link: URL?
    public var sessionID: String?
    public var media: MediaInfo?
    public var trim: TrimRange?
    public var stage: Stage
    public var wantsTrim: Bool          // "trim in cobalt": open the app on the trim
    public var pickedUp: Bool           // the app has taken it over
    public var updatedAt: Date
}
public final class SharedJobStore: Sendable {   // JSON file in the app group, NSFileCoordinator
    public init(directory: URL)
    public static func shared() -> SharedJobStore
    public func all() -> [SharedJob]
    public func upsert(_ job: SharedJob)
    public func remove(_ id: UUID)
    public func nextHandoff() -> SharedJob?       // newest from the extension with !pickedUp
}

public enum KeyInputError: Error, Sendable { case notAKey }   // not a lowercase UUID after trimming
public enum ServerInputError: Error, Sendable { case notAURL }

@MainActor @Observable
public final class Settings {
    public static let defaultServer: URL         // https://api.capybaraharmony.com
    public init(defaults: UserDefaults, keychain: Keychain)
    public static func shared() -> Settings       // app-group defaults, else .standard
    public private(set) var serverURL: URL
    public private(set) var hasAPIKey: Bool
    public var webpQuality: WebpQuality           // .med
    public var webpWidth: Int                     // 480
    public var keepVideosOnDevice: Bool           // true
    public var haptics: Bool                      // true
    public func apiKey() -> String?
    public func setAPIKey(pasted text: String) throws(KeyInputError)
    public func clearAPIKey()
    public func setServer(pasted text: String) throws(ServerInputError)   // first http(s) URL in the text, path dropped
    public func resetServer()
}
public struct Keychain: Sendable {
    public init(service: String = "com.capybaraharmony.cobalt", accessGroup: String?)
    public static let shared: Keychain            // shared access group when entitled, else default
    public func string(for account: String) -> String?
    public func set(_ value: String?, for account: String) throws
}
```

Fallbacks (unsigned builds, previews): no app-group container → `Application Support/` of the
process; no keychain group → default keychain; `UserDefaults(suiteName:)` nil → `.standard`.

### 4.7 App, library and share models

**Approved after wave 0 (Fable, 2026-10-02):** `ShareModel.live(inputItems:openApp:complete:)` and
`ShareModel.preview(_:)` (iOS only) are public; notification copy lives in CobaltKit
`Notifications.swift` (the extension posts with no UI around it) and each notification carries
`userInfo["url"]` (`cobalt-apple://job/<uuid>`), which the app delegate passes to `appModel.open(url)`.
`Pipeline` properties are `public internal(set)`. Placeholders are `Design/DesignPlaceholder.swift`
and `Shared/SharedPlaceholder.swift` (UI deletes them). Paste text per preview scenario:
`https://www.instagram.com/reel/Dd7P496wolG/` (default), `https://x.com/i/status/2105435404002562056`
(shortClip), `https://x.com/PopCrave/status/1682176754792955905` (picker), non-link text (noLink).

**Approved after the review-fix wave (Fable, 2026-10-02):** the API key is bound to the server it
was pasted for (`Settings.apiKey(in:forServer:)`; `hasAPIKey`/`apiKey()` mean "a key for the
current server"; a pre-binding key counts as the default server's); `keepsTrim` only for failures
raised while rendering (`PipelineFailure.renderPhasePrefix` = `render.`, UI strips it for display);
save polls paced ≥1 s with backoff to 10 s on quick unchanged replies; 502/503/504 retried (never
POST /render); handoffs older than 30 min ignored and never replace an on-screen result;
`ShareModel.isRendering` (sheet modal while rendering); notification permission is requested on the
first real run (app and share sheet), not at launch; `SafeFileName` for every server/share name.

**Approved after wave 1 (Fable, 2026-10-02):** `Pipeline.origin: SharedJob.Origin?` and
`Pipeline.resumedFromShare: Bool`; `ShareModel.capabilities` and `ShareModel.webpAvailable` (iOS);
public memberwise inits `Rail(steps:index:finished:)`, `TrimRange(start:end:)`,
`PickerItem(id:type:url:thumb:)`. `POST /` sends the key only when one is set (a plain cobalt
instance may be open; a fork without a key answers 401 → `.keyMissing`), superseding the
"throws `.noAPIKey` before any request" rule. Downloads of tunnel/CDN URLs omit
`Accept: application/json`. The upload reply's `item` may be `null` (server stored the file but
could not read its row back); the client tolerates it.

```swift
public enum AppTab: String, Sendable, CaseIterable { case save, library, settings }
public enum PreviewScenario: String, Sendable, CaseIterable {
    case happy, coldStart, noLink, privatePost, tooBig, renderBusy, renderLost, picker, image,
         shortClip, plainCobalt, legacyFork, revokedKey, emptyOrbit
}

@MainActor @Observable
public final class AppModel {
    public static func live() -> AppModel
    public static func preview(_ scenario: PreviewScenario = .happy) -> AppModel
    public let settings: Settings
    public let store: OfflineStore
    public let jobs: SharedJobStore
    public let library: LibraryModel
    public private(set) var capabilities: Capabilities
    public private(set) var isCheckingServer: Bool
    public private(set) var pipeline: Pipeline           // the home pipeline
    public var selectedTab: AppTab
    public var serverSummary: ServerSummary { get }       // for "this server"
    public func refreshServer() async                     // launch, foreground, server/key change
    public func open(_ url: URL)                          // cobalt-apple:// links
    public func pickUpSharedJobs() async                  // on scenePhase .active
    public func trimNewWebp(from post: LibraryPost) async // → selectedTab .save, pipeline at .ready
    public func setServer(pasted text: String) async throws(ServerInputError)
    public func setAPIKey(pasted text: String) async throws(KeyInputError)
}
public struct ServerSummary: Sendable, Equatable {
    public var host: String                               // "api.capybaraharmony.com"
    public var kind: ServerKind
    public var version: String?
    public var features: [String]                         // ["studio", "library"] (feature names, lowercase)
    public var key: KeyState
    public var keyName: String?
}

@MainActor @Observable
public final class LibraryModel {
    public private(set) var posts: [LibraryPost]
    public private(set) var postCount: Int
    public private(set) var fileCount: Int
    public private(set) var isLoading: Bool
    public private(set) var failure: PipelineFailure?
    public private(set) var hasMore: Bool
    public var expandedPostID: String?                    // one card open at a time
    public func refresh() async
    public func loadMore() async
    public func copyLink(_ file: LibraryFile)
    public func save(_ file: LibraryFile) async throws    // to Photos (macOS: caller uses fileExporter with `localCopy`)
    public func localCopy(_ file: LibraryFile) async throws -> URL
    public func host(_ file: LibraryFile) async throws -> URL   // private copy → public link (copied)
    public func delete(_ file: LibraryFile) async throws  // only when file.deletable; removes it from `posts`
}

#if os(iOS)
@MainActor @Observable
public final class ShareModel {                           // iOS only (the whole declaration is behind #if os(iOS))
    public enum CloseResult: Sendable { case dismissed, continuesInBackground }
    public let pipeline: Pipeline
    public private(set) var isLong: Bool                   // duration > maxClipSeconds once known
    public func close() async -> CloseResult               // mid-render: SharedJob(.rendering) + notification
    public func handOffToApp() async                       // wantsTrim job + open the app (or notification)
}
#endif
```

`ShareViewController` (CORE, UIKit) loads the extension's input with an internal `ShareInbox`
(web URL → link; text → `LinkInfo.firstLink`; movie → copied into `store.inboxURL` in the app
group), builds `ShareModel`, hosts `ShareRootView(model:)` (UI) in a `UIHostingController`, and
completes the request when `close()` returns. Opening the app: walk the responder chain to a
`UIApplication` and call `open(_:)` with `cobalt-apple://job/<uuid>`; if that does nothing
(it is not an official API for share extensions), post a local notification "your clip is
saved · tap to trim in cobalt" whose tap opens that URL. Either way the app takes the handoff
on its next foreground (`pickUpSharedJobs`).

### 4.8 Formatting and preview data

```swift
public enum Format {
    public static func bytes(_ n: Int64) -> String      // ≥ 1e6: "4.3 MB" (1 decimal); else "841 KB" (rounded, min "1 KB")
    public static func seconds(_ s: Double) -> String   // "10.0 s"
    public static func timecode(_ s: Double) -> String  // "00:04.1"
    public static func size(_ w: Int, _ h: Int) -> String   // "720×1280"
    public static func when(_ d: Date, now: Date) -> String // "today 12:46", "yesterday 13:59", else "3 oct 09:31"
}
```

`PreviewClient` replays the boards' real data and timings (timeScale 1 = the lab's compressed
timings; 5 = the live estimates). From `Main.dc.html`, `Share.dc.html`, `Library.dc.html`:

| thing | value |
|---|---|
| pasted link | `https://www.instagram.com/reel/Dd7P496wolG/`, title `instagram_Dd7P496wolG`, 14.77 s, 720×1280, 4,331,778 bytes |
| its webp | 480×854, 10.1 s, 4.5 MB, url `https://media.capybaraharmony.com/PrEvIeW001.webp` |
| short clip (`.shortClip`) | `https://x.com/i/status/2105435404002562056`, `twitter_2105435404002562056`, 5.46 s, 480×568; webp 841 KB, 5.4 s |
| fetch | 1.5 s; `.coldStart` 4.2 s with `waking` after 1.5 s |
| save | 0.9 s, bytes ease-out cubic `1 - (1-k)^3` to the full size |
| read | 9 frames, one per 150 ms, then 250 ms |
| upload | 8 MB/s |
| render | 4.7 s total (the live render took 23.5 s, one run): decode for the first 60 % with `frames_total = round(len × 15)`, then pack |
| `.renderLost` | fails at 55 % of the render time with `error.webp.job_lost` |
| `.picker` | 2 items: video + photo (`Picker.dc.html`) |
| `.image` | a 1.2 MB PNG upload |
| orbit (7) | `Dd55fEyN1Yy` 720×1280 37.43 s; `2105435404002562056` 480×568 5.46 s; `2105432512428445875` 498×280 1.9 s; `Dd5JFkMDt4N` 720×720 10.77 s; `Dd7RFsmT45H` 640×1136 (no duration); `2105358343657427103` 1920×1080 5.06 s; `clip` 1280×720 28 s |
| usage | 13 videos · 54 MB |
| library | the six posts of `Library.dc.html` `data()` (15 posts · 24 files in the header) |
| key | `.valid`, name `iphone`; `.revokedKey` → `.invalid` |

Frames in previews are grey gradient placeholders (`#4a4a4f → #232326`, as the boards).

## 5. Screens, copy and states

All copy is lowercase, IBM Plex Mono. Strings marked **new** are not on the boards (written
here; the owner may change them). Device word: "iphone" / "ipad" / "mac" by platform.

### 5.1 Home (save tab), `Main.dc.html`

| state | what shows | copy |
|---|---|---|
| `.idle` | orbit large (470 pt tall), offline line, two white 72 pt circles | "13 videos on this iphone · 54 MB" (`Format`; "1 video"); circles "paste", "file" (a11y "paste a link", "add a file"); empty store: **new** "your videos show up here" |
| `.fetching` | orbit small (132 pt, scale .46), rail, capsule 64 pt | "fetching from instagram" / "waking server", metric "1.4 s" (TimelineView from `since`) |
| `.uploading` | capsule + 3 pt bar | "uploading", "1.2 MB / 18.2 MB" |
| `.saving` | capsule | "saving privately", "4.3 MB"; degraded (bytes nil): "saving", seconds; plain cobalt: **new** "saving to this iphone" |
| `.reading` | work card 432 pt: title + length rolling, tc line "720×1280 · 4.3 MB", strip of frames developing, scale "0 s … …" | "reading the video", "4 / 9"; sub "frames appear as the video is read." |
| `.ready` | bracket on the strip, tc "00:00.0 → 00:10.0 of 00:14.8", scale "0 s · 7.4 s · 14.8 s" | > 10 s: "webps stop at 10 s, so the first 10 s are picked. drag to choose."; else "the whole clip fits in a webp."; "make webp"; "save to photos" → "saved to photos"; "host original" → "link copied" |
| `.rendering(.decoding)` | lit frames inside the bracket | "decoding frames", "42 / 150"; "every frame in the bracket lights up once decoded." |
| `.rendering(.packing)` | bracket breathes | "packing webp", "3.1 s"; "no count for this part, so it just breathes." |
| `.rendering(.working)` | bracket breathes | **new** "making webp", seconds; "no count from this server, so it just breathes." |
| `.done` | card 470 pt: tile lifts in, meta, url | "webp ready", "back to trim", "480×854 · 10.1 s · 4.5 MB", the URL without scheme, "copy link" → "copied", "share" |
| `.image` | card 190 pt | name + size; "this is an image, so there is nothing to trim. it can be hosted as it is."; "host as-is" → "link copied" |
| `.savedLocally` | card 190 pt (plain cobalt) | name + size; **new** "saved on this iphone."; "save to photos", "share" |
| `.picker` | sheet (5.4) | |
| `.failed` | capsule 64 pt (84 pt for `fetchFailed`), red ring, shake | "no link found in that text." / "that file is over the 100 MB limit." / "cobalt couldn't fetch this link. the post may be private or removed." + "ok"; **new**: `.unsupported` "cobalt for apple can't save this kind of post yet."; `.serverBusy` "cobalt is busy with another video. try again in a minute."; `.expired` "this video's studio has expired."; `.keyMissing` "add your api key in settings first." + "settings"; `.keyInvalid` "this key was revoked" + "settings"; `.unreachable` "can't reach the server."; `.server(code)` "something went wrong (\(code))." |
| `.failed(.renderBusy)` | inside the work card, trim kept | "another webp is being made right now." + "try again" |
| `.failed(.renderLost)` | inside the work card, trim kept | "the webp was lost while cobalt was in the background. your trim is kept." + "make it again" |

Rail labels: "fetch" / "upload", "save", "read", "webp" / "host" (image). Tab bar: "save",
"library", "settings". Mac/iPad with a keyboard: ⌘V = paste circle; dropping a file anywhere =
file circle; arrow keys move the focused handle 0.1 s; I / O set in / out at the preview's
playhead (wide tier).

### 5.2 Library, `Library.dc.html` (compact/regular) and `Mac.dc.html` (wide)

Header "library" + "15 posts · 24 files"; the two black circles (paste, file) under it, which
switch to the save tab and start the pipeline. Card: 64 pt preview with the aspect box, "x ·
2105435404002562056", meta "5.5 s · 480×568 · yesterday 13:43", pills "webp" (filled), "mp4
link" (blue outline), "private" (grey outline). One card open at a time; open card plays its
preview (local file when stored, else the webp). File rows: "webp 10.1 s" / "mp4 link" /
"private copy" with meta "4.5 MB · 480×854 · public" / "8.3 MB · public" / "4.3 MB · mp4";
actions "copy" → "copied" (public), "save" → "saved" (private), "delete" (deletable only),
disabled "delete on web" (hosted mp4). Delete asks inline: "delete for everyone? discord embeds
stop working." "delete" / "keep"; the row dissolves. Footer: "trim a new webp" (has a webp) or
"make a webp", and "close". Wide (Mac board): list 380 pt left, the post right with "what exists
for this post", "save as… ⌘S" (macOS file export), "host it", "copy link ⌘C", "delete ⌘⌫",
"trim a new webp ⌘T", meta "studio open 6 more days". Errors: **new** "can't load the library."
+ "try again". Hidden when `capabilities.library` is false.

### 5.3 Settings, `Settings.dc.html`

Title "settings". Group "server": "api" = host; "this server" = "cobalt 11.7.1 + studio,
library" / "cobalt 11.7.1" (plain) / "cobalt + studio" (legacy fork) / **new** "can't reach
this server" / **new** "this isn't a cobalt server"; buttons **new** "paste server url",
"reset". "api key" = "iphone · ••••••••" (`keyName`, else "set"); none: **new** "no key" +
"paste key"; invalid: red "this key was revoked" + "paste new key". Footnote: "make keys on the
web: cobalt → settings → api keys. the app keeps it in the keychain and sends it as
"Authorization: Api-Key …". revoking it on the web locks this phone out at once." Group
"making": "webp quality" (low / medium / high; wire values low/med/high); "keep videos on this
iphone" toggle; "stored here" "13 videos · 54 MB". Group "feel": "haptics" toggle; "motion"
"follows reduce motion" (display only). Footer: "on a plain cobalt server (no studio routes)
the same circles still save through cobalt's normal api; webp, studio and library just hide.
your two shortcuts keep working." Pasting a bad key: **new** "that isn't a cobalt api key."

### 5.4 Picker sheet, `Picker.dc.html`

Sheet over the dimmed home (detent ~612 pt on iPhone). "select what to save", "this post has
more than one thing in it. press an item to save it, or turn a video into a webp." 2-column
grid of square thumbs with a badge "video" / "photo" / "gif"; buttons "save" (filled) and
"webp" (videos and gifs, fork only). Bottom: "save both to photos" (2 items) / **new** "save all
\(n) to photos"; note "webp only appears on videos and gifs. photos stay photos."

### 5.5 Share sheet, `Share.dc.html`

Compact sheet: header "cobalt" + close; the chip (service + ref); the rail; a card with the
name, length, strip and one work row. Copy: "fetching from x", "saving privately", "reading the
video", "decoding frames" with the same metrics. ≤ 10 s ready: "the whole clip fits in a webp."
"make webp", "save to photos". > 10 s ready: "14.8 s is over the 10 s webp limit. it's saved, so
cobalt opens right on the trim." "trim in cobalt", "save to photos". Done: "480×568 · 5.4 s · 841
KB · <url>", "copy link" → "copied", "done". Close mid-render → notification **"cobalt is still
making your webp"** (tap opens the app). The app on that job: "still making the webp you
started in the share sheet…" + "making webp…" (disabled), then "finished while the sheet was
closed. 841 KB, link ready." + "copy link"; a handed-off long clip opens on the trim with "webps
stop at 10 s, so the first 10 s are picked. drag to choose." + "make webp".

## 6. Motion

Springs are written as SwiftUI `.spring(duration:bounce:)`, matched by feel to the boards'
cubic-beziers (the boards' numbers are the target, not an exact conversion).

| what | from → to | animation | reduce motion |
|---|---|---|---|
| circle press | scale 1 → 0.9 | `.spring(duration: 0.2, bounce: 0.4)` | none |
| tapped circle → work card | circle (72 pt) grows into the capsule, then the card (`matchedGeometryEffect(id: "input")`; paste opens from the left circle, file from the right) | `.spring(duration: 0.62, bounce: 0.22)`; card height 64 / 84 / 190 / 432 / 470 pt with radius 32 → 22 | crossfade 0.2 s |
| orbit large ↔ small | height 470 ↔ 132, scale 1 ↔ 0.46 | `.spring(duration: 0.7, bounce: 0.18)` | jump |
| orbit | 48 s per revolution, ellipse radius 132 pt tilted (y × 0.42), thumbs fit 92 pt, front scale 1 / brightness 1, sides 0.8 / 0.72, back 0.6 / 0.45; `TimelineView(.animation)` | linear | stopped; also stopped in Low Power Mode and when not visible |
| link chip | scale 1.35 + blur 5 → none, from the right | `.spring(duration: 0.55, bounce: 0.4)` | crossfade |
| rail highlight | moves cell to cell | `.spring(duration: 0.5, bounce: 0.35)` | jump |
| numbers (seconds, bytes, frames, length) | | `.contentTransition(.numericText())` | `.identity` |
| frame develops | opacity 0 → 1 (0.5 s ease), blur 8 → 0 and scale 1.12 → 1 (`.spring(duration: 0.6, bounce: 0.3)`), as each real frame arrives | | opacity only, 0.2 s |
| bracket appears | scaleY 1.4 → 1 | `.spring(duration: 0.55, bounce: 0.4)` | crossfade |
| bracket over limit | rubber band 0.25×, border + handles red `#ed2236`, light impact haptic per hit (`.sensoryFeedback(.impact(weight: .light), trigger: limitHits)`) | live | same (haptic stays) |
| bracket snap on release | back inside the limit | `.spring(duration: 0.5, bounce: 0.4)` | jump |
| decode lights | frames inside the bracket brighten (×1.45) with a 4 pt bottom bar as decoded | 0.3 s ease | same |
| packing | bracket glow 0 → 6 pt and back, 1.4 s | `PhaseAnimator` | static |
| result | the bracket span lifts into the tile (`matchedGeometryEffect(id: "span")`) | `.spring(duration: 0.75, bounce: 0.4)`; `.sensoryFeedback(.success)` | crossfade |
| result → orbit | on leaving `.done` the tile drops into the orbit's front slot and pops (scale 0.2 → 1, outlined) | `.spring(duration: 0.8, bounce: 0.45)` | crossfade |
| error | red ring + shake (-6, 5, -3, 0 pt over 0.42 s); `.sensoryFeedback(.error)` | | ring only |
| copy → copied | fill to `#30bd1b` (done) or text swap; `.sensoryFeedback(.success)` | 0.25 s | same |
| library card | expand/collapse body | `.spring(duration: 0.5, bounce: 0.2)`; file rows in `.spring(duration: 0.4, bounce: 0.35)` from y -6 | crossfade |
| library delete | row scale 0.9 + blur 5 + fade | 0.42 s easeIn | fade |
| fold / resize | regroup between tiers | `.spring(duration: 0.75, bounce: 0.12)` | jump |
| share → app | the app opens on the trim (clip reveal from the sheet) | `.spring(duration: 0.6, bounce: 0.1)` | crossfade |

Haptics obey `settings.haptics`. Players: the orbit keeps a pool of 3 `AVPlayer`s (muted,
`AVPlayerLooper` over the first 3 s) bound to the 3 front-most items; webp items animate with
`CGAnimateImageAtURLWithBlock`; everything else shows its poster.

## 7. Adaptive layout

One `AppShell` decides the tier from its own width (`GeometryReader` / `onGeometryChange`),
not size classes (a fold or an iPad split view changes width without a clean class change).

| tier | width | navigation | home / work card | library |
|---|---|---|---|---|
| compact | < 600 pt | bottom tab bar, 83 pt, 3 tabs | one column: orbit, rail, card, circles (`Main.dc.html`) | cards (`Library.dc.html`) |
| regular | 600-999 pt | cobalt's 80 pt sidebar (`--sidebar-width`), vertical icon + label tabs, active tab filled `#e1e1e1` with black text, background `#131313` | card regroups: preview (9:16, plays the selection) beside the trim, quality + "make webp" in a side column (`Fold.dc.html`); the strip stretches the same 9 real frames (the board's 14 is not reproduced) | cards, wider |
| wide | ≥ 1000 pt | labelled sidebar (iPad 236 pt, Mac 190 pt; "save", "library", "settings") | regular layout plus an inspector column 320 pt (selection "10.0 s", "00:03.2 → 00:13.2", quality "low / medium / high", "480 px", "make webp", "made from this video") (`IPad.dc.html`) | list 380 pt + post detail (`Mac.dc.html`) |

Nothing is added or renamed between tiers; elements regroup. Mac: `WindowGroup` min size
900×600, `.commands` for ⌘V / ⌘T, drop target on the whole window. Unfolded foldable size is
unverified (the board guessed 1125×844 pt); the tier logic does not depend on it.

## 8. Design tokens (UI owns `apple/Cobalt/Design/`)

From `web/src/app.css` and the boards. Dark (default look of the boards): background `#000`,
surface `#191919`, elevated `#282828`, text `#e1e1e1`, caption `#8f8f8f`, border `#383838`,
sidebar `#131313`, error text `#ff5c6c`. Light: `#fff`, `#f4f4f4`, `#e3e3e3`, `#000`,
`#6e6e75`, border `#adadb7`, error text `#c4142a`. Error fill / ring `#ed2236`; success
`#30bd1b`; focus ring `#2f8af9`. Radius 11 (cards 22, capsule 32, thumbs 12). Font IBM Plex
Mono 400/500/600 (sizes from the boards: 26 title, 13.5 body, 12 caption, 11 tab labels);
`CobaltFont.register()` at launch in both targets; fallback `.system(design: .monospaced)`.
Font files: the owner approves fetching IBM Plex Mono TTF (OFL-1.1) from IBM's official
`IBM/plex` release; until then the fallback is used (the latin `.woff2` subsets in a local web
build are not a substitute: CoreText's WOFF2 support is unverified here).

## 9. Gates (exact commands, from the repo root)

Every lane, before reporting done (Fable reruns them):

```sh
cd apple && xcodegen generate && cd ..
xcodebuild -project apple/Cobalt.xcodeproj -scheme Cobalt \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -derivedDataPath apple/.build/ios CODE_SIGNING_ALLOWED=NO build
xcodebuild -project apple/Cobalt.xcodeproj -scheme Cobalt \
  -destination 'platform=macOS' \
  -derivedDataPath apple/.build/mac CODE_SIGNING_ALLOWED=NO build
(cd apple/CobaltKit && swift test)
```

Plus: no `warning:` lines from files under `apple/` in either build log (Swift 6 concurrency
warnings included). Lane API: `cd deploy/cloudflare/api && npm test && npm run typecheck`, the
same in `deploy/cloudflare/web`.

`swift test` must cover at least: link extraction (the worker's cases), capability detection for
all five kinds (fixture responses, including the 302 and the bare 404), decoding of sessions,
render statuses and library pages **with and without** the new fields, the trim math cases in
4.4, the error code map, `Format`, the 4.5 state sequences against `PreviewClient` for every
`PreviewScenario` (with an injected clock, no real sleeps), `SharedJobStore` round trip across
two instances, `OfflineStore` add / usage / drop-files in a temp dir.

Wave 2 runtime checklist (Sonnet verification lane, evidence saved to a session path): iPhone
17 Pro simulator, compact: idle orbit, paste with a link on the pasteboard through `.done`
against the deployed API (or `PreviewClient` before it deploys); the same at 700 pt (regular)
and on an iPad simulator (wide); Mac app launches and the library list/detail renders; Reduce
Motion on (orbit still, crossfades); plain cobalt server detected (a local `docker run` of
upstream cobalt is acceptable) with webp/library hidden; share extension in a signed build only
(needs the owner's team).

## 10. Risks

- **Opening the app from the share extension** is not an official API; the responder-chain
  call may do nothing on iOS 18+/27. The notification fallback and `pickUpSharedJobs` keep the
  flow working, one tap longer.
- **Paste prompt**: reading `UIPasteboard.general.string` shows iOS's "allow paste" prompt
  every time unless the owner sets Settings › cobalt › Paste from Other Apps › Allow. The
  system `PasteButton` avoids the prompt but cannot look like the white circle. Product call;
  default here is the custom circle + the prompt. macOS 15.4+ has a similar pasteboard privacy
  setting.
- **Share extension memory** (~120 MB): never decode the whole video; frames via
  `AVAssetImageGenerator` with `maximumSize` 360 pt; copy files with `FileManager`, not `Data`.
- **AVURLAsset on `/source`**: the URL has no extension; AVFoundation relies on the
  `content-type` header. If it refuses, pass `AVURLAssetOverrideMIMETypeKey` with the
  session's content type.
- **Server sweep unverified on the deployed runtime** (API contract section 6). Until it is,
  closing the share sheet mid-render can still lose the webp; the app shows `.renderLost` with
  the trim kept.
- **Unsigned builds** have no app group or keychain sharing; anything crossing the
  app/extension boundary is only testable once the owner adds a team in `Local.xcconfig`.
- **Multiplatform target**: if XcodeGen's `supportedDestinations` output misbehaves with the
  iOS-only extension embed, fall back to two targets (`Cobalt` iOS, `CobaltMac` macOS) sharing
  `apple/Cobalt/**`, scheme `CobaltMac` for the macOS gate. CORE decides in wave 0 and reports.
- Orbit performance (3 players + 48 s rotation) is unmeasured on a phone.

## 11. Out of scope (first pass)

Push notifications and a "your webp is ready" alert; Live Activities; App Intents / Shortcuts
actions (the owner's two existing Shortcuts keep working); the Mac menu bar extra; a macOS share
extension; widgets; frame stepping and "play selection" buttons from the iPad board (the
preview loops the selection instead); deleting private copies or hosted mp4s from the app;
YouTube-specific handling (`local-processing` posts show `.unsupported`); localisation; App
Store distribution.
