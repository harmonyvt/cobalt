import Foundation

/// What the queue tab's previews show (`AppModel.previewQueue(_:)`). `.off` is every other preview: a server without
/// `features.queue`.
public enum QueuePreviewState: Sendable, Equatable, CaseIterable {
    /// No `features.queue` and nothing to show from the server.
    case off
    /// `features.queue`; a share from the "iphone" key runs on the server, two links of this app's wait behind it, a
    /// "keep offline" download is at 40 % and another failed, the photos album is adding 3 of 7, and the search index
    /// has 252 of 284 posts to go.
    case busy
    /// `features.queue`; nothing is happening anywhere: the empty state.
    case quiet
    /// A server without `features.queue`: only this device's work (two links, the downloads, the photos album).
    case localOnly

    /// The server answers `GET /queue`.
    var hasRoute: Bool { self == .busy || self == .quiet }
}

extension PreviewData {
    /// The preview library's posts, as the index would name the ones it takes next.
    static let queueTitles = [
        "x · 2105435404002562056", "instagram · Dd5JFkMDt4N", "instagram · Dd7RFsmT45H", "x · 2105358343657427103",
        "the harbour before the wind", "x · 2105432512428445875", "instagram · Dd55fEyN1Yy",
    ]

    /// The line of a `GET /queue` answer when the preview server holds no line of its own: one save from the "mac" key.
    static let queueLine = ServerLineSnapshot(
        running: .init(kind: "save", mine: false, origin: nil, keyName: "mac"), entries: [], max: 50, waitMs: 1_800_000)

    /// `GET /queue` for `state`: the index (284 posts, 32 indexed when the client was made, then one more every
    /// 20 s × `timeScale`, 180 an hour) and `line`.
    static func queueSnapshot(
        _ state: QueuePreviewState, now: Date, since start: Date, timeScale: Double, line: ServerLineSnapshot
    ) -> QueueSnapshot {
        if state == .quiet {
            return QueueSnapshot(
                now: now, line: ServerLineSnapshot(),
                search: .init(enabled: true, posts: 284, indexed: 284, pending: 0, failed: 0, running: false,
                              lastRunAt: now.addingTimeInterval(-600), ratePerHour: nil, next: []),
                posters: .init(pending: 0))
        }
        let posts = 284
        let step = 20 * max(0.01, timeScale)
        let indexed = min(posts, 32 + Int(max(0, now.timeIntervalSince(start)) / step))
        let pending = posts - indexed
        let next = (0..<min(3, pending)).map { i -> QueueSnapshot.Search.Next in
            let title = queueTitles[(indexed + i) % queueTitles.count]
            return .init(postKey: "PrEvIeWpost\(String(format: "%04d", indexed + i))", title: title)
        }
        return QueueSnapshot(
            now: now, line: line,
            search: .init(enabled: true, posts: posts, indexed: indexed, pending: pending, failed: 0, running: pending > 0,
                          lastRunAt: now.addingTimeInterval(-40), ratePerHour: 180, next: next),
            posters: .init(pending: 0))
    }
}

extension AppModel {
    /// The queue tab against `state` (see `QueuePreviewState`), nothing on the network.
    public static func previewQueue(_ state: QueuePreviewState = .busy) -> AppModel {
        makePreviewQueue(state, timeScale: 1, clock: SystemClock())
    }

    static func makePreviewQueue(_ state: QueuePreviewState, timeScale: Double, clock: any PipelineClock) -> AppModel {
        let line: LinePreviewMode = state == .busy ? .serverBusyWithShare : (state == .quiet ? .server : .off)
        let ctx = PipelineContext.preview(.happy, timeScale: timeScale, clock: clock)
        let client = PreviewClient(scenario: .happy, timeScale: timeScale, clock: clock, line: line, queue: state)
        ctx.client = client
        var caps = ctx.capabilities
        caps.line = line.hasLine
        caps.queue = state.hasRoute
        ctx.capabilities = caps
        let busy = state == .busy || state == .localOnly
        let model = AppModel(
            context: ctx, library: LibraryModel(context: ctx, seed: PreviewData.libraryPage(now: clock.now())),
            photosSync: PhotosSync.preview(.init(
                access: .album, enabled: true, added: busy ? 3 : 7, waiting: busy ? 4 : 0,
                progress: busy ? .init(done: 3, total: 7) : nil)),
            makeClient: { _ in client })
        guard busy else { return model }
        model.queue.trayIsShown = true
        let links = ["Dd8RkQ2xLpe", "De1Hj4tYm0Z"].map { URL(string: "https://www.instagram.com/reel/\($0)/")! }
        model.queue.add(links.map { .link($0) }, via: .review)
        model.seedOfflinePreviewStates()
        let now = clock.now()
        model.unifiedQueue.seedPreview(finished: [
            FinishedWork(
                id: UUID(), title: "instagram · Dd7P496wolG",
                outcome: .webp(WebpResult(job: "PrEvIeWjob00000001", url: PreviewData.mediaBase.appendingPathComponent("PrEvIeW001.webp"),
                                          bytes: 4_500_000, width: 480, height: 854, seconds: 10.1)),
                finishedAt: now.addingTimeInterval(-240)),
            FinishedWork(id: UUID(), title: "x · 2105435404002562056", outcome: .saved, finishedAt: now.addingTimeInterval(-900)),
        ])
        return model
    }
}

extension UnifiedQueue {
    /// Previews only: finished lines as if those jobs had left the queue a while ago.
    func seedPreview(finished: [FinishedWork]) {
        for work in finished.sorted(by: { $0.finishedAt < $1.finishedAt }) {
            finishedHistory.removeAll { $0.id == work.id }
            finishedHistory.insert(work, at: 0)
        }
    }
}
