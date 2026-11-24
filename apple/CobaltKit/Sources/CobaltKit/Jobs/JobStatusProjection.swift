import Foundation

// The projections into `JobStatus` (apple 03-PHASE3 3.2): one per owner of work. None of them says a word; they say stages
// and numbers, and the app's `Copy` files say the words.
//
// Precedence (3.2, "client pipeline takes precedence over server-line duplicate for the same `sessionID`") is not decided
// here but in `ActivitySummary.build`, which sees every source at once: a pipeline beats a download beats a server row that
// carries the same `sessionID`.

// MARK: - Receipt

extension JobStatus.LocalCopyReceipt {
    /// The pipeline's `localCopyState` as a receipt. `.downloading` is `.inProgress`.
    public init(_ state: LocalCopyState) {
        switch state {
        case .notRequested: self = .notNeeded
        case .downloading: self = .inProgress
        case .savedOnDevice: self = .savedOnDevice
        case .failed(let code): self = .failed(code: code)
        }
    }
}

extension JobStatus {
    /// The jobs ahead of a place in line: `inLine(2)` ("2nd in line", the running one is 1st) has one ahead. Nil for a line
    /// that cannot say.
    static func ahead(of line: LinePosition) -> Int? {
        switch line {
        case .inLine(let place, _): return max(0, place - 1)
        case .serverBusy: return nil
        }
    }

    static func ratio(_ done: Int64?, _ total: Int64?) -> Double? {
        guard let done, let total, total > 0 else { return nil }
        return min(1, max(0, Double(done) / Double(total)))
    }

    static func ratio(_ done: Int?, _ total: Int?) -> Double? {
        guard let done, let total, total > 0 else { return nil }
        return min(1, max(0, Double(done) / Double(total)))
    }

    /// "x.com" for `https://www.x.com/...`.
    static func host(of url: URL?) -> String? {
        guard var host = url?.host(percentEncoded: false), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// `service · ref` for a link, nil when the link is not one the app reads.
    static func linkTitle(_ url: URL?) -> String? {
        guard let url, let info = LinkInfo(url) else { return nil }
        return MediaTitle.text(MediaTitle.resolve(custom: nil, service: info.service, ref: info.ref, fileName: nil))
    }
}

// MARK: - From a pipeline

extension JobStatus {
    /// A job of the queue. `nil` for a job whose pipeline is idle. `isFocused`: it is the job the focus screen shows.
    @MainActor
    public init?(job: Job, isFocused: Bool, now: Date) {
        self.init(
            pipeline: job.pipeline, ref: .pipeline(job.id), jobID: job.id, isFocused: isFocused, startedAt: job.addedAt,
            finishedAt: job.finishedAt, owned: true, isLive: job.isLive, now: now)
    }

    /// What one pipeline is doing now, read as a status without a queue job behind it (the focus card's progress words, the planet's
    /// edge): the same projection every surface reads, only that nothing can be done to it from here (`canFocus` and the other
    /// actions are false). `nil` for an idle pipeline.
    @MainActor
    public init?(pipeline p: Pipeline, now: Date) {
        self.init(
            pipeline: p, ref: .pipeline(p.liveRunID), jobID: p.liveRunID, isFocused: false, startedAt: p.runStart,
            finishedAt: nil, owned: false, isLive: true, now: now)
    }

