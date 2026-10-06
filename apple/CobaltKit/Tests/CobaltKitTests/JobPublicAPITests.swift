// Deliberately a plain `import CobaltKit` (no @testable): this file only sees what the app, the share extension and the
// Shortcuts actions see. It type-checks the pinned CONTRACT-PARALLEL.md 3.2 surface; nothing here runs for its results.
import Foundation
import Testing
import CobaltKit

@MainActor
private func touchQueue(_ queue: JobQueue, _ model: AppModel) async {
    let _: [Job] = queue.jobs
    let _: Job.ID? = queue.focusedID
    let _: Job? = queue.focused
    let _: [Job] = queue.live
    let _: [Job] = queue.alongside
    let _: JobSummary = queue.summary
    let _: LineMode = queue.lineMode
    let url = URL(string: "https://x.com/i/status/1")!
    let jobs: [Job] = queue.add([.link(url), .file(url, photosAssetID: nil)], via: .shortcut, options: JobOptions(title: "t", makePublic: true))
    let _: [Job] = queue.add([.link(url)], via: .paste)
    let accepted: [Job.ID: JobAcceptance] = await queue.accepted(jobs.map(\.id), timeout: 20)
    for a in accepted.values {
        switch a {
        case .onServer(session: _, postKey: _, queued: _, ahead: _), .failed(_), .stillLocal: break
        }
    }
    queue.focus(jobs[0].id)
    queue.unfocus()
    await queue.cancel(jobs[0].id)
    queue.retry(jobs[0].id)
    queue.dismiss(jobs[0].id)
    queue.clearFinished()
    let _: JobQueue = model.queue
    let _: Pipeline = model.pipeline
    let _: Bool = model.requestedJobs
}

@MainActor
private func touchJob(_ job: Job) {
    let _: UUID = job.id
    let _: Pipeline = job.pipeline
    let _: Date = job.addedAt
    switch job.origin { case .app, .share, .relaunch, .shortcut: break }
    let _: LinePosition? = job.pipeline.line
    if let line = job.pipeline.line {
        switch line {
        case .inLine(let n, behind: let who): _ = (n, who)
        case .serverBusy(since: let since, label: let label): _ = (since, label)
        }
    }
}

private func touchTypes() {
    let _: [JobVia] = [.paste, .drop, .circle, .review, .relaunch, .share, .shortcut]
    let _: JobOptions = JobOptions()
    let s = JobSummary(live: 1, waiting: 1, finished: 0, failed: 0)
    _ = (s.live, s.waiting, s.finished, s.failed)
    let _: [LineMode] = [.server, .device]
    let _: [URL] = LinkInfo.allLinks(in: "https://x.com/i/status/1", limit: 20)
    let _: [URL] = LinkInfo.allLinks(in: "https://x.com/i/status/1")
    let _: PipelineFailure = .lineFull
    let _: Bool = Capabilities.unknown.line
    let _: Int = Capabilities.Limits.fork.lineMax
    let _: TimeInterval = Capabilities.Limits.fork.lineWait
    let _: [QueueCancel] = [.cancelled, .started]
    let _: [SaveStep] = [.fetching, .reading, .storing, .queued]
    let _: [RenderPhase] = [.fetching, .decode, .pack, .queued]
    let _: Int? = RenderStatus.pending(phase: .queued, framesDone: nil, framesTotal: nil, queueAhead: 2).queueAheadForPin
}

private extension RenderStatus {
    var queueAheadForPin: Int? { if case .pending(_, _, _, let ahead) = self { return ahead } else { return nil } }
}

private func touchClient(_ c: any CobaltClient) async throws {
    let url = URL(string: "https://x.com/i/status/1")!
    let created: StudioCreated = try await c.createStudio(link: url, public: true, queue: true, title: "t")
    let _: (Bool, Int?) = (created.queued, created.queueAhead)
    _ = try await c.openStudio(item: "x", queue: true)
    let up: UploadResult = try await c.upload(file: url, name: "n", contentType: "video/mp4", public: nil, queue: true, title: nil, progress: { _ in })
    let _: (Bool, Int?) = (up.queued, up.queueAhead)
    let _: QueueCancel = try await c.cancelQueued(session: "s")
    let _: QueueCancel = try await c.cancelQueued(session: "s", job: "j")
    let snap: ServerLineSnapshot = try await c.line()
    let _: [ServerLineSnapshot.Entry] = snap.entries
    let _: Int = try await c.setLineNotify()
    try await c.cancelLineNotify()
    let _: RenderRequest = RenderRequest(start: 0, length: 1, width: 480, quality: .med, queue: true, priority: "focused")
    let session: StudioSession = try await c.session("s", wait: 0)
    let _: Int? = session.queueAhead
}

@Test func theParallelWorkPublicSurfaceTypeChecks() {
    // compile-time pin; the functions above are never called
    _ = touchTypes
}
