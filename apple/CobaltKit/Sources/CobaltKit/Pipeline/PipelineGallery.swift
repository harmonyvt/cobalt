import Foundation

// A multi-item post saved whole, and what is made from it (apple/CONTRACT-GALLERY.md 1.10, 1.11, 1.15, 1.16, R7, R8).
//
// A pasted gallery is saved in full the moment it is recognised: no choice first (owner interview 2026-10-07). The
// pipeline sits in `.gallery(items:)` for the whole life of the post: `galleryRun` says how far the save is, which item
// could not be fetched, and what is being made from it. Plain cobalt (no `features.gallery`) never gets here: its
// picker stays `.picker`.

// MARK: - What the owner sees

/// The save and the make of one gallery run, for the focus hero and the tray.
public struct GalleryRun: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// cobalt is fetching the items (and, with "keep new saves offline", this device is receiving them).
        case saving
        /// Everything that could be saved is saved. Items listed in `failures` could not be fetched.
        case saved
        /// Nothing was saved (every item failed, the link failed, the server said no).
        case failed(PipelineFailure)
    }

    /// What is being made from the post. At most one make runs at a time; "make another" starts the next once this one
    /// is `.done` or `.failed`.
    public enum Make: Sendable, Equatable {
        case none
        /// Chosen before the save ended (R7): it runs when the save is ready ("after the save · 6 of 10").
        case waiting(GalleryMake)
        /// On its way to the server.
        case sending(GalleryMake)
        /// In the server's line (`ahead`: the jobs before it, the running one included).
        case queued(GalleryMake, ahead: Int)
        case making(GalleryMake, MakeProgress)
        case done(GalleryMake, MadeResult)
        case failed(GalleryMake, PipelineFailure)

        /// The make this run is asked for, in any state but `.none`.
        public var request: GalleryMake? {
            switch self {
            case .none: return nil
            case .waiting(let m), .sending(let m), .queued(let m, _), .making(let m, _), .done(let m, _), .failed(let m, _): return m
            }
        }

        /// The make is in flight or about to be (not done, failed or absent).
        public var isActive: Bool {
            switch self {
            case .waiting, .sending, .queued, .making: return true
            case .none, .done, .failed: return false
            }
        }
    }

    public struct MakeProgress: Sendable, Equatable {
        public var phase: MakePhase?
        public var done: Int?
        public var total: Int?
        public init(phase: MakePhase? = nil, done: Int? = nil, total: Int? = nil) {
            self.phase = phase
            self.done = done
            self.total = total
        }

        /// 0...1 for the bar: uploading the inputs a little, composing the stills to a half, encoding the rest.
        public var fraction: Double {
            func ratio() -> Double { total.map { $0 > 0 ? min(1, Double(done ?? 0) / Double($0)) : 0 } ?? 0 }
            switch phase {
            case nil, .queued?: return 0
            case .uploading?: return 0.05
            case .composing?: return 0.05 + 0.45 * ratio()
            case .encoding?: return 0.5 + 0.5 * ratio()
            }
        }
    }

    public var phase: Phase = .saving
    /// The items the post has (`item_count`), failed ones included.
    public var total: Int
    /// Items saved so far: "saving 4 of 10". Never above `total`; `total - failures.count` when the save ended.
    public var done: Int = 0
    /// Items that could not be fetched: index → the error code ("photo 7 couldn't be fetched").
    public var failures: [Int: String] = [:]
    public var make: Make = .none

    public init(total: Int) { self.total = total }

    public var isSaved: Bool { phase == .saved }
    /// How many items are safe (saved), once the save ended.
    public var kept: Int { max(0, total - failures.count) }
}

// MARK: - Starting a gallery

extension Pipeline {
    /// The items of the gallery on screen.
    public var galleryItems: [GalleryItem] {
        if case .gallery(let items) = state { return items }
        return []
    }

    /// "saving 4 of 10": nil outside a gallery run.
    public var galleryProgress: (done: Int, total: Int)? { galleryRun.map { ($0.done, $0.total) } }

