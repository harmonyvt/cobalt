import Foundation
import Testing
@testable import CobaltKit

/// The links that land in the queue (CONTRACT-PARALLEL.md 3.3): the Hark summary, and a hand-off over a busy home.
@MainActor
struct JobLinksTests {
    @Test func theJobsLinkAsksForTheTray() {
        let rig = LineRig(.server)
        rig.app.selectedTab = .library
        #expect(!rig.app.requestedJobs)
        rig.app.open(URL(string: "cobalt-apple://jobs")!)
        #expect(rig.app.requestedJobs && rig.app.selectedTab == .save)
        // it is not a run link
        #expect(!rig.app.openRunLink(URL(string: "cobalt-apple://jobs")!))
    }

    @Test func aRunLinkOverABusyHomeJoinsTheTrayAndLeavesTheFocusAlone() async throws {
        let rig = LineRig(.server)
        let focus = rig.queue.add([.link(linkA)], via: .paste)[0]
        await rig.run(for: 0.2)
        let other = try await rig.client.createStudio(link: linkB, public: nil, queue: true, title: nil)
        #expect(rig.app.openRunLink(URL(string: "cobalt-apple://session/\(other.id)")!))
        #expect(rig.queue.focusedID == focus.id, "a link never takes the screen from what the owner is waiting on")
        #expect(rig.queue.jobs.count == 2 && rig.queue.jobs.contains { $0.pipeline.sessionID == other.id && $0.origin == .share })
        // tapping it twice follows it once
        #expect(rig.app.openRunLink(URL(string: "cobalt-apple://session/\(other.id)")!))
        #expect(rig.queue.jobs.count == 2)
    }

    @Test func aRunLinkForAJobTheOwnerIsNotLookingAtFocusesItOnAQuietScreen() async throws {
        let rig = LineRig(.server)
        let jobs = rig.queue.add([.link(linkA), .link(linkB)], via: .review)
        await rig.run(for: 0.2)
        #expect(rig.queue.focusedID == nil)
        let sid = try #require(jobs[1].pipeline.sessionID)
        #expect(rig.app.openRunLink(URL(string: "cobalt-apple://session/\(sid)")!))
        #expect(rig.queue.focusedID == jobs[1].id && rig.app.pipeline === jobs[1].pipeline)
        await rig.drive(until: { rig.allSettled() }, maxVirtualSeconds: 100)
        #expect(jobs.allSatisfy { $0.pipeline.state == .ready })
    }

    @Test func aJobLinkOverABusyHomeJoinsTheTray() async throws {
        let rig = LineRig(.server)
        let focus = rig.queue.add([.link(linkA)], via: .paste)[0]
        await rig.run(for: 0.2)
        let created = try await rig.client.createStudio(link: linkB, public: nil, queue: true, title: nil)
        let handoff = SharedJob(
            id: UUID(), origin: .shareExtension, link: linkB, sessionID: created.id, media: nil, trim: nil, stage: .saving,
            wantsTrim: false, pickedUp: false, updatedAt: rig.clock.now())
        rig.ctx.jobs.upsert(handoff)
        rig.app.open(URL(string: "cobalt-apple://job/\(handoff.id.uuidString)")!)
        #expect(rig.queue.focusedID == focus.id && rig.queue.job(handoff.id) != nil)
        #expect(rig.queue.job(handoff.id)?.origin == .share)
    }

    @Test func withoutATrayALinkOverABusyHomeChangesNothing() async throws {
        let rig = LineRig(.server)
        rig.queue.trayIsShown = false
        let focus = rig.queue.add([.link(linkA)], via: .paste)[0]
        await rig.run(for: 0.2)
        let other = try await rig.client.createStudio(link: linkB, public: nil, queue: true, title: nil)
        #expect(rig.app.openRunLink(URL(string: "cobalt-apple://session/\(other.id)")!))
        let handoff = SharedJob(
            id: UUID(), origin: .shareExtension, link: linkB, sessionID: other.id, media: nil, trim: nil, stage: .saving,
            wantsTrim: false, pickedUp: false, updatedAt: rig.clock.now())
        rig.ctx.jobs.upsert(handoff)
        rig.app.open(URL(string: "cobalt-apple://job/\(handoff.id.uuidString)")!)
        #expect(rig.queue.jobs.map(\.id) == [focus.id], "as today: ignored over a busy home")
        #expect(rig.app.jobs.all().contains { $0.id == handoff.id && !$0.pickedUp })
    }
}

