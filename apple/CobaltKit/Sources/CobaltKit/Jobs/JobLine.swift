import Foundation

// What "waiting" means, behind one protocol (CONTRACT-PARALLEL.md 3.2). With `features.line` the server holds the line
// and the app mirrors it (`ServerLine`); without it the app keeps its own on the device (`LocalLine`).

enum LineKind: Sendable { case save, render }

enum LinePriority: Int, Comparable, Sendable {
    case batch = 0
    case focused = 1

    static func < (a: LinePriority, b: LinePriority) -> Bool { a.rawValue < b.rawValue }
}

@MainActor
protocol JobLine: AnyObject {
    /// `.device`: returns when it is `job`'s turn (the device line's acquire). `.server`: returns at once (the request
    /// itself carries `queue: true`). Throws CancellationError.
    func enter(_ job: UUID, kind: LineKind, priority: LinePriority) async throws
    /// From every poll answer (server mode): `queueAhead` is the jobs before this one, the running one included;
    /// nil means it started.
    func observe(_ job: UUID, queueAhead: Int?)
    /// Device mode: an upload's adopt or a resumed run already holds the server's one slot.
    func noteOnServer(_ job: UUID)
    func release(_ job: UUID)
    func position(of job: UUID) -> LinePosition?
}

/// Tells the queue a job's place changed (it sets `Pipeline.line`). Both lines call it on the main actor.
typealias LineChange = @MainActor (_ job: UUID, _ position: LinePosition?) -> Void