    /// The gallery run's save is over (saved, or failed) and no make is in flight: the job may be let go.
    public var galleryIsSettled: Bool {
        guard let run = galleryRun else { return true }
        if case .saving = run.phase { return false }
        return !run.make.isActive
    }

    /// A resolved picker of this post (`POST /`) on a server that saves galleries: saves everything at once.
    func runGalleryLink(_ info: LinkInfo, picker: [PickerItem]) async throws {
        let client = ctx.client
        let items = picker.map(GalleryItem.init)
        galleryRun = GalleryRun(total: items.count)
        media = MediaInfo(name: info.ref, duration: nil, width: nil, height: nil, bytes: nil, isImage: items.allSatisfy(\.isPhoto))
        setState(.gallery(items: items))
        let created: StudioCreated
        do { created = try await openStudioRetrying(client, link: info.url, item: nil, gallery: GalleryCreate(count: items.count)) }
        catch { releaseLine(); throw error }
        sessionID = created.id
        noteAccepted(session: created.id, postKey: created.id, queued: created.queued, ahead: created.queueAhead)
        recordJob(.saving)
        try await followGallerySave(client, session: created.id, link: info.url)
    }

    /// The server is saving the gallery of `sid` (a create, a relaunch, a retry): follow it to the end, then store the
    /// items on this device and run the make that was chosen meanwhile.
    func followGallerySave(_ client: any CobaltClient, session sid: String, link: URL?) async throws {
        let s: StudioSession
        do { s = try await pollGallerySaving(client, id: sid) }
        catch { releaseLine(); throw error }
        releaseLine()                                              // the server is free for the next save
        try await finishGallerySave(client, session: s, link: link)
    }

    /// `GET /studio/<sid>` until the save is over. The state stays `.gallery`: what moves is `galleryRun.done`.
    func pollGallerySaving(_ client: any CobaltClient, id: String) async throws -> StudioSession {
        var pacer = PollPacer()
        while true {
            try Task.checkCancellation()
            try await pacer.beforePoll(clock: ctx.clock)
            let s = try await retrying { try await client.session(id, wait: 1) }
            pacer.observe(s, clock: ctx.clock)
            switch s.status {
            case .ready:
                return s
            case .error:
                throw mapFailure(code: s.errorCode ?? "error.studio.unknown", during: .saving, limits: ctx.capabilities.limits)
            case .saving:
                observeLine(queueAhead: s.step == .queued ? max(1, s.queueAhead ?? 1) : nil)
                // The server says how many bytes of the whole post it has; the number of items done follows it.
                if let bytes = s.stepBytes, let total = s.stepTotal, total > 0, let run = galleryRun {
                    let share = min(1, max(0, Double(bytes) / Double(total)))
                    let done = min(max(0, run.total - 1), Int((share * Double(run.total)).rounded(.down)))
                    setGalleryRun { if done > $0.done { $0.done = done } }
                }
            }
        }
    }

