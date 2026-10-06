import Foundation
import Testing
@testable import CobaltKit

/// Until the Live lane teaches the activity about several jobs (wave 2), the router keeps today's single-run behaviour
/// for the sink it has: batch jobs the owner never focused report nothing, and a focused run that is closed carries
/// its activity alongside (CONTRACT-PARALLEL.md section 6, Jobs/LiveRouter.swift).
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
        let batch = queue.add([.link(linkB), .link(linkC)], via: .review)
        await rig.drive { batch.allSatisfy { $0.pipeline.state == .ready } }
        await rig.drive { if case .done = focused.pipeline.state { true } else { false } }
        await rig.settle()
        #expect(rig.adapter.requests.count == 1, "batch jobs report nothing to the single-run sink")
        let handle = try #require(rig.handle)
        #expect(rig.stages(of: handle).contains(.done), "the focused run finished its own activity: \(rig.stages(of: handle))")
        #expect(!rig.stages(of: handle).contains(.failed))
    }

    @Test func closingTheFocusMidRenderKeepsTheActivityGoing() async throws {
        let rig = LiveRig(.shortClip)
        let queue = rig.h.app.queue
        let job = queue.add([.link(URL(string: shortLink)!)], via: .paste)[0]
        await rig.drive { job.pipeline.state == .ready }
        job.pipeline.makeWebp()
        await rig.drive { if case .rendering = job.pipeline.state { true } else { false } }
        queue.unfocus()
        // the owner pastes another link: it takes the (now empty) focus, and the first run's activity must survive it
        let next = queue.add([.link(linkB)], via: .paste)[0]
        #expect(queue.focusedID == nil, "a render is still live, so nothing takes the focus")
        _ = next
        await rig.drive { if case .done = job.pipeline.state { true } else { false } }
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
