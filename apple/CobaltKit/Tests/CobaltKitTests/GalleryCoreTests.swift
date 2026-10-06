import CoreGraphics
import Foundation
import Testing
@testable import CobaltKit

// apple/CONTRACT-GALLERY.md section 4 and 9 (CORE tests): the values, the caps, the geometry table of 6.4, the estimates of
// 6.5, the names of 1.8, the title rule of 1.6. Pure: no network, no disk beyond temp dirs.

private func photo(_ id: Int, _ w: Int = 1080, _ h: Int = 1350) -> GalleryItem { GalleryItem(id: id, type: .photo, width: w, height: h) }
private func photos(_ n: Int) -> [GalleryItem] { (0..<n).map { photo($0) } }
private func json(_ any: Any) -> String {
    String(decoding: (try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
}

@Suite struct GalleryChoiceTests {
    @Test func encodesAsTheWireSays() throws {
        func enc(_ c: GalleryChoice) throws -> String { String(decoding: try JSONEncoder().encode([c]), as: UTF8.self) }
        #expect(try enc(.all) == #"["all"]"#)
        #expect(try enc(.firstVideo) == #"["first-video"]"#)
        #expect(try enc(.some([0, 3])) == "[[0,3]]")
        #expect(try JSONDecoder().decode([GalleryChoice].self, from: Data(#"["all","first-video",[2,5]]"#.utf8)) == [.all, .firstVideo, .some([2, 5])])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([GalleryChoice].self, from: Data(#"["some"]"#.utf8)) }
    }
}

@Suite struct SlideshowPlanTests {
    @Test @MainActor func standardIsTwoSecondsFadeAsPostedNoSound() {
        let webp = SlideshowPlan.standard(.webp, items: [0, 1, 2], settings: nil)
        #expect(webp.photoSeconds == 2 && webp.fade && webp.frame == .asPosted && webp.sound == .none)
        #expect(webp.quality == .med && webp.width == 480)
        let mp4 = SlideshowPlan.standard(.mp4, items: [0, 1], settings: nil)
        #expect(mp4.quality == nil && mp4.width == nil)
        // a webp never carries sound, whatever was asked
        #expect(SlideshowPlan(format: .webp, items: [0, 1], sound: .own).sound == .none)
        // and an mp4 never carries a webp's quality or width
        #expect(SlideshowPlan(format: .mp4, items: [0, 1], quality: .high, width: 320).quality == nil)
    }

    @Test func theWiresSecondsComeFromTheOnePhotoValueAndNullForVideos() {
        let items = [photo(0), GalleryItem(id: 1, type: .video, duration: 12.4), photo(2), GalleryItem(id: 3, type: .gif, duration: 3.2)]
        var plan = SlideshowPlan(format: .mp4, items: [2, 1, 0, 3], photoSeconds: 3.5)
        #expect(plan.seconds(for: items) == [3.5, nil, 3.5, nil])
        let body = plan.wireBody(items: items, includesQueue: true, focused: true, notify: false)
        #expect(json(body) == #"{"fade":true,"format":"mp4","frame":"keep","items":[2,1,0,3],"priority":"focused","queue":true,"seconds":[3.5,null,3.5,null],"sound":"none"}"#)
        plan = SlideshowPlan(format: .webp, items: [0, 2], photoSeconds: 2, fade: false, frame: .story, quality: .high, width: 320)
        let webp = plan.wireBody(items: items, includesQueue: false)
        #expect(json(webp) == #"{"fade":false,"format":"webp","frame":"9:16","items":[0,2],"quality":"high","seconds":[2,2],"sound":"none","width":320}"#)
    }

    @Test func theCreateCarriesThePlanWithoutQueueOrPriority() {
        let options = StudioCreateOptions(
            makePublic: true, queue: true, title: nil, origin: "share", notify: NotifyOptIn(on: [.rendered, .failed], label: "x · @a"),
            items: .all, itemCount: 4, slideshow: SlideshowPlan(format: .webp, items: [0, 1, 2, 3], quality: .med, width: 480), itemInfo: photos(4))
        let body = options.body(link: URL(string: "https://x.com/a/status/1")!)
        #expect(body["items"] as? String == "all" && body["item_count"] as? Int == 4 && body["origin"] as? String == "share")
        let slideshow = body["slideshow"] as? [String: Any]
        #expect(slideshow?["queue"] == nil && slideshow?["priority"] == nil && slideshow?["seconds"] as? [Double] == [2, 2, 2, 2])
        #expect(slideshow?["quality"] as? String == "med" && slideshow?["width"] as? Int == 480)
        #expect(!options.isPlain)
        #expect(StudioCreateOptions(makePublic: true, queue: true, title: "t").isPlain)
        // a gallery image of a mixed post sends only its photos
        let mixed = photos(2) + [GalleryItem(id: 2, type: .video, duration: 4)]
        let image = GalleryImagePlan(items: [0, 2, 1], layout: .grid3).wireBody(items: mixed, includesQueue: false)
        #expect(image["items"] as? [Int] == [0, 1] && image["layout"] as? String == "grid3")
    }

    @Test func lengthAndTheCaps() {
        // 10 photos at 2 s = 20 s: both formats take it
        let ten = photos(10)
        let plan = SlideshowPlan(format: .webp, items: Array(0..<10))
        #expect(plan.length(of: ten) == 20 && plan.check(ten) == .ok)
        // 10 s a photo = 100 s: too long for a webp (cap 60), the longest 0.5 s step that fits is 6 s; the mp4 takes 3:00
        var slow = plan; slow.photoSeconds = 10
        #expect(slow.check(ten) == .tooLong(length: 100, cap: 60, fitSeconds: 6))
        slow.format = .mp4
        #expect(slow.check(ten) == .ok)
        // the mp4 stops at 3:00 (18 photos at 10 s = 180 s fits, 20 = 200 s does not, and 9 s a photo fits)
        #expect(SlideshowPlan(format: .mp4, items: Array(0..<18), photoSeconds: 10).check(photos(18)) == .ok)
        let twenty = photos(20)
        let long = SlideshowPlan(format: .mp4, items: Array(0..<20), photoSeconds: 10)
        #expect(long.check(twenty) == .tooLong(length: 200, cap: 180, fitSeconds: 9))
        // 0.5 s of slack on the cap
        #expect(SlideshowPlan(format: .webp, items: Array(0..<10), photoSeconds: 6).check(ten) == .ok)
        #expect(SlideshowPlan(format: .webp, items: Array(0..<12), photoSeconds: 5).check(photos(12)) == .ok)
        #expect(SlideshowPlan(format: .webp, items: Array(0..<13), photoSeconds: 5).check(photos(13)) != .ok)
    }

    @Test func theVideosCapAndTheFit() {
        // 20 photos + a 25 s video at 2 s: 65 s, over the webp's 60; (60 - 25) / 20 = 1.75, so 1.5 s a photo fits
        let items = photos(20) + [GalleryItem(id: 20, type: .video, duration: 25)]
        let plan = SlideshowPlan(format: .webp, items: Array(0...20))
        #expect(plan.check(items) == .tooLong(length: 65, cap: 60, fitSeconds: 1.5))
        // nothing fits when the videos alone use the whole cap
        let heavy = photos(5) + [GalleryItem(id: 5, type: .video, duration: 59.9)]
        let bad = SlideshowPlan(format: .webp, items: Array(0...5))
        #expect(bad.check(heavy) == .tooLong(length: 69.9, cap: 60, fitSeconds: nil))
        // videos and gifs together stop at 60 s, in either format
        let motion = [photo(0), GalleryItem(id: 1, type: .video, duration: 40), GalleryItem(id: 2, type: .gif, duration: 33)]
        for format in [SlideshowPlan.Format.webp, .mp4] {
            #expect(SlideshowPlan(format: format, items: [0, 1, 2]).check(motion) == .tooMuchVideo(73))
        }
        // a gif of unknown length counts as nothing; one item or a repeated one is too few
        #expect(SlideshowPlan(format: .mp4, items: [0]).check(photos(3)) == .tooFew)
        #expect(SlideshowPlan(format: .mp4, items: [0, 0]).check(photos(3)) == .tooFew)
        #expect(SlideshowPlan(format: .mp4, items: [0, 9]).check(photos(3)) == .tooFew)
    }

    @Test func theSliderSnapsToHalfSeconds() {
        #expect(SlideshowPlan.snapped(0.2) == 0.5 && SlideshowPlan.snapped(2.26) == 2.5 && SlideshowPlan.snapped(99) == 10)
        #expect(SlideshowPlan.snapped(2.24) == 2)
    }

    @Test func aGalleryImageNeedsTwoPhotosAndLeavesVideosOut() {
        let mixed = photos(2) + [GalleryItem(id: 2, type: .video, duration: 4), GalleryItem(id: 3, type: .gif, duration: 1)]
        let all = GalleryImagePlan(items: [0, 1, 2, 3], layout: .grid3)
        let (shown, skipped) = all.photos(in: mixed)
        #expect(shown.map(\.id) == [0, 1] && skipped == 2 && all.isPossible(in: mixed))
        #expect(all.photoOnly(in: mixed).items == [0, 1])
        #expect(!GalleryImagePlan(items: [0, 2], layout: .strip).isPossible(in: mixed))
    }
}

@Suite struct GalleryGeometryTests {
    /// Every row of the 6.4 table (generated by executing the reference model, `GalleryGeometryFixtures.swift`).
    @Test func matchesTheReferenceModelForEverySizedPostAndLayout() throws {
        #expect(geometryFixtures.count == 28)
        for f in geometryFixtures {
            let layout = try #require(GalleryLayout(rawValue: f.layout))
            let canvas = try GalleryGeometry.layout(f.sizes.map { CGSize(width: $0.0, height: $0.1) }, layout)
            let tag = "\(f.post) \(f.layout)"
            #expect(canvas.width == f.width && canvas.height == f.height, "\(tag): \(canvas.width)x\(canvas.height)")
            #expect(canvas.scaledToCap == f.scaled, "\(tag)")
            #expect(canvas.cells.count == f.cells.count, "\(tag)")
            for (cell, want) in zip(canvas.cells, f.cells) {
                #expect(cell.index == want.i, "\(tag) #\(want.i)")
                #expect(cell.rect == CGRect(x: want.x, y: want.y, width: want.w, height: want.h), "\(tag) #\(want.i) \(cell.rect)")
                #expect(cell.cropped == want.crop, "\(tag) #\(want.i) crop")
                #expect((cell.upscale ?? 0) == want.up, "\(tag) #\(want.i) up \(String(describing: cell.upscale))")
            }
        }
    }

    @Test func cellsTileTheCanvasExactlyWithEvenSizes() throws {
        for f in geometryFixtures {
            let layout = try #require(GalleryLayout(rawValue: f.layout))
            let canvas = try GalleryGeometry.layout(f.sizes.map { CGSize(width: $0.0, height: $0.1) }, layout)
            #expect(canvas.width % 2 == 0 && canvas.height % 2 == 0, "\(f.post) \(f.layout)")
            var area = 0
            for cell in canvas.cells {
                area += Int(cell.rect.width * cell.rect.height)
                #expect(Int(cell.rect.width) % 2 == 0 && Int(cell.rect.height) % 2 == 0)
                #expect(cell.rect.maxX <= CGFloat(canvas.width) && cell.rect.maxY <= CGFloat(canvas.height))
            }
            #expect(area == canvas.width * canvas.height, "\(f.post) \(f.layout): no gaps and no overlap")
        }
    }

    @Test func theCapsAndTheTableRowsTheContractNames() throws {
        func canvas(_ post: String, _ layout: GalleryLayout) throws -> GalleryCanvas {
            let f = try #require(geometryFixtures.first { $0.post == post && $0.layout == layout.rawValue })
            return try GalleryGeometry.layout(f.sizes.map { CGSize(width: $0.0, height: $0.1) }, layout)
        }
        // ten in 3 across is 3+3+2+2 and 2160 x 4500; the strip of twenty stories is scaled to the 30,000 px cap
        let ig = try canvas("ig10", .grid3)
        #expect((ig.width, ig.height) == (2160, 4500) && !ig.scaledToCap)
        let rows = Dictionary(grouping: ig.cells, by: { $0.rect.minY }).sorted { $0.key < $1.key }.map(\.value.count)
        #expect(rows == [3, 3, 2, 2])
        let stories = try canvas("stories20", .strip)
        #expect((stories.width, stories.height) == (842, 29920) && stories.scaledToCap)
        #expect(max(stories.width, stories.height) <= GalleryGeometry.maxLongSide && stories.width * stories.height <= GalleryGeometry.maxPixels)
        // a photo alone in a 2-across row is drawn up to 2x its pixels
        let three = try canvas("ig3", .grid2)
        #expect(three.cells[2].upscale == 2 && three.upscaledIndices == [2])
        // x4: photos 2 and 3 (indices 1, 2) are cropped to the 4:5 cells
        #expect(try canvas("x4", .grid2).croppedIndices == [1, 2])
        // a strip and side by side never crop
        #expect(try canvas("x4", .strip).croppedIndices.isEmpty && canvas("x4", .row).croppedIndices.isEmpty)
    }

    @Test func fewerThanTwoPhotosThrows() {
        #expect(throws: GalleryGeometry.NeedsTwoPhotos.self) { try GalleryGeometry.layout([CGSize(width: 10, height: 10)], .strip) }
        #expect(throws: GalleryGeometry.NeedsTwoPhotos.self) { try GalleryGeometry.layout([], .grid3) }
    }

    @Test func aTieOfSizesTakesTheShapeThatReachedTheTopFirst() {
        // 4 sizes: A B B A: B reaches 2 first and A's 2 does not beat it
        let dims = [(w: 1000, h: 1000), (w: 1200, h: 1500), (w: 1200, h: 1500), (w: 1000, h: 1000)]
        #expect(GalleryGeometry.commonAspect(dims) == 1200.0 / 1500.0)
    }
}

@Suite struct MakeEstimateTests {
    // numbers from GM.webpKB / GM.mp4MB / GM.jpegMB / GM.frame, executed on the same inputs (CONTRACT-GALLERY.model.js)
    @Test func theWebpEstimateIsTheBoardsArithmetic() {
        let ten = photos(10)
        let plan = SlideshowPlan(format: .webp, items: Array(0..<10), quality: .med, width: 480)
        let frame = MakeEstimate.frame(for: plan, items: ten)
        #expect(frame == CGSize(width: 480, height: 600))
        #expect(MakeEstimate.webpBytes(ten, plan: plan, frame: frame) == 1_759_000)
        var cut = plan; cut.fade = false
        #expect(MakeEstimate.webpBytes(ten, plan: cut, frame: frame) == 310_000)
        var high = plan; high.quality = .high
        #expect(MakeEstimate.webpBytes(ten, plan: high, frame: frame) == 2_639_000)
        var low = plan; low.quality = .low
        #expect(MakeEstimate.webpBytes(ten, plan: low, frame: frame) == 1_231_000)
        // with a video and a gif it follows their seconds
        let mixed = photos(2) + [GalleryItem(id: 2, type: .video, width: 1080, height: 1350, duration: 12.4), GalleryItem(id: 3, type: .gif, width: 1080, height: 1350, duration: 3.2)]
        let mixedPlan = SlideshowPlan(format: .webp, items: [0, 1, 2, 3], quality: .med, width: 480)
        #expect(MakeEstimate.webpBytes(mixed, plan: mixedPlan, frame: CGSize(width: 480, height: 600)) == 2_751_000)
    }

    @Test func theMp4EstimateAndTheFrames() {
        let ten = photos(10)
        let plan = SlideshowPlan(format: .mp4, items: Array(0..<10))
        let frame = MakeEstimate.frame(for: plan, items: ten)
        #expect(frame == CGSize(width: 1080, height: 1350))
        #expect(MakeEstimate.mp4Bytes(ten, plan: plan, frame: frame) == 500_000)
        let mixed = photos(2) + [GalleryItem(id: 2, type: .video, width: 1080, height: 1350, duration: 12.4), GalleryItem(id: 3, type: .gif, width: 1080, height: 1350, duration: 3.2)]
        #expect(MakeEstimate.mp4Bytes(mixed, plan: SlideshowPlan(format: .mp4, items: [0, 1, 2, 3]), frame: frame) == 4_000_000)
        // 9:16 and 1:1, webp and mp4
        #expect(MakeEstimate.frame(for: SlideshowPlan(format: .webp, items: [0, 1], frame: .story, width: 320), items: ten) == CGSize(width: 320, height: 568))
        #expect(MakeEstimate.frame(for: SlideshowPlan(format: .webp, items: [0, 1], frame: .square, width: 480), items: ten) == CGSize(width: 480, height: 480))
        #expect(MakeEstimate.frame(for: SlideshowPlan(format: .mp4, items: [0, 1], frame: .story), items: ten) == CGSize(width: 1080, height: 1920))
        let stories = (0..<3).map { GalleryItem(id: $0, type: .photo, width: 1080, height: 1920) }
        #expect(MakeEstimate.frame(for: SlideshowPlan(format: .mp4, items: [0, 1]), items: stories) == CGSize(width: 1080, height: 1920))
    }

    @Test func theJpegEstimateIsThreeTenthsOfAMegabytePerMegapixel() throws {
        let ig = try GalleryGeometry.layout(Array(repeating: CGSize(width: 1080, height: 1350), count: 10), .grid3)
        #expect(MakeEstimate.jpegBytes(ig) == 2_900_000)
        let strip = try GalleryGeometry.layout(Array(repeating: CGSize(width: 1080, height: 1350), count: 10), .strip)
        #expect(MakeEstimate.jpegBytes(strip) == 4_400_000)
        let plan = GalleryImagePlan(items: Array(0..<10), layout: .grid3)
        #expect(MakeEstimate.canvas(for: plan, items: photos(10))?.height == 4500)
    }

    @Test func theServerSecondsFollowTheAssumedFactors() {
        let ten = photos(10)
        let webp = GalleryMake.slideshow(SlideshowPlan(format: .webp, items: Array(0..<10)))
        #expect(abs(MakeEstimate.serverSeconds(webp, items: ten) - (5 + 6 + 5.4)) < 1e-9)      // 10 photos, 9 crossfades
        let mp4 = GalleryMake.slideshow(SlideshowPlan(format: .mp4, items: Array(0..<10)))
        #expect(abs(MakeEstimate.serverSeconds(mp4, items: ten) - (5 + 0.45 * 20)) < 1e-9)
        let image = GalleryMake.image(GalleryImagePlan(items: Array(0..<10), layout: .grid3))
        #expect(abs(MakeEstimate.serverSeconds(image, items: ten) - (3 + 3)) < 1e-9)
        let withVideo = ten + [GalleryItem(id: 10, type: .video, duration: 10)]
        let plan = GalleryMake.slideshow(SlideshowPlan(format: .webp, items: Array(0...10)))
        #expect(abs(MakeEstimate.serverSeconds(plan, items: withVideo) - (5 + 0.6 * 10 + 0.6 * 10 + 25)) < 1e-9)
    }
}

@Suite struct MadeKindTests {
    @Test func aMadeRowIsKnownByItsRoleAndSpec() {
        func spec(_ json: String) -> MadeSpec? { MadeSpec(data: Data(json.utf8)) }
        #expect(MadeKind(role: .slideshow, spec: spec(#"{"format":"webp"}"#)) == .slideshow(.webp))
        #expect(MadeKind(role: .slideshow, spec: spec(#"{"format":"mp4"}"#)) == .slideshow(.mp4))
        // a slideshow made before 18.10 has no format: it counts as mp4
        #expect(MadeKind(role: .slideshow, spec: spec(#"{"items":[0,1]}"#)) == .slideshow(.mp4))
        #expect(MadeKind(role: .export, spec: spec(#"{"kind":"gallery","layout":"grid3","items":[0,1]}"#)) == .galleryImage(.grid3))
        // a long image or a PDF from the 2026-10-06 plan is not a tab
        #expect(MadeKind(role: .export, spec: spec(#"{"kind":"pdf"}"#)) == nil)
        #expect(MadeKind(role: .crop, spec: nil) == .crop && MadeKind(role: .item, spec: nil) == nil && MadeKind(role: nil, spec: nil) == nil)
        #expect(MadeKind.galleryImage(.grid3).tabName == "gallery image · 3 across" && MadeKind.slideshow(.webp).tabName == "slideshow webp")
        #expect(MadeKind.slideshow(.mp4).tabName == "slideshow")
    }

    @Test func aSpecKeepsItsItemsAndItsJson() throws {
        let spec = try #require(MadeSpec(data: Data(#"{"kind":"gallery","layout":"strip","items":[3,1,2]}"#.utf8)))
        #expect(spec.items == [3, 1, 2] && spec.layout == .strip && spec.kind == "gallery")
        #expect(MadeSpec(data: Data("[1]".utf8)) == nil)
    }
}

@Suite struct LinkTitleHandleTests {
    @Test func aPostThatNamesItsAuthorIsTitledByTheHandle() throws {
        let x = try #require(LinkInfo(URL(string: "https://x.com/ilokineedsleep/status/2106850389551374806?s=20")!))
        #expect(x.service == "x" && x.ref == "@ilokineedsleep")
        #expect(MediaTitle.text(MediaTitle.resolve(custom: nil, service: x.service, ref: x.ref, fileName: nil)) == "x · @ilokineedsleep")
        let tw = try #require(LinkInfo(URL(string: "https://twitter.com/ilokineedsleep/status/2106850389551374806")!))
        #expect(tw.service == "x" && tw.ref == "@ilokineedsleep")
        let tiktok = try #require(LinkInfo(URL(string: "https://www.tiktok.com/@someone/photo/7400000000000000000")!))
        #expect(tiktok.ref == "@someone")
        let ig = try #require(LinkInfo(URL(string: "https://www.instagram.com/p/Ddy0-gpGg5U/")!))
        #expect(MediaTitle.text(MediaTitle.resolve(custom: nil, service: ig.service, ref: ig.ref, fileName: nil)) == "instagram · Ddy0-gpGg5U")
    }

    @Test func theAnonymousXLinkKeepsItsNumber() throws {
        let anon = try #require(LinkInfo(URL(string: "https://x.com/i/status/2105435404002562056")!))
        #expect(anon.ref == "2105435404002562056")
        // a path with no second part names no author either
        #expect(try #require(LinkInfo(URL(string: "https://x.com/someone")!)).ref == "someone")
        // and a library post of the same link reads the same
        let post = LibraryPost(
            id: "p", service: "x", link: URL(string: "https://x.com/ilokineedsleep/status/2106850389551374806")!, title: nil, duration: nil,
            width: nil, height: nil, createdAt: Date(), session: nil, files: [])
        #expect(post.ref == "@ilokineedsleep")
    }
}
