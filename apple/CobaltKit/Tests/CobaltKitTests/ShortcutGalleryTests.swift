import Foundation
import Synchronization
import Testing
@testable import CobaltKit

// The Shortcuts actions and galleries (apple/CONTRACT-GALLERY.md 1.13, 27; CONTRACT-PARALLEL.md section 15): `Save links` with
// the `Galleries` and `Layout` parameters, `CobaltSave`'s kind / itemCount / itemLinks / madeLinks, and `Get latest saves`
// by kind. The save and the make run on `PreviewClient`'s gallery scenarios with the server's line and a virtual clock.

private let igLink = URL(string: "https://www.instagram.com/p/Ddy0-gpGg5U/")!
private let mixedLink = URL(string: "https://www.instagram.com/p/DdMix1xedPo/")!
private let oneLink = URL(string: "https://x.com/ilokineedsleep/status/2106850389551374807")!
private let reelLink = URL(string: "https://www.instagram.com/reel/Dd7P496wolG/")!

/// A preview app on one of the gallery scenarios with the server's line, the Shortcuts actions over it and a virtual clock.
@MainActor
private struct GalleryRig {
    let clock = VirtualClock()
    let app: AppModel
    let base: PreviewClient
    let wrapper: ForwardingClient
    let actions: ShortcutActions
    let clipboard = FakeShortcutClipboard()
    let activity = ShortcutFakeActivity()

    init(_ scenario: PreviewScenario, active: Bool = true, tweak: ((inout ForwardingClient) -> Void)? = nil) {
        let ctx = PipelineContext.preview(scenario, timeScale: 1, clock: clock)
        let base = PreviewClient(scenario: scenario, timeScale: 1, clock: clock, line: .server)
        var wrapper = ForwardingClient(base: base)
        tweak?(&wrapper)
        ctx.client = wrapper
        var caps = ctx.capabilities
        caps.line = true
        ctx.capabilities = caps
        ctx.settings.autoContinue = false
        activity.isActive = active
        ctx.background.activity = activity
        let app = AppModel(
            context: ctx, library: LibraryModel(context: ctx, seed: PreviewData.libraryPage(now: clock.now())),
            photosSync: PhotosSync.preview(.init(access: .album, enabled: false)), makeClient: { _ in wrapper })
        app.queue.trayIsShown = true
        self.app = app
        self.base = base
        self.wrapper = wrapper
        self.actions = ShortcutActions(model: app, clipboard: clipboard)
    }

    var queue: JobQueue { app.queue }
    var ctx: PipelineContext { app.ctx }
    func count(_ call: String) -> Int { base.server.lineCalls.filter { $0 == call }.count }

    /// What the preview server was asked, by call name ("create", "slideshow", "gallery-image").
    func calls(_ name: String) -> [String] { base.galleries.calls.filter { $0.name == name }.map(\.detail) }

    func settle() async {
        var last = clock.registrations
        var stable = 0
        while stable < 4 {
            try? await Task.sleep(for: .milliseconds(1))
            let r = clock.registrations
            if r == last { stable += 1 } else { stable = 0; last = r }
        }
    }

