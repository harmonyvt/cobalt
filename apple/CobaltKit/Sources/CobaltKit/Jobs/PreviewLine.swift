import Foundation

// The preview "server"'s line (APP-API-CONTRACT section 17) and the preview modes that use it. Everything runs on
// the pipeline's clock: a job starts at the moment the one before it ended, whoever is polling, so a test on a
// virtual clock sees the same order a real server would produce.

/// How the preview server of `AppModel.previewLine(_:)` holds the line.
public enum LinePreviewMode: Sendable, Equatable {
    /// A server without `features.line` (every other preview): a busy helper answers `429`.
    case off
    /// `features.line`; the line starts empty. A save or render sent with `queue: true` starts at once or waits.
    case server
    /// `features.line`, and a share from the "iphone" key runs first for 15 s: everything the app queues is behind it.
    case serverBusyWithShare
    /// `features.line` and the line is full: a queued create answers `429 error.studio.line_full`.
    case serverFull
    /// No `features.line`, and the helper is held by a save the app does not know for `seconds` (a share from another
    /// device): every create and render answers `429 busy` until then. The device line (`LocalLine`) has to wait it out.
    case deviceBusy(seconds: Double)

    var hasLine: Bool {
        switch self {
        case .server, .serverBusyWithShare, .serverFull: return true
        case .off, .deviceBusy: return false
        }
    }
}

extension PreviewData {
    /// The post of the boards' "Dd55fEyN1Yy fails": the preview server cannot save it (a private post).
    static let privateRef = "Dd55fEyN1Yy"
}

/// What the preview server remembers about its line.
struct PreviewLineState: Sendable {
    struct Spec: Sendable {
        enum Kind: Sendable { case save, render }
        var kind: Kind
        var sid: String
        var job: String?
        var focused: Bool
        var duration: Double                          // seconds the job holds the helper
        var mine: Bool
        var origin: String?
        var keyName: String?
        var link: URL?
        var failure: String?                          // the save ends with this code when its turn has run
    }

    struct Entry: Sendable {
        var spec: Spec
        var seq: Int
        var enqueuedAt: Date
        var started: Date?
        var ended: Date?
        var cancelled = false

        var kind: Spec.Kind { spec.kind }
        var failure: String? { spec.failure }
        /// Focused renders first, then everything else first in first out (17.2).
        var order: (Int, Int) { (spec.focused ? 0 : 1, seq) }
    }

    var entries: [Entry] = []
    var seq = 0
    /// When the helper is next free (the end of the last job started).
    var freeAt = Date.distantPast
    var lastNow = Date.distantPast
    var foreignUntil: Date?
    var calls: [String] = []
    var cancelledIDs: Set<String> = []
    var failReads = false
    var failCancel = false
    var titles: [String: String] = [:]

    // MARK: Seeds

    mutating func seed(mode: LinePreviewMode, at now: Date, timeScale: Double) {
        lastNow = now
        switch mode {
        case .serverBusyWithShare:
            _ = enqueue(
                Spec(kind: .save, sid: "PrEvIeWforeignshare00000", job: nil, focused: false, duration: 15 * timeScale,
                     mine: false, origin: "share", keyName: "iphone", link: nil, failure: nil), at: now)
        case .deviceBusy(let seconds):
            foreignUntil = now.addingTimeInterval(seconds * timeScale)
        case .off, .server, .serverFull:
            break
        }
    }

    // MARK: The pump

    /// Every job whose turn has come has started (at the moment the one before it ended), up to `now`.
    mutating func pump(now: Date) {
        lastNow = max(lastNow, now)
        while freeAt <= now,
              let next = entries.indices.filter({ entries[$0].started == nil && !entries[$0].cancelled })
                  .min(by: { entries[$0].order < entries[$1].order }) {
            let start = max(freeAt, entries[next].enqueuedAt)
            entries[next].started = start
            entries[next].ended = start.addingTimeInterval(entries[next].spec.duration)
            freeAt = entries[next].ended ?? freeAt
        }
    }

    private func isRunning(_ e: Entry) -> Bool {
        guard let started = e.started, let ended = e.ended else { return false }
        return started <= lastNow && ended > lastNow
    }

