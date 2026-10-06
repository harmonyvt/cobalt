import CoreGraphics
import Foundation
import Synchronization

// The gallery scenarios of `PreviewClient` (apple/CONTRACT-GALLERY.md, boards `Gallery-Paste`, `Gallery-Combine`,
// `Gallery-Image`): an Instagram carousel of 10 photos, an X post of 4, a mixed post, a single photo, a post whose item 7
// cannot be fetched (until it is retried), a server that cannot make, and a make that fails once. Everything runs on the
// pipeline's clock, so tests drive it with a virtual one.

extension PreviewScenario {
    /// Any of the gallery scenarios: the preview server has `features.gallery` and resolves a multi-item post.
    var isGallery: Bool {
        switch self {
        case .galleryInstagram, .galleryX, .galleryMixed, .galleryOne, .galleryPartial, .galleryNoMake, .galleryMakeFails: return true
        default: return false
        }
    }
}

/// One post of the gallery scenarios, as the boards drew it.
struct PreviewGalleryPost: Sendable, Equatable {
    struct Item: Sendable, Equatable {
        var type: MediaType
        var width: Int
        var height: Int
        var duration: Double?
        var bytes: Int64
    }

    var ref: String
    var service: String
    var link: URL
    var items: [Item]
    /// Items the first save cannot fetch ("photo 7 couldn't be fetched: the link expired"); a retry fetches them.
    var failing: Set<Int>
}

extension PreviewData {
    static func photos(_ n: Int, width: Int = 1080, height: Int = 1350) -> [PreviewGalleryPost.Item] {
        (0..<n).map { _ in PreviewGalleryPost.Item(type: .photo, width: width, height: height, duration: nil, bytes: 210_000) }
    }

    /// The post a gallery scenario resolves to; nil for every other scenario.
    static func galleryPost(for scenario: PreviewScenario) -> PreviewGalleryPost? {
        func ig(_ failing: Set<Int> = []) -> PreviewGalleryPost {
            PreviewGalleryPost(
                ref: "Ddy0-gpGg5U", service: "instagram", link: URL(string: "https://www.instagram.com/p/Ddy0-gpGg5U/")!,
                items: photos(10), failing: failing)
        }
        switch scenario {
        case .galleryInstagram, .galleryNoMake, .galleryMakeFails: return ig()
        case .galleryPartial: return ig([6])
        case .galleryX:
            // the post's real sizes were not recorded: the stand-ins of CONTRACT-GALLERY 6.4
            return PreviewGalleryPost(
                ref: "@ilokineedsleep", service: "x", link: URL(string: "https://x.com/ilokineedsleep/status/2106850389551374806")!,
                items: [(1200, 1500), (1500, 1200), (1200, 1200), (1200, 1500)].map {
                    PreviewGalleryPost.Item(type: .photo, width: $0.0, height: $0.1, duration: nil, bytes: 260_000)
                }, failing: [])
        case .galleryMixed:
            return PreviewGalleryPost(
                ref: "DdMix1xedPo", service: "instagram", link: URL(string: "https://www.instagram.com/p/DdMix1xedPo/")!,
                items: photos(2) + [
                    PreviewGalleryPost.Item(type: .video, width: 1080, height: 1350, duration: 12.4, bytes: 3_100_000),
                    PreviewGalleryPost.Item(type: .gif, width: 1080, height: 1350, duration: 3.2, bytes: 900_000),
                ], failing: [])
        case .galleryOne:
            return PreviewGalleryPost(
                ref: "@ilokineedsleep", service: "x", link: URL(string: "https://x.com/ilokineedsleep/status/2106850389551374807")!,
                items: [PreviewGalleryPost.Item(type: .photo, width: 1200, height: 1500, duration: nil, bytes: 260_000)], failing: [])
        default: return nil
        }
    }