    /// The server has the gallery (`session.items` says what became of each item). Stores each saved item on this
    /// device when the owner keeps new saves offline, then ends the save and starts a make chosen meanwhile.
    func finishGallerySave(_ client: any CobaltClient, session s: StudioSession, link: URL?) async throws {
        let count = max(s.itemCount ?? 0, s.items.count, galleryRun?.total ?? 0)
        if galleryRun == nil { galleryRun = GalleryRun(total: count) }
        var failures: [Int: String] = [:]
        for item in s.items where item.status == .error { failures[item.i] = item.code ?? "error.api.generic" }
        // A server that lists nothing (it should not) saved what it could: nothing failed as far as is known.
        setGalleryRun {
            $0.total = max(count, 1)
            $0.failures = failures
            $0.done = min($0.done, max(0, $0.total - failures.count))
        }
        if media == nil || media?.name.isEmpty == true {
            media = mediaInfo(s, fallbackName: link.flatMap(LinkInfo.init)?.ref ?? s.id)
        } else if let title = s.title, !title.isEmpty {
            media?.name = title
        }
        // The items as the library knows them: sizes, lengths and thumbs for the hero and for the plans' caps.
        let files = await galleryFiles(client, session: s.id)
        if !files.isEmpty { applyGalleryFiles(files, fromSession: s) }
        else if !s.items.isEmpty { applySessionItems(s) }
        if ctx.settings.keepVideosOnDevice, !files.isEmpty {
            try await keepGalleryItems(client, session: s, files: files, link: link, failures: failures)
        } else {
            setGalleryRun { $0.done = max(0, $0.total - failures.count) }
        }
        try Task.checkCancellation()
        let items = galleryItems
        Telemetry.log(.info, .pipeline, "gallery saved", data: [
            "items": .int(items.count), "photos": .int(items.filter(\.isPhoto).count),
            "videos": .int(items.filter { !$0.isPhoto }.count), "failed": .int(failures.count),
        ])
        setGalleryRun { $0.phase = .saved }
        settleJobRecords()
        ctx.galleryChanged?()
        if case .waiting(let chosen) = galleryRun?.make {
            // R7: chosen while the save was still running
            setGalleryRun { $0.make = .none }
            startMake(chosen, session: s.id)
        } else if let asked = makeAskedByOptions(items: items), galleryRun?.make == GalleryRun.Make.none {
            // a Shortcut (or a batch) asked for a make with the link: it goes out behind the save
            switch asked {
            case .success(let m): startMake(m, session: s.id)
            case .failure(let why):
                // nothing is sent: the run says why, for whoever reads the result (a Shortcut)
                let asked: GalleryMake = jobOptions.galleries == .slideshowWebp
                    ? .slideshow(SlideshowPlan.standard(.webp, items: items.map(\.id), settings: ctx.settings))
                    : .image(GalleryImagePlan(items: items.filter(\.isPhoto).map(\.id), layout: .grid3))
                setGalleryRun { $0.make = .failed(asked, mapFailure(code: why.code, during: .rendering)) }
            }
        }
    }

    /// The make `JobOptions.galleries` asks for, built from what was saved; or why it cannot be made (nothing is sent).
    private func makeAskedByOptions(items: [GalleryItem]) -> Result<GalleryMake, GalleryOptionFailure>? {
        let saved = items.filter { galleryRun?.failures[$0.id] == nil }
        switch jobOptions.galleries {
        case .slideshowWebp?:
            let plan = SlideshowPlan.standard(.webp, items: saved.map(\.id), settings: ctx.settings)
            switch plan.check(saved) {
            case .ok: return .success(.slideshow(plan))
            case .tooFew: return .failure(.init("error.studio.not_gallery"))
            case .tooLong, .tooMuchVideo: return .failure(.init("error.webp.too_long"))
            }
        case .galleryImage(let layout)?:
            let plan = GalleryImagePlan(items: saved.filter(\.isPhoto).map(\.id), layout: layout)
            return plan.isPossible(in: saved) ? .success(.image(plan)) : .failure(.init("error.studio.too_few_photos"))
        default:
            return nil
        }
    }

    /// The post's `item` rows from `GET /library?v=3`: a post just saved is on the first page; one being retried may be
    /// further back (at most 5 pages are read). Empty when the server lists none or cannot be read: the save stands, the
    /// items just carry less detail.
    private func galleryFiles(_ client: any CobaltClient, session sid: String) async -> [LibraryFile] {
        guard ctx.capabilities.library else { return [] }
        for attempt in 0..<2 {
            if attempt > 0 { try? await ctx.clock.sleep(seconds: 1) }
            var cursor: String?
            for _ in 0..<5 {
                guard !Task.isCancelled, let page = try? await ctx.libraryPage(cursor: cursor, limit: 20) else { break }
                if let post = page.posts.first(where: { $0.id == sid || $0.session?.id == sid }) {
                    let files = post.files.filter { $0.galleryRole == .item && $0.itemIndex != nil }
                        .sorted { ($0.itemIndex ?? 0) < ($1.itemIndex ?? 0) }
                    if !files.isEmpty { return files }
                    break
                }
                guard let next = page.next else { break }
                cursor = next
            }
        }
        return []
    }

