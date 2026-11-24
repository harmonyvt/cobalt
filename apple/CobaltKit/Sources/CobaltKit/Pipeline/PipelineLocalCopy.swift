import Foundation

// The copy of a run's file on this device (apple 02-PHASE2 2.2.4). The server's copy is what a run is about; the device's
// copy is a nicety that can fail (a full disk, a lost connection, a revoked key). It never fails the run, and it never
// reads as "saved" when it was not: `localCopyState` says where it stands and `retryLocalCopy()` tries again.

/// What the keep-original download came to: the stored original, or why there is none (both nil: cancelled).
struct KeptOriginal: Sendable {
    var video: StoredVideo?
    /// An `error.app.*` / `http.*` code, or an `error.api.*` code of the server.
    var failure: String?
    /// The queue still has it (the wait for it ran out): it lands on its own, this run stops following.
    var stillQueued = false

    init(video: StoredVideo? = nil, failure: String? = nil, stillQueued: Bool = false) {
        self.video = video
        self.failure = failure
        self.stillQueued = stillQueued
    }
}

extension Pipeline {
    /// How long a run follows an offline-queue download that is only waiting (no network): then it lets go, and the queue
    /// lands the file on its own. Without a bound a job whose phone is offline would never be let go.
    static let queuedFollowSeconds: Double = 600
    static let queuePollSeconds: Double = 0.5

    /// "keep videos on device": the original is fetched in the background and never blocks `.ready`.
    ///
    /// With the app's offline engine (`ctx.offlineDownloads`) it is queued there, as a background `URLSession` transfer
    /// that survives the app leaving the screen, with byte progress, failure tracking and retry; this run follows the
    /// entry. Without one (the share sheet, previews, tests) it is fetched here in the foreground. Either way the request is
    /// its own task (not the side task's), so `detach()` can hand it to a background run and it still lands in the store.
    ///
    /// `force`: a retry; the "the sheet already has it" check does not apply.
    func keepOriginalInBackground(_ client: any CobaltClient, session id: String, media m: MediaInfo, force: Bool = false) {
        guard ctx.settings.keepVideosOnDevice, !ctx.isPreview else { return }
        // The sheet already handed this original to a background download (or the app's own is going):
        // a second copy would only race it (CONTRACT-SYNC.md decision 6).
        if !force, ctx.originals?.pending.isLive(session: id) == true { return }
        let linkURL: URL?
        if case .link(let info) = input { linkURL = info.url } else { linkURL = nil }
        let store = ctx.store
        let clock = ctx.clock
        let token = runToken
        let target = targetMediaID
        let relay = MainActorRelay<TransferProgress> { [weak self] p in self?.keepDownloadProgress(p, token: token) }
        localCopyJob = .original(session: id, media: m)
        localCopyState = .downloading(TransferProgress(bytes: 0, total: m.bytes))
        let request: Task<KeptOriginal, Never>
        if let downloads = ctx.offlineDownloads {
            let job = Self.originalJob(session: id, media: m, link: linkURL, mediaID: target, now: clock.now())
            downloads.enqueue([job])
            request = Task {
                await Self.followOfflineOriginal(
                    downloads, store: store, clock: clock, key: job.key, session: id, progress: { relay.push($0) })
            }
        } else {
            request = Task {
                await Self.fetchOriginal(client, store: store, session: id, media: m, link: linkURL, mediaID: target, relay: relay)
            }
        }
        keepRequest = request
        ctx.continued?.pipelineChanged(self)
        spawn { p in await p.finishKeepOriginal(request, session: id) }
    }

    /// The original arrived (or did not). The run may have been replaced while the file was moving
    /// in: it keeps its own `stored`, and the entry stays in the store.
    func finishKeepOriginal(_ request: Task<KeptOriginal, Never>, session id: String) async {
        let token = runToken
        let kept = await request.value
        guard token == runToken else { return }
        keepRequest = nil
        keepProgress = nil
        defer { ctx.continued?.pipelineChanged(self) }
        guard let video = kept.video else {
            if let code = kept.failure {
                Telemetry.log(.warn, .store, "original not kept on device", data: [
                    "session": .string(String(id.prefix(8))), "code": .string(code)])
                localCopyState = .failed(code: code)
            } else if kept.stillQueued {
                localCopyState = .downloading(TransferProgress(bytes: 0, total: media?.bytes))
            } else {
                localCopyState = .notRequested                               // cancelled: nothing failed
            }
            return
        }
        localCopyState = .savedOnDevice
        localCopyJob = nil
        // "public share" finished before the original landed: the entry takes the link now.
        if let url = hostedURL { ctx.store.setPublicURL(url, forSession: id, orEntry: video.id) }
        stored = ctx.store.videos.first { $0.id == video.id } ?? video
        pinStored(video.id)
        syncStoreTitle()                            // the title typed before the original landed
    }