    var running: Entry? { entries.first(where: isRunning) }
    private var waiting: [Entry] {
        entries.filter { $0.started == nil && !$0.cancelled }.sorted { $0.order < $1.order }
    }

    /// The helper is held, or something waits (an old client's create is refused either way, 17.1).
    var isBusy: Bool { running != nil || !waiting.isEmpty }

    func foreignBusy(at now: Date) -> Bool { foreignUntil.map { now < $0 } ?? false }

    // MARK: Joining, reading, cancelling

    /// Adds a job. It starts at once when the helper is free and nothing waits (17.3), else it waits.
    mutating func enqueue(_ spec: Spec, at now: Date) -> (queued: Bool, ahead: Int) {
        pump(now: now)
        seq += 1
        entries.append(Entry(spec: spec, seq: seq, enqueuedAt: now))
        pump(now: now)
        let entry = entries[entries.count - 1]
        if entry.started != nil { return (false, 0) }
        return (true, ahead(of: entry))
    }

    func entry(sid: String, job: String?) -> Entry? {
        entries.last { $0.spec.sid == sid && $0.spec.job == job }
    }

    /// `queue_ahead`: the jobs that run before `entry`, the running one included.
    func ahead(of entry: Entry) -> Int {
        let before = waiting.filter { $0.order < entry.order }.count
        return (running != nil ? 1 : 0) + before
    }

    /// nil: unknown; true: cancelled (or already was); false: its turn came first (409).
    mutating func cancel(sid: String, job: String?) -> Bool? {
        guard let i = entries.lastIndex(where: { $0.spec.sid == sid && $0.spec.job == job }) else { return nil }
        if entries[i].cancelled { return true }
        if entries[i].started != nil { return false }
        entries[i].cancelled = true
        return true
    }

    /// What `PUT /studio/line/notify` would watch: the caller's jobs that have not finished.
    var watching: Int {
        entries.filter { $0.spec.mine && !$0.cancelled && ($0.ended ?? .distantFuture) > lastNow }.count
    }

    func snapshot(now: Date) -> ServerLineSnapshot {
        let live = running
        func wireKind(_ k: Spec.Kind) -> String { k == .save ? "save" : "render" }
        let runningWire = live.map {
            ServerLineSnapshot.Running(
                kind: wireKind($0.kind), mine: $0.spec.mine, sid: $0.spec.mine ? $0.spec.sid : nil,
                job: $0.spec.mine ? $0.spec.job : nil, origin: $0.spec.origin, keyName: $0.spec.keyName)
        }
        let base = live == nil ? 0 : 1
        let rows = waiting.enumerated().map { index, e in
            ServerLineSnapshot.Entry(
                position: base + index + 1, kind: wireKind(e.kind), mine: e.spec.mine,
                sid: e.spec.mine ? e.spec.sid : nil, job: e.spec.mine ? e.spec.job : nil, origin: e.spec.origin,
                priority: e.spec.focused ? "focused" : nil, keyName: e.spec.keyName,
                link: e.spec.mine && e.kind == .save ? e.spec.link?.absoluteString : nil)
        }
        return ServerLineSnapshot(running: runningWire, entries: rows, max: 50, waitMs: 1_800_000)
    }
}

extension AppModel {
    /// Every screen and test of the parallel work previews against this: a server with (or, for `.deviceBusy`, without)
    /// `features.line`, the boards' clip, a line that starts empty or behind a share, and the line's routes working.
    public static func previewLine(_ mode: LinePreviewMode = .server) -> AppModel {
        makePreviewLine(mode, timeScale: 1, clock: SystemClock())
    }

    static func makePreviewLine(_ mode: LinePreviewMode, timeScale: Double, clock: any PipelineClock) -> AppModel {
        let ctx = PipelineContext.preview(.happy, timeScale: timeScale, clock: clock)
        let client = PreviewClient(scenario: .happy, timeScale: timeScale, clock: clock, line: mode)
        ctx.client = client
        var caps = ctx.capabilities
        caps.line = mode.hasLine
        ctx.capabilities = caps
        return AppModel(
            context: ctx, library: LibraryModel(context: ctx, seed: PreviewData.libraryPage(now: clock.now())),
            photosSync: PhotosSync.preview(.init(access: .album, enabled: false)),
            makeClient: { _ in client })
    }
}
