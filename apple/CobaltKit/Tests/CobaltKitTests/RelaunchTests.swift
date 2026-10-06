import Foundation
import Testing
@testable import CobaltKit

/// What a relaunch picks up (CONTRACT-PARALLEL.md 3.3, 3.5): every in-flight app job, queued ones included, and the
/// share sheet's saves still on the server.
@MainActor
struct RelaunchTests {
    /// A session the "server" holds (queued behind the share) and the `SharedJob` the app left behind for it.
    private func leftBehind(_ rig: LineRig, _ link: URL, age: TimeInterval = 5) async throws -> SharedJob {
        let created = try await rig.client.createStudio(link: link, public: nil, queue: true, title: nil)
        let job = SharedJob(
            id: UUID(), origin: .app, link: link, sessionID: created.id, media: nil, trim: nil, stage: .saving,
            wantsTrim: false, pickedUp: false, updatedAt: rig.clock.now().addingTimeInterval(-age))
        rig.app.jobs.upsert(job)
        return job
    }

    @Test func everyInFlightJobResumesAsAJobQueuedOnesIncluded() async throws {
        let rig = LineRig(.serverBusyWithShare)
        let a = try await leftBehind(rig, linkA, age: 30)
        let b = try await leftBehind(rig, linkB, age: 20)
        let c = try await leftBehind(rig, linkC, age: 10)
        await rig.app.pickUpSharedJobs()
        #expect(Set(rig.queue.jobs.map(\.id)) == [a.id, b.id, c.id])
        #expect(rig.queue.jobs.allSatisfy { $0.origin == .relaunch })
        // the screen was quiet: the newest takes the focus (today's pickup), the others go alongside
        #expect(rig.queue.focusedID == c.id && rig.queue.alongside.count == 2)
        await rig.run(for: 1)
        // one /studio/line read covers them all; each job reads its own place from its own poll
        #expect(rig.count("GET line") == 1, "\(rig.calls)")
        let places = Dictionary(uniqueKeysWithValues: rig.queue.jobs.map { ($0.id, $0.pipeline.line) })
        #expect(places[a.id] == .inLine(2, behind: "a share from your iphone"))
        guard case .inLine(let nb, _)? = places[b.id], case .inLine(let nc, _)? = places[c.id] else { Issue.record("queued: \(places)"); return }
        #expect(nb == 3 && nc == 4)
        await rig.drive(until: { rig.allSettled() }, maxVirtualSeconds: 200)
        #expect(rig.queue.jobs.allSatisfy { $0.pipeline.state == .ready })
    }

    @Test func nothingIsFocusedOverARunTheOwnerIsInTheMiddleOf() async throws {
        let rig = LineRig(.serverBusyWithShare)
        let busy = rig.queue.add([.link(linkC)], via: .paste)[0]
        let a = try await leftBehind(rig, linkA)
        let b = try await leftBehind(rig, linkB)
        await rig.app.pickUpSharedJobs()
        #expect(rig.queue.focusedID == busy.id)
        #expect(Set(rig.queue.alongside.map(\.id)) == [a.id, b.id])
    }

    @Test func aJobThisProcessAlreadyRunsIsNotTakenAgain() async throws {
        let rig = LineRig(.server)
        rig.ctx.recordsJobs = true
        let focus = rig.queue.add([.link(linkA)], via: .paste)[0]
        await rig.run(for: 1)
        #expect(rig.app.jobs.all().contains { $0.id == focus.id }, "the run keeps its record while the server works for it")
        await rig.app.pickUpSharedJobs()
        await rig.app.pickUpSharedJobs()
        #expect(rig.queue.jobs.count == 1)
    }

    @Test func theWindowGrowsByTheLinesWaitOnAServerWithALine() async throws {
        let old: TimeInterval = 20 * 60                              // past 15 minutes, inside 15 + 30
        let line = LineRig(.server)
        let followed = try await leftBehind(line, linkA, age: old)
        await line.app.pickUpSharedJobs()
        #expect(line.queue.jobs.map(\.id) == [followed.id], "a job can wait 30 minutes in the server's line")

        let device = LineRig(.off)
        let stale = SharedJob(
            id: UUID(), origin: .app, link: linkA, sessionID: "PrEvIeWsession00000099", media: nil, trim: nil, stage: .saving,
            wantsTrim: false, pickedUp: false, updatedAt: device.clock.now().addingTimeInterval(-old))
        device.app.jobs.upsert(stale)
        await device.app.pickUpSharedJobs()
        #expect(device.queue.jobs.isEmpty, "without a line the window is 15 minutes, as before")
    }