    static func galleryPickerItems(_ post: PreviewGalleryPost) -> [PickerItem] {
        post.items.enumerated().map { i, item in
            PickerItem(
                id: i, type: item.type, url: URL(string: "https://api.capybaraharmony.com/tunnel?id=PrEvIeWg\(i)")!,
                thumb: URL(string: "https://media.capybaraharmony.com/PrEvIeWt\(i).jpg"))
        }
    }

    /// Seconds a gallery save takes: the fetch, then a little for each item (before the time scale).
    static func gallerySaveSeconds(_ post: PreviewGalleryPost) -> Double { fetchSeconds + 0.3 * Double(post.items.count) }
}

/// What the "server" holds for the galleries a preview client created.
final class PreviewGalleryServer: Sendable {
    struct Made: Sendable, Equatable {
        var id: String
        var kind: MadeKind
        var role: GalleryRole
        var createdAt: Date
        var bytes: Int64
        var width: Int
        var height: Int
        var seconds: Double?
        var items: [Int]
        var spec: Data
    }

    struct Job: Sendable {
        var job: String
        var make: GalleryMake
        var startedAt: Date
        var duration: Double
        var fails: Bool
        var result: MadeResult
        var made: Made
        var committed = false
    }

    struct Gallery: Sendable {
        var sid: String
        var post: PreviewGalleryPost
        var createdAt: Date
        var startedAt: Date
        var duration: Double
        var makePublic: Bool
        var failing: Set<Int>
        var deleted: Set<Int> = []
        var made: [Made] = []
        var jobs: [String: Job] = [:]
        var makeFailuresLeft: Int
        var counter = 0
        var itemCount: Int { post.items.count }
        /// The options the create carried, for tests ("items all, item_count 10").
        var createOptions: StudioCreateOptions
    }

    struct Call: Sendable, Equatable {
        var name: String
        var detail: String
    }

    private struct State {
        var galleries: [String: Gallery] = [:]
        var calls: [Call] = []
    }

    private let state = Mutex(State())

    var calls: [Call] { state.withLock { $0.calls } }
    func record(_ name: String, _ detail: String = "") { state.withLock { $0.calls.append(Call(name: name, detail: detail)) } }

    func add(_ g: Gallery) { state.withLock { $0.galleries[g.sid] = g } }
    func gallery(_ sid: String) -> Gallery? { state.withLock { $0.galleries[sid] } }
    var sessions: [String] { state.withLock { Array($0.galleries.keys).sorted() } }
    func galleries() -> [Gallery] { state.withLock { $0.galleries.values.sorted { $0.createdAt > $1.createdAt } } }

    @discardableResult
    func update<T>(_ sid: String, _ body: (inout Gallery) -> T) -> T? {
        state.withLock { s in
            guard var g = s.galleries[sid] else { return nil }
            let out = body(&g)
            s.galleries[sid] = g
            return out
        }
    }

    /// The gallery a library row id (`<sid>-i03`, `<sid>-m1`) belongs to.
    func gallery(forRow id: String) -> Gallery? {
        guard let sid = id.split(separator: "-", maxSplits: 1).first.map(String.init) else { return nil }
        return gallery(sid)
    }
}

// MARK: - The client

extension PreviewClient {
    var galleryPost: PreviewGalleryPost? { PreviewData.galleryPost(for: scenario) }

    /// A save or a retry pass: fetch, then a little per item, scaled.
    private func gallerySaveDuration(_ g: PreviewGalleryServer.Gallery) -> Double {
        PreviewData.gallerySaveSeconds(g.post) * timeScale
    }

    /// The wire's word for an `items` choice, for the recorded calls.
    static func describe(_ choice: GalleryChoice) -> String {
        switch choice {
        case .all: return "all"
        case .firstVideo: return "first-video"
        case .some(let indices): return indices.map(String.init).joined(separator: ",")
        }
    }

    // MARK: Create, session

