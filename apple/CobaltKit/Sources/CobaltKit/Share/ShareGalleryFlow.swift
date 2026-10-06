import Foundation
import Observation

// The share sheet for a gallery (apple/CONTRACT-GALLERY.md 1.12, board `Share-Gallery`; wire: APP-API-CONTRACT 18.12).
//
// A single video or photo stays notification-only: the extension asks the server what the link is (`POST /` and
// `GET /capabilities` together, the stored key), and when it is one item it queues the instant save and closes. A post
// with several items gets ONE compact sheet:
//
//   resolving   nothing on screen (the first 700 ms)
//   checking    the sheet at its final height: row 1 `save now` is live, rows 2-3 are bars (after 700 ms with no answer)
//   choosing    the same sheet with every row filled in: `save all`, `save + slideshow webp`, `save + gallery image`
//   oldServer   the same-height card `this server can't save photo posts yet`
//   sending     ONE request is on its way (a choice, `save now`, the 8 s fallback or a single item)
//   sent        the request was accepted; held for a moment when the sheet is on screen, then it closes
//   failed      the save could not be queued (same frame, same height)
//
// The sheet never changes height while it is open: `rows` is decided once, before the sheet first shows, and every
// state draws inside the same frame. Without an app group (the owner's Feather build) nothing is handed to the app: the
// server saves, makes and tells the owner through Hark; the app finds the post through `GET /studio/recent` and
// `GET /library?v=3` the next time it opens.

/// What the flow asks the server before it decides (resolve and capabilities); `HTTPCobaltClient` is the real one.
public protocol ShareGalleryServer: Sendable {
    func resolve(_ link: URL) async throws -> CobaltResult
    func capabilities() async -> Capabilities
}

extension HTTPCobaltClient: ShareGalleryServer {}

/// The request the flow hands to its sender: today's instant save, or `POST /studio` with the gallery fields.
enum ShareSend: Sendable, Equatable {
    case plain(LinkInfo)
    case options(LinkInfo, StudioCreateOptions)
}

/// Sends one request. The real one is `InstantShareEngine` (the same two transports as the instant share).
protocol ShareGallerySender: Sendable {
    func send(_ request: ShareSend, job: UUID) async -> InstantShare.Result
}

/// Every budget the sheet works to (pinned by the contract: 700 ms, 8 s). Tests and previews shorten or hold them.
public struct ShareGalleryTiming: Sendable, Equatable {
    /// No answer by now: the sheet appears in its checking state.
    public var showAfter: Duration = .milliseconds(700)
    /// The header changes from `checking the link` to `waking the server`.
    public var wakingAfter: Duration = .milliseconds(2500)
    /// No answer by now: save everything and close (owner decision 4).
    public var giveUpAfter: Duration = .seconds(8)
    /// How long `sent to cobalt` shows before the sheet closes (only when the sheet is on screen).
    public var sentHold: Duration = .milliseconds(500)

    public static let standard = ShareGalleryTiming()

    public init(
        showAfter: Duration = .milliseconds(700), wakingAfter: Duration = .milliseconds(2500),
        giveUpAfter: Duration = .seconds(8), sentHold: Duration = .milliseconds(500)
    ) {
        self.showAfter = showAfter
        self.wakingAfter = wakingAfter
        self.giveUpAfter = giveUpAfter
        self.sentHold = sentHold
    }
}

struct ShareGalleryEnvironment: Sendable {
    var server: any ShareGalleryServer
    var sender: any ShareGallerySender
    /// Waits `duration` (tests drive it by hand).
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// The local "saving to cobalt" notification: job, title, body. Only when the owner already allowed notifications.
    var notify: @Sendable (UUID, String, String) async -> Void = { _, _, _ in }
    /// Takes the notification back (the request could not be queued).
    var unnotify: @Sendable (UUID) -> Void = { _ in }
    var now: @Sendable () -> Date = { Date() }
    var timing = ShareGalleryTiming.standard
    /// Settings "make new saves public" (on by default).
    var makePublic = true
    /// The webp's quality and width: the extension's own settings defaults on a build with no app group.
    var webpQuality: WebpQuality = .med
    var webpWidth = 480
}