    @MainActor
    init?(
        pipeline p: Pipeline, ref: Ref, jobID: UUID, isFocused: Bool, startedAt: Date, finishedAt: Date?, owned: Bool,
        isLive: Bool, now: Date
    ) {
        let state = p.state
        if case .idle = state { return nil }
        let receipt = LocalCopyReceipt(p.localCopyState)
        let line = p.line
        var kind: Kind = { if case .file? = p.input { return .upload } else { return .save } }()
        var stage: Stage
        var fraction: Double?
        var failedStep: JobStep.ID?
        var woke = false

        /// A finished job: the cloud has it; the copy on this device is its receipt.
        func finished(cloud: Bool) -> Stage {
            if case .downloading(let t) = p.localCopyState {
                fraction = JobStatus.ratio(t.bytes, t.total)
                return .deviceCopy(bytes: t.bytes, total: t.total)
            }
            if p.photos == .working {                       // "save to photos" fetching the original, then adding it
                if case .downloading(let t) = p.photosStep {
                    fraction = JobStatus.ratio(t.bytes, t.total)
                    return .deviceCopy(bytes: t.bytes, total: t.total)
                }
                return .deviceCopy(bytes: nil, total: nil)
            }
            fraction = 1
            return .completed(cloudSaved: cloud, deviceCopy: receipt)
        }

        switch state {
        case .idle:
            return nil
        case .fetching(_, let waking):
            if let line {
                stage = .queued(ahead: Self.ahead(of: line))
            } else if waking {
                stage = .waking(engine: p.saveStatus.wakingEngine)
                woke = true
            } else {
                stage = .fetching(engine: p.saveStatus.engine, fallbackFrom: p.saveStatus.fallbackFrom)
            }
        case .uploading(let t):
            if let line {
                stage = .queued(ahead: Self.ahead(of: line))
            } else {
                stage = .downloading(bytes: t.bytes, total: t.total)
                fraction = Self.ratio(t.bytes, t.total)
            }
        case .saving(let bytes, let total, _):
            if let line {
                stage = .queued(ahead: Self.ahead(of: line))
            } else if p.saveStatus.phase == .downloading, kind != .upload {
                stage = .downloading(bytes: bytes, total: total)
                fraction = Self.ratio(bytes, total)
            } else {
                stage = .storing(bytes: bytes, total: total)
                fraction = Self.ratio(bytes, total)
            }
        case .reading(let developed, let of):
            stage = .readingFrames(done: developed, total: of)
            fraction = Self.ratio(developed, of)
        case .picker:
            stage = .awaitingChoice
        case .gallery:
            kind = .gallery
            let g = Self.galleryStage(p, line: line, finished: finished)
            stage = g.stage
            fraction = g.fraction ?? fraction
            failedStep = g.failedStep
            woke = p.galleryRun?.waking == true
        case .image:
            stage = finished(cloud: true)
        case .ready:
            stage = finished(cloud: true)
        case .rendering(let progress):
            kind = .webpRender
            if let line {
                stage = .queued(ahead: Self.ahead(of: line))
            } else {
                switch progress {
                case .decoding(let done, let total):
                    stage = .rendering(phase: .decode, done: done, total: total)
                    fraction = Self.ratio(done, total)
                case .packing:
                    stage = .rendering(phase: .pack, done: nil, total: nil)
                case .working:
                    stage = .rendering(phase: nil, done: nil, total: nil)
                }
            }
        case .done:
            kind = .webpRender
            stage = finished(cloud: true)
        case .savedLocally:
            stage = finished(cloud: false)
        case .failed(let failure):
            stage = .failed(failure: failure, retryable: failure.isRetryable)
            if failure.keepsTrim || p.saveStatus.phase == .storing { failedStep = .store }
        }

        // what the owner may do with it
        var retry = false
        switch stage {
        case .failed(_, let retryable): retry = retryable
        case .completed(_, .failed): retry = p.localCopyJob != nil
        default: break
        }
        if case .gallery = state, let run = p.galleryRun {
            if case .failed = run.phase { retry = true }
            if case .failed = run.make { retry = true }
        }

        self.init(
            id: "job:\(jobID.uuidString)", ref: ref, kind: kind, title: Self.title(of: p),
            sourceHost: { if case .link(let info)? = p.input { return Self.host(of: info.url) } else { return nil } }(),
            sessionID: p.sessionID, serverJobID: p.renderJobID ?? p.makeJobID, mediaID: p.mediaID, stage: stage, fraction: fraction, startedAt: startedAt,
            updatedAt: finishedAt ?? now, engine: p.saveStatus.engine, fallbackFrom: p.saveStatus.fallbackFrom,
            woke: woke, failedStep: failedStep, remote: nil, isFocused: isFocused, canFocus: owned,
            canCancel: owned && isLive, canRetry: owned && retry, canDismiss: owned && !isLive)
    }