    /// Runs virtual time forward until `condition` holds (or `maxVirtualSeconds` of it pass).
    func drive(until condition: @MainActor () -> Bool, maxVirtualSeconds: Double = 600) async {
        let start = clock.elapsed
        var idle = 0
        while !condition(), clock.elapsed - start < maxVirtualSeconds {
            await settle()
            if condition() { return }
            if clock.advance() { idle = 0 } else {
                idle += 1
                if idle > 30 { return }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    /// Runs `operation` while virtual time moves, until it answers.
    func run<T: Sendable>(maxVirtualSeconds: Double = 600, _ operation: @escaping @MainActor () async throws -> T) async -> Result<T, Error> {
        var result: Result<T, Error>?
        let task = Task { @MainActor in
            do { result = .success(try await operation()) } catch { result = .failure(error) }
        }
        await drive(until: { result != nil }, maxVirtualSeconds: maxVirtualSeconds)
        if result == nil { task.cancel(); await drive(until: { result != nil }, maxVirtualSeconds: 5) }
        await task.value
        return result ?? .failure(ShortcutTimedOut())
    }

    /// "Save links" with `Wait until saved`: the hand-over, then the wait (through the make when one was asked for).
    func saveAndWait(
        _ link: URL = igLink, galleries: ShortcutGalleries = .everything, layout: GalleryLayout = .grid3,
        cancel: ShortcutCancel = ShortcutCancel(), progress: ShortcutProgress? = nil
    ) async -> Result<ShortcutSaveOutcome, Error> {
        await run {
            let handed = try await actions.saveLinks(
                [link.absoluteString], visibility: .public, galleries: galleries, layout: layout, then: .wait)
            return try await actions.waitUntilSaved(handed, cancel: cancel, progress: progress)
        }
    }
}

// MARK: - The parameters

struct ShortcutGalleriesTests {
    @Test func theDefaultSavesEverythingAndAsksNothingOfTheJob() {
        #expect(ShortcutGalleries.everything.handling(layout: .strip) == nil, "JobOptions' own default is `.saveAll`")
        #expect(ShortcutGalleries.firstVideo.handling(layout: .grid3) == .firstVideo)
        #expect(ShortcutGalleries.slideshowWebp.handling(layout: .strip) == .slideshowWebp, "a slideshow has no layout")
        for layout in GalleryLayout.allCases {
            #expect(ShortcutGalleries.galleryImage.handling(layout: layout) == .galleryImage(layout))
        }
    }

    @Test func onlyTheTwoMakesMake() {
        #expect(ShortcutGalleries.allCases.filter(\.makes) == [.slideshowWebp, .galleryImage])
        #expect(ShortcutGalleries.slideshowWebp.what == "slideshow webp" && ShortcutGalleries.galleryImage.what == "gallery image")
        #expect(ShortcutGalleries.everything.what == nil && ShortcutGalleries.firstVideo.what == nil)
    }

    @Test func theKindsOfLatestSavesAreTheLibrarysChips() {
        #expect(ShortcutSaveKind.allCases.map(\.rawValue) == ["anything", "videos", "photos", "galleries", "webps"])
        #expect(ShortcutMediaKind.allCases.map(\.rawValue) == ["video", "photo", "gallery"])
    }
}

// MARK: - Save links

@MainActor
struct ShortcutGallerySaveTests {
    @Test func aGalleryIsSavedWholeByDefaultAndNothingIsMade() async throws {
        let t = GalleryRig(.galleryInstagram)
        let outcome = try await t.saveAndWait().get()
        #expect(t.calls("create") == ["items=all count=- queue=true"], "no resolve first, no choice: everything")
        #expect(t.calls("slideshow").isEmpty && t.calls("gallery-image").isEmpty)
        #expect(t.base.server.lineCalls.contains("POST /") == false)
        let save = try #require(outcome.saves.first)
        #expect(save.state == .saved && save.kind == .gallery && save.itemCount == 10)
        #expect(save.itemLinks.count == 10, "one public link per photo")
        #expect(save.itemLinks.map(\.pathExtension) == Array(repeating: "jpg", count: 10))
        #expect(save.madeLinks.isEmpty && save.webpLinks.isEmpty && !save.hasVideo)
        #expect(save.publicLink == save.itemLinks.first, "the lead item stands in for the original")
        #expect(outcome.makeFailures.isEmpty && save.itemsFailed == 0)
        #expect(t.count("PUT line/notify") == 0)
    }

    @Test func aPrivateGalleryHasNoLinksButStillSaysWhatItIs() async throws {
        let t = GalleryRig(.galleryX)
        let outcome = try await t.run {
            let handed = try await t.actions.saveLinks(["https://x.com/ilokineedsleep/status/2106850389551374806"], visibility: .private, then: .wait)
            return try await t.actions.waitUntilSaved(handed)
        }.get()
        let save = try #require(outcome.saves.first)
        #expect(save.kind == .gallery && save.itemCount == 4 && save.itemLinks.isEmpty && save.publicLink == nil)
        #expect(save.title == "x · @ilokineedsleep")
    }

    @Test func theHandOverDoesNotKnowTheKindYet() async throws {
        let t = GalleryRig(.galleryInstagram)
        let outcome = try await t.run { try await t.actions.saveLinks([igLink.absoluteString]) }.get()
        let save = try #require(outcome.saves.first)
        #expect(save.kind == nil && save.itemCount == nil && save.itemLinks.isEmpty && save.madeLinks.isEmpty, "unknown, not guessed")
        #expect(save.state == .saving || save.state == .queued)
    }

    @Test func firstVideoOnlyAsksTheServerForTodaysRule() async throws {
        let t = GalleryRig(.galleryMixed)
        _ = try await t.run { try await t.actions.saveLinks([mixedLink.absoluteString], galleries: .firstVideo) }.get()
        #expect(t.calls("create") == ["items=first-video count=- queue=true"])
        #expect(t.calls("slideshow").isEmpty)
    }

    @Test func aSlideshowWebpIsMadeBehindTheSaveAndItsLinkComesBack() async throws {
        let t = GalleryRig(.galleryInstagram)
        var steps: [(Int64, Int64)] = []
        let outcome = try await t.saveAndWait(galleries: .slideshowWebp, progress: { steps.append(($0, $1)) }).get()
        #expect(t.calls("create") == ["items=all count=- queue=true"])
        let asked = t.calls("slideshow")
        #expect(asked.count == 1)
        #expect(asked[0].hasPrefix("webp 0,1,2,3,4,5,6,7,8,9 2.0,2.0,2.0,2.0,2.0,2.0,2.0,2.0,2.0,2.0 fade=true frame=keep"), "\(asked)")
        let save = try #require(outcome.saves.first)
        #expect(save.kind == .gallery && save.itemLinks.count == 10)
        #expect(save.madeLinks.count == 1 && save.madeLinks[0].pathExtension == "webp")
        #expect(save.webpLinks.isEmpty, "a slideshow webp is a made file, not one of the post's webps")
        #expect(outcome.makeFailures.isEmpty)
        // saved, then made: two steps a save, growing, ending at the total
        #expect(steps.first?.0 == 0 && steps.last?.0 == 2 && steps.allSatisfy { $0.1 == 2 })
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $0.0 <= $1.0 }, "never goes back: \(steps)")
    }

    @Test func aGalleryImageIsMadeInTheLayoutAsked() async throws {
        let t = GalleryRig(.galleryInstagram)
        let outcome = try await t.saveAndWait(galleries: .galleryImage, layout: .strip).get()
        #expect(t.calls("gallery-image") == ["strip 0,1,2,3,4,5,6,7,8,9 focused=true"])
        let save = try #require(outcome.saves.first)
        #expect(save.madeLinks.count == 1 && save.madeLinks[0].pathExtension == "jpg")
        #expect(outcome.makeFailures.isEmpty)
    }

    @Test func theGalleryImageDefaultsToThreeAcross() async throws {
        let t = GalleryRig(.galleryX)
        _ = try await t.saveAndWait(URL(string: "https://x.com/ilokineedsleep/status/2106850389551374806")!, galleries: .galleryImage).get()
        #expect(t.calls("gallery-image").first?.hasPrefix("grid3 0,1,2,3") == true)
    }

    @Test func aMixedPostMakesAGalleryImageOfItsPhotosOnly() async throws {
        let t = GalleryRig(.galleryMixed)
        let outcome = try await t.saveAndWait(mixedLink, galleries: .galleryImage, layout: .grid2).get()
        #expect(t.calls("gallery-image") == ["grid2 0,1 focused=true"], "the video and the gif are left out")
        let save = try #require(outcome.saves.first)
        #expect(save.kind == .gallery && save.itemCount == 4 && save.hasVideo, "a video item is what Make webp needs")
        #expect(save.madeLinks.count == 1)
    }

    @Test func aServerThatCannotMakeIsToldBeforeAnythingIsSaved() async {
        let t = GalleryRig(.galleryNoMake)
        for galleries in [ShortcutGalleries.slideshowWebp, .galleryImage] {
            let result = await t.run { try await t.actions.saveLinks([igLink.absoluteString], galleries: galleries) }
            #expect(throws: ShortcutError.failed(.unsupported)) { try result.get() }
        }
        #expect(t.queue.jobs.isEmpty && t.calls("create").isEmpty, "nothing queued")
        // saving everything on that server still works
        let saved = await t.run { try await t.actions.saveLinks([igLink.absoluteString]) }
        #expect((try? saved.get().saves.count) == 1)
    }

    @Test func aMakeThatFailsKeepsTheSaveAndSaysWhy() async throws {
        let t = GalleryRig(.galleryMakeFails)
        let outcome = try await t.saveAndWait(galleries: .slideshowWebp).get()
        let save = try #require(outcome.saves.first)
        #expect(save.state == .saved && save.itemLinks.count == 10 && save.madeLinks.isEmpty, "the photos are saved and untouched")
        let failure = try #require(outcome.makeFailures.first)
        #expect(outcome.makeFailures.count == 1 && failure.what == "slideshow webp" && failure.title == save.title)
        guard case .server(let code) = failure.failure else { Issue.record("\(failure.failure)"); return }
        #expect(code.hasPrefix(PipelineFailure.renderPhasePrefix) && code.hasSuffix("encode_failed"), "\(code)")
        #expect(!outcome.isPartial, "the save itself went: this is not a partial save")
    }

    @Test func aGalleryImageOfOnePhotoSaysItNeedsTwo() async throws {
        let t = GalleryRig(.galleryOne)
        let outcome = try await t.saveAndWait(oneLink, galleries: .galleryImage).get()
        #expect(t.calls("gallery-image").isEmpty, "nothing is sent for a plan the caps refuse")
        let save = try #require(outcome.saves.first)
        #expect(save.kind == .photo && save.itemCount == 1 && save.itemLinks.count == 1 && save.madeLinks.isEmpty)
        #expect(outcome.makeFailures.first?.failure == .server(code: "render.error.studio.too_few_photos"))
    }

    @Test func aPartialSaveSaysHowManyItemsCameOver() async throws {
        let t = GalleryRig(.galleryPartial)
        let outcome = try await t.saveAndWait().get()
        let save = try #require(outcome.saves.first)
        #expect(save.kind == .gallery && save.itemCount == 9 && save.itemsFailed == 1 && save.itemLinks.count == 9)
    }

    @Test func aLinkThatIsNotAGalleryIsJustSavedAndNothingIsMade() async throws {
        // a server with galleries and a reel: the post turns out to be one video
        let t = ShortcutRig(.server) {
            $0.capsHook = { caps in caps.gallery = true; caps.galleryMake = true }
        }
        let outcome = try await t.run {
            let handed = try await t.actions.saveLinks([reelLink.absoluteString], visibility: .public, galleries: .slideshowWebp, then: .wait)
            return try await t.actions.waitUntilSaved(handed)
        }.get()
        #expect(outcome.saves.count == 1 && outcome.saves[0].state == .saved)
        #expect(outcome.makeFailures.isEmpty)
        #expect(t.wrapper.renders.all.isEmpty)
    }

    @Test func theStopButtonDuringTheMakeStopsTheMakeAndThrowsCancellation() async throws {
        let t = GalleryRig(.galleryInstagram, active: false)
        let cancel = ShortcutCancel()
        var asked = false
        let result = await t.run {
            let handed = try await t.actions.saveLinks(
                [igLink.absoluteString], visibility: .public, galleries: .slideshowWebp, then: .wait)
            let job = t.queue.jobs.first
            // the stop button is pressed the moment the make is in flight
            let watcher = Task { @MainActor in
                while !(job?.pipeline.galleryRun?.make.isActive ?? false), !Task.isCancelled {
                    try? await t.ctx.clock.sleep(seconds: 0.1)
                }
                asked = true
                cancel.cancel()
            }
            defer { watcher.cancel() }
            return try await t.actions.waitUntilSaved(handed, cancel: cancel)
        }
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(asked, "the make had started before the stop")
    }
}

// MARK: - What a library post says (CobaltSave's fields)

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func file(
    _ id: String, _ type: String, role: GalleryRole? = nil, index: Int? = nil, public isPublic: Bool = true, at offset: Double = 0,
    spec: MadeSpec? = nil
) -> LibraryFile {
    let ext = type.hasPrefix("video/") ? "mp4" : (type == "image/webp" ? "webp" : "jpg")
    // a webp of a video is a public file; everything else keeps its bytes private (and may be public by `visibility`)
    var f = LibraryFile(
        id: id, kind: type == "image/webp" && role == nil ? .public : .private, source: role == nil ? .saved : .studio, name: id,
        url: isPublic ? URL(string: "https://media.capybaraharmony.com/\(id).\(ext)") : nil, contentType: type, bytes: 1000,
        width: 1080, height: 1350, duration: type.hasPrefix("video/") ? 4 : nil, createdAt: now.addingTimeInterval(offset),
        mediaName: nil, deletable: false)
    f.wireVisibility = isPublic ? .public : .private
    f.galleryRole = role
    f.itemIndex = index
    f.madeSpec = spec
    return f
}

private func post(
    _ id: String, files: [LibraryFile], kind: MediaKind? = nil, count: Int? = nil, failed: [Int] = [], at offset: Double = 0
) -> LibraryPost {
    var p = LibraryPost(
        id: id, service: "instagram", link: URL(string: "https://www.instagram.com/p/\(id)/"), title: "instagram_\(id)", duration: nil,
        width: 1080, height: 1350, createdAt: now.addingTimeInterval(offset), session: nil, files: files)
    p.kind = kind
    p.itemCount = count
    p.itemsFailed = failed
    return p
}

struct ShortcutSavePostTests {
    private func gallery(isPublic: Bool = true) -> LibraryPost {
        post("Gal1", files: [
            file("it2", "image/jpeg", role: .item, index: 2, public: isPublic),
            file("it0", "image/jpeg", role: .item, index: 0, public: isPublic),
            file("it1", "image/jpeg", role: .item, index: 1, public: isPublic),
            file("mp4", "video/mp4", role: .slideshow, public: isPublic, at: 10, spec: MadeSpec(format: .mp4, items: [0, 1, 2])),
            file("img", "image/jpeg", role: .export, public: isPublic, at: 20, spec: MadeSpec(kind: "gallery", layout: .grid3, items: [0, 1, 2])),
            file("web", "image/webp", role: .slideshow, public: isPublic, at: 30, spec: MadeSpec(format: .webp, items: [0, 1, 2])),
        ], kind: .gallery, count: 3, failed: [3, 4])
    }