    /// Sizes, lengths and thumbs from the library rows, kept in the picker's order and types.
    private func applyGalleryFiles(_ files: [LibraryFile], fromSession s: StudioSession) {
        var byIndex: [Int: LibraryFile] = [:]
        for file in files { if let i = file.itemIndex { byIndex[i] = file } }
        var items = galleryItems
        if items.isEmpty { items = files.compactMap { f in f.itemIndex.map { GalleryItem(id: $0, type: MediaType(contentType: f.contentType) ?? .photo) } } }
        for i in items.indices {
            guard let file = byIndex[items[i].id] else { continue }
            items[i].type = MediaType(contentType: file.contentType) ?? items[i].type
            items[i].width = file.width ?? items[i].width
            items[i].height = file.height ?? items[i].height
            items[i].duration = items[i].isPhoto ? nil : (file.duration ?? items[i].duration)
            items[i].thumb = file.posterURL ?? items[i].thumb
        }
        // an index the picker did not have (a later build of the server): added
        for (index, file) in byIndex where !items.contains(where: { $0.id == index }) {
            items.append(GalleryItem(
                id: index, type: MediaType(contentType: file.contentType) ?? .photo, width: file.width, height: file.height,
                duration: file.duration, thumb: file.posterURL))
        }
        items.sort { $0.id < $1.id }
        setState(.gallery(items: items))
    }

    /// No library rows: the types the session reports, in index order, over what the picker gave.
    private func applySessionItems(_ s: StudioSession) {
        var items = galleryItems
        for entry in s.items {
            if let i = items.firstIndex(where: { $0.id == entry.i }) {
                if let type = entry.type { items[i].type = type }
            } else {
                items.append(GalleryItem(id: entry.i, type: entry.type ?? .photo))
            }
        }
        items.sort { $0.id < $1.id }
        setState(.gallery(items: items))
    }

    /// Downloads the saved items one after another into the offline store (kept: Files and Finder by the folder rules),
    /// counting each one as saved. An item that cannot be fetched from the library fails alone.
    private func keepGalleryItems(
        _ client: any CobaltClient, session s: StudioSession, files: [LibraryFile], link: URL?, failures: [Int: String]
    ) async throws {
        let sid = s.id
        let store = ctx.store
        let base = ((media?.name ?? sid) as NSString).deletingPathExtension
        let target = targetMediaID
        let token = runToken
        let have = Set(store.videos.filter { $0.role == .item && $0.sessionID == sid }.compactMap(\.itemIndex))
        // what the folder rule needs while the first items land one by one: a single pasted photo is a flat file, the first
        // item of a gallery is already in the gallery's folder
        let postItems = max(galleryRun?.total ?? 0, files.count)
        var done = 0
        let ready = files.filter { failures[$0.itemIndex ?? -1] == nil }
        for file in ready {
            try Task.checkCancellation()
            guard let index = file.itemIndex else { continue }
            if !have.contains(index) {
                let name = "\(base)-\(FolderNaming.itemNumber(index)).\(GalleryFiles.fileExtension(of: file))"
                do {
                    let local = try await client.download(.libraryItem(id: file.id), to: store.inboxURL(for: name), progress: { _ in })
                    try Task.checkCancellation()
                    guard token == runToken else { try? FileManager.default.removeItem(at: local); throw CancellationError() }
                    let type = MediaType(contentType: file.contentType) ?? .photo
                    let info = MediaInfo(
                        name: base, duration: type == .photo ? nil : file.duration, width: file.width,
                        height: file.height, bytes: file.bytes, isImage: type == .photo)
                    _ = try await store.add(
                        file: local, kind: .original, media: info, sessionID: sid, link: link, remoteURL: nil, move: true,
                        publicURL: file.isPublic ? file.url : nil, mediaID: target, keep: true, createdAt: file.createdAt,
                        role: .item, itemIndex: index, libraryID: file.id, postItems: postItems)
                } catch is CancellationError {
                    throw CancellationError()
                } catch let e as CobaltError where e == .cancelled || e == .network(.cancelled) {
                    throw e
                } catch {
                    // the item is saved on the server; only the copy here failed: it is not "kept", and the library has it
                    Telemetry.log(.warn, .store, "gallery item not kept on device", data: Telemetry.errorData(error))
                }
            }
            done += 1
            setGalleryRun { $0.done = max($0.done, min(done, max(0, $0.total - failures.count))) }
        }
        setGalleryRun { $0.done = max(0, $0.total - failures.count) }
    }