    public func createStudio(url: URL, options: StudioCreateOptions) async throws -> StudioCreated {
        guard let post = galleryPost, let choice = options.items, choice != .firstVideo else {
            if let choice = options.items {
                // `first-video` (today's rule): one file, as a plain save; the call is still recorded for tests
                galleries.record("create", "items=\(Self.describe(choice)) count=\(options.itemCount.map(String.init) ?? "-") queue=\(options.queue)")
            } else if !options.isPlain {
                throw PipelineFailure.unsupported
            }
            return try await createStudio(link: url, public: options.makePublic, queue: options.queue, title: options.title)
        }
        visibilityState.recordSave("create", public: options.makePublic)
        let now = clock.now()
        try throwIfBusyGallery(queue: options.queue, at: now)
        if let count = options.itemCount, count != post.items.count {
            // a post that changed since the client saw it: nothing is stored
            let sid = server.newSession(isUpload: false, clip: clip, name: nil, bytes: clip.bytes, at: now, link: url)
            galleries.record("create", "gallery_changed")
            return StudioCreated(id: sid, pageURL: nil)
        }
        let sid = server.newSession(isUpload: false, clip: clip, name: nil, bytes: clip.bytes, at: now, link: url)
        let gallery = PreviewGalleryServer.Gallery(
            sid: sid, post: post, createdAt: now, startedAt: now, duration: PreviewData.gallerySaveSeconds(post) * timeScale,
            makePublic: options.makePublic == true, failing: post.failing, makeFailuresLeft: scenario == .galleryMakeFails ? 1 : 0,
            createOptions: options)
        galleries.add(gallery)
        galleries.record("create", "items=\(Self.describe(choice)) count=\(options.itemCount.map(String.init) ?? "-") queue=\(options.queue)")
        server.recordLineCall("POST /studio queue=\(options.queue) title=\(options.title ?? "-")")
        guard lineMode.hasLine else { return StudioCreated(id: sid, pageURL: nil) }
        let placed = server.withLine(at: now) {
            $0.enqueue(
                .init(kind: .save, sid: sid, job: nil, focused: false, duration: gallery.duration, mine: true,
                      origin: options.origin, keyName: "iphone", link: url, failure: nil),
                at: now)
        }
        return StudioCreated(id: sid, pageURL: nil, queued: options.queue ? placed.queued : false, queueAhead: options.queue ? placed.ahead : nil)
    }

    private func throwIfBusyGallery(queue: Bool, at now: Date) throws {
        guard lineMode.hasLine else { return }
        if lineMode == .serverFull, queue { throw CobaltError.api(code: "error.studio.line_full", httpStatus: 429) }
        if !queue, server.withLine(at: now, { $0.isBusy }) { throw CobaltError.api(code: "error.studio.busy", httpStatus: 429) }
    }

    /// `GET /studio/<sid>` of a gallery: queued, then saving with bytes, then ready with `item_count` and `items`.
    func gallerySession(_ sid: String, wait: Int) async throws -> StudioSession? {
        guard galleries.gallery(sid) != nil else { return nil }
        func snap() -> (StudioSession, Double) { gallerySnapshot(sid, at: clock.now()) }
        var (session, next) = snap()
        if wait > 0, session.status == .saving {
            try await clock.sleep(seconds: max(0.001, min(Double(wait), next)))
            (session, next) = snap()
        }
        return session
    }