    @Test func aGalleryPostGivesItsItemsInOrderAndWhatWasMadeNewestFirst() throws {
        let save = ShortcutSave(post: gallery())
        #expect(save.kind == .gallery && save.itemCount == 3 && save.itemsFailed == 2)
        #expect(save.itemLinks.map(\.lastPathComponent) == ["it0.jpg", "it1.jpg", "it2.jpg"], "the post's order, not the file list's")
        #expect(save.madeLinks.map(\.lastPathComponent) == ["web.webp", "img.jpg", "mp4.mp4"], "newest first")
        #expect(save.publicLink?.lastPathComponent == "it0.jpg")
        #expect(save.webpLinks.isEmpty, "a slideshow webp is made, not one of the post's webps")
        #expect(!save.hasVideo, "a slideshow mp4 does not make a photo gallery a video")
    }

    @Test func aPrivateGalleryHasNoLinks() {
        let save = ShortcutSave(post: gallery(isPublic: false))
        #expect(save.kind == .gallery && save.itemCount == 3 && save.itemLinks.isEmpty && save.madeLinks.isEmpty && save.publicLink == nil)
    }

    @Test func aVideoItemIsWhatMakeWebpNeeds() {
        let mixed = post("Mix1", files: [
            file("a", "image/jpeg", role: .item, index: 0), file("b", "video/mp4", role: .item, index: 1),
            file("c", "image/gif", role: .item, index: 2),
        ], kind: .gallery, count: 3)
        let save = ShortcutSave(post: mixed)
        #expect(save.kind == .gallery && save.hasVideo && save.itemLinks.count == 3)
        let gifOnly = post("Gif1", files: [file("a", "image/jpeg", role: .item, index: 0), file("c", "image/gif", role: .item, index: 1)], kind: .gallery, count: 2)
        #expect(!ShortcutSave(post: gifOnly).hasVideo, "the server renders a gallery's first video, not a gif")
    }

