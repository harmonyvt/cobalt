import Foundation
import Testing
@testable import CobaltKit

/// The server's line, mirrored (CONTRACT-PARALLEL.md 3.3): positions come from each job's own poll, labels from one
/// `GET /studio/line` read every 3 s for all of them.
@MainActor
struct ServerLineTests {
    @Test func enterReturnsAtOnce() async throws {
        let rig = LineRig(.server)
        try await rig.queue.serverLine.enter(UUID(), kind: .save, priority: .batch)
        #expect(rig.clock.registrations == 0)
    }

    @Test func aQueuedCreateGivesPositionQueueAheadPlusOne() async {
        let rig = LineRig(.serverBusyWithShare)             // a share from "iphone" runs for 15 s
        let jobs = rig.queue.add([.link(linkA), .link(linkB)], via: .review)
        await rig.settle()
        // 1st is the share on the server; ahead = 1 -> "2nd in line", ahead = 2 -> "3rd in line"
        #expect(jobs[0].pipeline.line == .inLine(2, behind: "a share from your iphone") || jobs[0].pipeline.line == .inLine(2, behind: nil))
        guard case .inLine(let first, _)? = jobs[0].pipeline.line, case .inLine(let second, _)? = jobs[1].pipeline.line else {
            Issue.record("both jobs should wait: \(String(describing: jobs[0].pipeline.line)) \(String(describing: jobs[1].pipeline.line))")
            return
        }
        #expect(first == 2 && second == 3)
        if case .fetching = jobs[0].pipeline.state {} else { Issue.record("a waiting save stays .fetching: \(jobs[0].pipeline.state)") }
    }

    @Test func thePositionMovesWithEachPollAndIsNilWhenItStarts() async {
        let rig = LineRig(.serverBusyWithShare)
        let jobs = rig.queue.add([.link(linkA), .link(linkB)], via: .review)
        await rig.settle()
        var seen: [Int] = []
        await rig.drive(until: {
            if case .inLine(let n, _)? = jobs[1].pipeline.line, seen.last != n { seen.append(n) }
            return jobs[1].pipeline.line == nil && jobs[1].pipeline.sessionID != nil && !jobs[1].isFinished && seen.count >= 2
        }, maxVirtualSeconds: 60)
        #expect(seen.first == 3 && seen.contains(2), "3rd in line, then 2nd as the share and the first save finish: \(seen)")
        await rig.drive(until: { rig.allSettled() }, maxVirtualSeconds: 120)
        #expect(jobs.allSatisfy { $0.pipeline.state == .ready })
        #expect(jobs.allSatisfy { $0.pipeline.line == nil })
    }

    @Test func oneLineReadPerThreeSecondsForAnyNumberOfQueuedJobs() async {
        let rig = LineRig(.serverBusyWithShare)
        _ = rig.queue.add([.link(linkA), .link(linkB), .link(linkC)], via: .review)
        await rig.run(for: 10)
        let reads = rig.count("GET line")
        // the share holds the server for 15 s: three jobs wait the whole time and one read covers all of them
        #expect(reads >= 3 && reads <= 5, "10 s at one read per 3 s, not per job: \(reads)")
    }

    @Test func noReadsWhileNothingIsQueued() async {
        let rig = LineRig(.server)
        let jobs = rig.queue.add([.link(linkA)], via: .review)       // the server is free: it starts at once
        await rig.drive(until: { rig.allSettled() }, maxVirtualSeconds: 60)
        #expect(jobs[0].pipeline.state == .ready)
        #expect(rig.count("GET line") == 0)
    }

    @Test func noReadsWhileTheAppIsInactive() async {
        let rig = LineRig(.serverBusyWithShare)
        let activity = FakeActivity()
        activity.isActive = false
        rig.ctx.background.activity = activity
        _ = rig.queue.add([.link(linkA), .link(linkB)], via: .review)
        await rig.run(for: 9)
        #expect(rig.count("GET line") == 0)
        activity.isActive = true
        await rig.run(for: 4)
        #expect(rig.count("GET line") >= 1)
    }

    @Test func labelsComeFromOriginKeyNameAndMine() {
        let snapshot = ServerLineSnapshot(
            running: .init(kind: "save", mine: false, origin: "share", keyName: "iphone"),
            entries: [
                .init(position: 2, kind: "save", mine: true, sid: "s", link: "https://x.com/i/status/1"),
                .init(position: 3, kind: "save", mine: false, keyName: "mac"),
                .init(position: 4, kind: "save", mine: false, keyName: nil),
                .init(position: 5, kind: "render", mine: false, keyName: "mac"),
            ])
        let labels = ServerLine.labels(from: snapshot)
        #expect(labels[1] == "a share from your iphone")
        #expect(labels[2] == nil, "this app's own work is shown as its own job")
        #expect(labels[3] == "a save from your mac")
        #expect(labels[4] == "a save that isn't in this list")
        #expect(labels[5] == "a webp from your mac")
    }

    @Test func aFailedLineReadKeepsThePositionsAndDropsTheLabels() async {
        let rig = LineRig(.serverBusyWithShare)
        let jobs = rig.queue.add([.link(linkA)], via: .review)
        await rig.settle()
        #expect(jobs[0].pipeline.line == .inLine(2, behind: "a share from your iphone"))
        rig.server.lineFails = true
        await rig.run(for: 4)
        #expect(jobs[0].pipeline.line == .inLine(2, behind: nil), "the position stays, who is ahead goes: \(String(describing: jobs[0].pipeline.line))")
        rig.server.lineFails = false
        await rig.run(for: 4)
        #expect(jobs[0].pipeline.line == .inLine(2, behind: "a share from your iphone"))
    }

    @Test func aJobBehindOurOwnJobHasNoLabel() async {
        let rig = LineRig(.serverBusyWithShare)
        let jobs = rig.queue.add([.link(linkA), .link(linkB)], via: .review)
        await rig.settle()
        await rig.run(for: 1)
        #expect(jobs[1].pipeline.line == .inLine(3, behind: nil), "directly behind this app's own save: it is in the tray")
    }
}
