import CoreGraphics
import Foundation

// The server → state mapping of section 4.5. Every flow runs inside `launch`, so a thrown
// `PipelineFailure` / `CobaltError` becomes `.failed(...)` in one place (`handle`).

extension Pipeline {
    // MARK: - Helpers

    /// Capabilities as last known; re-read once when the app has none (launch offline).
    func knownCapabilities() async throws -> Capabilities {
        var caps = ctx.capabilities
        if caps.kind == .unreachable || caps.kind == .notCobalt { caps = await ctx.refreshCapabilities() }
        switch caps.kind {
        case .unreachable: throw PipelineFailure.unreachable
        case .notCobalt: throw PipelineFailure.server(code: "error.app.not_cobalt")
        default: return caps
        }
    }

    /// `waking` turns true when an outstanding request has taken longer than 1.5 s.
    func watched<T: Sendable>(_ op: @Sendable () async throws -> T) async throws -> T {
        let since = runStart
        let watcher = Task { [weak self] in
            guard let self else { return }
            try? await self.ctx.clock.sleep(seconds: 1.5)
            guard !Task.isCancelled else { return }
            self.markWaking(since: since)
        }
        defer { watcher.cancel() }
        return try await op()
    }

    func markWaking(since: Date) {
        if case .fetching(let s, false) = state, s == since { setState(.fetching(since: s, waking: true)) }
    }

    /// Network blips and a gateway that is briefly down (502/503/504, the Worker's answer while the
    /// container or D1 hiccups) are retried while polling (5 × 1 s) before they fail the run. Only
    /// idempotent reads go through here: a POST (`/render`, `/studio`) is never retried.
    func retrying<T: Sendable>(_ op: @Sendable () async throws -> T) async throws -> T {
        var attempts = 0
        while true {
            do { return try await op() }
            catch let e as CobaltError {
                if Pipeline.isTransient(e), attempts < 5 {
                    attempts += 1
                    try await ctx.clock.sleep(seconds: 1)
                    continue
                }
                throw e
            }
        }
    }

    static func isTransient(_ e: CobaltError) -> Bool {
        switch e {
        case .network(let code): return code != .cancelled
        case .invalidResponse(let status), .api(_, let status): return [502, 503, 504].contains(status)
        default: return false
        }
    }

    /// What a new save asks for: `public: true` when the owner keeps "make new saves public" on and the server takes
    /// the field (`features.public_default`), else nothing at all (CONTRACT-VISIBILITY decision 3).
    var publicFlag: Bool? { ctx.capabilities.publicDefault && ctx.settings.newSavesPublic ? true : nil }

    /// `POST /studio` (or the library's reopen) with the 3 s / 60 s busy retry.
    func openStudioRetrying(_ client: any CobaltClient, link: URL?, item: String?) async throws -> StudioCreated {
        let deadline = ctx.clock.now().addingTimeInterval(60)
        let makePublic = publicFlag                              // read here: the closure below is not on the main actor
        while true {
            do {
                return try await watched {
                    if let item { return try await client.openStudio(item: item) }
                    guard let link else { throw PipelineFailure.noLink }
                    return try await client.createStudio(link: link, public: makePublic)
                }
            } catch CobaltError.api(let code, _) where code == "error.studio.busy" {
                if ctx.clock.now().addingTimeInterval(3) > deadline { throw PipelineFailure.serverBusy }
                try await ctx.clock.sleep(seconds: 3)
            }
        }
    }

    func mediaInfo(_ s: StudioSession, fallbackName: String, bytes: Int64? = nil) -> MediaInfo {
        MediaInfo(
            name: s.title ?? fallbackName, duration: s.duration, width: s.width, height: s.height,
            bytes: bytes ?? s.bytes, isImage: false)
    }

    /// The local original when the store has it, else the server's ranged source.
    func sourceInput(session id: String, link: URL? = nil) -> FrameInput {
        if let video = ctx.store.videos.first(where: {
            $0.kind == .original && ($0.sessionID == id || (link != nil && $0.link == link))
        }),
           let url = video.fileURL,
           FileManager.default.fileExists(atPath: url.path) {
            pinStored(video.id)                                // the offline limit must not unlink what is being read
            return .local(url)
        }
        return .remote(ctx.client.sourceURL(session: id))
    }

    /// The store's copy of this session's original (the focus card's preview plays `stored`), pinned
    /// so the offline limit does not unlink it. Nothing when the store has none.
    func adoptStoredOriginal(session id: String, link: URL?) {
        guard stored == nil,
              let video = ctx.store.videos.first(where: {
                  $0.kind == .original && ($0.sessionID == id || (link != nil && $0.link == link))
              }),
              let url = video.fileURL, FileManager.default.fileExists(atPath: url.path)
        else { return }
        stored = video
        pinStored(video.id)
    }

    func mediaForSession(_ id: String, known: MediaInfo?) async throws -> MediaInfo {
        if let known, known.duration != nil { return known }
        let client = ctx.client
        let s = try await retrying { try await client.session(id, wait: 0) }
        var m = mediaInfo(s, fallbackName: known?.name ?? id)
        if let known { m.name = known.name; m.bytes = known.bytes ?? m.bytes }
        return m
    }