    @Test func aSinglePostIsOneItemWithItsOwnLink() {
        let photo = ShortcutSave(post: post("Ph1", files: [file("p", "image/jpeg")], kind: .photo, count: 1))
        #expect(photo.kind == .photo && photo.itemCount == 1 && photo.itemLinks.map(\.lastPathComponent) == ["p.jpg"] && !photo.hasVideo)
        let video = ShortcutSave(post: post("Vi1", files: [file("v", "video/mp4")], kind: .video))
        #expect(video.kind == .video && video.itemCount == 1 && video.itemLinks.map(\.lastPathComponent) == ["v.mp4"] && video.hasVideo)
        #expect(video.publicLink == video.itemLinks.first)
    }

    @Test func aCropOfAPhotoIsAMadeLink() {
        let cropped = ShortcutSave(post: post("Ph2", files: [file("p", "image/jpeg"), file("crop", "image/jpeg", role: .crop, at: 5)], kind: .photo, count: 1))
        #expect(cropped.kind == .photo && cropped.madeLinks.map(\.lastPathComponent) == ["crop.jpg"] && cropped.itemLinks.map(\.lastPathComponent) == ["p.jpg"])
    }

    @Test func aServerWithoutKindsIsReadFromItsFiles() {
        // a library read without `v=3` names no kind: a video original is a video, an image upload a photo, 2+ items a gallery
        #expect(ShortcutSave(post: post("A", files: [file("v", "video/mp4")])).kind == .video)
        #expect(ShortcutSave(post: post("B", files: [file("p", "image/png")])).kind == .photo)
        #expect(ShortcutSave(post: post("C", files: [file("g", "image/gif")])).kind == .video, "a gif is the video flow's")
        #expect(ShortcutSave(post: post("D", files: [file("a", "image/jpeg", role: .item, index: 0), file("b", "image/jpeg", role: .item, index: 1)])).kind == .gallery)
        // a post that is only webps is an animated thing, not a photo
        #expect(ShortcutSave(post: post("E", files: [file("w", "image/webp", role: .slideshow)], kind: .webp)).kind == .video)
    }

