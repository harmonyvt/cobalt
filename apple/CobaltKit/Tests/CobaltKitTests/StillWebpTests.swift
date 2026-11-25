import Foundation
import Testing
@testable import CobaltKit

// The animated webp of one photo (APP-API-CONTRACT 18.14): the plan and its wire body, the made file's kind and tab, the
// capability. Pure, plus one loopback read of /capabilities.

@Suite struct StillWebpPlanTests {
    @Test func theStillPlanIsOnePhotoAt640HighTwoSecondsNoFade() {
        let plan = SlideshowPlan.still(index: 3, quality: .high)
        #expect(plan.isStill && plan.format == .webp && plan.items == [3])
        #expect(plan.width == 640 && plan.quality == .high && plan.photoSeconds == 2 && !plan.fade && plan.sound == .none)
        #expect(GalleryMake.slideshow(plan).what == "animated webp")
        #expect(GalleryMake.slideshow(plan).madeKind == .still(item: 3))
        // a slideshow of two is not a still, and neither is an mp4 of one
        #expect(!SlideshowPlan(format: .webp, items: [0, 1]).isStill)
        #expect(!SlideshowPlan(format: .mp4, items: [0]).isStill)
    }

    @Test func theWireBodyIsThe18_14Body() throws {
        let plan = SlideshowPlan.still(index: 2, quality: .high)
        let body = plan.wireBody(items: [GalleryItem(id: 2, type: .photo)], includesQueue: true, focused: true)
        #expect(body["items"] as? [Int] == [2])
        #expect((body["seconds"] as? [Any])?.compactMap { $0 as? Double } == [2])
        #expect(body["format"] as? String == "webp" && body["width"] as? Int == 640 && body["quality"] as? String == "high")
        #expect(body["fade"] as? Bool == false && body["sound"] as? String == "none" && body["priority"] as? String == "focused")
    }

    @Test func checkTakesOnePhotoAndRefusesAVideo() {
        let plan = SlideshowPlan.still(index: 0, quality: .high)
        #expect(plan.check([GalleryItem(id: 0, type: .photo)]) == .ok)
        #expect(plan.check([GalleryItem(id: 0, type: .video, duration: 3)]) == .tooFew)
        #expect(plan.check([]) == .tooFew)
    }
}

@Suite struct StillWebpKindTests {
    private func spec(_ json: String) -> MadeSpec? { MadeSpec(data: Data(json.utf8)) }

    @Test func aStillRowIsItsOwnKindPerPhoto() {
        #expect(MadeKind(role: .slideshow, spec: spec(#"{"format":"webp","still":true,"items":[4]}"#)) == .still(item: 4))
        #expect(MadeKind(role: .slideshow, spec: spec(#"{"format":"webp","still":true}"#)) == .still(item: 0))
        // `still` on an mp4 means nothing; a webp without it is the slideshow webp
        #expect(MadeKind(role: .slideshow, spec: spec(#"{"format":"mp4","still":true,"items":[1]}"#)) == .slideshow(.mp4))
        #expect(MadeKind(role: .slideshow, spec: spec(#"{"format":"webp","items":[1]}"#)) == .slideshow(.webp))
        #expect(MadeKind.still(item: 2).tabName == "animated webp")
        #expect(MadeKind.still(item: 1) != MadeKind.still(item: 2))
        #expect(MadeKind.still(item: 1) != MadeKind.slideshow(.webp))
    }

    @Test @MainActor func theLocalSpecSaysStill() throws {
        let data = try #require(Pipeline.madeSpec(
            for: .slideshow(.still(index: 1, quality: .high)),
            result: MadeResult(job: "j", itemID: "x", bytes: 1, width: 640, height: 800, seconds: 2, format: .webp)))
        let spec = try #require(MadeSpec(data: data))
        #expect(spec.still && spec.items == [1] && spec.format == .webp)
        #expect(MadeKind(role: .slideshow, spec: spec) == .still(item: 1))
    }

    @Test func theRenditionIsAnAnimatedMadeWebp() {
        let r = Rendition(id: "m:x", kind: .animated(item: 2), createdAt: .distantPast)
        #expect(r.isMade && r.isAnimatedMade && r.isAnimatedStill && !r.isWebp)
        #expect(r.madeKind == .still(item: 2))
        #expect(r.tabName == "animated webp")
    }
}