    /// The tray's title: what the owner typed, else `service · ref`, else the file's name (`MediaTitle`, CONTRACT-LIBRARY2).
    @MainActor
    static func title(of p: Pipeline) -> String {
        var service: String?
        var ref: String?
        var fileName: String?
        let local: StoredVideo? = p.stored ?? { if case .savedLocally(let v) = p.state { return v } else { return nil } }()
        if case .link(let info)? = p.input {
            service = info.service
            ref = info.ref
        } else {
            var picked: String?
            if case .file(let name, _, _)? = p.input { picked = name }
            fileName = p.media?.name ?? local?.name ?? picked
        }
        return MediaTitle.text(MediaTitle.resolve(custom: p.runTitle ?? local?.title, service: service, ref: ref, fileName: fileName))
    }

    /// A gallery run: the save's item count, then (once saved) the make that was asked of it.
    @MainActor
    private static func galleryStage(
        _ p: Pipeline, line: LinePosition?, finished: (Bool) -> Stage
    ) -> (stage: Stage, fraction: Double?, failedStep: JobStep.ID?) {
        guard let run = p.galleryRun else { return (finished(true), nil, nil) }
        if let line, run.phase == .saving || run.make.isActive {
            return (.queued(ahead: ahead(of: line)), nil, nil)
        }
        switch run.phase {
        case .saving:
            let stage = Stage.galleryProgress(done: run.done, total: run.total, currentBytes: nil, currentTotal: nil)
            return (stage, ratio(run.done, run.total), nil)
        case .failed(let failure):
            return (.failed(failure: failure, retryable: failure.isRetryable), nil, nil)
        case .saved:
            switch run.make {
            case .none, .done:
                return (finished(true), nil, nil)
            case .waiting, .sending:
                return (.queued(ahead: nil), nil, nil)
            case .queued(_, let ahead):
                return (.queued(ahead: max(0, ahead)), nil, nil)
            case .making(_, let progress):
                let phase: RenderPhase?
                switch progress.phase {
                case .queued?: phase = .queued
                case .uploading?: phase = .fetching
                case .composing?: phase = .decode
                case .encoding?: phase = .pack
                case nil: phase = nil
                }
                return (.rendering(phase: phase, done: progress.done, total: progress.total), progress.fraction, nil)
            case .failed(_, let failure):
                return (.failed(failure: failure, retryable: failure.isRetryable), nil, .store)
            }
        }
    }
}

// MARK: - From a download onto this device

extension JobStatus {
    /// A row of `OfflineDownloads` ("keep offline", a pulled save, a pipeline's own original, a share-prep copy).
    /// A key `s:<session>` names the session, so a pipeline of that session is not counted twice.
    public init(download row: OfflineDownloadRow, now: Date) {
        let stage: Stage
        var fraction: Double?
        var retry = false
        var cancel = false
        switch row.state {
        case .downloading(let t):
            let total = t.total ?? row.expectedBytes
            stage = .deviceCopy(bytes: t.bytes, total: total)
            fraction = Self.ratio(t.bytes, total)
            cancel = true
        case .failed(let failure):
            let why = Self.failure(of: failure)
            stage = .failed(failure: why, retryable: why.isRetryable)
            retry = why.isRetryable
        default:                                               // waiting (no network, or behind the two connections)
            stage = .queued(ahead: nil)
            cancel = true
        }
        self.init(
            id: "download:\(row.id)", ref: .download(key: row.id), kind: .deviceDownload, title: row.name,
            sessionID: row.id.hasPrefix("s:") ? String(row.id.dropFirst(2)) : nil, stage: stage, fraction: fraction,
            startedAt: row.queuedAt, updatedAt: now, canCancel: cancel, canRetry: retry, canDismiss: row.isFailed)
    }

    /// A download's failure as the one failure type every surface words.
    static func failure(of failure: OfflineFailure) -> PipelineFailure {
        switch failure {
        case .gone: return .expired
        case .unreachable: return .unreachable
        case .auth: return .keyInvalid
        case .full, .other: return .server(code: Pipeline.localCopyCode(failure))
        }
    }