    @Test func aSessionSaysWhatItIsOnceReady() {
        func session(_ status: SessionStatus, count: Int?, items: [SessionItem]) -> ShortcutSave {
            var s = StudioSession(
                id: "S1", status: status, link: "https://www.instagram.com/p/Ddy0-gpGg5U/", service: "instagram", title: nil, duration: nil,
                width: nil, height: nil, bytes: nil, createdAt: now, expiresAt: now.addingTimeInterval(86_400), errorCode: nil, renders: [],
                step: nil, stepBytes: nil, stepTotal: nil, waking: nil)
            s.itemCount = count
            s.items = items
            return ShortcutSave(session: s)
        }
        let photos = (0..<3).map { SessionItem(i: $0, type: .photo, status: .ready, code: nil) }
        let gallery = session(.ready, count: 3, items: photos)
        #expect(gallery.kind == .gallery && gallery.itemCount == 3 && !gallery.hasVideo)
        let withVideo = session(.ready, count: 2, items: [photos[0], SessionItem(i: 1, type: .video, status: .ready, code: nil)])
        #expect(withVideo.kind == .gallery && withVideo.hasVideo)
        #expect(session(.ready, count: 1, items: [photos[0]]).kind == .photo)
        #expect(session(.saving, count: nil, items: []).kind == nil, "not saved yet: unknown")
        #expect(session(.ready, count: nil, items: []).kind == nil && session(.ready, count: nil, items: []).hasVideo, "an older server: as before")
    }
}

// MARK: - Get latest saves by kind

@MainActor
struct ShortcutGalleryLatestTests {
    private func rig() -> ShortcutRig {
        let video = post("Vid1", files: [file("v", "video/mp4"), file("w", "image/webp")], at: 1)
        let photo = post("Pho1", files: [file("p", "image/jpeg")], kind: .photo, count: 1, at: 2)
        let gallery = post("Gal1", files: [
            file("a", "image/jpeg", role: .item, index: 0), file("b", "image/jpeg", role: .item, index: 1),
            file("m", "video/mp4", role: .slideshow, at: 9),
        ], kind: .gallery, count: 2, at: 3)
        let slideshowWebp = post("Gal2", files: [
            file("c", "image/jpeg", role: .item, index: 0), file("d", "image/jpeg", role: .item, index: 1),
            file("s", "image/webp", role: .slideshow, at: 9, spec: MadeSpec(format: .webp, items: [0, 1])),
        ], kind: .gallery, count: 2, at: 4)
        let plain = post("Vid2", files: [file("v2", "video/mp4")], at: 0)
        return ShortcutRig(.server) {
            $0.libraryHook = { LibraryPage(posts: [video, photo, gallery, slideshowWebp, plain], postCount: 5, fileCount: 12, publicBytes: 0, privateBytes: 0, next: nil) }
        }
    }