@Suite(.serialized)
struct StillWebpCapabilityTests {
    @Test func still_webpIsReadAndNeedsGalleryMake() async throws {
        let on = try await LoopbackServer.start { _ in
            .json(#"{"server":"cobalt-cloudflare","features":{"studio":true,"line":true,"gallery":true,"gallery_make":true,"still_webp":true},"key":"valid"}"#)
        }
        defer { on.stop() }
        #expect(await HTTPCobaltClient(baseURL: on.base, apiKey: { "k" }).capabilities().stillWebp)
        let half = try await LoopbackServer.start { _ in
            .json(#"{"server":"cobalt-cloudflare","features":{"studio":true,"gallery":true,"still_webp":true},"key":"valid"}"#)
        }
        defer { half.stop() }
        #expect(!(await HTTPCobaltClient(baseURL: half.base, apiKey: { "k" }).capabilities().stillWebp))
    }
}

@Suite(.serialized) @MainActor
struct StillWebpUpdateTests {
    private func samplePhotoPost(id: String = "post-1", photoID: String = "photo-1", animatedID: String? = nil) -> LibraryPost {
        let photo = LibraryFile(
            id: photoID, kind: .private, source: .studio, name: "photo.jpg",
            url: URL(string: "https://media.example.com/\(photoID).jpg"),
            contentType: "image/jpeg", bytes: 120_000, width: 1071, height: 1464,
            duration: nil, createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            deletable: false, galleryRole: .item, itemIndex: 0
        )
        var files = [photo]
        if let animatedID {
            let spec = MadeSpec(data: Data(#"{"format":"webp","still":true,"items":[0]}"#.utf8))
            files.append(LibraryFile(
                id: animatedID, kind: .private, source: .studio, name: "photo-animated.webp",
                url: URL(string: "https://media.example.com/\(animatedID).webp"),
                contentType: "image/webp", bytes: 240_000, width: 640, height: 874,
                duration: 2, createdAt: Date(timeIntervalSince1970: 1_800_000_010),
                deletable: false, galleryRole: .slideshow, itemIndex: nil, madeFrom: [photoID], madeSpec: spec
            ))
        }
        return LibraryPost(
            id: id, link: URL(string: "https://x.com/frootybhai/status/1"),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            files: files, kind: .photo, itemCount: 1
        )
    }

    @Test func facePrefersAnimatedStillOverPhoto() throws {
        let before = try #require(MediaItem.merge(local: nil, post: samplePhotoPost(animatedID: nil)))
        #expect(!before.face.isAnimatedStill)
        #expect(before.face.isItem)

        let after = try #require(MediaItem.merge(local: nil, post: samplePhotoPost(animatedID: "anim-1")))
        #expect(after.made.count == 1)
        #expect(after.made[0].isAnimatedStill)
        #expect(after.face.id == "m:anim-1")
        #expect(after.face.isAnimatedStill)
    }

    @Test func reopenedAnimatedWebpJoinsOriginalPostByLibraryID() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("still-webp-join-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = OfflineStore(root: dir)
        let tmp = dir.appendingPathComponent("anim.webp")
        try Data("RIFF0000WEBP".utf8).write(to: tmp)
        let specData = Data(#"{"format":"webp","still":true,"items":[0]}"#.utf8)
        let info = MediaInfo(name: "x · @frootybhai", duration: 2, width: 640, height: 874, bytes: 12, isImage: true)

        _ = try await store.add(
            file: tmp, kind: .webp, media: info, sessionID: "reopened-session-999",
            link: nil, remoteURL: nil, move: false,
            publicURL: URL(string: "https://media.example.com/anim-1.webp"),
            keep: true, role: .slideshow, madeFrom: [0], madeSpec: specData, libraryID: "anim-1"
        )

        let post = samplePhotoPost(id: "original-post-1", photoID: "photo-1", animatedID: "anim-1")
        let local = try #require(store.media.first)
        #expect(MediaItem.joins(local, post))
        #expect(store.media(joining: post)?.id == local.id)
        #expect(LibraryMediaJoin(media: store.media, localTitles: [:]).media(joining: post)?.id == local.id)
    }

    @Test func makeAnimatedWebpTracksJobUpdatesPostAndFace() async throws {
        let h = Harness(.galleryOne)
        let app = h.app
        h.pipeline.start(link: URL(string: "https://x.com/frootybhai/status/2106850389551374807")!)
        await h.driveToSettled()
        let sid = try #require(h.pipeline.sessionID)
        // Dismiss the initial save job so makeAnimatedWebp opens a dedicated make job on the queue.
        if let initial = app.queue.galleryJob(session: sid) { app.queue.dismiss(initial.id) }
        await app.library.refresh()
        let post = try #require(app.library.posts.first { $0.id == sid })
        let item = app.mediaItem(for: post)
        let photo = try #require(item.items.first)
        #expect(app.canMakeAnimatedWebp(of: photo, in: item))

        let job = try await app.makeAnimatedWebp(of: photo, in: item)
        #expect(job.via == .make)
        #expect(job.pipeline.targetPostKey == post.id)
        #expect(app.animatedWebpJob(for: photo, in: item)?.id == job.id)
        #expect(app.isBusy(item))

        // Re-requesting while active reuses the same job instead of spawning a duplicate.
        let again = try await app.makeAnimatedWebp(of: photo, in: item)
        #expect(again.id == job.id)

        await h.drive(until: { !job.isLive })
        #expect(job.isFinished && !job.isFailed)
        #expect(!app.isBusy(item))

        await app.library.refresh()
        let updatedPost = try #require(app.library.posts.first { $0.id == sid })
        let updated = app.mediaItem(for: updatedPost)
        #expect(updated.made.count == 1)
        #expect(updated.made[0].isAnimatedStill)
        #expect(updated.made[0].local != nil)
        #expect(updated.face.isAnimatedStill)
    }

    @Test func failedMakeJobReportsFailedNotFinished() async throws {
        let h = Harness(.galleryOne)
        let app = h.app
        let photo = GalleryItem(id: 0, type: .photo, width: 640, height: 800)
        let make = GalleryMake.slideshow(SlideshowPlan.still(index: 0, quality: .high))
        let job = app.queue.addGallery(
            .make(make), session: "dead-session", items: [photo], media: nil, link: nil,
            mediaID: nil, postKey: "post-1"
        )
        var run = GalleryRun(total: 1)
        run.phase = .saved
        run.done = 1
        run.make = .failed(make, .serverBusy)
        job.pipeline.galleryRun = run
        #expect(job.isFailed)
        #expect(!job.isFinished)
    }

    @Test func libraryRefreshCoalescesConcurrentRequests() async throws {
        let firstStarted = AsyncStream<Void>.makeStream()
        let releaseFirst = DispatchSemaphore(value: 0)
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            var count = 0
            func next() -> Int {
                lock.lock(); defer { lock.unlock() }
                count += 1
                return count
            }
        }
        let counter = Counter()

        let server = try await LoopbackServer.start { req in
            guard req.path.hasPrefix("/library") else {
                return .json(#"{"server":"cobalt-cloudflare","features":{"studio":true,"gallery":true},"key":"valid"}"#)
            }
            let n = counter.next()
            if n == 1 {
                firstStarted.continuation.yield()
                _ = releaseFirst.wait(timeout: .now() + 5)
                return .json(#"{"posts":[{"id":"p1","created_at":1800000000000,"kind":"photo","item_count":1,"files":[{"id":"f1","kind":"private","source":"studio","name":"p.jpg","content_type":"image/jpeg","created_at":1800000000000,"role":"item","item_index":0}]}],"post_count":1,"file_count":1}"#)
            }
            return .json(#"{"posts":[{"id":"p1","created_at":1800000000000,"kind":"photo","item_count":1,"files":[{"id":"f1","kind":"private","source":"studio","name":"p.jpg","content_type":"image/jpeg","created_at":1800000000000,"role":"item","item_index":0},{"id":"m1","kind":"private","source":"studio","name":"p-animated.webp","content_type":"image/webp","created_at":1800000010000,"role":"slideshow","made_spec":{"format":"webp","still":true,"items":[0]}}]}],"post_count":1,"file_count":2}"#)
        }
        defer {
            releaseFirst.signal()
            server.stop()
        }

        let suite = UserDefaults(suiteName: "still-webp-refresh-\(UUID().uuidString)")!
        let base = AppModel.makePreview(.emptyOrbit, timeScale: 1, clock: SystemClock()).ctxForTests
        base.client = HTTPCobaltClient(baseURL: server.base, apiKey: { "k" })
        base.settings.syncEngine = false
        let library = LibraryModel(context: base, defaults: suite)

        let t1 = Task { await library.refreshFromServer() }
        for await _ in firstStarted.stream { break }

        // A second refresh arrives while the first is still waiting on the server.
        let t2 = Task { await library.refreshFromServer() }
        try? await Task.sleep(for: .milliseconds(30))
        releaseFirst.signal()

        await t1.value
        await t2.value

        #expect(counter.next() == 3, "both the initial load and the coalesced refresh should have run")
        #expect(library.posts.first?.files.count == 2)
        #expect(library.posts.first?.files.contains { $0.id == "m1" } == true)
    }
}