    private func gallerySnapshot(_ sid: String, at now: Date) -> (StudioSession, Double) {
        guard let g = galleries.gallery(sid), let base = server.session(sid) else {
            return (StudioSession(
                id: sid, status: .error, link: nil, service: nil, title: nil, duration: nil, width: nil, height: nil, bytes: nil,
                createdAt: now, expiresAt: now, errorCode: "error.studio.not_found", renders: [], step: nil, stepBytes: nil,
                stepTotal: nil, waking: nil), 0)
        }
        var startedAt = g.startedAt
        let link = g.post.link.absoluteString
        var out = StudioSession(
            id: sid, status: .saving, link: link, service: g.post.service == "x" ? "twitter" : g.post.service, title: nil,
            duration: nil, width: nil, height: nil, bytes: nil, createdAt: g.createdAt, expiresAt: g.createdAt.addingTimeInterval(7 * 86_400),
            errorCode: nil, renders: [], step: nil, stepBytes: nil, stepTotal: nil, waking: false)
        if lineMode.hasLine, let entry = server.withLine(at: now, { $0.entry(sid: sid, job: nil) }) {
            guard let started = entry.started else {
                out.step = .queued
                out.queueAhead = server.withLine(at: now) { $0.ahead(of: entry) }
                return (out, 0.1)
            }
            startedAt = started
        }
        _ = base
        let t = max(0, now.timeIntervalSince(startedAt))
        let fetchEnd = PreviewData.fetchSeconds * timeScale
        let total = PreviewData.gallerySaveSeconds(g.post) * timeScale
        if t < fetchEnd {
            out.step = .fetching
            return (out, fetchEnd - t)
        }
        let bytes = g.post.items.reduce(Int64(0)) { $0 + $1.bytes }
        if t < total {
            out.step = .storing
            out.stepTotal = bytes
            out.stepBytes = Int64(Double(bytes) * (t - fetchEnd) / max(0.001, total - fetchEnd))
            return (out, min(0.1, total - t))
        }
        let lead = g.post.items.first { $0.type == .video } ?? g.post.items[0]
        out.status = .ready
        out.title = g.post.service == "x" ? "twitter_\(g.post.ref)" : "instagram_\(g.post.ref)"
        out.duration = lead.duration; out.width = lead.width; out.height = lead.height; out.bytes = bytes
        out.step = nil; out.itemCount = g.itemCount
        out.itemID = "\(sid)-i00"
        out.items = g.post.items.enumerated().map { i, item in
            let failed = g.failing.contains(i)
            return SessionItem(i: i, type: item.type, status: failed ? .error : .ready, code: failed ? "error.api.fetch.expired" : nil)
        }
        return (out, 0)
    }

    // MARK: Library v3

    /// The v3 library: the fixture page plus every gallery this client made.
    public func library(cursor: String?, limit: Int, v3: Bool) async throws -> LibraryPage {
        var page = visibility != .off
            ? try await library(cursor: cursor, limit: limit, v2: true)
            : try await library(cursor: cursor, limit: limit)
        guard v3 else { return page }
        let posts = galleries.galleries().map { libraryPost($0) }
        page.posts = posts + page.posts
        page.postCount += posts.count
        page.fileCount += posts.reduce(0) { $0 + $1.files.count }
        return page
    }

    private func itemName(_ i: Int, _ item: PreviewGalleryPost.Item) -> String {
        let ext: String
        switch item.type { case .photo: ext = "jpg"; case .video: ext = "mp4"; case .gif: ext = "gif" }
        return "\(FolderNaming.itemNumber(i)).\(ext)"
    }