    /// "retry" on a device copy that failed: the original is fetched again, or the webp. Nothing happens when the copy did not
    /// fail or there is nothing to fetch again (an upload's own file).
    public func retryLocalCopy() {
        guard case .failed = localCopyState, let job = localCopyJob else { return }
        let client = ctx.client
        switch job {
        case .original(let sid, let m):
            keepOriginalInBackground(client, session: sid, media: m, force: true)
        case .webp(let sid, let r):
            let token = runToken
            localCopyState = .downloading(TransferProgress(bytes: 0, total: r.bytes))
            spawn { p in
                do {
                    try await p.storeWebpCopy(client, sid: sid, result: r)
                    guard token == p.runToken else { return }
                    p.localCopyState = .savedOnDevice
                    p.localCopyJob = nil
                } catch is CancellationError {
                    return
                } catch {
                    guard token == p.runToken else { return }
                    let code = Pipeline.localCopyCode(error)
                    Telemetry.log(.warn, .store, "webp not kept on device", data: Telemetry.errorData(error).merging(["copy": .string(code)]) { a, _ in a })
                    p.localCopyState = .failed(code: code)
                }
            }
        }
    }

    /// The copy failed and a retry has something to fetch again (the button is offered only then).
    public var canRetryLocalCopy: Bool {
        if case .failed = localCopyState { return localCopyJob != nil }
        return false
    }

    // MARK: - The two ways the original comes

    /// The pipeline's original as a job of the offline engine: the studio session's source, landing as this run's original
    /// (`AddOrigin.save`, so the photos album copies it like any save made here).
    static func originalJob(session id: String, media m: MediaInfo, link: URL?, mediaID: String?, now: Date) -> OfflineJob {
        let record = OfflineJob.NewRecord(
            kind: .original, media: m, sessionID: id, link: link, remoteURL: nil, publicURL: nil, createdAt: now,
            title: nil, mediaID: mediaID)
        var job = OfflineJob(
            key: "s:\(id)", aliases: ["s:\(id)"], target: .new(record), sources: [.studioSource(session: id)],
            expectedBytes: m.bytes, fileName: "\(m.name).mp4")
        job.origin = OfflineDownloads.saveOrigin
        return job
    }

    /// Follows one entry of the offline engine until it lands (the store has the original), fails (why), or is gone.
    @MainActor
    static func followOfflineOriginal(
        _ downloads: OfflineDownloads, store: OfflineStore, clock: any PipelineClock, key: String, session id: String,
        progress: @escaping @MainActor (TransferProgress) -> Void
    ) async -> KeptOriginal {
        var waitingSince: Date?
        while !Task.isCancelled {
            if let state = downloads.states[key] {
                switch state {
                case .failed(let failure):
                    return KeptOriginal(failure: Pipeline.localCopyCode(failure))
                case .downloading(let p):
                    progress(p)
                    waitingSince = nil
                case .waiting, .none:
                    waitingSince = waitingSince ?? clock.now()
                    if let since = waitingSince, clock.now().timeIntervalSince(since) > queuedFollowSeconds {
                        return KeptOriginal(stillQueued: true)
                    }
                default:
                    break
                }
            } else {
                // out of the queue: it landed (the store has it) or the owner stopped it
                if let video = store.videos.first(where: { $0.kind == .original && $0.sessionID == id }) { return KeptOriginal(video: video) }
                return KeptOriginal()
            }
            do { try await clock.sleep(seconds: queuePollSeconds) } catch { return KeptOriginal() }
        }
        return KeptOriginal()
    }

    /// No offline engine: the original is fetched here, in the foreground, and stored.
    @MainActor
    static func fetchOriginal(
        _ client: any CobaltClient, store: OfflineStore, session id: String, media m: MediaInfo, link: URL?, mediaID: String?,
        relay: MainActorRelay<TransferProgress>
    ) async -> KeptOriginal {
        let dest = store.inboxURL(for: "\(m.name).mp4")
        let file: URL
        do {
            file = try await client.download(.studioSource(session: id), to: dest, progress: { relay.push($0) })
        } catch {
            if Task.isCancelled || error is CancellationError { return KeptOriginal() }
            if let e = error as? CobaltError, e == .cancelled || e == .network(.cancelled) { return KeptOriginal() }
            return KeptOriginal(failure: Pipeline.localCopyCode(error))
        }
        guard !Task.isCancelled else {
            try? FileManager.default.removeItem(at: file)
            return KeptOriginal()
        }
        do {
            let video = try await store.add(
                file: file, kind: .original, media: m, sessionID: id, link: link, remoteURL: nil, move: true,
                mediaID: mediaID, keep: true)
            return KeptOriginal(video: video)
        } catch {
            return KeptOriginal(failure: Pipeline.localCopyCode(error))
        }
    }

    // MARK: - Codes

    /// The code a failed device copy goes by (`Copy.localCopyFailure` words it): the server's own code, `http.<status>`, or an
    /// `error.app.*` one.
    public nonisolated static func localCopyCode(_ error: Error) -> String {
        if OfflineSources.isDiskFull(error) { return "error.app.disk_full" }
        switch error {
        case let e as CobaltError:
            switch e {
            case .api(let code, _): return code
            case .invalidResponse(let status): return "http.\(status)"
            case .network: return "error.app.offline"
            case .noAPIKey: return "error.api.auth.key.missing"
            case .tooLarge: return "error.studio.too_large"
            case .cancelled: return "error.app.cancelled"
            }
        case is URLError:
            return "error.app.offline"
        default:
            return "error.app.local_copy_failed"
        }
    }

    /// The code of an offline-queue failure.
    nonisolated static func localCopyCode(_ failure: OfflineFailure) -> String {
        switch failure {
        case .gone: return "error.studio.expired"
        case .unreachable: return "error.app.offline"
        case .auth: return "error.api.auth.key.invalid"
        case .full: return "error.app.disk_full"
        case .other(let status): return "http.\(status)"
        }
    }
}
