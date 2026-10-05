import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import CobaltKit

// "trim in cobalt" opens the app on the trim, and the filmstrip no longer waits for the server's
// ranged reads when the device's own copy is faster.

@MainActor
private func job(
    session: String = "handoff-sid", wantsTrim: Bool, stage: SharedJob.Stage = .ready, at now: Date
) -> SharedJob {
    SharedJob(
        id: UUID(), origin: .shareExtension, link: URL(string: pastedLink), sessionID: session,
        media: MediaInfo(name: "clip", duration: 14.77, width: 480, height: 854, bytes: 1_000_000, isImage: false),
        trim: TrimRange(start: 0, end: 10), stage: stage, wantsTrim: wantsTrim, pickedUp: false, updatedAt: now)
}

@MainActor
@Suite(.serialized)
struct TrimHandoffTests {
    @Test func aWantsTrimJobOpensOnTheTrimOnce() async throws {
        let h = Harness(.happy)
        let p = h.pipeline
        #expect(p.opensOnTrim == false && p.takeTrimRequest() == false)
        p.resume(job(wantsTrim: true, at: h.clock.now()))
        #expect(p.opensOnTrim)
        #expect(p.takeTrimRequest() == true, "the first read says yes")
        #expect(p.takeTrimRequest() == false && p.opensOnTrim == false, "and only the first")
        await h.drive { p.state == .ready }
        #expect(p.state == .ready && p.takeTrimRequest() == false, "reaching ready does not bring it back")
    }

    @Test func aPlainJobNeverAsksForTheTrimAndANewRunClearsIt() async throws {
        let h = Harness(.happy)
        let p = h.pipeline
        p.resume(job(wantsTrim: false, at: h.clock.now()))
        #expect(p.opensOnTrim == false)
        p.resume(job(wantsTrim: true, at: h.clock.now()))
        #expect(p.opensOnTrim)
        p.start(link: URL(string: shortLink)!)
        #expect(p.opensOnTrim == false, "a different run is not a trim request")
        p.resume(job(wantsTrim: true, at: h.clock.now()))
        p.reset()
        #expect(p.opensOnTrim == false)
    }

    @Test func aReadyHandoffTakesTheStoredOriginalSoTheTrimPlaysALocalFile() async throws {
        let h = Harness(.happy)
        let p = h.pipeline
        let dir = try makeTempDirectory()
        let store = OfflineStore(root: dir, tools: h.ctx.tools)
        let file = dir.appendingPathComponent("orig.mp4")
        try Data("x".utf8).write(to: file)
        let m = MediaInfo(name: "clip", duration: 14.77, width: 480, height: 854, bytes: 1, isImage: false)
        let video = try await store.add(
            file: file, kind: .original, media: m, sessionID: "handoff-sid", link: URL(string: pastedLink), remoteURL: nil, move: true)
        let ctx = PipelineContext(
            client: h.ctx.client, capabilities: h.ctx.capabilities, settings: h.ctx.settings, store: store, jobs: h.ctx.jobs,
            tools: h.ctx.tools, clock: h.clock, photos: h.ctx.photos, clipboard: h.ctx.clipboard, intake: h.ctx.intake, isPreview: true)
        let q = Pipeline(context: ctx)
        _ = p
        q.resume(job(wantsTrim: true, at: h.clock.now()))
        await h.drive { q.state == .ready }
        #expect(q.stored?.id == video.id, "the preview plays the stored original, not the network")
        #expect(q.opensOnTrim)
    }
}

@MainActor
@Suite(.serialized)
struct TrimHandoffAppModelTests {
    private func readyHome(_ h: Harness) async -> String? {
        h.pipeline.start(link: URL(string: shortLink)!)
        await h.drive { h.pipeline.state == .ready }
        return h.pipeline.sessionID
    }

    @Test func aTrimHandoffReplacesAClipSittingAtReady() async throws {
        let h = Harness(.happy)
        let first = await readyHome(h)
        #expect(first != nil)
        let j = job(wantsTrim: true, at: h.clock.now())
        h.ctx.jobs.upsert(j)
        await h.app.pickUpSharedJobs()
        #expect(h.pipeline.sessionID == j.sessionID && h.pipeline.opensOnTrim, "foregrounding took the explicit trim request")
        #expect(h.ctx.jobs.all().first { $0.id == j.id }?.pickedUp == true)
    }

    @Test func aPlainHandoffLeavesAClipAtReadyAlone() async throws {
        let h = Harness(.happy)
        let first = await readyHome(h)
        let j = job(wantsTrim: false, at: h.clock.now())
        h.ctx.jobs.upsert(j)
        await h.app.pickUpSharedJobs()
        #expect(h.pipeline.sessionID == first && !h.pipeline.opensOnTrim)
        h.app.open(URL(string: "cobalt-apple://job/\(j.id.uuidString)")!)
        #expect(h.pipeline.sessionID == first, "opening it does not push a ready clip aside either")
        #expect(h.ctx.jobs.all().first { $0.id == j.id }?.pickedUp == false)
    }

    @Test func openingATrimJobTakesAReadyClipToo() async throws {
        let h = Harness(.happy)
        _ = await readyHome(h)
        let j = job(wantsTrim: true, at: h.clock.now())
        h.ctx.jobs.upsert(j)
        h.app.open(URL(string: "cobalt-apple://job/\(j.id.uuidString)")!)
        #expect(h.pipeline.sessionID == j.sessionID && h.pipeline.opensOnTrim)
    }

