import Foundation

/// What the server runs or holds: its line (this key's saves and renders, another device's, the share sheet's) and the video
/// editor's renders, from `ServerActivityStore`'s last answer. The store polls on every screen (30 s while the server is quiet,
/// 3 s while it moves), so the answer is news wherever the owner is; it is dropped only when it stopped being refreshed (the app is
/// away, or the reads keep failing) for `serverFreshness` seconds (this device's own editor renders stay).
@MainActor
final class ServerActivitySource: ActivitySource {
    let tier = ActivityTier.server
    /// A backgrounded or failing app uses the server's last answer for this long after it arrived.
    static let serverFreshness: TimeInterval = 45

    private let ctx: PipelineContext
    private let unified: UnifiedQueue

    init(context: PipelineContext, unified: UnifiedQueue) {
        self.ctx = context
        self.unified = unified
    }

    func statuses(now: Date) -> [JobStatus] {
        var out: [JobStatus] = []
        let store = unified.activityStore
        let queueOn = ctx.capabilities.queue
        let snapshot = queueOn ? store.snapshot : nil
        let fresh = queueOn && store.isFresh(at: now)
        let at = store.updatedAt ?? now
        // ids are the queue tab's own (`QueueItem.id`), so a row and its action find each other
        if fresh, let line = snapshot?.line {
            if let r = line.running {
                let work = ServerWork(kind: r.kind, running: true, mine: r.mine, origin: r.origin, keyName: r.keyName, sid: r.sid, job: r.job)
                if let s = JobStatus(server: work, id: "server:running:\(r.sid ?? r.job ?? r.kind)", at: at) { out.append(s) }
            }
            for e in line.entries {
                let work = ServerWork(
                    kind: e.kind, running: false, position: e.position, mine: e.mine, origin: e.origin, keyName: e.keyName,
                    sid: e.sid, job: e.job, link: e.link.flatMap(URL.init(string:)))
                let key = e.job ?? e.sid ?? "\(e.kind):\(e.keyName ?? "-"):\(e.position)"
                if let s = JobStatus(server: work, id: "server:\(key)", at: at) { out.append(s) }
            }
        }
        // the editor's renders: this device's own are always known; the server's only while its answer is fresh
        let renders = UnifiedQueue.mergeEdits(
            server: fresh ? (snapshot?.edits ?? []) : [], local: ctx.capabilities.editor ? (unified.editRenders?() ?? []) : [])
        for r in renders where !store.dismissedEdits.contains(r.id) {
            if !r.isActive, now.timeIntervalSince(r.lastMoment) >= UnifiedQueue.finishedLinger { continue }
            if let s = JobStatus(edit: r, now: now) { out.append(s) }
        }
        return out
    }

    func perform(_ action: ActivityModel.Action, on status: JobStatus) async -> Bool {
        switch status.ref {
        case .server, .editRender: break
        default: return false
        }
        let mapped: QueueAction
        switch action {
        case .cancel: mapped = .cancel
        case .retry: mapped = .retry
        case .dismiss: mapped = .dismiss
        case .focus: return true
        }
        if let row = unified.items.first(where: { $0.id == status.id }) { await unified.perform(mapped, on: row) }
        return true
    }
}