    func libraryPost(_ g: PreviewGalleryServer.Gallery) -> LibraryPost {
        let now = g.createdAt
        var files: [LibraryFile] = []
        func url(_ key: String, _ ext: String) -> URL? {
            g.makePublic ? PreviewData.mediaBase.appendingPathComponent("\(key).\(ext)") : nil
        }
        for (i, item) in g.post.items.enumerated() where !g.deleted.contains(i) && !g.failing.contains(i) {
            let type: String
            switch item.type { case .photo: type = "image/jpeg"; case .video: type = "video/mp4"; case .gif: type = "image/gif" }
            var file = LibraryFile(
                id: "\(g.sid)-i\(String(format: "%02d", i))", kind: .private, source: .saved,
                name: itemName(i, item), url: url("\(g.sid.suffix(6))i\(i)", item.type == .photo ? "jpg" : "mp4"),
                contentType: type, bytes: item.bytes, width: item.width, height: item.height, duration: item.duration,
                createdAt: now.addingTimeInterval(Double(i)), mediaName: nil, deletable: false,
                posterURL: PreviewData.mediaBase.appendingPathComponent("\(g.sid.suffix(6))t\(i).jpg"))
            file.wireVisibility = g.makePublic ? .public : .private
            file.canToggleVisibility = true
            file.galleryRole = .item
            file.itemIndex = i
            files.append(file)
        }
        for made in g.made {
            let isImage = made.role == .export || made.kind == .slideshow(.webp)
            var file = LibraryFile(
                id: made.id, kind: .private, source: .studio, name: made.kind.tabName,
                url: url(made.id, made.kind == .slideshow(.webp) ? "webp" : (isImage ? "jpg" : "mp4")),
                contentType: made.kind == .slideshow(.webp) ? "image/webp" : (isImage ? "image/jpeg" : "video/mp4"),
                bytes: made.bytes, width: made.width, height: made.height, duration: made.seconds, createdAt: made.createdAt,
                mediaName: nil, deletable: false,
                posterURL: PreviewData.mediaBase.appendingPathComponent("\(g.sid.suffix(6))p\(made.id.suffix(2)).jpg"))
            file.wireVisibility = g.makePublic ? .public : .private
            file.canToggleVisibility = true
            file.galleryRole = made.role
            file.madeFrom = made.items.map { "\(g.sid)-i\(String(format: "%02d", $0))" }
            file.madeSpec = MadeSpec(data: made.spec)
            files.append(file)
        }
        let live = g.post.items.indices.filter { !g.deleted.contains($0) && !g.failing.contains($0) }.count
        var post = LibraryPost(
            id: g.sid, service: g.post.service, link: g.post.link, title: nil, duration: nil,
            width: g.post.items[0].width, height: g.post.items[0].height, createdAt: now,
            session: LibrarySession(
                id: g.sid, status: .ready, expiresAt: g.createdAt.addingTimeInterval(7 * 86_400),
                sourceURL: URL(string: "https://api.capybaraharmony.com/studio/\(g.sid)/source")!),
            files: files, customTitle: nil,
            posterURL: PreviewData.mediaBase.appendingPathComponent("\(g.sid.suffix(6))t0.jpg"))
        post.visibility = g.makePublic ? .public : .private
        post.kind = live >= 2 ? .gallery : .photo
        post.itemCount = live
        post.itemsFailed = g.failing.sorted()
        return post
    }

    // MARK: Retry, delete, visibility

    public func retryItems(session: String, items: [Int]) async throws -> StudioCreated {
        guard let g = galleries.gallery(session) else { throw CobaltError.api(code: "error.studio.not_found", httpStatus: 404) }
        let now = clock.now()
        try await clock.sleep(seconds: 0.05)
        galleries.record("retry", items.map(String.init).joined(separator: ","))
        server.recordLineCall("POST items/retry")
        let valid = items.filter { g.failing.contains($0) }
        guard !valid.isEmpty else { return StudioCreated(id: session, pageURL: nil) }
        // the retry is a save of its own: queued behind the line like any, then it fixes the items
        galleries.update(session) { g in
            g.failing.subtract(valid)
            g.startedAt = now
            g.duration = (PreviewData.fetchSeconds + 0.3 * Double(valid.count)) * timeScale
        }
        guard lineMode.hasLine else { return StudioCreated(id: session, pageURL: nil) }
        let placed = server.withLine(at: now) {
            $0.enqueue(
                .init(kind: .save, sid: session, job: nil, focused: false, duration: g.duration, mine: true, origin: nil,
                      keyName: "iphone", link: g.post.link, failure: nil),
                at: now)
        }
        return StudioCreated(id: session, pageURL: nil, queued: placed.queued, queueAhead: placed.ahead)
    }

