import Foundation

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
    /// The title the owner typed in the sheet (CONTRACT-LIBRARY2 decision 4), for the app to apply when it
    /// resumes the job if the extension was closed before it could. Additive: older records decode as nil.
    public var pendingTitle: String?
}

/// Jobs crossing the app / share extension boundary: one JSON file in the app group, read and
/// written under `NSFileCoordinator` so the two processes never tear it.
public final class SharedJobStore: Sendable {
    private let fileURL: URL

    public init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("jobs.json")
    }

    private static let sharedInstance = SharedJobStore(directory: AppGroup.directory("Jobs"))

    public static func shared() -> SharedJobStore { sharedInstance }

    public func all() -> [SharedJob] {
        var out: [SharedJob] = []
        coordinate(writing: false) { url in out = Self.read(url) }
        return out
    }

    public func upsert(_ job: SharedJob) {
        coordinate(writing: true) { url in
            var jobs = Self.read(url)
            if let i = jobs.firstIndex(where: { $0.id == job.id }) { jobs[i] = job } else { jobs.append(job) }
            // Age is measured against the write that is happening now (the writer's own clock).
            Self.write(Self.pruned(jobs, now: job.updatedAt), to: url)
        }
    }

    public func remove(_ id: UUID) {
        coordinate(writing: true) { url in
            var jobs = Self.read(url)
            jobs.removeAll { $0.id == id }
            Self.write(jobs, to: url)
        }
    }

    /// Newest from the extension that the app has not taken over yet and that is still fresh: a
    /// handoff left behind half an hour ago is not what the owner is about to do.
    public func nextHandoff() -> SharedJob? {
        nextHandoff(now: Date())
    }

    /// `nextHandoff()` against a given "now" (the pipeline's clock), no older than `maxAge`.
    public func nextHandoff(now: Date, maxAge: TimeInterval = SharedJobStore.handoffMaxAge) -> SharedJob? {
        all()
            .filter { $0.origin == .shareExtension && !$0.pickedUp && now.timeIntervalSince($0.updatedAt) <= maxAge }
            .max { $0.updatedAt < $1.updatedAt }
    }

    /// Past this a share-sheet handoff is stale: the owner moved on, the notification (if they
    /// still have it) is the only way back to it.
    public static let handoffMaxAge: TimeInterval = 30 * 60

    /// What an app that was closed (or killed) mid-save or mid-render can still pick up: its own
    /// unfinished job, newest first, no older than `window`.
    /// `excluding` are the jobs this process is itself carrying on (detached runs).
    func nextInFlightAppJob(
        now: Date, window: TimeInterval = SharedJobStore.inFlightWindow, excluding: Set<UUID> = []
    ) -> SharedJob? {
        all()
            .filter { job in
                guard job.origin == .app, !job.pickedUp, !excluding.contains(job.id),
                      now.timeIntervalSince(job.updatedAt) < window else { return false }
                switch job.stage {
                case .saving, .rendering: return true
                default: return false
                }
            }
            .max { $0.updatedAt < $1.updatedAt }
    }

    /// A render has a 240 s budget on the server plus upload time; a save 10 minutes before the
    /// server gives up. Past this, a relaunch does not try to follow the job any more.
    static let inFlightWindow: TimeInterval = 15 * 60
    /// Records are bookkeeping, not history: a job nobody finished is dropped after a week (the
    /// studio session's own lifetime), one the app took over after a day.
    static let retention: TimeInterval = 7 * 24 * 60 * 60
    static let pickedUpRetention: TimeInterval = 24 * 60 * 60

    static func pruned(_ jobs: [SharedJob], now: Date) -> [SharedJob] {
        jobs.filter { job in
            now.timeIntervalSince(job.updatedAt) < (job.pickedUp ? pickedUpRetention : retention)
        }
    }

    // MARK: -

    private func coordinate(writing: Bool, _ body: (URL) -> Void) {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var error: NSError?
        if writing {
            coordinator.coordinate(writingItemAt: fileURL, options: .forMerging, error: &error, byAccessor: body)
        } else {
            coordinator.coordinate(readingItemAt: fileURL, options: [], error: &error, byAccessor: body)
        }
    }

    private static func read(_ url: URL) -> [SharedJob] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        return (try? JSONDecoder().decode([SharedJob].self, from: data)) ?? []
    }

    private static func write(_ jobs: [SharedJob], to url: URL) {
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