    private func ids(_ t: ShortcutRig, _ kind: ShortcutSaveKind) async throws -> [String] {
        try await t.run { try await t.actions.latestSaves(count: 20, kind: kind) }.get().map(\.id)
    }

    @Test func eachKindIsItsOwnChip() async throws {
        let t = rig()
        #expect(try await ids(t, .anything) == ["Gal2", "Gal1", "Pho1", "Vid1", "Vid2"], "newest first")
        #expect(try await ids(t, .videos) == ["Vid1", "Vid2"], "a gallery with a slideshow mp4 is not a video")
        #expect(try await ids(t, .photos) == ["Pho1"])
        #expect(try await ids(t, .galleries) == ["Gal2", "Gal1"])
        #expect(try await ids(t, .webps) == ["Gal2", "Vid1"], "a webp of a video, or a slideshow webp")
    }

    @Test func theLatestGalleryCarriesItsLinks() async throws {
        let t = rig()
        let saves = try await t.run { try await t.actions.latestSaves(count: 1, kind: .galleries) }.get()
        let save = try #require(saves.first)
        #expect(save.id == "Gal2" && save.kind == .gallery && save.itemCount == 2)
        #expect(save.itemLinks.map(\.lastPathComponent) == ["c.jpg", "d.jpg"] && save.madeLinks.map(\.lastPathComponent) == ["s.webp"])
    }