@MainActor @Observable
public final class ShareGalleryFlow {
    /// One request, as the owner's choice or the flow's fallback.
    public enum Request: Sendable, Equatable {
        /// A single video or photo (or a link the server could not resolve): today's instant save.
        case single
        /// `save now` while the sheet is still checking: everything, with no count to check against.
        case saveNow
        /// 8 s without an answer: save everything and close.
        case timeout
        case saveAll
        case slideshowWebp
        case galleryImage(GalleryLayout)

        var telemetryName: String {
            switch self {
            case .single: return "single"
            case .saveNow: return "now"
            case .timeout: return "timeout"
            case .saveAll: return "all"
            case .slideshowWebp: return "webp"
            case .galleryImage: return "image"
            }
        }
    }

    public enum Phase: Sendable, Equatable {
        case resolving, checking, choosing, oldServer
        case sending(Request), sent(Request)
        case failed(InstantShare.Failure)
    }

    public enum Finish: Sendable, Equatable {
        /// The request was accepted: complete the extension request.
        case sent
        /// The owner closed the sheet: nothing was sent.
        case cancelled
        /// `open cobalt`: open the app, then complete.
        case openCobalt
    }

    /// Which rows the sheet has. Decided once, before the sheet first shows, and never again.
    public enum Rows: Sendable, Equatable {
        /// header + `save all` + `save + slideshow webp` + `save + gallery image`.
        case full
        /// header + `save all` only: the server can save galleries but not make anything (known before the sheet showed).
        case short
    }

    /// The post, as the picker described it (the extension knows each item's kind and nothing else).
    public struct Summary: Sendable, Equatable {
        /// The items a request names: the first 20 (the server saves 20 at most).
        public var items: [GalleryItem]
        /// What the post holds (`item_count`).
        public var total: Int
        public var photos: Int
        /// Videos and gifs.
        public var videos: Int
        /// The estimate under `save + slideshow webp` (every figure is "about").
        public var webpSeconds: Double
        public var webpBytes: Int64

        public var count: Int { items.count }
        public var photosOnly: Bool { videos == 0 }
        /// A gallery image needs 2 photos.
        public var imagePossible: Bool { photos >= 2 }
    }

    // MARK: what the sheet and the controller read

    public private(set) var phase: Phase = .resolving
    /// Set once the flow is over: complete the extension request.
    public private(set) var finish: Finish?
    /// The sheet was asked for (checking, choosing or the old-server card) and stays on screen until `finish`.
    public private(set) var sheetShown = false
    public private(set) var rows: Rows = .full
    public private(set) var summary: Summary?
    /// The server can make slideshows and gallery images (`features.gallery_make`). False until known.
    public private(set) var canMake = false
    /// The header says `waking the server` (2.5 s without an answer).
    public private(set) var waking = false
    /// When the share began: the header counts seconds from here.
    public let startedAt: Date
    /// `instagram · Ddy0-gpGg5U`: what the sheet and the notifications call the post.
    public let title: String

    /// A request is on its way: the sheet cannot be swiped away (that would drop the request).
    public var isSending: Bool { if case .sending = phase { return true } else { return false } }
    /// A failure with no sheet to show it in: the controller draws the one-line card.
    public var cardFailure: InstantShare.Failure? {
        if case .failed(let failure) = phase, !sheetShown { return failure }
        return nil
    }
    /// The rows answer a tap (checking: only `save now`).
    public var canChoose: Bool { phase == .choosing }
    public var canSaveNow: Bool { phase == .checking || phase == .choosing }

    // MARK: wiring

    let link: LinkInfo
    let env: ShareGalleryEnvironment
    private var resolved: Result<CobaltResult, any Error>?
    private var caps: Capabilities?
    private var started = false
    private var requested = false
    private var job = UUID()
    private var tasks: [Task<Void, Never>] = []

    init(link: LinkInfo, env: ShareGalleryEnvironment) {
        self.link = link
        self.env = env
        self.title = InstantShareEngine.label(for: link)
        self.startedAt = env.now()
    }

    /// Starts the clock and asks the server (`POST /` and `GET /capabilities` together). Call once.
    public func begin() {
        guard !started else { return }
        started = true
        let server = env.server, url = link.url
        track { [weak self] in
            let result: Result<CobaltResult, any Error>
            do { result = .success(try await server.resolve(url)) } catch { result = .failure(error) }
            self?.received(resolved: result)
        }
        track { [weak self] in
            let caps = await server.capabilities()
            self?.received(capabilities: caps)
        }
        let timing = env.timing, sleep = env.sleep
        track { [weak self] in
            guard (try? await sleep(timing.showAfter)) != nil else { return }
            self?.showAfterElapsed()
        }
        track { [weak self] in
            guard (try? await sleep(timing.wakingAfter)) != nil else { return }
            self?.waking = true
        }
        track { [weak self] in
            guard (try? await sleep(timing.giveUpAfter)) != nil else { return }
            self?.gaveUp()
        }
    }