    @Test func aTrimHandoffNeverInterruptsABusyState() async throws {
        let h = Harness(.happy)
        h.pipeline.start(link: URL(string: shortLink)!)
        await h.drive { if case .reading = h.pipeline.state { return true } else { return false } }
        let busy = h.pipeline.sessionID
        let j = job(wantsTrim: true, at: h.clock.now())
        h.ctx.jobs.upsert(j)
        await h.app.pickUpSharedJobs()
        #expect(h.pipeline.sessionID == busy && !h.pipeline.opensOnTrim, "reading is busy: the job waits")
        h.app.open(URL(string: "cobalt-apple://job/\(j.id.uuidString)")!)
        #expect(h.pipeline.sessionID == busy)
        #expect(h.ctx.jobs.all().first { $0.id == j.id }?.pickedUp == false)
    }
}

// MARK: - The filmstrip race

/// Remote reads are slow (`remoteDelay` per frame on the virtual clock), local ones are quick.
private final class RaceTools: MediaTools, Sendable {
    let clock: any PipelineClock
    let remoteDelay: Double
    let localWorks: Bool
    private let log = Mutex<[String]>([])

    init(clock: any PipelineClock, remoteDelay: Double, localWorks: Bool = true) {
        self.clock = clock
        self.remoteDelay = remoteDelay
        self.localWorks = localWorks
    }

    var reads: [String] { log.withLock { $0 } }

    func probe(file: URL) async -> MediaInfo? { nil }
    func poster(for file: URL, isImage: Bool, to destination: URL) async -> Bool { false }

    func frames(of input: FrameInput, duration: Double?, count: Int) -> AsyncThrowingStream<Frame, Error> {
        let isLocal: Bool
        if case .local = input { isLocal = true } else { isLocal = false }
        log.withLock { $0.append(isLocal ? "local" : "remote") }
        let delay = isLocal ? 0.02 : remoteDelay
        let fails = isLocal && !localWorks
        let clock = clock
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if fails { throw MediaError.noFrames }
                    for i in 0..<count {
                        try await clock.sleep(seconds: delay)
                        if let image = PreviewMedia.gradient(width: 24, height: 48) { continuation.yield(Frame(index: i, image: image)) }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@MainActor
@Suite(.serialized)
struct FramesRaceTests {
    private func rig(_ tools: RaceTools, h: Harness, client: (any CobaltClient)? = nil) -> Pipeline {
        let base = h.ctx
        let ctx = PipelineContext(
            client: client ?? base.client, capabilities: base.capabilities, settings: base.settings, store: base.store,
            jobs: base.jobs, tools: tools, clock: h.clock, photos: base.photos, clipboard: base.clipboard,
            intake: base.intake, isPreview: true)
        return Pipeline(context: ctx)
    }

    @Test func aSlowNetworkReaderLosesToTheLocalCopy() async throws {
        let h = Harness(.shortClip)
        let tools = RaceTools(clock: h.clock, remoteDelay: 6)          // 54 s of ranged reads
        let p = rig(tools, h: h)
        p.start(link: URL(string: shortLink)!)
        await h.drive { p.state == .ready }
        #expect(p.state == .ready)
        #expect(p.frames.allSatisfy { $0 != nil } && !p.framesFailed)
        #expect(p.frames.enumerated().allSatisfy { $0.element?.index == $0.offset }, "real decoded frames, in their own slots")
        #expect(tools.reads.contains("local"), "the local copy supplied the frames")
        #expect(h.clock.elapsed < 20, "ready after \(h.clock.elapsed) virtual s, not after the ranged reads")
        #expect(p.localFile != nil, "the copy stays for save to photos")
    }

    @Test func withoutALocalCopyTheNetworkResultIsUsed() async throws {
        let h = Harness(.shortClip)
        let tools = RaceTools(clock: h.clock, remoteDelay: 0.5)
        var stub = ScriptedClient(base: h.ctx.client)
        stub.downloadHook = { _, _ in throw CobaltError.network(.timedOut) }
        let p = rig(tools, h: h, client: stub)
        p.start(link: URL(string: shortLink)!)
        await h.drive { p.state == .ready }
        #expect(p.frames.allSatisfy { $0 != nil } && !p.framesFailed)
        #expect(tools.reads == ["remote"], "the copy never arrived; only the ranged reader produced frames")
        #expect(p.localFile == nil)
    }

    @Test func aFastNetworkReaderDoesNotWaitForTheCopy() async throws {
        let h = Harness(.shortClip)
        let tools = RaceTools(clock: h.clock, remoteDelay: 0.01)       // 0.09 s for all nine
        let p = rig(tools, h: h)
        p.start(link: URL(string: shortLink)!)
        await h.drive { p.state == .ready }
        #expect(p.frames.allSatisfy { $0 != nil })
        #expect(tools.reads.first == "remote")
        #expect(h.clock.elapsed < PreviewData.saveSeconds + 6, "ready without waiting for the download")
    }

    @Test func aCopyThatDecodesNothingLeavesTheNetworkToFinish() async throws {
        let h = Harness(.shortClip)
        let tools = RaceTools(clock: h.clock, remoteDelay: 3, localWorks: false)
        let p = rig(tools, h: h)
        p.start(link: URL(string: shortLink)!)
        await h.drive { p.state == .ready }
        #expect(p.frames.allSatisfy { $0 != nil } && !p.framesFailed, "the ranged reader still delivered")
        #expect(tools.reads.contains("local") && tools.reads.contains("remote"))
    }
}