    public func deleteItem(_ itemID: String) async throws {
        try await clock.sleep(seconds: 0.1)
        guard let g = galleries.gallery(forRow: itemID) else { throw CobaltError.api(code: "error.library.not_found", httpStatus: 404) }
        galleries.record("delete", itemID)
        if let made = g.made.first(where: { $0.id == itemID }) {
            galleries.update(g.sid) { $0.made.removeAll { $0.id == made.id } }
            return
        }
        guard let index = Int(itemID.suffix(2)), index < g.post.items.count, !g.deleted.contains(index) else {
            throw CobaltError.api(code: "error.library.not_found", httpStatus: 404)
        }
        let live = g.post.items.indices.filter { !g.deleted.contains($0) && !g.failing.contains($0) }
        if live.count <= 1 { throw CobaltError.api(code: "error.library.last_item", httpStatus: 409) }
        galleries.update(g.sid) { $0.deleted.insert(index) }
    }

    public func setPostVisibility(anchor itemID: String, public makePublic: Bool) async throws -> VisibilityResult {
        try await clock.sleep(seconds: 0.3)
        guard let g = galleries.gallery(forRow: itemID) else { throw CobaltError.api(code: "error.library.not_found", httpStatus: 404) }
        galleries.record("visibility", "\(makePublic ? "public" : "private") post")
        galleries.update(g.sid) { $0.makePublic = makePublic }
        guard let updated = galleries.gallery(g.sid) else { throw PipelineFailure.expired }
        return VisibilityResult(files: libraryPost(updated).files, cacheCleared: makePublic ? nil : true, remaining: [])
    }

    // MARK: Makes

    private func makeDuration(_ m: GalleryMake, items: [GalleryItem]) -> Double {
        (1.2 + 0.15 * Double(m.items.count)) * timeScale
    }

    private func galleryItems(_ g: PreviewGalleryServer.Gallery) -> [GalleryItem] {
        g.post.items.enumerated().map { i, item in
            GalleryItem(id: i, type: item.type, width: item.width, height: item.height, duration: item.duration)
        }
    }

    public func makeSlideshow(
        session: String, plan: SlideshowPlan, items: [GalleryItem], focused: Bool, notify: Bool
    ) async throws -> RenderAccepted {
        guard scenario.isGallery, scenario != .galleryNoMake else { throw PipelineFailure.unsupported }
        guard let g = galleries.gallery(session) else { throw CobaltError.api(code: "error.studio.not_found", httpStatus: 404) }
        let now = clock.now()
        try throwIfBusyGallery(queue: true, at: now)
        let live = galleryItems(g).filter { !g.deleted.contains($0.id) && !g.failing.contains($0.id) }
        let seconds = plan.seconds(for: items)
        galleries.record("slideshow", [
            plan.format.rawValue, plan.items.map(String.init).joined(separator: ","),
            seconds.map { $0.map { String($0) } ?? "null" }.joined(separator: ","), "fade=\(plan.fade)", "frame=\(plan.frame.rawValue)",
            "sound=\(plan.sound.rawValue)", "quality=\(plan.quality?.rawValue ?? "-")", "width=\(plan.width.map(String.init) ?? "-")",
            "focused=\(focused)",
        ].joined(separator: " "))
        guard live.count >= 2 else { throw CobaltError.api(code: "error.studio.not_gallery", httpStatus: 409) }
        guard plan.items.count >= 2, Set(plan.items).count == plan.items.count,
              plan.items.allSatisfy({ i in live.contains { $0.id == i } })
        else { throw CobaltError.api(code: "error.webp.invalid_params", httpStatus: 400) }
        switch plan.check(live) {
        case .ok: break
        case .tooFew: throw CobaltError.api(code: "error.webp.invalid_params", httpStatus: 400)
        case .tooLong, .tooMuchVideo: throw CobaltError.api(code: "error.webp.too_long", httpStatus: 400)
        }
        let frame = MakeEstimate.frame(for: plan, items: live)
        let bytes = plan.format == .webp ? MakeEstimate.webpBytes(live, plan: plan, frame: frame) : MakeEstimate.mp4Bytes(live, plan: plan, frame: frame)
        let length = plan.length(of: live)
        return try accept(
            g, .slideshow(plan), now: now, focused: focused, role: .slideshow,
            bytes: bytes, width: Int(frame.width), height: Int(frame.height), seconds: length, format: plan.format)
    }