    @Test func aSettledRecordIsNotResumed() async throws {
        let rig = LineRig(.server)
        let done = SharedJob(
            id: UUID(), origin: .app, link: linkA, sessionID: "PrEvIeWsession00000098", media: nil, trim: nil, stage: .ready,
            wantsTrim: false, pickedUp: false, updatedAt: rig.clock.now())
        rig.app.jobs.upsert(done)
        await rig.app.pickUpSharedJobs()
        #expect(rig.queue.jobs.isEmpty)
    }

    @Test func aShareSheetSaveStillQueuedBecomesAShareJobAlongside() async throws {
        let rig = LineRig(.serverBusyWithShare)
        // the share sheet's own save, queued behind the running share: `GET /studio/recent` lists it with step "queued"
        let shared = try await rig.client.createStudio(link: linkA, public: nil, queue: true, title: nil)
        let session = StudioSession(
            id: shared.id, status: .saving, link: linkA.absoluteString, service: "instagram", title: nil, duration: nil,
            width: nil, height: nil, bytes: nil, createdAt: rig.clock.now(), expiresAt: rig.clock.now().addingTimeInterval(3600),
            errorCode: nil, renders: [], step: .queued, stepBytes: nil, stepTotal: nil, waking: false, queueAhead: 1)
        let ready = StudioSession(
            id: "PrEvIeWsession00000077", status: .ready, link: linkB.absoluteString, service: "x", title: "t", duration: 5, width: 480,
            height: 568, bytes: 1, createdAt: rig.clock.now(), expiresAt: rig.clock.now().addingTimeInterval(3600),
            errorCode: nil, renders: [], step: nil, stepBytes: nil, stepTotal: nil, waking: nil)
        rig.ctx.recentShares = { [session, ready] }
        await rig.queue.adoptRecentShares()
        #expect(rig.queue.jobs.count == 1, "a finished share is left to the original's download")
        #expect(rig.queue.jobs[0].origin == .share && rig.queue.focusedID == nil)
        #expect(rig.queue.jobs[0].pipeline.sessionID == shared.id)
        await rig.run(for: 1)
        #expect(rig.queue.jobs[0].pipeline.line != nil, "it reads its place in the server's line")
        // asking again does not follow it twice
        await rig.queue.adoptRecentShares()
        #expect(rig.queue.jobs.count == 1)
    }

    // MARK: Without a tray on screen (wave 1's UI): nothing invisible starts

    @Test func withoutATrayOnlyTodaysSingleRunIsPickedUpIntoTheFocus() async throws {
        let rig = LineRig(.serverBusyWithShare)
        rig.queue.trayIsShown = false
        let a = try await leftBehind(rig, linkA, age: 30)
        let c = try await leftBehind(rig, linkC, age: 10)
        await rig.app.pickUpSharedJobs()
        #expect(rig.queue.jobs.map(\.id) == [c.id], "the newest, into the focus; the older one stays in the store")
        #expect(rig.queue.focusedID == c.id)
        #expect(rig.app.jobs.all().contains { $0.id == a.id && !$0.pickedUp })
    }

    @Test func withoutATrayABusyHomeLeavesTheRunInTheStore() async throws {
        let rig = LineRig(.serverBusyWithShare)
        rig.queue.trayIsShown = false
        let busy = rig.queue.add([.link(linkC)], via: .paste)[0]
        let a = try await leftBehind(rig, linkA)
        await rig.app.pickUpSharedJobs()
        #expect(rig.queue.jobs.map(\.id) == [busy.id] && rig.app.jobs.all().contains { $0.id == a.id })
    }

    @Test func withoutATrayShareSheetSavesAreLeftToTheOriginalsDownload() async throws {
        let rig = LineRig(.serverBusyWithShare)
        rig.queue.trayIsShown = false
        let shared = try await rig.client.createStudio(link: linkA, public: nil, queue: true, title: nil)
        let session = StudioSession(
            id: shared.id, status: .saving, link: linkA.absoluteString, service: "instagram", title: nil, duration: nil,
            width: nil, height: nil, bytes: nil, createdAt: rig.clock.now(), expiresAt: rig.clock.now().addingTimeInterval(3600),
            errorCode: nil, renders: [], step: .queued, stepBytes: nil, stepTotal: nil, waking: false, queueAhead: 1)
        rig.ctx.recentShares = { [session] }
        await rig.queue.adoptRecentShares()
        #expect(rig.queue.jobs.isEmpty)
    }
}

