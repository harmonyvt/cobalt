import Foundation
import Synchronization
import Testing
@testable import CobaltKit

// MARK: - Focus flow: public share and webp, in either order (CONTRACT-ORBIT.md 2)

@MainActor
private func isDone(_ p: Pipeline) -> Bool { if case .done = p.state { true } else { false } }

@MainActor
private func isFailed(_ p: Pipeline) -> Bool { if case .failed = p.state { true } else { false } }

@MainActor
@Suite(.serialized)
struct FocusFlowTests {
    private func ready(_ scenario: PreviewScenario = .shortClip) async -> Harness {
        let h = Harness(scenario)
        h.pipeline.start(link: URL(string: shortLink)!)
        await h.driveToSettled()
        return h
    }

    @Test func hostThenWebpKeepsBothResults() async throws {
        let h = await ready()
        let p = h.pipeline
        #expect(p.state == .ready && p.canMakeWebp && p.canHostOriginal)
        #expect(p.hostedOriginalURL == nil && p.webpResult == nil)

        p.hostOriginal()
        await h.drive { p.hosting == .done }
        let hosted = try #require(p.hostedOriginalURL)
        #expect(p.state == .ready, "hosting never moves the run")
        #expect(!p.canHostOriginal && p.canMakeWebp)

        p.makeWebp()
        await h.drive { isDone(p) }
        guard case .done(let r) = p.state else { Issue.record("expected .done"); return }
        #expect(p.webpResult == r)
        #expect(p.hostedOriginalURL == hosted, "the hosted link survives the render")
        #expect(p.hosting == .done)
        #expect(!p.canHostOriginal && !p.canMakeWebp)
    }

    @Test func webpThenHostKeepsBothResults() async throws {
        let h = await ready()
        let p = h.pipeline
        p.makeWebp()
        await h.drive { isDone(p) }
        guard case .done(let r) = p.state else { Issue.record("expected .done"); return }
        #expect(p.canHostOriginal, "from .done the original can still be shared")

        p.hostOriginal()
        await h.drive { p.hosting == .done }
        #expect(p.state == .done(r), "hosting leaves the finished webp on screen")
        #expect(p.webpResult == r)
        #expect(p.hostedOriginalURL != nil)
        #expect(h.clipboard.copies.isEmpty, "hosting never writes the pasteboard: the owner copies explicitly")
    }

    @Test func bothCanRunAtTheSameTime() async throws {
        let h = await ready()
        let p = h.pipeline
        p.makeWebp()
        await h.drive { if case .rendering = p.state { true } else { false } }
        #expect(p.canHostOriginal, "while the webp renders")
        p.hostOriginal()
        await h.drive { isDone(p) && p.hosting == .done }
        #expect(p.webpResult != nil && p.hostedOriginalURL != nil)
    }

    @Test func aFailedHostLeavesTheWebpAndCanBeRetried() async throws {
        let h = await ready()
        let p = h.pipeline
        p.makeWebp()
        await h.drive { isDone(p) }
        let result = try #require(p.webpResult)
        let attempts = Mutex(0)
        var stub = ScriptedClient(base: h.ctx.client)
        stub.publishSessionHook = { _ in
            let n = attempts.withLock { v -> Int in v += 1; return v }
            if n == 1 { throw CobaltError.network(.timedOut) }
            return HostedFile(url: URL(string: "https://media.capybaraharmony.com/PrEvIeW021.mp4")!, bytes: 1, contentType: "video/mp4", itemID: nil)
        }
        h.ctx.client = stub

        p.hostOriginal()
        await h.drive { p.hosting != .working }
        #expect(p.hosting == .failed(.unreachable))
        #expect(p.state == .done(result) && p.webpResult == result, "the webp is untouched")
        #expect(p.hostedOriginalURL == nil && p.canHostOriginal, "a failed attempt may be retried")

        p.hostOriginal()
        await h.drive { p.hosting == .done }
        #expect(p.hostedOriginalURL != nil && p.webpResult == result && attempts.withLock { $0 } == 2)
    }

