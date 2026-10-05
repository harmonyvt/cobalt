import CoreGraphics
import Foundation
import Synchronization

/// What a server would remember between calls, for `PreviewClient`.
final class PreviewServer: Sendable {
    struct Session: Sendable {
        var id: String
        var startedAt: Date
        var isUpload: Bool
        var clip: PreviewData.Clip
        var name: String?
        var bytes: Int64
    }

    struct Render: Sendable {
        var job: String
        var sessionID: String
        var startedAt: Date
        var request: RenderRequest
        var clip: PreviewData.Clip
        /// The hosted link of the result: the clip's own, or (where the store already holds the
        /// clip's webp) a link of its own per render, so a new render is a new webp.
        var webpURL: URL
    }

    private struct State {
        var sessions: [String: Session] = [:]
        var renders: [String: Render] = [:]
        var counter = 0
        var deleted: Set<String> = []
        var deletedFiles: Set<String> = []     // library file ids gone through `deletePost`
        var postDeletes: [String: Int] = [:]   // post id -> calls so far
        var webpCounter = 0
        var notifications: [String: NotifyOptIn] = [:]
        var notifyCalls: [String] = []         // "PUT <sid>" / "DELETE <sid>", in order
        var titles: [String: String] = [:]     // post id -> custom title the "server" holds ("" = cleared)
        var titleCalls: [String] = []          // "<item id> <title or ->" for every `setTitle`, in order
    }

    private let state = Mutex(State())

    func newSession(isUpload: Bool, clip: PreviewData.Clip, name: String?, bytes: Int64, at now: Date) -> String {
        state.withLock { s in
            s.counter += 1
            let id = "PrEvIeWsession\(String(format: "%08d", s.counter))"
            s.sessions[id] = Session(id: id, startedAt: now, isUpload: isUpload, clip: clip, name: name, bytes: bytes)
            return id
        }
    }

    func session(_ id: String) -> Session? { state.withLock { $0.sessions[id] } }

    func newRender(
        sessionID: String, request: RenderRequest, clip: PreviewData.Clip, at now: Date, uniqueLink: Bool
    ) -> String {
        state.withLock { s in
            s.counter += 1
            let job = "PrEvIeWjob\(String(format: "%08d", s.counter))"
            var url = clip.webpURL
            if uniqueLink {
                s.webpCounter += 1
                url = PreviewData.mediaBase.appendingPathComponent("PrEvIeW\(100 + s.webpCounter).webp")
            }
            s.renders[job] = Render(
                job: job, sessionID: sessionID, startedAt: now, request: request, clip: clip, webpURL: url)
            return job
        }
    }

    func render(_ job: String) -> Render? { state.withLock { $0.renders[job] } }

    /// The notify opt-ins the "server" holds (session id -> opt-in), and every call made, for tests.
    var notifications: [String: NotifyOptIn] { state.withLock { $0.notifications } }
    var notifyCalls: [String] { state.withLock { $0.notifyCalls } }
    func setNotify(_ id: String, _ optIn: NotifyOptIn) {
        state.withLock { s in s.notifications[id] = optIn; s.notifyCalls.append("PUT \(id)") }
    }
    func cancelNotify(_ id: String) {
        state.withLock { s in s.notifications[id] = nil; s.notifyCalls.append("DELETE \(id)") }
    }

    /// Custom titles the "server" holds (CONTRACT-LIBRARY2 6): a post id -> its title; "" is a clear.
    var titles: [String: String] { state.withLock { $0.titles } }
    var titleCalls: [String] { state.withLock { $0.titleCalls } }
    /// Records the call and returns how many came in for `itemID` so far (this one included).
    func recordTitleCall(_ itemID: String, title: String?) -> Int {
        state.withLock { s in
            s.titleCalls.append("\(itemID) \(title ?? "-")")
            return s.titleCalls.filter { $0.hasPrefix("\(itemID) ") }.count
        }
    }
    func setTitle(_ title: String?, post id: String) { state.withLock { $0.titles[id] = title ?? "" } }