    // MARK: the owner's taps

    /// A tap on a row. In `checking` only `save now` (row 1) is live: it is `.saveNow`, whatever was asked.
    public func choose(_ request: Request) {
        guard !requested else { return }
        switch phase {
        case .checking:
            if request == .saveAll { start(.saveNow) }
        case .choosing:
            switch request {
            case .saveAll, .slideshowWebp, .galleryImage:
                if request != .saveAll, !canMake { return }
                if case .galleryImage = request, !(summary?.imagePossible ?? false) { return }
                start(request)
            default: return
            }
        default: return
        }
    }

    /// Close (the X, a swipe away): nothing is sent. Ignored while a request is on its way.
    public func cancel() {
        guard finish == nil else { return }
        if case .sending = phase { return }
        if case .sent = phase { return }
        stop()
        Telemetry.log(.info, .share, "share choice", data: ["choice": "closed", "waited_ms": .int(waitedMs)])
        finish = .cancelled
    }

    /// `open cobalt` on the old-server card or the failure card.
    public func openCobalt() {
        guard finish == nil else { return }
        switch phase {
        case .oldServer, .failed: stop(); finish = .openCobalt
        default: return
        }
    }

    // MARK: the server's answers

    private func received(resolved result: Result<CobaltResult, any Error>) {
        guard !requested, finish == nil, resolved == nil else { return }
        resolved = result
        evaluate()
    }

    private func received(capabilities value: Capabilities) {
        guard !requested, finish == nil, caps == nil else { return }
        caps = value
        evaluate()
    }

    private func showAfterElapsed() {
        guard phase == .resolving, !requested, finish == nil else { return }
        phase = .checking
        sheetShown = true
        rows = .full
    }

    private func gaveUp() {
        guard !requested, finish == nil else { return }
        switch phase {
        case .resolving, .checking: start(.timeout)
        default: return
        }
    }

    private func evaluate() {
        guard !requested, finish == nil, phase == .resolving || phase == .checking, let resolved else { return }
        switch resolved {
        case .failure:
            // cobalt could not resolve it from here: the server's own save decides, and tells the owner if it fails.
            start(.single)
        case .success(let result):
            guard case .picker(let items, _) = result, items.count >= 2 else { start(.single); return }
            guard let caps else { return }                       // rows depend on what the server can do: wait for it
            summary = Self.summary(of: items, width: env.webpWidth, quality: env.webpQuality)
            guard caps.gallery else {
                rows = .full
                sheetShown = true
                phase = .oldServer
                Telemetry.log(.info, .share, "share gallery", data: ["result": "old-server", "items": .int(items.count)])
                return
            }
            canMake = caps.galleryMake
            if phase == .resolving { rows = caps.galleryMake ? .full : .short } else { rows = .full }
            sheetShown = true
            phase = .choosing
            Telemetry.log(.info, .share, "share gallery", data: [
                "result": "picker", "items": .int(items.count), "make": .bool(caps.galleryMake), "ms": .int(waitedMs),
            ])
        }
    }

    // MARK: the one request

    private var waitedMs: Int { Int(env.now().timeIntervalSince(startedAt) * 1000) }

    private func start(_ request: Request) {
        guard !requested, finish == nil else { return }
        requested = true
        cancelTimers()
        let send = built(request)
        let (head, body) = ShareGalleryText.notification(for: request, summary: summary, title: title)
        phase = .sending(request)
        var data: [String: TelemetryValue] = ["choice": .string(request.telemetryName), "waited_ms": .int(waitedMs)]
        if case .galleryImage(let layout) = request { data["layout"] = .string(layout.rawValue) }
        Telemetry.log(.info, .share, "share choice", data: data)
        let job = job, env = env
        track { [weak self] in
            async let notified: Void = env.notify(job, head, body)
            let result = await env.sender.send(send, job: job)
            await notified
            await self?.sendFinished(request, result)
        }
    }