    public func makeGalleryImage(session: String, plan: GalleryImagePlan, focused: Bool, notify: Bool) async throws -> RenderAccepted {
        guard scenario.isGallery, scenario != .galleryNoMake else { throw PipelineFailure.unsupported }
        guard let g = galleries.gallery(session) else { throw CobaltError.api(code: "error.studio.not_found", httpStatus: 404) }
        let now = clock.now()
        try throwIfBusyGallery(queue: true, at: now)
        let live = galleryItems(g).filter { !g.deleted.contains($0.id) && !g.failing.contains($0.id) }
        galleries.record("gallery-image", "\(plan.layout.rawValue) \(plan.items.map(String.init).joined(separator: ",")) focused=\(focused)")
        guard live.filter(\.isPhoto).count >= 2 else { throw CobaltError.api(code: "error.studio.too_few_photos", httpStatus: 409) }
        guard plan.items.count >= 2, Set(plan.items).count == plan.items.count,
              plan.items.allSatisfy({ i in live.contains { $0.id == i && $0.isPhoto } })
        else { throw CobaltError.api(code: "error.webp.invalid_params", httpStatus: 400) }
        guard let canvas = MakeEstimate.canvas(for: plan, items: live) else { throw CobaltError.api(code: "error.webp.invalid_params", httpStatus: 400) }
        return try accept(
            g, .image(plan), now: now, focused: focused, role: .export, bytes: MakeEstimate.jpegBytes(canvas),
            width: canvas.width, height: canvas.height, seconds: nil, format: nil,
            cropped: canvas.croppedIndices.map { plan.items[$0] }, upscaled: canvas.upscaledIndices.map { plan.items[$0] })
    }

    /// Stores the job: its result is decided now (and committed when its time comes), a replaced file is named.
    private func accept(
        _ g: PreviewGalleryServer.Gallery, _ m: GalleryMake, now: Date, focused: Bool, role: GalleryRole, bytes: Int64,
        width: Int, height: Int, seconds: Double?, format: SlideshowPlan.Format?, cropped: [Int] = [], upscaled: [Int] = []
    ) throws -> RenderAccepted {
        let kind = m.madeKind
        let spec: Data
        switch m {
        case .image(let plan):
            spec = (try? JSONSerialization.data(withJSONObject: ["kind": "gallery", "layout": plan.layout.rawValue, "items": plan.items], options: [.sortedKeys])) ?? Data()
        case .slideshow(let plan):
            spec = (try? JSONSerialization.data(withJSONObject: ["format": plan.format.rawValue, "items": plan.items, "fade": plan.fade], options: [.sortedKeys])) ?? Data()
        }
        let duration = makeDuration(m, items: [])
        var job = ""
        var jobDuration = duration
        galleries.update(g.sid) { g in
            g.counter += 1
            job = "PrEvIeWmake\(String(format: "%04d", g.counter))"
            let id = "\(g.sid)-m\(g.counter)"
            let replaced = g.made.filter { $0.kind == kind }.map(\.id)
            let fails = g.makeFailuresLeft > 0
            if fails { g.makeFailuresLeft -= 1 }
            let made = PreviewGalleryServer.Made(
                id: id, kind: kind, role: role, createdAt: now.addingTimeInterval(duration), bytes: bytes, width: width,
                height: height, seconds: seconds, items: m.items, spec: spec)
            let result = MadeResult(
                job: job, itemID: id, url: g.makePublic ? PreviewData.mediaBase.appendingPathComponent("\(id).\(format == .webp ? "webp" : (format == .mp4 ? "mp4" : "jpg"))") : nil,
                bytes: bytes, width: width, height: height, seconds: seconds, format: format, cropped: cropped, upscaled: upscaled,
                replaced: replaced)
            g.jobs[job] = PreviewGalleryServer.Job(
                job: job, make: m, startedAt: now, duration: duration, fails: fails, result: result, made: made)
            jobDuration = duration
        }
        guard lineMode.hasLine else { return RenderAccepted(job: job) }
        let placed = server.withLine(at: now) {
            $0.enqueue(
                .init(kind: .render, sid: g.sid, job: job, focused: focused, duration: jobDuration, mine: true, origin: nil,
                      keyName: "iphone", link: nil, failure: nil),
                at: now)
        }
        return RenderAccepted(job: job, queued: placed.queued, queueAhead: placed.ahead)
    }