    /// A save that the server finished before the app looked (the focus job, a Shortcut, a relaunch): the same ending.
    func finishUnfocusedGallery(_ client: any CobaltClient, session s: StudioSession, link: URL?) async throws {
        galleryRun = GalleryRun(total: max(s.itemCount ?? 0, s.items.count))
        setState(.gallery(items: s.items.map { GalleryItem(id: $0.i, type: $0.type ?? .photo) }.sorted { $0.id < $1.id }))
        try await finishGallerySave(client, session: s, link: link)
    }
}

extension Pipeline {
    /// A job on a gallery that is already on the server: the post's items are known, the save is behind it. `.make` goes
    /// straight to the server; `.retry` asks it to fetch the missing items again and follows that save to its end.
    func startGallery(
        _ work: JobQueue.GalleryWork, session sid: String, items: [GalleryItem], media info: MediaInfo?, link: URL?,
        mediaID: String?, failures: [Int: String]
    ) {
        let linkInfo = link.flatMap { LinkInfo($0) }
        begin(input: linkInfo.map { .link($0) })
        sessionID = sid
        media = info
        targetMediaID = mediaID
        var run = GalleryRun(total: max(items.count, 1))
        run.failures = failures
        run.done = max(0, run.total - failures.count)
        run.phase = .saved
        galleryRun = run
        setState(.gallery(items: items))
        switch work {
        case .make(let m):
            startMake(m, session: sid)
        case .retry(let indices):
            setGalleryRun { $0.phase = .saving; $0.done = max(0, $0.total - $0.failures.count) }
            launch { p in
                let client = p.ctx.client
                let created: StudioCreated
                do { created = try await p.retryRequest(client, session: sid, items: indices) }
                catch { p.releaseLine(); throw error }
                p.noteAccepted(session: created.id, postKey: sid, queued: created.queued, ahead: created.queueAhead)
                try await p.followGallerySave(client, session: created.id, link: link)
            }
        }
    }

    /// `POST /studio/<sid>/items/retry`: a save job in the server's line (queued when the line has one).
    private func retryRequest(_ client: any CobaltClient, session sid: String, items: [Int]) async throws -> StudioCreated {
        if let line = ctx.line, ctx.capabilities.line { try await line.enter(lineKey, kind: .save, priority: .batch) }
        let created = try await client.retryItems(session: sid, items: items)
        observeLine(queueAhead: created.queued ? max(1, created.queueAhead ?? 1) : nil)
        return created
    }
}

struct GalleryOptionFailure: Error, Sendable, Equatable {
    var code: String
    init(_ code: String) { self.code = code }
}

extension Pipeline {
    /// "make a webp" of one video or gif item of a gallery (APP-API-CONTRACT 18.13, CONTRACT-GALLERY 1.18): today's trim
    /// flow on that item. The frames come from the kept copy when this device has one (`localFile`), else the item is
    /// fetched from the library into a temporary file first (the keyed route cannot be read by ranges); the render goes to
    /// the same session with `item` set, and the webp that comes back is stored as the media's own (`madeFrom: [item]`,
    /// named `NN · webp n` in its folder). Same states as any trim: `.reading` → `.ready` → `.rendering` → `.done`.
    public func resume(session id: String, media info: MediaInfo?, item index: Int, localFile url: URL?, libraryItem: String?) {
        begin(input: nil)
        sessionID = id
        media = info
        renderItem = index
        setState(.reading(developed: 0, of: Pipeline.frameCount))
        launch { p in
            let fm = FileManager.default
            let input: FrameInput
            if let url, fm.fileExists(atPath: url.path) {
                p.pinnedLocal(url)
                input = .local(url)
            } else if let libraryItem {
                let file = try await p.ctx.client.download(
                    .libraryItem(id: libraryItem), to: p.ctx.store.inboxURL(for: "item-\(index).mp4"), progress: { _ in })
                p.temporaryFiles.append(file)
                input = .local(file)
            } else {
                throw PipelineFailure.server(code: "error.app.no_original")
            }
            let m = info ?? MediaInfo(name: id, duration: nil, width: nil, height: nil, bytes: nil, isImage: false)
            try await p.develop(m, from: input, readyFirst: m.duration != nil)
        }
    }

