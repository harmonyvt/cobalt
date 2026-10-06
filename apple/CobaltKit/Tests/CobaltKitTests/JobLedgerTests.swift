import Foundation
import Testing
@testable import CobaltKit

/// Jobs that have no server session yet survive a relaunch (CONTRACT-PARALLEL.md 3.5).
@MainActor
struct JobLedgerTests {
    private func entry(_ link: URL, at: Date, id: UUID = UUID(), via: JobVia = .shortcut) -> JobLedger.Entry {
        JobLedger.Entry(id: id, input: .link(link), options: JobOptions(), via: via, addedAt: at)
    }

    @Test func writtenOnAddAndReadBackByANewProcess() async throws {
        let rig = LineRig(.deviceBusy(seconds: 100_000))
        let jobs = rig.queue.add([.link(linkA)], via: .shortcut, options: JobOptions(title: "t", makePublic: true))
        let ledger = try #require(rig.queue.ledger)
        #expect(ledger.all.count == 1 && ledger.all[0].id == jobs[0].id)
        // a second process opens the same file
        let reopened = JobLedger(fileURL: ledgerURL(rig), now: { rig.clock.now() })
        #expect(reopened.all == ledger.all)
        #expect(reopened.all[0].options == JobOptions(title: "t", makePublic: true) && reopened.all[0].via == .shortcut)
        if case .link(let url) = reopened.all[0].input { #expect(url == linkA) } else { Issue.record("a link entry") }
    }

    @Test func removedWhenTheJobGetsItsSession() async {
        let rig = LineRig(.serverBusyWithShare)
        let jobs = rig.queue.add([.link(linkA), .link(linkB)], via: .review)
        #expect(rig.queue.ledger?.all.count == 2, "between add and the server's answer a job is only in the ledger")
        await rig.settle()
        #expect(jobs.allSatisfy { $0.pipeline.sessionID != nil })
        #expect(rig.queue.ledger?.all.isEmpty == true, "the 201 is the hand-over: the SharedJob record covers it from here")
    }

    @Test func removedWhenTheJobEndsOrIsCancelledBeforeASession() async {
        let rig = LineRig(.deviceBusy(seconds: 100_000))
        let jobs = rig.queue.add([.link(linkA), .link(linkB)], via: .review)
        await rig.settle()
        #expect(rig.queue.ledger?.all.count == 2)
        await rig.queue.cancel(jobs[1].id)
        #expect(rig.queue.ledger?.all.map(\.id) == [jobs[0].id])
        await rig.drive(until: { rig.settled(jobs[0]) }, maxVirtualSeconds: 700)
        #expect(jobs[0].pipeline.state == .failed(.serverBusy))
        #expect(rig.queue.ledger?.all.isEmpty == true)
    }

    @Test func everyWaitingJobOfADeviceLineStaysUntilItsTurn() async {
        let rig = LineRig(.off)
        _ = rig.queue.add([.link(linkA), .link(linkB), .link(linkC)], via: .review)
        #expect(rig.queue.ledger?.all.count == 3)
        await rig.drive(until: { rig.allSettled() }, maxVirtualSeconds: 200)
        #expect(rig.queue.ledger?.all.isEmpty == true)
    }

    @Test func aRelaunchPutsThemBackInTheirOldOrderWithoutFocusing() async {
        let rig = LineRig(.serverBusyWithShare)
        let now = rig.clock.now()
        let ledger = rig.queue.ledger!
        ledger.add(entry(linkC, at: now.addingTimeInterval(-30)))
        ledger.add(entry(linkA, at: now.addingTimeInterval(-90)))
        ledger.add(entry(linkB, at: now.addingTimeInterval(-60)))
        await rig.queue.restoreLedger()
        #expect(rig.queue.jobs.count == 3 && rig.queue.restoredCount == 3)
        #expect(rig.queue.jobs.compactMap { job -> URL? in if case .link(let i)? = job.pipeline.input { return i.url } else { return nil } } == [linkA, linkB, linkC],
                "oldest first")
        #expect(rig.queue.focusedID == nil && rig.queue.jobs.allSatisfy { $0.origin == .relaunch })
        await rig.settle()
        #expect(rig.queue.jobs.allSatisfy { $0.pipeline.sessionID != nil }, "on a server line they go straight in")
        rig.queue.acknowledgeRestored()
        #expect(rig.queue.restoredCount == 0)
    }