    @Test func aFailedRenderKeepsTheHostedLinkAndCanBeRetried() async throws {
        let h = await ready(.renderLost)
        let p = h.pipeline
        p.hostOriginal()
        await h.drive { p.hosting == .done }
        let hosted = try #require(p.hostedOriginalURL)

        p.makeWebp()
        await h.drive { isFailed(p) }
        #expect(p.state == .failed(.renderLost))
        #expect(p.hostedOriginalURL == hosted && p.hosting == .done, "the share survives a failed render")
        #expect(p.webpResult == nil)
        #expect(p.canMakeWebp, "the trim is kept: try again")
        #expect(!p.canHostOriginal, "already hosted")
    }

    @Test func eachOfTheTwoRunsOnce() async throws {
        let h = await ready()
        let p = h.pipeline
        let publishes = Mutex(0)
        var stub = ScriptedClient(base: h.ctx.client)
        stub.publishSessionHook = { _ in
            publishes.withLock { $0 += 1 }
            return HostedFile(url: URL(string: "https://media.capybaraharmony.com/PrEvIeW021.mp4")!, bytes: 1, contentType: "video/mp4", itemID: nil)
        }
        h.ctx.client = stub
        p.hostOriginal()
        p.hostOriginal()                                      // a double tap while working
        await h.drive { p.hosting == .done }
        p.hostOriginal()                                      // and after it is done
        await h.settle()
        #expect(publishes.withLock { $0 } == 1)

        p.makeWebp()
        await h.drive { isDone(p) }
        let result = try #require(p.webpResult)
        p.makeWebp()                                          // .done: nothing to make again
        await h.settle()
        #expect(p.state == .done(result))
    }

    @Test func cancellingMidHostLeavesNothingStuckOnWorking() async throws {
        let h = await ready()
        let p = h.pipeline
        let gate = Gate()
        var stub = ScriptedClient(base: h.ctx.client)
        stub.publishSessionHook = { _ in
            await gate.wait()
            return HostedFile(url: URL(string: "https://media.capybaraharmony.com/late.mp4")!, bytes: 1, contentType: "video/mp4", itemID: nil)
        }
        h.ctx.client = stub
        p.hostOriginal()
        while await gate.waiting == 0 { await h.settle(); h.clock.advance() }
        #expect(p.hosting == .working)
        p.cancel()
        #expect(p.hosting == .idle, "a cancelled side job never reports back")
        await gate.open()
        await h.settle()
        #expect(p.hostedOriginalURL == nil, "the late answer belongs to a run that was stopped")
        #expect(p.canHostOriginal || p.state == .ready)
    }

    @Test func anImageCanBeSharedAsIs() async throws {
        let h = Harness(.image)
        let p = h.pipeline
        p.start(file: try makeTempFile("photo.png"))
        await h.driveToSettled()
        guard case .image = p.state else { Issue.record("expected .image"); return }
        #expect(p.canHostOriginal && !p.canMakeWebp)
    }

    @Test func plainCobaltOffersNeitherOfTheTwo() async throws {
        let h = Harness(.plainCobalt)
        let p = h.pipeline
        p.start(link: URL(string: pastedLink)!)
        await h.driveToSettled()
        #expect(!p.canHostOriginal && !p.canMakeWebp)
    }
}

// MARK: - Fetching an evicted item again

@MainActor
@Suite(.serialized)
struct RedownloadTests {
    private func evictedOriginal(
        _ h: Harness, session: String? = "PrEvIeWsession00000042", link: URL? = URL(string: shortLink),
        remote: URL? = nil, name: String = "twitter_2105435404002562056"
    ) async throws -> StoredVideo {
        let file = try makeTempFile("clip.mp4", bytes: 5_000)
        let video = try await h.ctx.store.add(
            file: file, kind: .original,
            media: MediaInfo(name: name, duration: 5.46, width: 480, height: 568, bytes: 5_000, isImage: false),
            sessionID: session, link: link, remoteURL: remote, move: true)
        await h.ctx.store.dropFilesKeepingPosters()
        let evicted = try #require(h.ctx.store.videos.first { $0.id == video.id })
        #expect(evicted.fileURL == nil)
        return evicted
    }

    final class RemoteLog: Sendable {
        private let items = Mutex<[RemoteFile]>([])
        func add(_ f: RemoteFile) { items.withLock { $0.append(f) } }
        var all: [RemoteFile] { items.withLock { $0 } }
    }