    private func pinnedLocal(_ url: URL) {
        if let video = ctx.store.videos.first(where: { $0.fileURL == url }) { pinStored(video.id) }
    }
}

/// How `Pipeline.openStudioRetrying` is asked to create a gallery: every item, with the count the client saw (nil when
/// it did not resolve the post itself).
struct GalleryCreate: Sendable, Equatable {
    var count: Int?
    /// `.all`, or `.firstVideo` for a Shortcut that wants today's behaviour.
    var choice: GalleryChoice = .all
}

// MARK: - Library rows to files

enum GalleryFiles {
    /// The extension a library row's file gets on this device.
    static func fileExtension(of file: LibraryFile) -> String {
        switch file.contentType?.lowercased() {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/png": return "png"
        case "image/webp": return "webp"
        case "image/heic", "image/heif": return "heic"
        case "image/gif": return "gif"
        case "video/mp4", "video/quicktime", "video/x-m4v": return "mp4"
        default: break
        }
        let ext = (file.name as NSString).pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "webp", "heic", "gif", "mp4", "mov"].contains(ext) { return ext == "jpeg" ? "jpg" : ext }
        return "jpg"
    }
}

// MARK: - Making things from the post

extension Pipeline {
    /// Asks for a slideshow or a gallery image of this post. Sent now when the save is ready, else after it (R7): the
    /// make is held as `galleryRun.make = .waiting(m)` and goes out with the same call chain the moment the save ends.
    /// Returns as soon as the make is handed to the run (held, or sent by the run's own task): it never waits for the
    /// server, which finishes in `galleryRun.make`. One make at a time: asking while another is in flight changes
    /// nothing. The request goes out with `focused` priority (the owner is looking at this planet).
    public func make(_ m: GalleryMake) async {
        guard var run = galleryRun, !run.make.isActive else { return }
        switch run.phase {
        case .failed:
            return
        case .saving:
            run.make = .waiting(m)
            galleryRun = run
            ctx.live?.stateChanged(self)
            jobEvent?(self, .state)
            return
        case .saved:
            break
        }
        guard let sid = sessionID else { return }
        startMake(m, session: sid)
    }

    /// Starts the make as a side task of this run (it dies with the run, like every side job).
    func startMake(_ m: GalleryMake, session sid: String) {
        setGalleryRun { $0.make = .sending(m) }
        spawn { p in await p.runMake(m, session: sid) }
    }

    /// The owner cancelled a make still waiting in the server's line: the save stays, the make is gone.
    func cancelMake() {
        // A make still `.waiting` for the save never took a place of its own in the line: what the line holds is the
        // save's, and it stays.
        let waiting: Bool = { if case .waiting? = galleryRun?.make { return true } else { return false } }()
        for t in sideTasks { t.cancel() }
        sideTasks = []
        makeJobID = nil
        if !waiting { releaseLine() }
        setGalleryRun { $0.make = .none }
    }