    func markDeleted(_ name: String) { state.withLock { _ = $0.deleted.insert(name) } }
    func isDeleted(_ name: String?) -> Bool { name.map { n in state.withLock { $0.deleted.contains(n) } } ?? false }

    /// Whole-post deletes: the files that went (by library file id) and how often a post was asked.
    func markFilesDeleted(_ ids: [String]) { state.withLock { $0.deletedFiles.formUnion(ids) } }
    func isFileDeleted(_ id: String) -> Bool { state.withLock { $0.deletedFiles.contains(id) } }
    func recordPostDelete(_ postID: String) -> Int {
        state.withLock { s in
            s.postDeletes[postID, default: 0] += 1
            return s.postDeletes[postID] ?? 1
        }
    }
    var postDeleteCalls: [String: Int] { state.withLock { $0.postDeletes } }
}

/// A `CobaltClient` that replays the boards' data and timings (section 4.8). Everything runs on
/// the pipeline's clock, so tests drive it with a virtual one and nobody sleeps for real.
public struct PreviewClient: CobaltClient {
    let scenario: PreviewScenario
    /// 1 = the lab's compressed timings; 5 = the live estimates (fetch, save, upload and render
    /// stretch; reading the frames stays at 150 ms, it is on the device).
    let timeScale: Double
    let clock: any PipelineClock
    let server = PreviewServer()
    /// The server of `AppModel.previewVisibility(_:)`: lists one file per rendition on `v=2` and takes the switch.
    /// `.off` (every other preview) is a server without `features.visibility`.
    let visibility: VisibilityPreviewMode
    let visibilityState = PreviewVisibilityState()

    public var baseURL: URL { PreviewData.base }

    public init(scenario: PreviewScenario = .happy, timeScale: Double = 1) {
        self.init(scenario: scenario, timeScale: timeScale, clock: SystemClock())
    }

    init(scenario: PreviewScenario, timeScale: Double, clock: any PipelineClock, visibility: VisibilityPreviewMode = .off) {
        self.scenario = scenario
        self.timeScale = max(0.01, timeScale)
        self.clock = clock
        self.visibility = visibility
    }

    var clip: PreviewData.Clip { PreviewData.clip(for: scenario) }
    var hasProgress: Bool { scenario != .legacyFork && scenario != .plainCobalt }

    // MARK: - Capabilities, resolve

    public func capabilities() async -> Capabilities { PreviewData.capabilities(for: scenario) }

    public func resolve(_ link: URL) async throws -> CobaltResult {
        switch scenario {
        case .revokedKey:
            throw CobaltError.api(code: "error.api.auth.key.invalid", httpStatus: 401)
        case .privatePost:
            try await clock.sleep(seconds: PreviewData.fetchSeconds * timeScale)
            throw CobaltError.api(code: "error.api.fetch.empty", httpStatus: 400)
        case .picker:
            return .picker(items: PreviewData.pickerItems(), audio: nil)
        case .plainCobalt:
            // plain cobalt has no studio: the fetch is the response itself
            try await clock.sleep(seconds: PreviewData.fetchSeconds * timeScale)
            return .file(url: PreviewData.tunnelURL, filename: "\(clip.title).mp4")
        default:
            return .file(url: PreviewData.tunnelURL, filename: "\(clip.title).mp4")
        }
    }

    public func createStudio(link: URL) async throws -> StudioCreated {
        try await createStudio(link: link, public: nil)
    }

    /// Records what the app asked for (`visibilityState.saveCalls`: "create public" / "create -"), so tests can
    /// see the default-public flag go out, or not.
    public func createStudio(link: URL, public makePublic: Bool?) async throws -> StudioCreated {
        visibilityState.recordSave("create", public: makePublic)
        let id = server.newSession(isUpload: false, clip: clip, name: nil, bytes: clip.bytes, at: clock.now())
        return StudioCreated(id: id, pageURL: nil)
    }

    // MARK: - Upload