    private func calls() -> (log: RemoteLog, hook: @Sendable (RemoteFile, URL) async throws -> URL) {
        let log = RemoteLog()
        return (log, { file, dest in
            log.add(file)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 9, count: 7_000).write(to: dest)
            return dest
        })
    }

    @Test func theSessionsSourceRefillsTheExistingRecord() async throws {
        let h = Harness(.shortClip)
        let video = try await evictedOriginal(h)
        let c = calls()
        var stub = ScriptedClient(base: h.ctx.client)
        stub.downloadHook = c.hook
        h.ctx.client = stub
        let before = h.ctx.store.videos.count

        let refilled = try await h.app.library.redownload(video)
        #expect(refilled.id == video.id && refilled.name == video.name && refilled.sessionID == video.sessionID)
        let url = try #require(refilled.fileURL)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(refilled.bytes == 7_000)
        #expect(h.ctx.store.videos.count == before, "no duplicate record")
        #expect(h.ctx.store.videos.first { $0.id == video.id }?.fileURL == url)
        #expect(c.log.all == [.studioSource(session: "PrEvIeWsession00000042")])
        #expect(h.app.library.redownloads.isEmpty)
    }

    @Test func progressShowsWhileItDownloadsAndClearsAfterwards() async throws {
        let h = Harness(.shortClip)
        let video = try await evictedOriginal(h)
        let gate = Gate()
        var stub = ScriptedClient(base: h.ctx.client)
        stub.downloadProgressHook = { _, dest, progress in
            progress(TransferProgress(bytes: 2_500, total: 5_000))
            await gate.wait()
            try Data(repeating: 1, count: 5_000).write(to: dest)
            return dest
        }
        h.ctx.client = stub
        let library = h.app.library
        let task = Task { try await library.redownload(video) }
        while library.redownloads[video.id]?.bytes != 2_500 { await h.settle(); h.clock.advance() }
        #expect(library.redownloads[video.id]?.total == 5_000)
        await gate.open()
        let refilled = try await task.value
        #expect(refilled.fileURL != nil)
        #expect(library.redownloads[video.id] == nil)
    }

    @Test func aSecondRequestForTheSameEntryJoinsTheFirst() async throws {
        let h = Harness(.shortClip)
        let video = try await evictedOriginal(h)
        let gate = Gate()
        let count = Mutex(0)
        var stub = ScriptedClient(base: h.ctx.client)
        stub.downloadHook = { _, dest in
            count.withLock { $0 += 1 }
            await gate.wait()
            try Data(repeating: 1, count: 5_000).write(to: dest)
            return dest
        }
        h.ctx.client = stub
        let library = h.app.library
        async let one = library.redownload(video)
        async let two = library.redownload(video)
        while await gate.waiting == 0 { await h.settle(); h.clock.advance() }
        await gate.open()
        let (a, b) = try await (one, two)
        #expect(a == b)
        #expect(count.withLock { $0 } == 1)
    }

    @Test func anExpiredSessionFallsBackToTheLibrarysPrivateCopy() async throws {
        let h = Harness(.shortClip)
        let page = PreviewData.libraryPage(now: h.clock.now())
        let post = try #require(page.posts.first { $0.files.contains { $0.role == .privateCopy } })
        let file = try #require(post.files.first { $0.role == .privateCopy })
        let video = try await evictedOriginal(h, session: "PrEvIeWsession00000043", link: post.link)
        let c = calls()
        var stub = ScriptedClient(base: h.ctx.client)
        stub.downloadHook = { remote, dest in
            if case .studioSource = remote {
                c.log.add(remote)
                throw CobaltError.api(code: "error.studio.expired", httpStatus: 410)
            }
            return try await c.hook(remote, dest)
        }
        h.ctx.client = stub
        let refilled = try await h.app.library.redownload(video)
        #expect(refilled.fileURL != nil && refilled.id == video.id)
        #expect(c.log.all == [.studioSource(session: "PrEvIeWsession00000043"), .libraryItem(id: file.id)])
    }

    @Test func anOriginalWithOnlyItsFirstDownloadUrlUsesIt() async throws {
        let h = Harness(.shortClip)
        let tunnel = URL(string: "https://api.capybaraharmony.com/tunnel?id=PrEvIeWpick0")!
        let video = try await evictedOriginal(h, session: nil, link: nil, remote: tunnel)
        let c = calls()
        var stub = ScriptedClient(base: h.ctx.client)
        stub.downloadHook = c.hook
        h.ctx.client = stub
        _ = try await h.app.library.redownload(video)
        #expect(c.log.all == [.open(tunnel)])
    }

    @Test func aWebpComesBackFromItsPublicUrl() async throws {
        let h = Harness(.shortClip)
        let url = URL(string: "https://media.capybaraharmony.com/PrEvIeW001.webp")!
        let file = try makeTempFile("a.webp", bytes: 3_000)
        let stored = try await h.ctx.store.add(
            file: file, kind: .webp, media: MediaInfo(name: "x.webp", duration: 5, width: 480, height: 480, bytes: 3_000, isImage: false),
            sessionID: "PrEvIeWsession00000044", link: nil, remoteURL: url, move: true)
        await h.ctx.store.dropFilesKeepingPosters()
        let evicted = try #require(h.ctx.store.videos.first { $0.id == stored.id })
        let c = calls()
        var stub = ScriptedClient(base: h.ctx.client)
        stub.downloadHook = c.hook
        h.ctx.client = stub
        let refilled = try await h.app.library.redownload(evicted)
        #expect(refilled.fileURL?.pathExtension == "webp")
        #expect(c.log.all == [.open(url)], "a public file never goes through the studio")
    }

    @Test func whenNothingHasItAnymoreItIsExpiredAndNothingIsAttached() async throws {
        let h = Harness(.shortClip)
        let video = try await evictedOriginal(h, link: URL(string: "https://x.com/i/status/1")!)
        var stub = ScriptedClient(base: h.ctx.client)
        stub.downloadHook = { _, _ in throw CobaltError.api(code: "error.studio.expired", httpStatus: 410) }
        h.ctx.client = stub
        await #expect(throws: PipelineFailure.expired) { try await h.app.library.redownload(video) }
        #expect(h.ctx.store.videos.first { $0.id == video.id }?.fileURL == nil)
        #expect(h.app.library.redownloads.isEmpty)
    }

    @Test func offlineFailsAtOnceWithoutTryingTheOtherPlaces() async throws {
        let h = Harness(.shortClip)
        let video = try await evictedOriginal(h)
        let c = calls()
        var stub = ScriptedClient(base: h.ctx.client)
        stub.downloadHook = { remote, dest in
            c.log.add(remote)
            throw CobaltError.network(.notConnectedToInternet)
        }
        h.ctx.client = stub
        await #expect(throws: PipelineFailure.unreachable) { try await h.app.library.redownload(video) }
        #expect(c.log.all.count == 1)
        #expect(h.app.library.redownloads.isEmpty)
    }

    @Test func aRecordRemovedMeanwhileSaysSoAndLeavesNoFileBehind() async throws {
        let h = Harness(.shortClip)
        let video = try await evictedOriginal(h)
        let gate = Gate()
        var stub = ScriptedClient(base: h.ctx.client)
        stub.downloadHook = { _, dest in
            await gate.wait()
            try Data(repeating: 1, count: 5_000).write(to: dest)
            return dest
        }
        h.ctx.client = stub
        let library = h.app.library
        let task = Task { try await library.redownload(video) }
        while await gate.waiting == 0 { await h.settle(); h.clock.advance() }
        await h.ctx.store.remove(video.id)
        await gate.open()
        await #expect(throws: OfflineStoreError.notFound) { try await task.value }
    }

    @Test func anEntryThatIsAlreadyBackIsReturnedWithoutADownload() async throws {
        let h = Harness(.shortClip)
        let video = try await evictedOriginal(h)
        let c = calls()
        var stub = ScriptedClient(base: h.ctx.client)
        stub.downloadHook = c.hook
        h.ctx.client = stub
        let first = try await h.app.library.redownload(video)
        let again = try await h.app.library.redownload(video)
        #expect(again.fileURL == first.fileURL)
        #expect(c.log.all.count == 1)
    }
}