    @Test func entriesOlderThanADayAreDropped() async {
        let rig = LineRig(.server)
        let now = rig.clock.now()
        rig.queue.ledger!.add(entry(linkA, at: now.addingTimeInterval(-25 * 3600)))
        rig.queue.ledger!.add(entry(linkB, at: now.addingTimeInterval(-3600)))
        await rig.queue.restoreLedger()
        #expect(rig.queue.jobs.count == 1 && rig.queue.restoredCount == 1)
        if case .link(let info)? = rig.queue.jobs[0].pipeline.input { #expect(info.url == linkB) }
    }

    @Test func aFileWhoseInboxCopyIsGoneIsDroppedAndSaidSo() async throws {
        let rig = LineRig(.server)
        let there = try makeTempFile("kept.mov", bytes: 150_000)
        let now = rig.clock.now()
        rig.queue.ledger!.add(JobLedger.Entry(
            id: UUID(), input: .file(path: "/nonexistent/inbox/IMG_0412.mov", name: "IMG_0412.mov", bytes: 5, contentType: "video/quicktime", photosAssetID: nil),
            options: JobOptions(), via: .shortcut, addedAt: now))
        rig.queue.ledger!.add(JobLedger.Entry(
            id: UUID(), input: .file(path: there.path, name: "kept.mov", bytes: 150_000, contentType: "video/quicktime", photosAssetID: nil),
            options: JobOptions(), via: .shortcut, addedAt: now.addingTimeInterval(1)))
        await rig.queue.restoreLedger()
        #expect(rig.queue.restoredGoneFiles == ["IMG_0412.mov"])
        #expect(rig.queue.jobs.count == 1 && rig.queue.restoredCount == 1)
        #expect(rig.queue.ledger?.all.allSatisfy { if case .file(_, let name, _, _, _) = $0.input { name != "IMG_0412.mov" } else { true } } == true)
    }

    @Test func aLinkTheServerAlreadyHasIsFollowedNotSentAgain() async throws {
        let rig = LineRig(.serverBusyWithShare)
        // a POST /studio that reached the server whose 201 was lost: its session is in the line, `mine`, with the link
        let lost = try await rig.client.createStudio(link: linkA, public: nil, queue: true, title: nil)
        let sends = rig.calls.filter { $0.hasPrefix("POST /studio") }.count
        let now = rig.clock.now()
        rig.queue.ledger!.add(entry(linkA, at: now.addingTimeInterval(-20)))
        rig.queue.ledger!.add(entry(linkB, at: now.addingTimeInterval(-10)))
        await rig.queue.restoreLedger()
        await rig.settle()
        #expect(rig.calls.filter { $0.hasPrefix("POST /studio") }.count == sends + 1, "only B is sent: \(rig.calls)")
        #expect(rig.calls.contains("GET line"))
        #expect(rig.queue.jobs.count == 2)
        #expect(rig.queue.jobs[0].pipeline.sessionID == lost.id, "A follows the session the server already has")
        #expect(rig.queue.jobs[1].pipeline.sessionID != nil && rig.queue.jobs[1].pipeline.sessionID != lost.id)
    }

    @Test func restoresOnlyOncePerLaunch() async {
        let rig = LineRig(.server)
        rig.queue.ledger!.add(entry(linkA, at: rig.clock.now()))
        await rig.queue.restoreLedger()
        rig.queue.ledger!.add(entry(linkB, at: rig.clock.now()))
        await rig.queue.restoreLedger()
        #expect(rig.queue.jobs.count == 1)
    }

    private func ledgerURL(_ rig: LineRig) -> URL {
        rig.ctx.store.root.deletingLastPathComponent().appendingPathComponent("job-ledger.json")
    }
}
