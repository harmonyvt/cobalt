import Foundation
import Testing
@testable import CobaltKit

// CONTRACT-OFFLINE.md 13.8: `Sync/pull.json`. Temp directories only.

struct PullLedgerTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func ledger() throws -> (PullLedger, URL) {
        let dir = try makeTempDirectory()
        return (PullLedger(directory: dir), dir)
    }

    @Test func aFreshLedgerHasNoBaselineAndNothingDecided() throws {
        let (ledger, dir) = try ledger()
        let f = ledger.read()
        #expect(f.v == 1 && f.enabledAt == nil && f.watermark == nil && f.lastCheck == nil && f.problem == nil)
        #expect(f.done.isEmpty && f.own.isEmpty && f.backlog.isEmpty && f.server == nil)
        #expect(ledger.url == dir.appendingPathComponent("pull.json"))
    }

    @Test func theBaselineIsTakenAtTheGivenMomentAndNamesItsServer() throws {
        let (ledger, _) = try ledger()
        ledger.rebaseline(now: t0, server: "https://api.example")
        let f = ledger.read()
        #expect(f.enabledAt == t0 && f.server == "https://api.example" && f.watermark == nil && f.done.isEmpty)
    }

    @Test func aNewBaselineForgetsWhatWasDecidedAndWhatWasLeftToWalkButNotWhatThisMacUploaded() throws {
        let (ledger, _) = try ledger()
        ledger.rebaseline(now: t0, server: "s")
        ledger.record(["F1", "F2"], at: t0, state: .queued)
        ledger.noteOwn(["UP"], now: t0)
        ledger.finishCheck(now: t0, watermark: t0, backlog: [PullSegment(cursor: "9", floor: t0)], problem: nil, markSeen: true)
        #expect(ledger.read().backlog.count == 1 && ledger.read().lastCheck == t0)

        ledger.rebaseline(now: t0.addingTimeInterval(60), server: "s")
        let f = ledger.read()
        #expect(f.enabledAt == t0.addingTimeInterval(60) && f.done.isEmpty && f.backlog.isEmpty && f.watermark == nil && f.lastCheck == nil)
        #expect(f.own["UP"] == t0, "the uploads this Mac made stay remembered")
    }

    @Test func disarmingForgetsTheBaselineSoTheNextOnIsANewOne() throws {
        let (ledger, _) = try ledger()
        ledger.rebaseline(now: t0, server: "s")
        ledger.record(["F1"], at: t0, state: .queued)
        ledger.disarm()
        let f = ledger.read()
        #expect(f.enabledAt == nil && f.watermark == nil && f.done.isEmpty && f.backlog.isEmpty)
    }

    @Test func aQueuedEntryStaysQueuedWhenALaterDecisionSaysSkipped() throws {
        let (ledger, _) = try ledger()
        ledger.record(["F1"], at: t0, state: .queued)
        ledger.record(["F1"], at: t0, state: .skipped, why: "local")
        #expect(ledger.read().done["F1"] == PullDone(at: t0, state: .queued, why: nil), "handed over stays handed over")
        ledger.record(["F2"], at: t0, state: .skipped, why: "local")
        ledger.record(["F2"], at: t0, state: .queued)
        #expect(ledger.read().done["F2"]?.state == .queued, "and a skip can still become a hand-over")
    }

    @Test func aDownloadThatEndedGoneReadsSkippedAndAnUnknownIdIsIgnored() throws {
        let (ledger, _) = try ledger()
        ledger.record(["F1"], at: t0, state: .queued)
        ledger.markGone(["F1", "never-seen"])
        #expect(ledger.read().done["F1"] == PullDone(at: t0, state: .skipped, why: "gone"))
        #expect(ledger.read().done["never-seen"] == nil)
    }

    @Test func entriesOlderThanTheWatermarkByADayArePrunedAndRecentOnesStay() throws {
        let (ledger, _) = try ledger()
        ledger.record(["old"], at: t0.addingTimeInterval(-2 * 86_400), state: .queued)
        ledger.record(["edge"], at: t0.addingTimeInterval(-86_400 + 5), state: .queued)
        ledger.record(["new"], at: t0, state: .queued)
        ledger.finishCheck(now: t0, watermark: t0, backlog: [], problem: nil, markSeen: true)
        #expect(Set(ledger.read().done.keys) == ["edge", "new"])
    }

    @Test func nothingIsPrunedBeforeAWatermarkExists() throws {
        let (ledger, _) = try ledger()
        ledger.record(["old"], at: t0.addingTimeInterval(-9 * 86_400), state: .queued)
        ledger.finishCheck(now: t0, watermark: nil, backlog: [], problem: nil, markSeen: true)
        #expect(ledger.read().done["old"] != nil)
    }

    @Test func uploadsThisMacMadeAreRememberedForAWeekAndAFewDays() throws {
        let (ledger, _) = try ledger()
        ledger.noteOwn(["A"], now: t0)
        ledger.noteOwn(["A"], now: t0.addingTimeInterval(3_600))
        #expect(ledger.read().own["A"] == t0, "the first time it was noted stays")
        ledger.finishCheck(now: t0.addingTimeInterval(7 * 86_400), watermark: nil, backlog: [], problem: nil, markSeen: false)
        #expect(ledger.read().own["A"] != nil)
        ledger.finishCheck(now: t0.addingTimeInterval(9 * 86_400), watermark: nil, backlog: [], problem: nil, markSeen: false)
        #expect(ledger.read().own["A"] == nil)
    }

    @Test func aFinishedCheckWritesWhatItSawAndAFailureOnlyTheProblem() throws {
        let (ledger, _) = try ledger()
        ledger.rebaseline(now: t0, server: "s")
        ledger.finishCheck(now: t0.addingTimeInterval(10), watermark: t0.addingTimeInterval(5), backlog: [], problem: nil, markSeen: true)
        #expect(ledger.read().lastCheck == t0.addingTimeInterval(10) && ledger.read().watermark == t0.addingTimeInterval(5))
        ledger.setProblem("network")
        let f = ledger.read()
        #expect(f.problem == "network" && f.lastCheck == t0.addingTimeInterval(10) && f.watermark == t0.addingTimeInterval(5))
        ledger.finishCheck(now: t0.addingTimeInterval(20), watermark: nil, backlog: [], problem: nil, markSeen: true)
        #expect(ledger.read().problem == nil && ledger.read().watermark == t0.addingTimeInterval(5), "no watermark given: it stays")
    }

    @Test func theFileSurvivesARelaunchAndReadsALedgerWrittenWithFewerOrOddFields() throws {
        let (ledger, dir) = try ledger()
        ledger.rebaseline(now: t0, server: "s")
        ledger.record(["F1"], at: t0, state: .queued)
        let again = PullLedger(directory: dir)
        #expect(again.read() == ledger.read() && again.read().done["F1"]?.state == .queued)

        // 13.8's own shape (no `own`, no `backlog`), and a field of the wrong type, still read
        let minimal = #"{"v":1,"enabledAt":123.5,"done":{"F9":{"at":1,"state":"skipped","why":"gone"}},"problem":7}"#
        try Data(minimal.utf8).write(to: ledger.url)
        let f = PullLedger(directory: dir).read()
        #expect(f.enabledAt == Date(timeIntervalSinceReferenceDate: 123.5) && f.done["F9"]?.why == "gone")
        #expect(f.own.isEmpty && f.backlog.isEmpty && f.problem == nil, "a value of the wrong type reads as unsaid")
    }

    @Test func aFileThatIsNotJSONReadsAsFresh() throws {
        let (ledger, dir) = try ledger()
        try Data("not json".utf8).write(to: ledger.url)
        #expect(PullLedger(directory: dir).read() == PullFile())
    }
}
