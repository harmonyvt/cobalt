import Foundation
import Testing
@testable import CobaltKit

/// The router and the Live manager once the manager hears every job (`LiveActivityManager: JobLiveSink`, wave 2): a
/// batch beside a focused run no longer reports nothing; the run's activity becomes the busy period's one activity and
/// is not ended by it (CONTRACT-PARALLEL.md section 6, Jobs/LiveRouter.swift). The summary's own rules are in
/// `LiveSummaryTests`.
@MainActor
struct JobLiveCompatTests {
    @Test func aBatchNeverStartsOrEndsTheFocusedRunsActivity() async throws {
        let rig = LiveRig(.shortClip)
        let queue = rig.h.app.queue
        let focused = queue.add([.link(URL(string: shortLink)!)], via: .paste)[0]
        await rig.drive { focused.pipeline.state == .ready }
        focused.pipeline.makeWebp()
        await rig.drive { if case .rendering = focused.pipeline.state { true } else { false } }
        await rig.settle()
        #expect(rig.adapter.requests.count == 1, "the focused run has its activity")

        // a batch lands beside it: none of it touches the activity
        let batch = queue.add([.link(linkA), .link(linkC)], via: .review)
        await rig.drive { batch.allSatisfy { $0.pipeline.state == .ready } }
        await rig.drive { if case .done = focused.pipeline.state { true } else { false } }
        await rig.settle()
        #expect(rig.adapter.requests.count == 1, "the batch joins the focused run's activity: no second request")
        await rig.drive { batch.allSatisfy { $0.pipeline.state == .ready } }
        await rig.settle()
        let handle = try #require(rig.handle)
        #expect(rig.stages(of: handle).contains(.done), "the period ended on the run's activity: \(rig.stages(of: handle))")
        #expect(!rig.stages(of: handle).contains(.failed))
        #expect(handle.end?.state.savedCount == 2 && handle.end?.state.webpCount == 1, "\(String(describing: handle.end?.state))")
    }

    @Test func closingTheFocusMidRenderKeepsTheActivityGoing() async throws {
        let rig = LiveRig(.shortClip)
        let queue = rig.h.app.queue
        let job = queue.add([.link(URL(string: shortLink)!)], via: .paste)[0]
        await rig.drive { job.pipeline.state == .ready }
        job.pipeline.makeWebp()
        await rig.drive { if case .rendering = job.pipeline.state { true } else { false } }
        queue.unfocus()
        // the owner pastes another link: nothing takes the focus while the render is live, and the first run's activity
        // survives it (it carries both jobs now)
        let next = queue.add([.link(linkA)], via: .paste)[0]
        #expect(queue.focusedID == nil, "a render is still live, so nothing takes the focus")
        await rig.drive { if case .done = job.pipeline.state { true } else { false } }
        await rig.drive { next.pipeline.state == .ready }
        await rig.settle()
        let handle = try #require(rig.handle)
        #expect(rig.stages(of: handle).contains(.done), "\(rig.stages(of: handle))")
        #expect(rig.adapter.requests.count == 1)
    }

    @Test func aRouterThatHearsEveryJobForwardsEverything() async throws {
        final class Sink: JobLiveSink {
            var began: [ObjectIdentifier] = []
            var changed = 0
            func runBegan(_ pipeline: Pipeline) { began.append(ObjectIdentifier(pipeline)) }
            func stateChanged(_ pipeline: Pipeline) {}
            func sessionChanged(_ pipeline: Pipeline) {}
            func jobsChanged(_ queue: JobQueue) { changed += 1 }
        }
        let rig = LineRig(.server)
        let sink = Sink()
        rig.ctx.live = sink
        let jobs = rig.queue.add([.link(linkA), .link(linkB)], via: .review)
        #expect(Set(sink.began) == Set(jobs.map { ObjectIdentifier($0.pipeline) }), "an aware sink hears every job, muted or not")
        #expect(sink.changed >= 1)
    }
}