    func fileBytes(_ url: URL) -> Int64? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value
    }

    // MARK: - Frames and ready

    /// Fills the filmstrip, one frame at a time, as the video is read. Frames are cosmetic: when
    /// they fail the run carries on without them.
    ///
    /// Frames of the server's copy are read over HTTP with ranges, which is fragile and slow (9
    /// ranged reads took 14-18 s on a real link) while the whole original arrives in a couple of
    /// seconds. So the two RACE: the ranged reader and the device's own copy (the keep download that
    /// is under way, else one fetched for the purpose, never both). Whichever finishes first wins; if
    /// the copy arrives, the frames still missing are read from it in a fraction of a second and the
    /// ranged reader is dropped. The copy also serves "save to photos" afterwards.
    ///
    /// The black strip was intermittent, so the ladder is built for transient failures (the object
    /// not servable yet right after "ready", a cold or slow range request, AVFoundation failing once):
    /// the remote read is tried again after a short wait, lower-res on the way down; then the device's
    /// own copy; whatever frames arrived fill the gaps between them. Only when every rung fails is
    /// `framesFailed` set.
    func runFrames(_ input: FrameInput, duration: Double?) async throws {
        var isRemote = false
        if case .remote = input { isRemote = true }
        let edge = ctx.frameEdge
        if isRemote {
            if let sid = sessionID {
                try await raceRemoteFramesAgainstLocalCopy(input, duration: duration, edge: edge, session: sid)
            } else {
                try await readRemoteLadder(input, duration: duration, edge: edge)
            }
        } else {
            for (pause, rungEdge) in [(0.0, edge), (1.0, min(edge, 160))] where frames.allSatisfy({ $0 == nil }) {
                if pause > 0 { try await ctx.clock.sleep(seconds: pause) }
                _ = try await readFrames(input, duration: duration, patience: nil, maxEdge: rungEdge)
            }
        }
        framesFailed = frames.allSatisfy { $0 == nil }
        fillFrameGaps()
        try Task.checkCancellation()
    }

    /// The ranged reads of the server's copy, with the retries for the transient failures (the object
    /// not servable yet right after "ready", a cold or slow range request, AVFoundation failing
    /// once): again after a short wait, lower-res on the way down. Stops at the first rung that
    /// brings any frame. Throws only when cancelled.
    func readRemoteLadder(_ input: FrameInput, duration: Double?, edge: CGFloat) async throws {
        // (pause before, long edge, patience)
        let rungs: [(Double, CGFloat, Double)] = [
            (0, edge, Self.remoteFramesPatience), (1.5, edge, Self.remoteFramesPatience),
            (4, min(edge, 160), Self.remoteFramesPatience),
        ]
        for (pause, rungEdge, patience) in rungs where frames.allSatisfy({ $0 == nil }) {
            if pause > 0 { try await ctx.clock.sleep(seconds: pause) }
            _ = try await readFrames(input, duration: duration, patience: patience, maxEdge: rungEdge)
        }
    }

    /// How long a partial ranged read waits for the copy that is still coming before it is accepted.
    static let localCopyGrace: Double = 5

    private enum FrameRace: Sendable { case network, local(URL?), grace }

    /// The ranged reader and the local copy, side by side (see `runFrames`). Frames only ever come
    /// from real decodes; each slot is filled once (both writers check it on the main actor).
    private func raceRemoteFramesAgainstLocalCopy(
        _ input: FrameInput, duration: Double?, edge: CGFloat, session sid: String
    ) async throws {
        let (events, out) = AsyncStream.makeStream(of: FrameRace.self)
        let network = Task { [weak self] in
            guard let self else { return }
            try? await readRemoteLadder(input, duration: duration, edge: edge)
            out.yield(.network)
        }
        let local = Task { [weak self] in
            guard let self else { return }
            let url = try? await localCopyForFrames(session: sid)
            out.yield(.local(url ?? nil))
        }
        var grace: Task<Void, Never>?
        defer { network.cancel(); local.cancel(); grace?.cancel(); out.finish() }
        try await withTaskCancellationHandler {
            var networkDone = false
            var localDone = false
            for await event in events {
                try Task.checkCancellation()
                switch event {
                case .local(let url):
                    localDone = true
                    guard let url else {
                        if networkDone { return }                       // neither has more to give
                        continue                                        // no copy: the ranged reader is what is left
                    }
                    let added = frames.contains(where: { $0 == nil })
                        ? try await readFrames(.local(url), duration: duration, patience: nil, maxEdge: edge) : 0
                    if added > 0 || !frames.contains(where: { $0 == nil }) { return }
                    if networkDone { return }                           // the copy decoded nothing either
                case .network:
                    networkDone = true
                    if !frames.contains(where: { $0 == nil }) { return }    // complete: the copy is not needed
                    if localDone { return }
                    if frames.contains(where: { $0 != nil }), grace == nil {
                        // a partial strip is acceptable, but the copy is close: give it a moment
                        grace = Task { [weak self] in
                            try? await self?.ctx.clock.sleep(seconds: Self.localCopyGrace)
                            out.yield(.grace)
                        }
                    }
                case .grace:
                    if networkDone { return }
                }
            }
        } onCancel: {
            network.cancel(); local.cancel(); out.finish()
        }
        try Task.checkCancellation()
    }

    /// A frame that never came takes its nearest neighbour's picture: a strip with holes is read as
    /// broken, and the frames are cosmetic anyway.
    func fillFrameGaps() {
        let have = frames.enumerated().compactMap { i, f in f.map { (i, $0) } }
        guard !have.isEmpty, have.count < frames.count else { return }
        for i in frames.indices where frames[i] == nil {
            if let nearest = have.min(by: { abs($0.0 - i) < abs($1.0 - i) }) {
                frames[i] = Frame(index: i, image: nearest.1.image)
            }
        }
    }

    /// How long the server's copy gets to produce a first frame before the next rung is tried.
    static let remoteFramesPatience: Double = 12

    /// Reads frames from `input` into `frames`, as they come. Errors are swallowed (frames are
    /// cosmetic); cancelling the run throws. `patience` is the time allowed before the first frame.
    private func readFrames(_ input: FrameInput, duration: Double?, patience: Double?, maxEdge: CGFloat) async throws -> Int {
        let reader = Task { [weak self] () -> Int in
            guard let self else { return 0 }
            var added = 0
            do {
                let stream = ctx.tools.frames(
                    of: input, duration: duration, count: Pipeline.frameCount, maxEdge: maxEdge)
                for try await frame in stream {
                    try Task.checkCancellation()
                    guard frame.index >= 0, frame.index < frames.count, frames[frame.index] == nil else { continue }
                    frames[frame.index] = frame
                    added += 1
                    // (a run that is already on the trim keeps it: its strip just fills in)
                    if case .reading = state { setState(.reading(developed: frames.compactMap { $0 }.count, of: Pipeline.frameCount)) }
                }
            } catch {
                // carry on without the remaining frames (a cancelled reader ends the same way)
            }
            return added
        }
        let watchdog: Task<Void, Never>? = patience.map { seconds in
            Task { [weak self] in
                guard let self else { return }
                try? await ctx.clock.sleep(seconds: seconds)
                guard !Task.isCancelled, frames.allSatisfy({ $0 == nil }) else { return }
                reader.cancel()
            }
        }
        let added = await withTaskCancellationHandler { await reader.value } onCancel: { reader.cancel() }
        watchdog?.cancel()
        try Task.checkCancellation()
        return added
    }

    /// A copy of the original on this device to read frames from: the stored one, the download the
    /// keep-on-device setting already has under way (waited for, never fetched twice), or a fetch of
    /// its own. Nil when none could be had. The fetch stays as `localFile`, so "save to photos"
    /// finds it instead of downloading the video again.
    func localCopyForFrames(session sid: String) async throws -> URL? {
        let fm = FileManager.default
        if let url = stored?.fileURL, fm.fileExists(atPath: url.path) { return url }
        if let url = localFile, fm.fileExists(atPath: url.path) { return url }
        if let request = keepRequest, let video = await request.value, let url = video.fileURL, fm.fileExists(atPath: url.path) {
            return url
        }
        try Task.checkCancellation()
        let token = runToken
        let relay = MainActorRelay<TransferProgress> { [weak self] p in self?.keepDownloadProgress(p, token: token) }
        let name = ((media?.name ?? sid) as NSString).deletingPathExtension
        do {
            let file = try await ctx.client.download(
                .studioSource(session: sid), to: ctx.store.inboxURL(for: "\(name).mp4"), progress: { relay.push($0) })
            guard token == runToken else { try? fm.removeItem(at: file); throw CancellationError() }
            try Task.checkCancellation()
            localFile = file
            temporaryFiles.append(file)
            keepProgress = nil
            return file
        } catch {
            if Task.isCancelled || token != runToken { throw CancellationError() }
            Telemetry.log(.warn, .upload, "original download for frames failed", data: Telemetry.errorData(error))
            keepProgress = nil
            return nil
        }
    }

    /// Progress of the original's download (any of the three that fetch it) for the UI, the
    /// continued-processing task and, when "save to photos" is waiting on it, the button.
    func keepDownloadProgress(_ p: TransferProgress, token: UUID) {
        guard token == runToken else { return }
        keepProgress = p
        if photos == .working, case .downloading = photosStep { photosStep = .downloading(p) }
        ctx.continued?.pipelineChanged(self)
    }

    /// `.reading` while frames arrive, then 250 ms, then `.ready`.
    ///
    /// `readyFirst`: a source on this device with a known length (the "another webp" runs) opens the trim at once
    /// and lets the filmstrip fill in behind it; the frames are cosmetic, and reading nine of them takes a second
    /// or more, which is a long time to look at "reading the video" for a video that is already here.
    func develop(_ m: MediaInfo, from input: FrameInput, readyFirst: Bool = false) async throws {
        media = m
        if readyFirst, case .local = input, m.duration != nil {
            enterReady()
            try await runFrames(input, duration: m.duration)
            return
        }
        setState(.reading(developed: frames.compactMap { $0 }.count, of: Pipeline.frameCount))
        try await runFrames(input, duration: m.duration)
        try await ctx.clock.sleep(seconds: 0.25)
        enterReady()
    }

    func enterReady() {
        let d = media?.duration ?? maxClipSeconds
        trim = TrimRange(start: 0, end: min(d, maxClipSeconds))
        trimOverLimit = false
        setState(.ready)
    }

    // MARK: - Pasted link

    func runLink(_ info: LinkInfo) async throws {
        let caps = try await knownCapabilities()
        let client = ctx.client
        let link = info.url
        let resolved = try await watched { try await client.resolve(link) }
        try Task.checkCancellation()
        switch resolved {
        case .localProcessing:
            throw PipelineFailure.unsupported
        case .picker(let items, _):
            guard !items.isEmpty else { throw PipelineFailure.unsupported }
            setState(.picker(items: items))
        case .file(let url, let filename):
            if caps.studio {
                try await forkSave(client, info)
            } else {
                try await plainSave(client, url: url, filename: filename, info: info)
            }
        }
    }

    /// Fork / legacy fork: `POST /studio`, poll until saved, read the frames from the source.
    func forkSave(_ client: any CobaltClient, _ info: LinkInfo) async throws {
        let created = try await openStudioRetrying(client, link: info.url, item: nil)
        sessionID = created.id
        recordJob(.saving)
        let s = try await pollSaving(client, id: created.id)
        let m = mediaInfo(s, fallbackName: info.ref)
        media = m
        keepOriginalInBackground(client, session: created.id, media: m)
        try await develop(m, from: .remote(client.sourceURL(session: created.id)))
    }

    func pollSaving(_ client: any CobaltClient, id: String) async throws -> StudioSession {
        var wakingSeen = false
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
                switch s.step {
                case .fetching:
                    wakingSeen = wakingSeen || (s.waking ?? false)
                    setState(.fetching(since: runStart, waking: s.waking ?? wakingSeen))
                case .reading, .storing:
                    setState(.saving(bytes: s.stepBytes, total: s.stepTotal, since: runStart))
                case nil:
                    setState(.saving(bytes: nil, total: nil, since: runStart))
                }
            }
        }
    }

    /// Polls without touching the state (the upload flow shows the frames instead).
    func waitReady(_ client: any CobaltClient, id: String) async throws -> StudioSession {
        var pacer = PollPacer()
        while true {
            try Task.checkCancellation()
            try await pacer.beforePoll(clock: ctx.clock)
            let s = try await retrying { try await client.session(id, wait: 1) }
            pacer.observe(s, clock: ctx.clock)
            switch s.status {
            case .ready: return s
            case .error:
                throw mapFailure(code: s.errorCode ?? "error.studio.unknown", during: .saving, limits: ctx.capabilities.limits)
            case .saving: continue
            }
        }
    }

    /// "keep videos on device": the original is downloaded in the background and never blocks `.ready`.
    /// The download is its own task (not the side task's), so `detach()` can hand it to a background
    /// run and it still lands in the store.
    func keepOriginalInBackground(_ client: any CobaltClient, session id: String, media m: MediaInfo) {
        guard ctx.settings.keepVideosOnDevice, !ctx.isPreview else { return }
        // The sheet already handed this original to a background download (or the app's own is going):
        // a second copy would only race it (CONTRACT-SYNC.md decision 6).
        if ctx.originals?.pending.isLive(session: id) == true { return }
        let linkURL: URL?
        if case .link(let info) = input { linkURL = info.url } else { linkURL = nil }
        let store = ctx.store
        let token = runToken
        let target = targetMediaID
        let relay = MainActorRelay<TransferProgress> { [weak self] p in self?.keepDownloadProgress(p, token: token) }
        let request = Task<StoredVideo?, Never> {
            let dest = store.inboxURL(for: "\(m.name).mp4")
            guard let file = try? await client.download(.studioSource(session: id), to: dest, progress: { relay.push($0) }) else { return nil }
            guard !Task.isCancelled else { try? FileManager.default.removeItem(at: file); return nil }
            return try? await store.add(
                file: file, kind: .original, media: m, sessionID: id, link: linkURL, remoteURL: nil, move: true,
                mediaID: target)
        }
        keepRequest = request
        ctx.continued?.pipelineChanged(self)
        spawn { p in await p.finishKeepOriginal(request, session: id) }
    }

    /// The original arrived (or did not). The run may have been replaced while the file was moving
    /// in: it keeps its own `stored`, and the entry stays in the store.
    func finishKeepOriginal(_ request: Task<StoredVideo?, Never>, session id: String) async {
        let token = runToken
        let video = await request.value
        guard token == runToken else { return }
        keepRequest = nil
        keepProgress = nil
        defer { ctx.continued?.pipelineChanged(self) }
        if video == nil { Telemetry.log(.warn, .store, "original not kept on device", data: ["session": .string(String(id.prefix(8)))]) }
        guard let video else { return }
        // "public share" finished before the original landed: the entry takes the link now.
        if let url = hostedURL { ctx.store.setPublicURL(url, forSession: id, orEntry: video.id) }
        stored = ctx.store.videos.first { $0.id == video.id } ?? video
        pinStored(video.id)
        syncStoreTitle()                            // the title typed before the original landed
    }

    // MARK: - Plain cobalt

    func plainSave(_ client: any CobaltClient, url: URL, filename: String?, info: LinkInfo) async throws {
        // The server's `filename` is data, not a path: "..", separators and control characters never
        // reach the file system or the library.
        let name = filename.flatMap(SafeFileName.clean) ?? "\(info.service)_\(info.ref).mp4"
        let base = (name as NSString).deletingPathExtension
        let since = runStart
        let token = runToken
        setState(.saving(bytes: 0, total: nil, since: since))
        let dest = ctx.store.inboxURL(for: name)
        let relay = MainActorRelay<TransferProgress> { [weak self] p in
            self?.savingProgress(p, since: since, token: token)
        }
        let local = try await client.download(.open(url), to: dest) { relay.push($0) }
        try Task.checkCancellation()
        localFile = local
        let probed = await ctx.tools.probe(file: local)
        let m = MediaInfo(
            name: base, duration: probed?.duration, width: probed?.width, height: probed?.height,
            bytes: fileBytes(local) ?? probed?.bytes, isImage: false)
        media = m
        setState(.reading(developed: 0, of: Pipeline.frameCount))
        try await runFrames(.local(local), duration: m.duration)
        let video = try await ctx.store.add(
            file: local, kind: .original, media: m, sessionID: nil, link: info.url, remoteURL: nil, move: true)
        stored = video
        pinStored(video.id)
        syncStoreTitle()
        localFile = video.fileURL
        setState(.savedLocally(video))
    }

    func savingProgress(_ p: TransferProgress, since: Date, token: UUID) {
        guard token == runToken, case .saving = state else { return }
        setState(.saving(bytes: p.bytes, total: p.total, since: since))
    }

    // MARK: - File upload

    func runFile(_ file: IntakeFile) async throws {
        let caps = try await knownCapabilities()
        guard caps.studio, caps.upload else { throw PipelineFailure.unsupported }
        if caps.limits.maxUploadBytes > 0, file.bytes > caps.limits.maxUploadBytes {
            throw PipelineFailure.tooLarge(limit: caps.limits.maxUploadBytes)
        }
        // The share extension already copied its movie into the inbox: no second copy.
        let inbox = ctx.store.root.appendingPathComponent("inbox", isDirectory: true).resolvingSymlinksInPath().path
        let copy: URL
        if file.url.resolvingSymlinksInPath().path.hasPrefix(inbox + "/") {
            copy = file.url
        } else {
            copy = try await ctx.intake.copyIn(file, to: ctx.store.inboxURL(for: file.name))
        }
        var local = file
        local.url = copy
        try await runUpload(local)
    }

    /// The common tail of a file: from a picked file, a picker item, or an interrupted upload.
    /// `keepsOriginal`: the file the owner picked stays on the phone as a stored original (what a
    /// finished save does with its download). Off for a picker item's own download, which is not an upload
    /// the owner made.
    func runUpload(_ file: IntakeFile, keepsOriginal: Bool = true) async throws {
        let client = ctx.client
        let token = runToken
        localFile = file.url
        setState(.uploading(TransferProgress(bytes: 0, total: file.bytes)))
        let relay = MainActorRelay<TransferProgress> { [weak self] p in self?.uploadProgress(p, token: token) }
        Telemetry.log(.info, .upload, "upload start", data: ["bytes": .bytes(file.bytes), "type": .string(file.contentType)])
        let uploaded = try await client.upload(
            file: file.url, name: file.name, contentType: file.contentType, public: publicFlag
        ) { relay.push($0) }
        Telemetry.log(.info, .upload, "upload finished", data: ["bytes": .bytes(file.bytes), "session": .bool(uploaded.sessionID != nil), "studioError": .string(uploaded.studioErrorCode ?? "")])
        try Task.checkCancellation()
        guard token == runToken else { throw CancellationError() }
        uploadedItemID = uploaded.item.id.isEmpty ? nil : uploaded.item.id
        titleItemID = uploadedItemID
        sendTitleIfPossible()                       // a title typed while the upload ran goes right behind its answer

        // The stored count stays on screen long enough to read.
        setState(.saving(bytes: file.bytes, total: file.bytes, since: ctx.clock.now()))
        try await ctx.clock.sleep(seconds: 0.6)

        if uploaded.sessionID == nil && uploaded.studioErrorCode == nil {
            let probed = ctx.tools.imageInfo(file: file.url)
            let m = MediaInfo(
                name: file.name, duration: nil, width: uploaded.item.width ?? probed?.width,
                height: uploaded.item.height ?? probed?.height, bytes: file.bytes, isImage: true)
            media = m
            setState(.image(m))
            return
        }
        var sid = uploaded.sessionID
        if sid == nil {
            guard let item = uploadedItemID else {
                throw mapFailure(code: uploaded.studioErrorCode ?? "error.api.generic", during: .saving, limits: ctx.capabilities.limits)
            }
            sid = try await openStudioRetrying(client, link: nil, item: item).id
        }
        guard let sid else { throw PipelineFailure.unsupported }
        sessionID = sid
        media = MediaInfo(name: file.name, duration: nil, width: nil, height: nil, bytes: file.bytes, isImage: false)
        setState(.reading(developed: 0, of: Pipeline.frameCount))

        // Frames come from the local file while the server reads its copy. The poll is a structured
        // child (`async let`): cancelling this run cancels it, and leaving this scope ends it, so it
        // can never outlive the run and write into the next one.
        async let poll = self.waitReady(client, id: sid)
        try await runFrames(.local(file.url), duration: nil)
        let s = try await poll
        try Task.checkCancellation()
        guard token == runToken else { throw CancellationError() }
        media = MediaInfo(
            name: file.name, duration: s.duration, width: s.width, height: s.height,
            bytes: file.bytes, isImage: false)
        // The upload is the original: it stays on this phone like a saved link's does (and, with the
        // photos album on, goes into the album), as soon as the frames no longer need the file.
        if keepsOriginal, let media { keepUploadedOriginal(file, session: sid, media: media) }
        try await ctx.clock.sleep(seconds: 0.25)
        enterReady()
    }

    /// Moves the uploaded file into the offline store, off the ready transition (the poster and the
    /// flipbook take a moment). A Photos-picker upload first tells the album which asset it is, so the
    /// album adopts that asset and the sync never adds the same video to Photos again.
    func keepUploadedOriginal(_ file: IntakeFile, session id: String, media m: MediaInfo) {
        guard ctx.settings.keepVideosOnDevice, !ctx.isPreview, stored == nil else { return }
        guard FileManager.default.fileExists(atPath: file.url.path) else {
            Telemetry.log(.warn, .store, "uploaded original not kept", data: ["reason": "file gone"])
            return
        }
        var info = m
        info.name = (file.name as NSString).deletingPathExtension
        let store = ctx.store
        let target = targetMediaID
        let sync = ctx.photosSync
        let assetID = file.photosAssetID
        let source = file.url
        let request = Task<StoredVideo?, Never> {
            // Not cancellation-aware on purpose: the owner's upload is on the server already, and its
            // local original must not be lost because the card was closed a moment later.
            if let assetID { await sync?.adoptExistingAsset(localIdentifier: assetID, forSession: id) }
            do {
                return try await store.add(
                    file: source, kind: .original, media: info, sessionID: id, link: nil, remoteURL: nil, move: true,
                    mediaID: target)
            } catch {
                return nil                                        // `store.add` logged why
            }
        }
        keepRequest = request
        ctx.continued?.pipelineChanged(self)
        spawn { p in await p.finishKeepOriginal(request, session: id) }
    }

    func uploadProgress(_ p: TransferProgress, token: UUID) {
        guard token == runToken, case .uploading(let current) = state, p.bytes >= current.bytes else { return }
        setState(.uploading(p))
    }

    // MARK: - Picker

    func savePickerItems(_ items: [PickerItem]) {
        guard photos != .working else { return }
        photos = .working
        let client = ctx.client
        let base: String
        if case .link(let info) = input { base = info.ref } else { base = "cobalt" }
        let token = runToken
        let runLink: URL?
        if case .link(let info) = input { runLink = info.url } else { runLink = nil }
        spawn { p in
            do {
                for item in items {
                    let ext = item.type == .photo ? "jpg" : (item.type == .gif ? "gif" : "mp4")
                    let dest = p.ctx.store.inboxURL(for: "\(base)-\(item.id).\(ext)")
                    let local = try await client.download(.open(item.url), to: dest, progress: { _ in })
                    try Task.checkCancellation()
                    try await p.ctx.savePhoto(
                        fileURL: local, isImage: item.type != .video, key: item.type == .photo ? nil : PhotosKey.picker(url: item.url))
                    if item.type != .photo, p.ctx.settings.keepVideosOnDevice {
                        let probed = await p.ctx.tools.probe(file: local)
                        let m = MediaInfo(
                            name: "\(base)-\(item.id)", duration: probed?.duration, width: probed?.width,
                            height: probed?.height, bytes: p.fileBytes(local), isImage: false)
                        _ = try? await p.ctx.store.add(
                            file: local, kind: .original, media: m, sessionID: nil, link: runLink, remoteURL: item.url, move: true)
                    } else {
                        try? FileManager.default.removeItem(at: local)
                    }
                }
                guard p.runToken == token else { return }
                p.photos = .done
            } catch {
                Telemetry.log(.error, .photos, "save picker items failed", data: Telemetry.errorData(error))
                guard p.runToken == token else { return }
                p.photos = pipelineFailure(from: error, during: .saving).map(ActionStatus.failed) ?? .idle
            }
        }
    }

    func convertPickerItem(_ item: PickerItem) {
        let caps = ctx.capabilities
        guard caps.studio, caps.upload, item.canWebp else { return }
        setState(.fetching(since: ctx.clock.now(), waking: false))
        let base: String
        if case .link(let info) = input { base = info.ref } else { base = "cobalt" }
        launch { p in
            let client = p.ctx.client
            let ext = item.type == .gif ? "gif" : "mp4"
            let name = "\(base)-\(item.id).\(ext)"
            let local = try await client.download(.open(item.url), to: p.ctx.store.inboxURL(for: name), progress: { _ in })
            let bytes = p.fileBytes(local) ?? 0
            let limit = caps.limits.maxUploadBytes
            if limit > 0, bytes > limit { throw PipelineFailure.tooLarge(limit: limit) }
            try await p.runUpload(
                IntakeFile(url: local, name: name, bytes: bytes, contentType: MIME.type(forFileName: name)), keepsOriginal: false)
        }
    }

    // MARK: - Render

    func runRender(_ sid: String, existingJob: String?, since: Date) async throws {
        errorPhase = .rendering
        let client = ctx.client
        let token = runToken
        renderStart = since
        setState(.rendering(.working(since: since)))
        let jobID: String
        if let existingJob {
            jobID = existingJob
        } else {
            // The POST is its own task so `detach()` can hand it over while it is on the wire (a
            // second POST would start a second render); a run that is cancelled cancels it.
            let post: Task<String, Error>
            if let pending = renderRequest {
                post = pending
            } else {
                func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
                // Only a server that says `features.crop` is sent one (it would ignore it and render the whole frame).
                let sentCrop = ctx.capabilities.crop ? crop.flatMap { $0.isFull ? nil : $0 } : nil
                let request = RenderRequest(
                    start: round3(trim.start), length: round3(min(trim.length, maxClipSeconds)),
                    width: ctx.settings.webpWidth, quality: ctx.settings.webpQuality, crop: sentCrop)
                post = Task { try await client.render(session: sid, request) }
                renderRequest = post
                lastRenderRequest = request
            }
            jobID = try await post.value
            try Task.checkCancellation()
            guard token == runToken else { throw CancellationError() }
            renderRequest = nil
        }
        renderJobID = jobID
        if existingJob == nil { recordJob(.rendering(job: jobID)) }
        var packSince: Date?
        while true {
            try Task.checkCancellation()
            let status = try await retrying { try await client.renderStatus(session: sid, job: jobID, wait: 1) }
            // A poll that comes back after detach()/reset() must not write into the next run
            // (it stranded home in `.rendering` with no session when focus closed mid-pack).
            try Task.checkCancellation()
            guard token == runToken else { throw CancellationError() }
            switch status {
            case .pending(let phase, let done, let total):
                switch phase {
                case .decode:
                    if let done, let total { setState(.rendering(.decoding(done: done, total: total))) }
                    else { setState(.rendering(.working(since: since))) }
                case .pack:
                    let s = packSince ?? ctx.clock.now()
                    packSince = s
                    setState(.rendering(.packing(since: s)))
                case .fetching, nil:
                    setState(.rendering(.working(since: since)))
                }
            case .success(let r):
                try await finishRender(client, sid: sid, result: r)
                return
            case .failed(let code):
                throw mapFailure(code: code, during: .rendering, limits: ctx.capabilities.limits)
            }
        }
    }

    /// The webp joins the orbit (downloaded into the store) before `.done`.
    func finishRender(_ client: any CobaltClient, sid: String, result r: WebpResult) async throws {
        let linkURL: URL?
        if case .link(let info) = input { linkURL = info.url } else { linkURL = nil }
        let base = media.map { ($0.name as NSString).deletingPathExtension } ?? r.job
        do {
            // A render that was handed to a background run while its webp was coming in may already
            // have been stored by the first attempt: one entry per webp.
            let kept = ctx.store.videos.contains { $0.kind == .webp && $0.remoteURL == r.url && $0.sessionID == sid }
            if !kept {
                let dest = ctx.store.inboxURL(for: "\(r.job).webp")
                let file = try await client.download(.open(r.url), to: dest, progress: { _ in })
                let info = MediaInfo(name: "\(base).webp", duration: r.seconds, width: r.width, height: r.height, bytes: r.bytes, isImage: false)
                let clip = lastRenderRequest.map {
                    WebpClip(start: $0.start, length: $0.length, crop: $0.crop, quality: $0.quality, width: $0.width)
                }
                _ = try await ctx.store.add(
                    file: file, kind: .webp, media: info, sessionID: sid, link: linkURL, remoteURL: r.url, move: true,
                    mediaID: targetMediaID, clip: clip)
                syncStoreTitle()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as CobaltError where e == .cancelled || e == .network(.cancelled) {
            throw e
        } catch {
            // the orbit copy is a nicety; the hosted webp is what counts
            Telemetry.log(.warn, .store, "webp not kept on device", data: Telemetry.errorData(error))
        }
        try Task.checkCancellation()
        result = r
        renderJobID = nil
        setState(.done(r))
    }

    // MARK: - Photos and hosting

    func runSaveToPhotos() async {
        let token = runToken
        defer { ctx.continued?.pipelineChanged(self) }
        do {
            let (url, isTemp) = try await originalFile()
            guard token == runToken else { return }
            photosStep = .adding
            try await ctx.savePhoto(fileURL: url, isImage: media?.isImage ?? false, key: photosKey)
            if isTemp { try? FileManager.default.removeItem(at: url) }
            guard token == runToken else { return }        // a newer run owns `photos` now
            photosTick += 1
            photosStep = .idle
            photos = .done
        } catch {
            Telemetry.log(.error, .photos, "save to photos failed", data: Telemetry.errorData(error))
            guard token == runToken else { return }
            photosStep = .idle
            photos = pipelineFailure(from: error, during: .saving, limits: ctx.capabilities.limits).map(ActionStatus.failed) ?? .idle
        }
    }

    /// The local original, or a temporary download of the server's copy. The download reports its
    /// bytes through `photosStep`: a large file in the share sheet used to look like a button that
    /// did nothing.
    func originalFile() async throws -> (URL, Bool) {
        let fm = FileManager.default
        if let url = stored?.fileURL, fm.fileExists(atPath: url.path) { return (url, false) }
        if let url = localFile, fm.fileExists(atPath: url.path) { return (url, false) }
        guard let sid = sessionID else { throw PipelineFailure.server(code: "error.app.no_original") }
        photosStep = .downloading(keepProgress ?? TransferProgress(bytes: 0, total: media?.bytes))
        // The keep-on-device download is already bringing this very file: wait for it, never fetch twice.
        if let request = keepRequest, let video = await request.value, let url = video.fileURL, fm.fileExists(atPath: url.path) {
            return (url, false)
        }
        try Task.checkCancellation()
        let token = runToken
        let relay = MainActorRelay<TransferProgress> { [weak self] p in self?.keepDownloadProgress(p, token: token) }
        let name = ((media?.name ?? sid) as NSString).deletingPathExtension
        let file = try await ctx.client.download(
            .studioSource(session: sid), to: ctx.store.inboxURL(for: "\(name).mp4"), progress: { relay.push($0) })
        keepProgress = nil
        return (file, true)
    }

    /// The publish call, as a task of its own so `detach()` can hand it to a background run.
    func makeHostRequest() -> Task<HostedFile, Error> {
        let client = ctx.client
        if media?.isImage == true, let item = uploadedItemID {
            return Task { try await client.publish(item: item) }
        } else if let sid = sessionID, ctx.capabilities.studio {
            return Task { try await client.publish(session: sid) }
        } else {
            return Task { throw PipelineFailure.unsupported }
        }
    }

    func finishHostOriginal(_ request: Task<HostedFile, Error>) async {
        // Everything below happens after a network wait: by then the run may be gone (cancelled, or
        // replaced by a new link), and a stale run must not touch the new one's fields. The link is
        // never copied to the pasteboard here: the owner copies it explicitly (a background
        // completion must not write to the pasteboard).
        let token = runToken
        do {
            let hosted = try await request.value
            guard token == runToken, !Task.isCancelled else { return }
            hostRequest = nil
            hostedURL = hosted.url
            if media?.isImage != true, let sid = sessionID {
                ctx.store.setPublicURL(hosted.url, forSession: sid, orEntry: stored?.sessionID == sid ? stored?.id : nil)
                if let id = stored?.id, let fresh = ctx.store.videos.first(where: { $0.id == id }) { stored = fresh }
            }
            hosting = .done
        } catch {
            Telemetry.log(.error, .pipeline, "host original failed", data: Telemetry.errorData(error))
            guard token == runToken else { return }
            hostRequest = nil
            hosting = pipelineFailure(from: error, during: .saving, limits: ctx.capabilities.limits).map(ActionStatus.failed) ?? .idle
        }
    }

    // MARK: - Resume (share-sheet handoff, relaunch)

    func resumeJob(_ job: SharedJob) {
        let linkInfo = job.link.flatMap { LinkInfo($0) }
        begin(input: linkInfo.map { .link($0) })
        origin = job.origin
        if let title = job.pendingTitle {
            // The sheet's typed title: applied here (idempotent when the extension already sent it); the item
            // id is known from the interrupted upload, else from the session's `upload:<item id>` link.
            applyTitle(title)
            if let sid = job.sessionID { resolveTitleItem(session: sid) }
        }
        opensOnTrim = job.wantsTrim             // "trim in cobalt": the focus card opens on the trim timeline
        liveRunID = job.id                      // the share sheet's activity (or this app's own, after a relaunch) carries on
        sessionID = job.sessionID
        media = job.media
        if let t = job.trim { trim = t }
        if job.origin == .shareExtension {
            // The sheet may have asked the server to tell the owner when this finishes; the app has
            // it now, and the owner is looking.
            if let sid = job.sessionID, ctx.capabilities.notifyBridge || ctx.capabilities.kind == .unreachable {
                let client = ctx.client
                Task { try? await client.cancelNotify(session: sid) }
            }
            var taken = job
            taken.pickedUp = true
            taken.updatedAt = ctx.clock.now()
            ctx.jobs.upsert(taken)
            takenOverJobID = job.id             // removed once this run settles
        } else {
            jobRecordID = job.id                // an unfinished run of this app: keep its record current
            if case .saving = job.stage { recordJob(.saving) }
            if case .rendering(let renderJob) = job.stage { recordJob(.rendering(job: renderJob)) }
        }
        let limits = ctx.capabilities.limits
        switch job.stage {
        case .failed(let code):
            setState(.failed(mapFailure(code: code, during: .saving, limits: limits)))

        case .uploadInterrupted(let localFile):
            launch { p in
                let file = try p.ctx.intake.inspect(localFile)
                p.input = .file(name: file.name, bytes: file.bytes, contentType: file.contentType)
                try await p.runUpload(file)
            }

        case .saving:
            if let sid = job.sessionID {
                setState(.saving(bytes: nil, total: nil, since: runStart))
                launch { p in
                    let client = p.ctx.client
                    let s = try await p.pollSaving(client, id: sid)
                    let m = p.mediaInfo(s, fallbackName: linkInfo?.ref ?? sid)
                    // The sheet that started this save closed before it finished: the original still
                    // belongs on this phone (CONTRACT-SYNC.md, the second gap).
                    await p.ctx.store.reload()
                    p.adoptStoredOriginal(session: sid, link: linkInfo?.url)
                    if p.stored == nil { p.keepOriginalInBackground(client, session: sid, media: m) }
                    try await p.develop(m, from: p.sourceInput(session: sid, link: linkInfo?.url))
                }
            } else if let link = job.link {
                start(link: link)
            } else {
                setState(.failed(.server(code: "error.app.job_lost")))
            }

        case .ready:
            guard let sid = job.sessionID else { setState(.failed(.server(code: "error.app.job_lost"))); return }
            setState(.reading(developed: 0, of: Pipeline.frameCount))
            launch { p in
                // The extension may have stored the original after this process last read the store
                // (a warm app's index is stale): look again, so the trim plays a local file.
                await p.ctx.store.reload()
                let m = try await p.mediaForSession(sid, known: job.media)
                p.media = m
                p.adoptStoredOriginal(session: sid, link: linkInfo?.url)
                if p.stored == nil { p.keepOriginalInBackground(p.ctx.client, session: sid, media: m) }
                try await p.develop(m, from: p.sourceInput(session: sid, link: linkInfo?.url))
                if let t = job.trim, t.length > 0 { p.trim = t }
            }

        case .rendering(let jobID):
            guard let sid = job.sessionID else { setState(.failed(.server(code: "error.app.job_lost"))); return }
            renderJobID = jobID
            errorPhase = .rendering
            setState(.rendering(.working(since: job.updatedAt)))
            loadFramesInBackground(session: sid, known: job.media)
            launch { try await $0.runRender(sid, existingJob: jobID, since: job.updatedAt) }

        case .done(let r):
            result = r
            setState(.done(r))
            if let sid = job.sessionID { loadFramesInBackground(session: sid, known: job.media) }
        }
    }

    /// The work card needs the strip even when the run resumes past `.reading`.
    func loadFramesInBackground(session sid: String, known: MediaInfo?) {
        spawn { p in
            guard let m = try? await p.mediaForSession(sid, known: known) else { return }
            if p.media == nil || p.media?.duration == nil { p.media = m }
            let input = p.sourceInput(session: sid)
            do {
                for try await frame in p.ctx.tools.frames(of: input, duration: m.duration, count: Pipeline.frameCount, maxEdge: p.ctx.frameEdge) {
                    if frame.index >= 0, frame.index < p.frames.count, p.frames[frame.index] == nil { p.frames[frame.index] = frame }
                }
            } catch {}
        }
    }
}

extension Pipeline {
    /// Library "trim a new webp": reuse the post's open session, or reopen one from its private copy.
    func resumeFromLibrary(_ post: LibraryPost) {
        let linkInfo = post.link.flatMap { LinkInfo($0) }
        begin(input: linkInfo.map { .link($0) })
        let privateCopy = post.files.first { $0.role == .privateCopy }
        let m = MediaInfo(
            name: post.title ?? post.ref ?? post.id, duration: post.duration ?? privateCopy?.duration,
            width: post.width, height: post.height, bytes: privateCopy?.bytes, isImage: false)
        media = m
        titleItemID = post.files.first?.id
        let open = post.session.flatMap { $0.status == .ready && $0.expiresAt > ctx.clock.now() ? $0.id : nil }
        if open != nil {
            setState(.reading(developed: 0, of: Pipeline.frameCount))
        } else {
            setState(.fetching(since: runStart, waking: false))
        }
        launch { p in
            let sid: String
            if let open {
                sid = open
            } else if let item = privateCopy {
                sid = try await p.openStudioRetrying(p.ctx.client, link: nil, item: item.id).id
            } else {
                throw PipelineFailure.expired
            }
            p.sessionID = sid
            try await p.develop(m, from: p.sourceInput(session: sid, link: post.link), readyFirst: true)
        }
    }
}
