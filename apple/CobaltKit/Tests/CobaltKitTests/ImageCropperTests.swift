import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import CobaltKit

// Cropping pictures on the device (APP-API-CONTRACT 44.1, apple/CONTRACT-EDITOR.md 13): the server's rules for the box
// (`api/src/image-crop-core.ts` `pixelBox`: outward to whole pixels, clamped, at least 2 x 2), the quarter turn and the flip
// on real pixels, the shown-picture mapping the sheet drags in, the wire (JSON body and upload query), the capability, and the
// editor session's place / replace.

/// A `width` x `height` opaque picture whose pixel (x, y) is (red 10 + 20x, green 10 + 20y, blue 7).
private func numbered(_ width: Int, _ height: Int) -> CGImage {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let i = (y * width + x) * 4
            pixels[i] = UInt8(10 + 20 * x); pixels[i + 1] = UInt8(10 + 20 * y); pixels[i + 2] = 7; pixels[i + 3] = 255
        }
    }
    return RGBA(width: width, height: height, pixels: pixels).image()!
}

/// Which source pixel sits at (x, y) of `image` (made from `numbered`).
private func origin(_ image: CGImage, _ x: Int, _ y: Int) -> [Int] {
    let rgba = RGBA(image)!
    let i = (y * rgba.width + x) * 4
    return [(Int(rgba.pixels[i]) - 10) / 20, (Int(rgba.pixels[i + 1]) - 10) / 20]
}

private let turns = [0, 90, 180, 270]
private let flips: [ImageCropFlip] = [.none, .h, .v]

struct ImageCropRectTests {
    @Test func theBoxIsRoundedOutwardToWholePixels() {
        #expect(ImageCropper.pixelRect(ImageCropRect(x: 0.15, y: 0.15, w: 0.5, h: 0.5), width: 10, height: 10)
            == ImageCropper.PixelRect(x: 1, y: 1, w: 6, h: 6))
        // 0.1 * 10 and 0.6 * 10 are not exact in floating point: the millionth keeps them on their pixel
        #expect(ImageCropper.pixelRect(ImageCropRect(x: 0.1, y: 0.2, w: 0.3, h: 0.4), width: 10, height: 10)
            == ImageCropper.PixelRect(x: 1, y: 2, w: 3, h: 4))
        #expect(ImageCropper.pixelRect(nil, width: 7, height: 5) == ImageCropper.PixelRect(x: 0, y: 0, w: 7, h: 5))
    }

    @Test func theBoxIsClampedToTheEdge() {
        #expect(ImageCropper.pixelRect(ImageCropRect(x: 0.7, y: 0.7, w: 0.6, h: 0.6), width: 10, height: 10)
            == ImageCropper.PixelRect(x: 7, y: 7, w: 3, h: 3))
        let c = ImageCropRect(x: -0.2, y: 0.5, w: 2, h: 2).clamped
        #expect(c.x == 0 && c.w == 1 && c.y == 0.5 && c.h == 0.5)
        #expect(ImageCropRect(x: 1, y: 1, w: 1, h: 1).clamped.x < 1)
        // the whole picture is no crop at all
        #expect(ImageCropSpec(crop: ImageCropRect(x: 0, y: 0, w: 1, h: 1)).crop == nil)
        #expect(ImageCropSpec(crop: ImageCropRect(x: -1, y: -1, w: 5, h: 5)).crop == nil)
        #expect(!ImageCropSpec(crop: .whole).changesSomething)
    }

    @Test func aBoxUnderTwoPixelsIsRefused() throws {
        #expect(ImageCropper.pixelRect(ImageCropRect(x: 0.5, y: 0.5, w: 0.05, h: 0.05), width: 10, height: 10) == nil)
        #expect(ImageCropper.pixelRect(ImageCropRect(x: 0.5, y: 0.5, w: 0.05, h: 0.05), width: 100, height: 100)
            == ImageCropper.PixelRect(x: 50, y: 50, w: 5, h: 5))
        #expect(ImageCropper.pixelRect(nil, width: 1, height: 5) == nil)
        #expect(throws: ImageCropError.tooSmall) {
            try ImageCropper.crop(numbered(10, 10), ImageCropSpec(crop: ImageCropRect(x: 0.5, y: 0.5, w: 0.05, h: 0.05)))
        }
        let two = try ImageCropper.crop(numbered(10, 10), ImageCropSpec(crop: ImageCropRect(x: 0.5, y: 0.5, w: 0.15, h: 0.15)))
        #expect(two.width == 2 && two.height == 2)
    }

    @Test func theOutputSizeFollowsTheTurn() {
        let spec = ImageCropSpec(crop: ImageCropRect(x: 0, y: 0, w: 0.5, h: 1), rotate: 90)
        #expect(ImageCropper.outputSize(spec, width: 40, height: 30).map { [$0.width, $0.height] } == [30, 20])
        #expect(ImageCropper.outputSize(ImageCropSpec(rotate: 180), width: 40, height: 30).map { [$0.width, $0.height] } == [40, 30])
        #expect(ImageCropSpec.quarter(-90) == 270 && ImageCropSpec.quarter(450) == 90 && ImageCropSpec(rotate: 360).rotate == 0)
    }
}