    func runMake(_ m: GalleryMake, session sid: String) async {
        let token = runToken
        let client = ctx.client
        let items = galleryItems
        defer { releaseLine(); if token == runToken { makeJobID = nil } }
        let started = ctx.clock.now()
        Telemetry.log(.info, .pipeline, "make start", data: makeTelemetry(m, items: items))
        do {
            // On a server with a line the request waits there, ahead of every waiting save (the owner is looking);
            // on one without, this device's line takes the turn first and a busy helper is waited out like a render.
            let serverLine = usesServerLine
            if serverLine || usesDeviceLine, let line = ctx.line { try await line.enter(lineKey, kind: .render, priority: .focused) }
            let accepted = try await sendMake(client, m, session: sid, items: items, focused: true, waitsOutBusy: usesDeviceLine)
            guard token == runToken else { return }
            makeJobID = accepted.job
            observeLine(queueAhead: accepted.queued ? max(1, accepted.queueAhead ?? 1) : nil)
            setGalleryRun { $0.make = accepted.queued ? .queued(m, ahead: max(1, accepted.queueAhead ?? 1)) : .making(m, .init(phase: .uploading)) }
            while true {
                try Task.checkCancellation()
                let status = try await retrying { try await client.makeStatus(session: sid, job: accepted.job, wait: 1) }
                try Task.checkCancellation()
                guard token == runToken else { return }
                switch status {
                case .pending(let phase, let done, let total, let ahead):
                    observeLine(queueAhead: phase == .queued ? max(1, ahead ?? 1) : nil)
                    if phase == .queued {
                        setGalleryRun { $0.make = .queued(m, ahead: max(1, ahead ?? 1)) }
                    } else {
                        setGalleryRun { $0.make = .making(m, .init(phase: phase, done: done, total: total)) }
                    }
                case .success(let result):
                    let landed = await finishMake(client, m, session: sid, result: result)
                    guard token == runToken else { return }
                    var data = makeTelemetry(m, items: items)
                    data["ms"] = .int(Int(ctx.clock.now().timeIntervalSince(started) * 1000))
                    Telemetry.log(.info, .pipeline, "make done", data: data)
                    setGalleryRun { $0.make = .done(m, landed) }
                    ctx.galleryChanged?()
                    return
                case .failed(let code):
                    throw mapFailure(code: code, during: .rendering, limits: ctx.capabilities.limits)
                }
            }
        } catch {
            guard token == runToken, !Task.isCancelled, let failure = pipelineFailure(from: error, during: .rendering, limits: ctx.capabilities.limits)
            else { return }
            var data = makeTelemetry(m, items: items)
            data["code"] = .string(failure.telemetryCode)
            Telemetry.log(.error, .pipeline, "make fail", data: data)
            setGalleryRun { $0.make = .failed(m, failure) }
            if failure == .keyInvalid { ctx.keyRejected?() }
        }
    }

    private func sendMake(
        _ client: any CobaltClient, _ m: GalleryMake, session sid: String, items: [GalleryItem], focused: Bool, waitsOutBusy: Bool
    ) async throws -> RenderAccepted {
        let deadline = ctx.clock.now().addingTimeInterval(600)
        let priority = usesServerLine && focused
        while true {
            do {
                let accepted: RenderAccepted
                switch m {
                case .slideshow(let plan):
                    accepted = try await client.makeSlideshow(session: sid, plan: plan, items: items, focused: priority)
                case .image(let plan):
                    accepted = try await client.makeGalleryImage(session: sid, plan: plan.photoOnly(in: items), focused: priority)
                }
                if waitsOutBusy { ctx.line?.clearBusyElsewhere() }
                return accepted
            } catch CobaltError.api(let code, _) where waitsOutBusy && (code == "error.webp.busy" || code == "error.studio.busy") {
                if ctx.clock.now().addingTimeInterval(3) > deadline { throw CobaltError.api(code: code, httpStatus: 429) }
                ctx.line?.noteBusyElsewhere(label: nil)
                try await ctx.clock.sleep(seconds: 3)
            }
        }
    }