    func galleryMakeStatus(_ sid: String, job: String, wait: Int) async throws -> MakeStatus? {
        guard let g = galleries.gallery(sid) else { return nil }
        guard var j = g.jobs[job] else { return .failed(code: "error.webp.job_lost") }
        if server.isCancelled(job) { return .failed(code: "error.webp.cancelled") }
        if lineMode.hasLine, let entry = server.withLine(at: clock.now(), { $0.entry(sid: sid, job: job) }) {
            guard let started = entry.started else {
                let ahead = server.withLine(at: clock.now()) { $0.ahead(of: entry) }
                if wait > 0 { try await clock.sleep(seconds: 0.1) }
                return .pending(phase: .queued, done: nil, total: nil, queueAhead: ahead)
            }
            j.startedAt = started
        }
        func snap() -> (MakeStatus, Double) { makeSnapshot(g, j, at: clock.now()) }
        var (status, next) = snap()
        if wait > 0, case .pending = status {
            try await clock.sleep(seconds: max(0.001, min(Double(wait), 0.1, next)))
            (status, next) = snap()
        }
        if case .success = status {
            galleries.update(sid) { g in
                guard var stored = g.jobs[job], !stored.committed else { return }
                stored.committed = true
                g.jobs[job] = stored
                g.made.removeAll { stored.result.replaced.contains($0.id) }
                g.made.append(stored.made)
            }
        }
        return status
    }

    private func makeSnapshot(_ g: PreviewGalleryServer.Gallery, _ j: PreviewGalleryServer.Job, at now: Date) -> (MakeStatus, Double) {
        let t = max(0, now.timeIntervalSince(j.startedAt))
        let total = max(0.001, j.duration)
        if j.fails, t >= total * 0.6 { return (.failed(code: "error.webp.encode_failed"), 0) }
        if t >= total { return (.success(j.result), 0) }
        let k = t / total
        let stills = max(1, j.make.items.count)
        switch j.make {
        case .image:
            if k < 0.1 { return (.pending(phase: .uploading, done: nil, total: nil, queueAhead: nil), total * 0.1 - t) }
            return (.pending(phase: .composing, done: Int(Double(stills) * (k - 0.1) / 0.9), total: stills, queueAhead: nil), min(0.1, total - t))
        case .slideshow:
            if k < 0.1 { return (.pending(phase: .uploading, done: nil, total: nil, queueAhead: nil), total * 0.1 - t) }
            if k < 0.55 { return (.pending(phase: .composing, done: Int(Double(stills) * (k - 0.1) / 0.45), total: stills, queueAhead: nil), min(0.1, total - t)) }
            let seconds = max(1, Int((j.result.seconds ?? 10).rounded()))
            return (.pending(phase: .encoding, done: Int(Double(seconds) * (k - 0.55) / 0.45), total: seconds, queueAhead: nil), min(0.1, total - t))
        }
    }
}