struct ImageCropPixelTests {
    @Test func aQuarterTurnClockwise() throws {
        let out = try ImageCropper.crop(numbered(3, 2), ImageCropSpec(rotate: 90))
        #expect(out.width == 2 && out.height == 3)
        // source (x, y) lands at (h - 1 - y, x): the top-left goes to the top-right
        #expect(origin(out, 1, 0) == [0, 0])
        #expect(origin(out, 0, 0) == [0, 1])
        #expect(origin(out, 0, 2) == [2, 1])
    }

    @Test func halfAndThreeQuarterTurns() throws {
        let half = try ImageCropper.crop(numbered(3, 2), ImageCropSpec(rotate: 180))
        #expect(half.width == 3 && half.height == 2 && origin(half, 2, 1) == [0, 0] && origin(half, 0, 0) == [2, 1])
        let left = try ImageCropper.crop(numbered(3, 2), ImageCropSpec(rotate: 270))
        #expect(left.width == 2 && left.height == 3)
        #expect(origin(left, 0, 2) == [0, 0])          // the top-left goes to the bottom-left
        #expect(origin(left, 1, 0) == [2, 1])
    }

    @Test func flipsMirror() throws {
        let h = try ImageCropper.crop(numbered(3, 2), ImageCropSpec(flip: .h))
        #expect(origin(h, 2, 0) == [0, 0] && origin(h, 0, 1) == [2, 1])
        let v = try ImageCropper.crop(numbered(3, 2), ImageCropSpec(flip: .v))
        #expect(origin(v, 0, 1) == [0, 0] && origin(v, 2, 0) == [2, 1])
    }

    @Test func theTurnComesBeforeTheFlip() throws {
        // a quarter turn then a left-right mirror is a transpose
        let out = try ImageCropper.crop(numbered(3, 2), ImageCropSpec(rotate: 90, flip: .h))
        #expect(out.width == 2 && out.height == 3)
        #expect(origin(out, 0, 0) == [0, 0] && origin(out, 1, 2) == [2, 1] && origin(out, 1, 0) == [0, 1])
    }

    @Test func theCropComesBeforeTheTurn() throws {
        // the right two columns of a 3 x 2 picture, turned: 2 x 2
        let out = try ImageCropper.crop(numbered(3, 2), ImageCropSpec(crop: ImageCropRect(x: 1.0 / 3, y: 0, w: 2.0 / 3, h: 1), rotate: 90))
        #expect(out.width == 2 && out.height == 2)
        #expect(origin(out, 1, 0) == [1, 0] && origin(out, 0, 1) == [2, 1])
    }