    @Test func theLibraryIsReadInTheNewestShapeTheServerSpeaks() async throws {
        let t = GalleryRig(.galleryInstagram)
        // a gallery server asks for `v=3` (items and made files): it lists the gallery just saved
        _ = try await t.saveAndWait(galleries: .galleryImage).get()
        let saves = try await t.run { try await t.actions.latestSaves(count: 1, kind: .galleries) }.get()
        #expect(saves.first?.itemCount == 10 && saves.first?.madeLinks.count == 1 && saves.first?.itemLinks.count == 10)
    }
}

// MARK: - Make webp on a gallery

@MainActor
struct ShortcutGalleryWebpTests {
    @Test func aPhotoGalleryHasNoVideoToMakeAWebpOf() async throws {
        let t = GalleryRig(.galleryInstagram)
        let outcome = try await t.saveAndWait().get()
        let id = try #require(outcome.saves.first?.id)
        let result = await t.run { try await t.actions.makeWebp(of: id) }
        #expect(throws: ShortcutError.noVideo) { try result.get() }
    }

    @Test func aGalleryCannotBeOpenedAgainOnceItsSessionIsGone() async throws {
        let gallery = post("Mix1", files: [
            file("a", "image/jpeg", role: .item, index: 0), file("b", "video/mp4", role: .item, index: 1),
        ], kind: .gallery, count: 2)
        let t = ShortcutRig(.server) {
            $0.libraryHook = { LibraryPage(posts: [gallery], postCount: 1, fileCount: 2, publicBytes: 0, privateBytes: 0, next: nil) }
        }
        t.rig.app.library.reset()
        let result = await t.run { try await t.actions.makeWebp(of: "Mix1") }
        #expect(throws: ShortcutError.failed(.expired)) { try result.get() }
        #expect(t.calls.filter { $0.hasPrefix("POST library/items/") }.isEmpty && t.calls.filter { $0.hasPrefix("POST render") }.isEmpty)
    }
}
