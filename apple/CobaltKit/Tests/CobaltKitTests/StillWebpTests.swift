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

    @Test func theLocalSpecSaysStill() throws {
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