    @Test func theShownPictureMappingAgreesWithThePixels() throws {
        let w = 4, h = 3
        for r in turns {
            for f in flips {
                let out = try ImageCropper.crop(numbered(w, h), ImageCropSpec(rotate: r, flip: f))
                for y in 0..<h {
                    for x in 0..<w {
                        let q = ImageCropSpec.displayedPoint((x: (Double(x) + 0.5) / Double(w), y: (Double(y) + 0.5) / Double(h)), rotate: r, flip: f)
                        let ox = Int(q.x * Double(out.width)), oy = Int(q.y * Double(out.height))
                        #expect(origin(out, ox, oy) == [x, y], "rotate \(r) flip \(f.rawValue) at \(x),\(y)")
                    }
                }
                // and the sheet's picture is the same
                let shown = try #require(ImageCropper.turned(numbered(w, h), rotate: r, flip: f))
                #expect(origin(shown, 0, 0) == origin(out, 0, 0))
            }
        }
    }

    @Test func aBoxOnTheShownPictureGoesBackToTheStoredOne() {
        let box = ImageCropRect(x: 0.1, y: 0.2, w: 0.3, h: 0.5)
        for r in turns {
            for f in flips {
                let shown = ImageCropSpec.displayed(box, rotate: r, flip: f)
                let back = ImageCropSpec.stored(shown, rotate: r, flip: f)
                #expect(abs(back.x - box.x) < 1e-9 && abs(back.y - box.y) < 1e-9 && abs(back.w - box.w) < 1e-9 && abs(back.h - box.h) < 1e-9)
                if r % 180 == 90 { #expect(abs(shown.w - box.h) < 1e-9 && abs(shown.h - box.w) < 1e-9) }
            }
        }
        // a quarter turn clockwise: the left strip goes to the top
        let top = ImageCropSpec.displayed(ImageCropRect(x: 0, y: 0, w: 0.25, h: 1), rotate: 90, flip: .none)
        #expect(abs(top.x) < 1e-9 && abs(top.y) < 1e-9 && abs(top.w - 1) < 1e-9 && abs(top.h - 0.25) < 1e-9)
    }

    @Test func turningTheShownPictureLeft() throws {
        let picture = numbered(4, 3)
        for r in turns {
            for f in [ImageCropFlip.none, .h] {
                let shown = try #require(ImageCropper.turned(picture, rotate: r, flip: f))
                let wanted = try #require(ImageCropper.turned(shown, rotate: 270, flip: .none))
                let made = try #require(ImageCropper.turned(picture, rotate: ImageCropSpec.turnedLeft(rotate: r, flip: f), flip: f))
                #expect(made.width == wanted.width && made.height == wanted.height)
                for y in 0..<made.height {
                    for x in 0..<made.width { #expect(origin(made, x, y) == origin(wanted, x, y), "rotate \(r) flip \(f.rawValue)") }
                }
            }
        }
    }

    @Test func thePngIsFullSizeAndChecked() throws {
        let out = try ImageCropper.make(numbered(10, 8), ImageCropSpec(crop: ImageCropRect(x: 0.2, y: 0.25, w: 0.5, h: 0.5)))
        let png = try #require(ImageCropper.png(out))
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let back = try #require(CGImageSourceCreateWithData(png as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(back.width == 5 && back.height == 4)
        #expect(origin(back, 0, 0) == [2, 2])
    }
}

struct ImageCropWireTests {
    private func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func theJsonBodyNamesWhatChanges() throws {
        let full = ImageCropSpec(crop: ImageCropRect(x: 0.52, y: 0.38, w: 0.36, h: 0.22), rotate: 90, flip: .h, cutout: true, title: "sticker")
        let o = try object(full.jsonBody())
        let crop = try #require(o["crop"] as? [String: Double])
        #expect(crop["x"] == 0.52 && crop["y"] == 0.38 && crop["w"] == 0.36 && crop["h"] == 0.22)
        #expect(o["rotate"] as? Int == 90 && o["flip"] as? String == "h" && o["cutout"] as? Bool == true && o["title"] as? String == "sticker")
        // defaults are left out
        let turn = try object(ImageCropSpec(rotate: 270).jsonBody())
        #expect(Set(turn.keys) == ["rotate"] && turn["rotate"] as? Int == 270)
        let plain = try object(ImageCropSpec(crop: ImageCropRect(x: 0, y: 0, w: 0.5, h: 0.5)).jsonBody())
        #expect(Set(plain.keys) == ["crop"])
    }

    @Test func theUploadQueryRecordsWhatTheDeviceDid() {
        let spec = ImageCropSpec(crop: ImageCropRect(x: 0.5, y: 0.25, w: 0.125, h: 0.3333333333), rotate: 180, flip: .v, cutout: true, title: "a b")
        let q = Dictionary(uniqueKeysWithValues: spec.query)
        #expect(q["x"] == "0.5" && q["y"] == "0.25" && q["w"] == "0.125" && q["h"] == "0.333333")
        #expect(q["rotate"] == "180" && q["flip"] == "v" && q["cutout"] == "auto" && q["title"] == "a b")
        #expect(ImageCropSpec(rotate: 90).query.map(\.0) == ["rotate"])
        #expect(ImageCropSpec(flip: .h).query.map(\.0) == ["flip"])
    }

    @Test func errorsMapFromTheirCodes() {
        #expect(ImageCropError(code: "error.crop.not_found", status: 404) == .notFound)
        #expect(ImageCropError(code: "error.crop.not_image", status: 409) == .notImage)
        #expect(ImageCropError(code: "error.crop.too_large", status: 413) == .tooLarge)
        #expect(ImageCropError(code: "error.crop.empty", status: 422) == .empty)
        #expect(ImageCropError(code: "error.crop.storage", status: 502) == .failed)
        #expect(ImageCropError(code: "error.crop.off", status: 503) == .off)
        #expect(ImageCropError(code: "error.api.something", status: 503) == .unavailable)
        #expect(ImageCropError(code: "http 404", status: 404) == .notFound)            // an older server without the route
    }

    @Test func theAnswerDecodes() throws {
        let json = #"{"status":"success","item":{"id":"Cr4abc","name":"shot crop.png"},"title":"shot crop","crop":{"width":465,"height":615}}"#
        let wire = try JSONDecoder().decode(ImageCropWire.self, from: Data(json.utf8))
        #expect(wire.result == ImageCropResult(id: "Cr4abc", name: "shot crop.png", title: "shot crop", width: 465, height: 615))
        #expect(wire.result.source.kind == .photo && wire.result.source.contentType == "image/png")
    }
}

struct ImageCropCapabilityTests {
    private func caps(_ rest: String) throws -> Capabilities {
        let json = #"{"server":"cobalt-cloudflare"\#(rest),"key":"valid"}"#
        return try #require(HTTPCobaltClient.parseForkCapabilities(Data(json.utf8)))
    }

    @Test func imageCropIsReadAndOffWhenAbsent() throws {
        let on = try caps(#","features":{"image_crop":true}"#)
        #expect(on.imageCrop)
        let off = try caps(#","features":{"cutout":true}"#)
        #expect(!off.imageCrop)
        #expect(try !caps("").imageCrop)
    }

    @Test func theServerCropsPngsOnItsOwnAndTheRestWithImages() throws {
        let plain = try caps(#","features":{"image_crop":true}"#)
        #expect(plain.canServerCropImage(contentType: "image/png", cutout: false))
        #expect(!plain.canServerCropImage(contentType: "image/png", cutout: true))
        #expect(!plain.canServerCropImage(contentType: "image/jpeg", cutout: false))
        let images = try caps(#","features":{"image_crop":true,"cutout":true,"cutout_auto":true}"#)
        #expect(images.canServerCropImage(contentType: "image/jpeg", cutout: true))
        let none = try caps(#","features":{"cutout":true,"cutout_auto":true}"#)
        #expect(!none.canServerCropImage(contentType: "image/png", cutout: false))
    }
}

@MainActor
struct ImageCropSessionTests {
    private func session(_ h: Harness) async throws -> EditSession {
        let client = h.ctx.client as! PreviewClient
        let (full, named) = try await client.editProject(id: PreviewEditorIDs.beach)
        var summary = full
        summary.timeline = nil
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("crop-\(UUID().uuidString)", isDirectory: true)
        let cache = EditSourceCache(                                 // real files: the preview download waits on the harness clock
            directory: dir, client: { [ctx = h.ctx] in ctx.client },
            provider: { await PreviewEditorMedia.shared.url(forFile: $0) })
        return EditSession(
            project: summary, timeline: try #require(full.timeline), sources: named, context: h.ctx, cache: cache,
            onProject: { _ in }, onRender: { _ in })
    }

    @Test func theDevicesCropIsUploadedAndPlacedOnAFreeLayer() async throws {
        let h = Harness(.happy)
        let client = h.ctx.client as! PreviewClient
        let session = try await session(h)
        defer { session.tearDown() }
        #expect(session.canCropImage)
        session.seek(frame: 100)                                        // inside the dance on layer 0
        let photo = PreviewData.editorSources()[PreviewEditorIDs.photo]!
        let spec = ImageCropSpec(crop: ImageCropRect(x: 0, y: 0, w: 0.5, h: 0.25), rotate: 90)
        let made = try await session.makeImageCrop(of: photo, picture: numbered(10, 8), spec: spec)
        #expect(made.kind == .photo && made.contentType == "image/png")
        #expect(made.width == 2 && made.height == 5)                    // 5 x 2 turned
        let placed = try #require(session.timeline.overlay.first { $0.item == made.id })
        #expect(placed.track == 1)
        #expect(client.editorState.calls.contains("POST /library/items/\(PreviewEditorIDs.photo)/crop png"))
        #expect(session.problems.isEmpty)
    }

    @Test func withoutThePictureTheServerMakesItAndItCanReplaceAnOverlay() async throws {
        let h = Harness(.happy)
        let client = h.ctx.client as! PreviewClient
        let session = try await session(h)
        defer { session.tearDown() }
        let dance = try #require(session.timeline.overlay.first)
        let gif = PreviewData.editorSources()[PreviewEditorIDs.dance]!
        #expect(session.canServerCrop(gif, cutout: true))
        let made = try await session.makeImageCrop(of: gif, picture: nil, spec: ImageCropSpec(flip: .h), replacing: dance.id)
        #expect(client.editorState.calls.contains("POST /library/items/\(PreviewEditorIDs.dance)/crop"))
        #expect(session.timeline.overlay.count == 1)
        #expect(session.timeline.overlay[0].item == made.id && session.timeline.overlay[0].id == dance.id)
        #expect(session.timeline.overlay[0].at == dance.at && session.timeline.overlay[0].track == dance.track)
    }

    @Test func aBoxTooSmallIsRefusedBeforeAnythingIsSent() async throws {
        let h = Harness(.happy)
        let client = h.ctx.client as! PreviewClient
        let session = try await session(h)
        defer { session.tearDown() }
        let photo = PreviewData.editorSources()[PreviewEditorIDs.photo]!
        await #expect(throws: ImageCropError.tooSmall) {
            try await session.makeImageCrop(
                of: photo, picture: numbered(10, 10), spec: ImageCropSpec(crop: ImageCropRect(x: 0.5, y: 0.5, w: 0.01, h: 0.01)))
        }
        #expect(!client.editorState.calls.contains { $0.contains("/crop") })
    }
}