    /// The photos album adding saves (`PhotosSync.Status.progress`): one status while it adds.
    public init?(photos progress: PhotosSync.Progress?, now: Date) {
        guard let progress, progress.total > 0 else { return nil }
        self.init(
            id: "photos", ref: .photosAlbum, kind: .photosExport, stage: .deviceCopy(bytes: nil, total: nil),
            fraction: Self.ratio(progress.done, progress.total), startedAt: now, updatedAt: now)
    }
}

// MARK: - From the server

extension JobStatus {
    /// One entry of the server's line (`GET /queue`) that no pipeline of this app follows. `nil` for the line's posters (not
    /// work the owner started). `id` is the row's `QueueItem.id`.
    public init?(server work: ServerWork, id: String, at snapshot: Date) {
        let kind: Kind
        switch work.kind {
        case "save": kind = .save
        case "render", "webp": kind = .webpRender
        default: return nil
        }
        let stage: Stage
        if work.running {
            stage = kind == .save ? .fetching(engine: nil, fallbackFrom: nil) : .rendering(phase: nil, done: nil, total: nil)
        } else {
            stage = .queued(ahead: max(0, (work.position ?? 2) - 1))
        }
        let own = work.mine && !work.isShare
        self.init(
            id: id, ref: .server(id: id), kind: kind, title: Self.linkTitle(work.link) ?? "", sourceHost: Self.host(of: work.link),
            sessionID: work.sid, serverJobID: work.job, stage: stage, startedAt: snapshot, updatedAt: snapshot,
            remote: own ? nil : Remote(keyName: work.keyName, fromShare: work.isShare),
            canCancel: work.mine && work.sid != nil && !work.running)
    }

    /// A render of the video editor (own or another device's). `nil` for a cancelled one.
    public init?(edit r: EditRender, now: Date) {
        let stage: Stage
        var fraction = r.progress
        var retry = false
        var dismiss = false
        switch r.status {
        case .queued:
            stage = .queued(ahead: r.queueAhead)
            fraction = nil
        case .preparing:
            stage = .rendering(phase: .fetching, done: nil, total: nil)
        case .rendering:
            stage = .rendering(phase: .decode, done: r.secondsDone.map { Int($0.rounded(.down)) }, total: Int(r.secondsTotal.rounded(.up)))
        case .finishing:
            stage = .rendering(phase: .pack, done: nil, total: nil)
        case .done:
            stage = .completed(cloudSaved: true, deviceCopy: .notNeeded)
            fraction = 1
            dismiss = true
        case .error:
            stage = .failed(failure: .server(code: r.error ?? "error.edit.render_failed"), retryable: !r.isProjectless)
            fraction = nil
            retry = !r.isProjectless
            dismiss = true
        case .cancelled:
            return nil
        }
        self.init(
            id: "edit:\(r.id)", ref: .editRender(id: r.id), kind: .editorRender, title: r.title,
            mediaID: r.itemID.map { "post:\($0)" }, stage: stage, fraction: fraction, startedAt: r.startedAt ?? r.createdAt,
            updatedAt: r.finishedAt ?? now, failedStep: .store, canFocus: !r.isProjectless,
            canCancel: r.isActive && !r.cancelRequested, canRetry: retry, canDismiss: dismiss)
    }

    /// A job that finished and left the queue (`UnifiedQueue.finishedHistory`). The receipt is what is known: a stored media
    /// means the original is on this device.
    public init(finished work: FinishedWork) {
        let isWebp: Bool = { if case .webp = work.outcome { return true } else { return false } }()
        self.init(
            id: "finished:\(work.id.uuidString)", ref: .finished(work.id), kind: isWebp ? .webpRender : .save, title: work.title,
            mediaID: work.mediaID, stage: .completed(cloudSaved: true, deviceCopy: work.mediaID == nil ? .notNeeded : .savedOnDevice),
            fraction: 1, startedAt: work.finishedAt, updatedAt: work.finishedAt, canDismiss: true)
    }
}