    /// The made file becomes a tab: downloaded into the store (kept by the owner's setting, like every file made on this
    /// device), and any file it replaces (R8: one `slideshow webp`, one `slideshow`, one `gallery image` per layout) goes
    /// from this device first, so the new file takes the old one's name. A download that fails leaves the made file on
    /// the server, where the library lists it.
    private func finishMake(_ client: any CobaltClient, _ m: GalleryMake, session sid: String, result r: MadeResult) async -> MadeResult {
        let store = ctx.store
        let kind = m.madeKind
        // the library's copy of what was replaced is gone with the server's answer
        if !r.replaced.isEmpty {
            ctx.libraryDropped?(r.replaced)
            // and so is this device's, whether or not the new file comes down (a failed download must not leave two tabs:
            // the replaced file here and the new one in the library)
            let gone = Set(r.replaced)
            for old in store.videos where old.libraryID.map(gone.contains) == true && old.libraryID != r.itemID {
                await store.replaceMade(old.id)
            }
        }
        guard let itemID = r.itemID else { return r }
        let isImage: Bool
        let ext: String
        var kindOnDisk = StoredVideo.Kind.original
        var role = GalleryRole.export
        switch m {
        case .slideshow(let plan):
            role = .slideshow
            isImage = plan.format == .webp
            ext = plan.format == .webp ? "webp" : "mp4"
            if plan.format == .webp { kindOnDisk = .webp }
        case .image:
            isImage = true
            ext = "jpg"
        }
        let base = ((media?.name ?? sid) as NSString).deletingPathExtension
        let name = "\(base)-\(role == .slideshow ? "slideshow" : "gallery-image").\(ext)"
        do {
            let local = try await client.download(.libraryItem(id: itemID), to: store.inboxURL(for: name), progress: { _ in })
            let spec = Self.madeSpec(for: m, result: r)
            // a make that replaces one: the old record and its Files copy leave first (R8), so the name is free
            for old in store.videos where old.madeKind == kind && old.libraryID != itemID && (old.sessionID == sid || old.mediaID == mediaID) {
                await store.replaceMade(old.id)
            }
            let info = MediaInfo(name: (name as NSString).deletingPathExtension, duration: r.seconds, width: r.width, height: r.height, bytes: r.bytes, isImage: isImage)
            let link: URL?
            if case .link(let l)? = input { link = l.url } else { link = nil }
            _ = try await store.add(
                file: local, kind: kindOnDisk, media: info, sessionID: sid, link: link, remoteURL: nil, move: true,
                mediaID: targetMediaID, keep: ctx.settings.keepVideosOnDevice, role: role, madeFrom: m.items, madeSpec: spec,
                libraryID: itemID)
        } catch {
            Telemetry.log(.warn, .store, "made file not kept on device", data: Telemetry.errorData(error))
        }
        return r
    }

    /// The JSON the made file carries (`made_spec`, at most 512 bytes): what the server stores, so a record made here
    /// and the library's row read alike.
    static func madeSpec(for m: GalleryMake, result r: MadeResult) -> Data? {
        var object: [String: Any]
        switch m {
        case .image(let plan):
            object = ["kind": "gallery", "layout": plan.layout.rawValue, "items": plan.items]
        case .slideshow(let plan):
            object = ["format": plan.format.rawValue, "items": plan.items, "fade": plan.fade, "frame": plan.frame.rawValue]
        }
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        if data.count > 512 {
            object["items"] = nil
            data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        }
        return data
    }

    private func makeTelemetry(_ m: GalleryMake, items: [GalleryItem]) -> [String: TelemetryValue] {
        switch m {
        case .slideshow(let plan):
            return [
                "what": .string(plan.format == .webp ? "webp" : "mp4"), "items": .int(plan.items.count),
                "seconds": .double(plan.photoSeconds), "fade": .bool(plan.fade), "frame": .string(plan.frame.rawValue),
            ]
        case .image(let plan):
            return ["what": "image", "items": .int(plan.items.count), "layout": .string(plan.layout.rawValue)]
        }
    }
}

extension GalleryMake {
    /// What a remake of this replaces.
    var madeKind: MadeKind {
        switch self {
        case .slideshow(let plan): return .slideshow(plan.format)
        case .image(let plan): return .galleryImage(plan.layout)
        }
    }
}