    private func built(_ request: Request) -> ShareSend {
        switch request {
        case .single: return .plain(link)
        default: return .options(link, options(for: request))
        }
    }

    /// The `POST /studio` body of each choice (APP-API-CONTRACT 18.12).
    func options(for request: Request) -> StudioCreateOptions {
        var o = StudioCreateOptions(makePublic: env.makePublic ? true : nil, queue: true, origin: "share", items: .all)
        let saved = NotifyOptIn(on: [.saved, .failed], label: title)
        let made = NotifyOptIn(on: [.rendered, .failed], label: title)
        let info = summary?.items ?? []
        switch request {
        case .single, .saveNow, .timeout:
            o.notify = saved
        case .saveAll:
            o.itemCount = summary?.total
            o.notify = saved
        case .slideshowWebp:
            o.itemCount = summary?.total
            o.notify = made
            o.itemInfo = info
            o.slideshow = SlideshowPlan(
                format: .webp, items: info.map(\.id), photoSeconds: SlideshowPlan.defaultPhotoSeconds, fade: true,
                frame: .asPosted, sound: .none, quality: env.webpQuality, width: env.webpWidth)
        case .galleryImage(let layout):
            o.itemCount = summary?.total
            o.notify = made
            o.itemInfo = info
            o.galleryImage = GalleryImagePlan(items: info.map(\.id), layout: layout)
        }
        return o
    }

    private func sendFinished(_ request: Request, _ result: InstantShare.Result) async {
        guard finish == nil else { return }
        switch result {
        case .saved, .needsSheet:
            if sheetShown {
                phase = .sent(request)
                if (try? await env.sleep(env.timing.sentHold)) == nil { return }
            }
            guard finish == nil else { return }
            finish = .sent
        case .failed(let failure):
            env.unnotify(job)
            phase = .failed(failure)
        }
    }

    private func track(_ work: @escaping @MainActor @Sendable () async -> Void) {
        tasks.append(Task { await work() })
    }

    private func cancelTimers() {
        for task in tasks { task.cancel() }
        tasks.removeAll()
    }

    private func stop() { cancelTimers() }
}

extension ShareGalleryFlow {
    /// The post as the picker described it: the first 20 items (the server saves 20 at most), their kinds, and the
    /// webp estimate at the frame the extension can guess (4:5, the width the owner's settings give).
    static func summary(of picker: [PickerItem], width: Int, quality: WebpQuality) -> Summary {
        let all = picker.map(GalleryItem.init)
        let items = Array(all.prefix(20))
        let photos = items.filter(\.isPhoto).count
        let plan = SlideshowPlan(
            format: .webp, items: items.map(\.id), photoSeconds: SlideshowPlan.defaultPhotoSeconds, fade: true,
            frame: .asPosted, sound: .none, quality: quality, width: width)
        let frame = CGSize(width: CGFloat(width), height: CGFloat(width) * 1.25)
        return Summary(
            items: items, total: all.count, photos: photos, videos: items.count - photos,
            webpSeconds: plan.length(of: items), webpBytes: MakeEstimate.webpBytes(items, plan: plan, frame: frame))
    }
}

/// The local notification's words (the share extension posts it before any UI exists: the strings live in CobaltKit like
/// the rest of `Notifications`). They read exactly like `Copy.Gallery` (CONTRACT-GALLERY.md section 3).
enum ShareGalleryText {
    static func notification(
        for request: ShareGalleryFlow.Request, summary: ShareGalleryFlow.Summary?, title: String
    ) -> (head: String, body: String) {
        switch request {
        case .single:
            return ("saving to cobalt", title)
        case .saveNow, .timeout:
            return ("saving everything to cobalt", "open cobalt to make something from it")
        case .saveAll:
            return (saving(summary), title)
        case .slideshowWebp:
            return (saving(summary), "making a slideshow webp · \(title)")
        case .galleryImage:
            return (saving(summary), "making a gallery image · \(title)")
        }
    }

    /// "saving 10 photos to cobalt" / "saving 4 items to cobalt".
    static func saving(_ summary: ShareGalleryFlow.Summary?) -> String {
        guard let summary else { return "saving everything to cobalt" }
        let n = summary.count
        let noun = summary.photosOnly ? (n == 1 ? "photo" : "photos") : (n == 1 ? "item" : "items")
        return "saving \(n) \(noun) to cobalt"
    }
}