    public func upload(
        file: URL, name: String, contentType: String,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> UploadResult {
        try await upload(file: file, name: name, contentType: contentType, public: nil, progress: progress)
    }

    public func upload(
        file: URL, name: String, contentType: String, public makePublic: Bool?,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> UploadResult {
        visibilityState.recordSave("upload", public: makePublic)
        let onDisk = ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.int64Value
        let size = PreviewData.uploadBytes(forFileSize: onDisk, scenario: scenario)
        let step = PreviewData.uploadBytesPerSecond / timeScale * 0.1
        var sent = 0.0
        progress(TransferProgress(bytes: 0, total: size))
        while sent < Double(size) {
            try await clock.sleep(seconds: 0.1)
            sent = min(Double(size), sent + step)
            progress(TransferProgress(bytes: Int64(sent), total: size))
        }
        let isImage = scenario == .image || (contentType.hasPrefix("image/") && contentType != "image/gif")
        let now = clock.now()
        var item = LibraryFile(
            id: "PrEvIeWupload0001", kind: .private, source: .upload, name: name, url: nil,
            contentType: isImage ? (contentType.hasPrefix("image/") ? contentType : "image/png") : contentType,
            bytes: size, width: nil, height: nil, duration: nil, createdAt: now, mediaName: nil, deletable: false)
        if isImage {
            item.width = 1170; item.height = 2532
            return UploadResult(sessionID: nil, item: item, studioErrorCode: nil)
        }
        let id = server.newSession(isUpload: true, clip: clip, name: name, bytes: size, at: now)
        return UploadResult(sessionID: id, item: item, studioErrorCode: nil)
    }

    // MARK: - Sessions

    /// A session this client made, or one of the library fixture's (`PrEvIeWsession0000000aN`, open on
    /// the "server" since before the app started): "another webp" from a library post renders on it.
    private func knownSession(_ id: String) -> PreviewServer.Session? {
        if let s = server.session(id) { return s }
        guard id.hasPrefix("PrEvIeWsession0000000a") else { return nil }
        return PreviewServer.Session(
            id: id, startedAt: clock.now().addingTimeInterval(-3_600), isUpload: false, clip: clip, name: nil, bytes: clip.bytes)
    }

    public func session(_ id: String, wait: Int) async throws -> StudioSession {
        guard let s = knownSession(id) else { throw CobaltError.api(code: "error.studio.not_found", httpStatus: 404) }
        var snap = snapshot(of: s, at: clock.now())
        if wait > 0, snap.session.status == .saving {
            let pause = max(0.001, min(Double(wait), snap.nextChange))
            try await clock.sleep(seconds: pause)
            snap = snapshot(of: s, at: clock.now())
        }
        return snap.session
    }

    public func sourceURL(session id: String) -> URL {
        PreviewData.base.appendingPathComponent("studio/\(id)/source")
    }

    private func snapshot(of s: PreviewServer.Session, at now: Date) -> (session: StudioSession, nextChange: Double) {
        let t = max(0, now.timeIntervalSince(s.startedAt))
        let cold = scenario == .coldStart
        let ts = timeScale
        var out = StudioSession(
            id: s.id, status: .saving, link: s.isUpload ? "upload:PrEvIeWupload0001" : s.clip.link.absoluteString,
            service: s.isUpload ? "upload" : (LinkInfo(s.clip.link)?.service),
            title: nil, duration: nil, width: nil, height: nil, bytes: nil,
            createdAt: s.startedAt, expiresAt: s.startedAt.addingTimeInterval(7 * 86_400), errorCode: nil,
            renders: [], step: nil, stepBytes: nil, stepTotal: nil, waking: nil)

        func ready() {
            out.status = .ready
            out.title = s.isUpload ? (s.name ?? s.clip.title) : s.clip.title
            out.duration = s.clip.duration; out.width = s.clip.width; out.height = s.clip.height
            out.bytes = s.isUpload ? s.bytes : s.clip.bytes
            out.step = nil; out.stepBytes = nil; out.stepTotal = nil
            out.waking = hasProgress ? false : nil
        }

        if s.isUpload {
            let readEnd = PreviewData.uploadReadSeconds * ts
            if t >= readEnd { ready(); return (out, 0) }
            if hasProgress { out.step = .reading; out.waking = false }
            return (out, readEnd - t)
        }

        let fetchEnd = (cold ? PreviewData.coldFetchSeconds : PreviewData.fetchSeconds) * ts
        let saveEnd = fetchEnd + PreviewData.saveSeconds * ts
        if t < fetchEnd {
            let wakeAt = PreviewData.wakingAfterSeconds * ts
            if hasProgress {
                out.step = .fetching
                out.waking = cold && t >= wakeAt
            }
            var next = fetchEnd - t
            if cold, t < wakeAt { next = min(next, wakeAt - t) }
            return (out, next)
        }
        if t < saveEnd {
            if hasProgress {
                let k = min(1, (t - fetchEnd) / (PreviewData.saveSeconds * ts))
                out.step = .storing
                out.stepTotal = s.clip.bytes
                out.stepBytes = Int64(Double(s.clip.bytes) * (1 - pow(1 - k, 3)))
                out.waking = false
            }
            return (out, min(0.1, saveEnd - t))
        }
        ready()
        return (out, 0)
    }

    // MARK: - Render

    public func render(session id: String, _ request: RenderRequest) async throws -> String {
        guard let s = knownSession(id) else { throw CobaltError.api(code: "error.studio.not_found", httpStatus: 404) }
        if scenario == .renderBusy { throw CobaltError.api(code: "error.webp.busy", httpStatus: 429) }
        if request.notify { server.setNotify(id, NotifyOptIn(on: [.rendered, .failed], label: s.name ?? s.clip.title)) }
        return server.newRender(
            sessionID: id, request: request, clip: s.clip, at: clock.now(),
            uniqueLink: scenario == .renditions || scenario == .renditionsLegacy || scenario.failsRenames)
    }

    public func renderStatus(session id: String, job: String, wait: Int) async throws -> RenderStatus {
        guard let r = server.render(job) else { throw CobaltError.api(code: "error.webp.job_lost", httpStatus: 404) }
        var snap = renderSnapshot(r, at: clock.now())
        if wait > 0, case .pending = snap.status {
            try await clock.sleep(seconds: max(0.001, min(Double(wait), 0.1, snap.nextChange)))
            snap = renderSnapshot(r, at: clock.now())
        }
        return snap.status
    }

    private func renderSnapshot(_ r: PreviewServer.Render, at now: Date) -> (status: RenderStatus, nextChange: Double) {
        let t = max(0, now.timeIntervalSince(r.startedAt))
        let total = PreviewData.renderSeconds * timeScale
        if scenario == .renderLost, t >= total * PreviewData.renderLostShare {
            return (.failed(code: "error.webp.job_lost"), 0)
        }
        if t >= total { return (.success(webpResult(r)), 0) }
        guard hasProgress else { return (.pending(phase: nil, framesDone: nil, framesTotal: nil), total - t) }
        let decodeEnd = total * PreviewData.renderDecodeShare
        let frames = max(1, Int((r.request.length * 15).rounded()))
        if t < decodeEnd {
            return (.pending(phase: .decode, framesDone: Int(Double(frames) * t / decodeEnd), framesTotal: frames), min(0.1, decodeEnd - t))
        }
        return (.pending(phase: .pack, framesDone: frames, framesTotal: frames), min(0.1, total - t))
    }

    private func webpResult(_ r: PreviewServer.Render) -> WebpResult {
        let c = r.clip
        // a crop narrows the source first; the output keeps the crop's aspect
        let cropped = r.request.crop.map { $0.pixelSize(in: CGSize(width: c.width, height: c.height)) }
        let sourceW = cropped.map { Int($0.width) } ?? c.width
        let sourceH = cropped.map { Int($0.height) } ?? c.height
        let w = min(r.request.width, sourceW)
        let h = cropped != nil
            ? Int((Double(sourceH) * Double(w) / Double(sourceW) / 2).rounded()) * 2
            : (w == c.webpWidth ? c.webpHeight : Int((Double(c.height) * Double(w) / Double(c.width)).rounded()))
        let len = r.request.length
        let isDefault = abs(len - min(c.duration, 10)) < 0.06 && r.request.start < 0.06
        let seconds = isDefault ? c.webpSeconds : (len * 10).rounded() / 10
        let bytes = isDefault ? c.webpBytes : Int64(Double(c.webpBytes) * len / c.webpSeconds)
        return WebpResult(job: r.job, url: r.webpURL, bytes: bytes, width: w, height: h, seconds: seconds)
    }

    // MARK: - Hosting, library

    public func publish(session id: String) async throws -> HostedFile {
        try await clock.sleep(seconds: 0.3)
        let c = server.session(id)?.clip ?? clip
        return HostedFile(
            url: URL(string: "https://media.capybaraharmony.com/PrEvIeW021.mp4")!,
            bytes: c.bytes, contentType: "video/mp4", itemID: "PrEvIeWitem000021")
    }

    public func publish(item id: String) async throws -> HostedFile {
        try await clock.sleep(seconds: 0.3)
        return HostedFile(
            url: URL(string: "https://media.capybaraharmony.com/PrEvIeW022.png")!,
            bytes: PreviewData.imageUploadBytes, contentType: "image/png", itemID: "PrEvIeWitem000022")
    }

    public func openStudio(item id: String) async throws -> StudioCreated {
        let sid = server.newSession(isUpload: true, clip: clip, name: nil, bytes: clip.bytes, at: clock.now())
        return StudioCreated(id: sid, pageURL: nil)
    }

    public func library(cursor: String?, limit: Int) async throws -> LibraryPage {
        shown(PreviewData.libraryPage(now: clock.now()))
    }

    /// `v=2` on a server that has the switch: one file per rendition with its visibility (and the switches made
    /// so far); anything else is the page older apps know.
    public func library(cursor: String?, limit: Int, v2: Bool) async throws -> LibraryPage {
        guard v2, visibility != .off else { return try await library(cursor: cursor, limit: limit) }
        var page = PreviewData.libraryPageV2(now: clock.now())
        page.posts = page.posts.map { post in
            var p = post
            p.files = post.files.map { visibilityState.applying(to: $0) }
            p.visibility = p.files.first { $0.role == .privateCopy }?.visibility ?? (p.files.contains { $0.isPublic } ? .public : .private)
            return p
        }
        return shown(page)
    }

    /// What the "server" has deleted or retitled so far, applied to a fixture page.
    private func shown(_ fixture: LibraryPage) -> LibraryPage {
        var page = fixture
        let titles = server.titles
        page.posts = page.posts.map { post in
            var p = post
            p.files = post.files.filter { !server.isDeleted($0.mediaName) && !server.isFileDeleted($0.id) }
            if let t = titles[post.id] { p.customTitle = t.isEmpty ? nil : t }
            return p
        }.filter { !$0.files.isEmpty }
        return page
    }

    /// Previews: `.working` switches the file after a short wait (the same link every time, like the server);
    /// `.failsOnce` answers 502 to the first call for each file (the revert, then the retry); `.failing` always
    /// does. A file no post lists is `error.library.not_found`.
    public func setVisibility(item id: String, public makePublic: Bool) async throws -> VisibilityChange {
        guard visibility != .off else { throw PipelineFailure.unsupported }
        let calls = visibilityState.recordCall(id, public: makePublic)         // the server hears it at once
        try await clock.sleep(seconds: 0.4)
        if visibility == .failing || (visibility == .failsOnce && calls == 1) {
            throw CobaltError.api(code: "error.library.storage", httpStatus: 502)
        }
        guard let base = PreviewData.libraryPageV2(now: clock.now()).posts.flatMap(\.files).first(where: { $0.id == id }) else {
            throw PipelineFailure.server(code: "error.library.not_found")
        }
        guard base.canToggleVisibility else { throw PipelineFailure.unsupported }
        let file = visibilityState.set(base, public: makePublic)
        return VisibilityChange(file: file, cacheCleared: makePublic ? nil : true)
    }

    /// Previews: the title goes into the "server"'s memory and the next `library` carries it. In
    /// `.renameFails` the first call for item `PrEvIeWitem000008` answers 503 (the second works), so
    /// the revert and the retry preview and test. An item no post lists is `error.library.not_found`.
    public func setTitle(anchor itemID: String, _ title: String?) async throws -> PostTitleResult {
        try await clock.sleep(seconds: 0.2)
        let cleaned = title.flatMap(MediaTitle.clean)
        let calls = server.recordTitleCall(itemID, title: cleaned)
        if scenario.failsRenames, itemID == "PrEvIeWitem000008", calls == 1 {
            throw CobaltError.api(code: "error.api.generic", httpStatus: 503)
        }
        let all = PreviewData.libraryPage(now: clock.now()).posts
        guard let post = all.first(where: { $0.files.contains { $0.id == itemID } }) else {
            throw PipelineFailure.server(code: "error.library.not_found")
        }
        server.setTitle(cleaned, post: post.id)
        return PostTitleResult(post: post.id, title: cleaned)
    }

    /// Previews: the post of `itemID` goes. In `.renditions` the first call for a post answers partial
    /// (every file but its private copy went), the second finishes it, so the retry path previews and
    /// tests; any other scenario deletes it in one call. An unknown id is a post that is already gone.
    public func deletePost(anchor itemID: String) async throws -> PostDeleteResult {
        try await clock.sleep(seconds: 0.3)
        let all = PreviewData.libraryPage(now: clock.now()).posts
        guard let post = all.first(where: { $0.files.contains { $0.id == itemID } }) else { throw PipelineFailure.expired }
        let live = post.files.filter { !server.isDeleted($0.mediaName) && !server.isFileDeleted($0.id) }
        let call = server.recordPostDelete(post.id)
        var gone = live
        var kept: [LibraryFile] = []
        if scenario == .renditions, call == 1, live.count > 1, let keep = live.first(where: { $0.role == .privateCopy }) ?? live.last {
            kept = [keep]
            gone = live.filter { $0.id != keep.id }
        }
        server.markFilesDeleted(gone.map(\.id))
        return PostDeleteResult(
            deletedFiles: gone.count, deletedBytes: gone.reduce(0) { $0 + ($1.bytes ?? 0) }, remaining: kept.map(\.id))
    }

    public func deleteMedia(name: String) async throws {
        try await clock.sleep(seconds: 0.2)
        server.markDeleted(name)
    }

    // MARK: - Download

    // Live Activities: previews never push, so every run stays in local mode.
    public func registerLiveStartToken(_ token: String, environment: LiveEnvironment) async throws {}
    public func registerLiveRun(_ r: LiveRunRegistration) async throws -> LiveRunReply {
        LiveRunReply(pushing: false, started: false)
    }
    public func relayLiveState(run: UUID, _ state: LiveContentState) async throws {}
    public func endLiveRun(_ run: UUID) async throws {}
    public func liveSelftest() async throws -> LiveSelftest { LiveSelftest(configured: false) }

    // Notify bridge: previews remember the opt-in so tests can see what the app asked for.
    public func setNotify(session id: String, _ optIn: NotifyOptIn) async throws { server.setNotify(id, optIn) }
    public func cancelNotify(session id: String) async throws { server.cancelNotify(id) }

    public func download(
        _ file: RemoteFile, to destination: URL,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> URL {
        let total: Int64
        switch file {
        case .studioSource(let id): total = server.session(id)?.clip.bytes ?? clip.bytes
        case .open(let url): total = url == clip.webpURL ? clip.webpBytes : 2_000_000
        case .libraryItem: total = clip.bytes
        }
        // the finished webp is small and already hosted: it must not delay "webp ready"
        let isWebp: Bool
        if case .open(let url) = file, url == clip.webpURL || url.pathExtension == "webp" { isWebp = true } else { isWebp = false }
        let duration = (isWebp ? 0.1 : PreviewData.saveSeconds) * timeScale
        let steps = 5
        for i in 1...steps {
            try await clock.sleep(seconds: duration / Double(steps))
            progress(TransferProgress(bytes: total * Int64(i) / Int64(steps), total: total))
        }
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try PreviewMedia.placeholderBytes.write(to: destination)
        return destination
    }
}
