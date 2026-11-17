import Foundation
import Testing
@testable import CobaltKit

// "wide" emotes for 7TV (APP-API-CONTRACT 57.9, 57.10): 7TV has no wide flag, a wide emote is a picture wider than tall (up to
// 3:1). A shape is the largest centred crop box of that ratio (`SevenTvEmoteShape`), sent as the upload's `crop`; the size chips
// bring its longest side to the size, and `SevenTvEmoteRule.outputSize` says the px 7TV gets (the server's `planFit` rounding).

struct SevenTvEmoteShapeTests {
    private func px(_ box: ImageCropRect?, _ width: Int, _ height: Int) -> (x: Int, y: Int, w: Int, h: Int)? {
        SevenTvEmoteRule.cropPixels(width: width, height: height, crop: box)
    }

    @Test func aLandscapePictureLosesItsHeightForWideAndItsWidthForSquare() throws {
        let wide = try #require(SevenTvEmoteShape.wide.box(width: 1_200, height: 900))
        #expect(px(wide, 1_200, 900)! == (0, 150, 1_200, 600), "2:1 keeps the whole width, centred on the height")
        let extra = try #require(SevenTvEmoteShape.extraWide.box(width: 1_200, height: 900))
        #expect(px(extra, 1_200, 900)! == (0, 250, 1_200, 400))
        let square = try #require(SevenTvEmoteShape.square.box(width: 1_200, height: 900))
        #expect(px(square, 1_200, 900)! == (150, 0, 900, 900), "1:1 keeps the whole height, centred on the width")
        // a very wide picture: the height is kept and the width is cut to the shape
        let panorama = try #require(SevenTvEmoteShape.wide.box(width: 3_000, height: 500))
        #expect(px(panorama, 3_000, 500)! == (1_000, 0, 1_000, 500))
    }

    @Test func aPortraitPictureKeepsItsWidth() throws {
        let wide = try #require(SevenTvEmoteShape.wide.box(width: 600, height: 1_000))
        #expect(px(wide, 600, 1_000)! == (0, 350, 600, 300))
        let extra = try #require(SevenTvEmoteShape.extraWide.box(width: 600, height: 1_000))
        #expect(px(extra, 600, 1_000)! == (0, 400, 600, 200))
        let square = try #require(SevenTvEmoteShape.square.box(width: 600, height: 1_000))
        #expect(px(square, 600, 1_000)! == (0, 200, 600, 600))
    }

    @Test func aPictureOfExactlyThatShapeNeedsNoBox() {
        #expect(SevenTvEmoteShape.wide.box(width: 1_024, height: 512) == nil, "the box would be the whole picture: no crop")
        #expect(SevenTvEmoteShape.extraWide.box(width: 900, height: 300) == nil)
        #expect(SevenTvEmoteShape.square.box(width: 64, height: 64) == nil)
        #expect(SevenTvEmoteShape.asIs.box(width: 1_200, height: 900) == nil)
    }

    @Test func tinyOddAndUnusableSizes() throws {
        #expect(SevenTvEmoteShape.wide.box(width: 1, height: 1) == nil, "1 x 1 cannot be cut any smaller")
        #expect(SevenTvEmoteShape.wide.box(width: 2, height: 1) == nil)
        let squareInStrip = try #require(SevenTvEmoteShape.square.box(width: 3, height: 1))
        #expect(px(squareInStrip, 3, 1)! == (1, 0, 1, 1))
        let odd = try #require(SevenTvEmoteShape.wide.box(width: 1_001, height: 1_000))
        #expect(px(odd, 1_001, 1_000)! == (0, 249, 1_001, 501), "a 2:1 box a pixel too tall, never one too wide")
        #expect(SevenTvEmoteShape.centredBox(ratio: 2, width: 0, height: 100) == nil)
        #expect(SevenTvEmoteShape.centredBox(ratio: 2, width: 100, height: -1) == nil)
        #expect(SevenTvEmoteShape.centredBox(ratio: 0, width: 100, height: 100) == nil)
        #expect(SevenTvEmoteShape.centredBox(ratio: .nan, width: 100, height: 100) == nil)
        #expect(SevenTvEmoteShape.centredBox(ratio: .infinity, width: 100, height: 100) == nil)
    }

    /// Every size from 1 to 80 px a side, every shape: inside 0...1, rounds back to whole px inside the picture, never wider
    /// than the ratio (so 7TV's 3:1 holds), and the largest that fits.
    @Test func everyBoxStaysInsideAndNeverBeatsItsRatio() {
        for width in 1...80 {
            for height in 1...80 {
                for shape in [SevenTvEmoteShape.square, .wide, .extraWide] {
                    let ratio = shape.ratio!
                    guard let box = shape.box(width: width, height: height) else {
                        // no box: the picture is the shape already (within a pixel it cannot be cut)
                        #expect(Double(width) <= ratio * Double(height) + 1e-9, "\(width)x\(height) \(shape)")
                        continue
                    }
                    #expect(box.x >= 0 && box.y >= 0 && box.w > 0 && box.h > 0, "\(width)x\(height) \(shape)")
                    #expect(box.x <= 1 && box.y <= 1 && box.w <= 1 && box.h <= 1, "\(width)x\(height) \(shape)")
                    #expect(box.x + box.w <= 1 + 1e-12 && box.y + box.h <= 1 + 1e-12, "\(width)x\(height) \(shape)")
                    let p = SevenTvEmoteRule.cropPixels(width: width, height: height, crop: box)!
                    #expect(p.x + p.w <= width && p.y + p.h <= height, "\(width)x\(height) \(shape)")
                    #expect(Double(p.w) <= ratio * Double(p.h) + 1e-9, "\(width)x\(height) \(shape) is \(p.w)x\(p.h)")
                    #expect(p.w == width || p.h == height, "the largest box touches two sides: \(width)x\(height) \(shape)")
                    #expect(SevenTvEmoteRule.shapeFits(width: Double(p.w), height: Double(p.h)))
                }
            }
        }
    }

    @Test func aBoxMatchesItsShapeToAPixelOrTwo() throws {
        #expect(SevenTvEmoteShape.matching(width: 1_200, height: 900, crop: nil) == .asIs)
        let extra = try #require(SevenTvEmoteShape.extraWide.box(width: 1_200, height: 900))
        #expect(SevenTvEmoteShape.matching(width: 1_200, height: 900, crop: extra) == .extraWide)
        let square = try #require(SevenTvEmoteShape.square.box(width: 1_200, height: 900))
        #expect(SevenTvEmoteShape.matching(width: 1_200, height: 900, crop: square) == .square)
        let custom = ImageCropRect(x: 0.1, y: 0.1, w: 0.5, h: 0.5)
        #expect(SevenTvEmoteShape.matching(width: 1_200, height: 900, crop: custom) == nil, "666 x 450 is no shape of the chips")
        #expect(SevenTvEmoteShape.matching(width: nil, height: nil, crop: custom) == nil)
    }

    @Test func aLockedThreeToOneBoxARoundingPixelOverIsBroughtBackToThreeToOne() {
        // a 3:1 box drawn in floats on a 1234 x 987 picture: 925 x 308, one px over
        let hFrac = 0.3123, wFrac = 3 * 0.3123 * 987 / 1_234
        let drawn = ImageCropRect(x: 0.1, y: 0.2, w: wFrac, h: hFrac)
        let before = SevenTvEmoteRule.croppedSize(width: 1_234, height: 987, crop: drawn)!
        #expect(before.width == 925 && before.height == 308 && !SevenTvEmoteRule.shapeFits(width: 925, height: 308))
        let snapped = SevenTvEmoteRule.snappedToLimit(drawn, width: 1_234, height: 987)
        let after = SevenTvEmoteRule.croppedSize(width: 1_234, height: 987, crop: snapped)!
        #expect(after.width == 924 && after.height == 308 && SevenTvEmoteRule.shapeFits(width: 924, height: 308))
        let p0 = SevenTvEmoteRule.cropPixels(width: 1_234, height: 987, crop: drawn)!
        let p1 = SevenTvEmoteRule.cropPixels(width: 1_234, height: 987, crop: snapped)!
        #expect(p1.x == p0.x && p1.y == p0.y, "only the width gives")
        // a box clearly wider is left to the "crop it first" note; a tiny box is left alone
        let wider = ImageCropRect(x: 0, y: 0, w: 1, h: 0.2)
        #expect(SevenTvEmoteRule.snappedToLimit(wider, width: 1_234, height: 987) == wider)
        let tiny = ImageCropRect(x: 0, y: 0, w: 0.04, h: 0.01)
        #expect(SevenTvEmoteRule.snappedToLimit(tiny, width: 100, height: 100) == tiny)
    }

    // MARK: the px 7TV gets

    @Test func theSizeChipsSetTheLongestSideOfTheBox() throws {
        let extra = try #require(SevenTvEmoteShape.extraWide.box(width: 1_200, height: 900))   // 1200 x 400
        func out(_ size: Int?) -> String {
            let o = SevenTvEmoteRule.outputSize(width: 1_200, height: 900, crop: extra, size: size)!
            return "\(o.width)x\(o.height)"
        }
        #expect(out(512) == "512x171", "wide 3:1 at 512 is 512 x 171 (170.67 rounds up)")
        #expect(out(256) == "256x85")
        #expect(out(128) == "128x43")
        #expect(out(1_000) == "1000x333")
        #expect(out(nil) == "512x171", "a crop alone fits to the server's default 512")
        let wide = try #require(SevenTvEmoteShape.wide.box(width: 1_200, height: 900))        // 1200 x 600
        let o = SevenTvEmoteRule.outputSize(width: 1_200, height: 900, crop: wide, size: 512)!
        #expect(o.width == 512 && o.height == 256)
    }

    @Test func theFitNeverEnlargesAndPassesAFileThatNeedsNoFit() {
        let small = ImageCropRect(x: 0, y: 0.25, w: 1, h: 0.5)
        let up = SevenTvEmoteRule.outputSize(width: 600, height: 400, crop: small, size: 1_000)!
        #expect(up.width == 600 && up.height == 200, "never larger than the picture")
        let asIs = SevenTvEmoteRule.outputSize(width: 800, height: 600, crop: nil, size: nil)!
        #expect(asIs.width == 800 && asIs.height == 600, "no crop, no size, not too big: the file as it is")
        let over = SevenTvEmoteRule.outputSize(width: 2_000, height: 1_000, crop: nil, size: nil)!
        #expect(over.width == 512 && over.height == 256, "over 1000 px a side is fitted to 512")
        let heavy = SevenTvEmoteRule.outputSize(width: 800, height: 600, crop: nil, size: nil, overBytes: true)!
        #expect(heavy.width == 512 && heavy.height == 384, "over the byte cap too")
        #expect(SevenTvEmoteRule.outputSize(width: nil, height: 600, crop: nil, size: 128) == nil)
        let tiny = SevenTvEmoteRule.outputSize(width: 3, height: 100, crop: nil, size: 100)!
        #expect(tiny.width == 3 && tiny.height == 100)
    }

    @Test func theCroppedPixelsRoundLikeTheServer() {
        // planFit: x = round(x*W), w = min(W - x, round(w*W)); a box at the right edge cannot spill out
        let edge = ImageCropRect(x: 0.6, y: 0, w: 0.5, h: 1)
        let size = SevenTvEmoteRule.croppedSize(width: 1_000, height: 100, crop: edge)!
        #expect(size.width == 400, "x + w is held inside the picture")
        let half = SevenTvEmoteRule.croppedSize(width: 1_281, height: 720, crop: ImageCropRect(x: 0, y: 0, w: 0.5, h: 0.5))!
        #expect(half.width == 641 && half.height == 360, "640.5 rounds up, as Math.round does")
    }
}

@MainActor
struct SevenTvEmoteShapeModelTests {
    private func model(width: Int?, height: Int?, type: String? = "image/webp", name: String? = "capy.webp") async -> SevenTvUploadModel {
        let app = AppModel.makePreview(.happy, timeScale: 0.01, clock: SystemClock())
        await app.sevenTv.load()
        return app.sevenTv.uploader(
            fileID: "f_shape", bytes: 300_000, title: "capy", contentType: type, fileName: name, width: width, height: height)
    }

    @Test func pickingAShapeSetsTheCentredBoxAndAsIsClearsIt() async throws {
        let m = await model(width: 1_200, height: 900)
        #expect(m.shape == .asIs && m.canPickShape && m.crop == nil)
        m.pickShape(.wide)
        #expect(m.shape == .wide)
        let p = try #require(SevenTvEmoteRule.cropPixels(width: 1_200, height: 900, crop: m.crop))
        #expect(p == (0, 150, 1_200, 600))
        #expect(m.cropPixels?.width == 1_200 && m.cropPixels?.height == 600)
        m.size = 512
        #expect(m.outputPixels?.width == 512 && m.outputPixels?.height == 256)
        m.pickShape(.extraWide)
        #expect(m.shape == .extraWide && m.cropPixels?.height == 400)
        #expect(m.outputPixels?.width == 512 && m.outputPixels?.height == 171, "wide 3:1 at 512")
        m.pickShape(.asIs)
        #expect(m.shape == .asIs && m.crop == nil)
        #expect(m.outputPixels?.width == 512 && m.outputPixels?.height == 384, "the size chips alone")
    }

    @Test func aMovedBoxKeepsItsShapeWhileTheRatioMatchesAndIsCustomOtherwise() async throws {
        let m = await model(width: 1_200, height: 900)
        m.pickShape(.wide)
        // the crop sheet moved the 2:1 box up: same ratio, new place
        m.useCrop(ImageCropRect(x: 0, y: 0, w: 1, h: 600.0 / 900), width: 1_200, height: 900)
        #expect(m.shape == .wide, "the label follows the ratio, not the place")
        #expect(SevenTvEmoteRule.cropPixels(width: 1_200, height: 900, crop: m.crop)! == (0, 0, 1_200, 600))
        // a free box: custom, no chip lit
        m.useCrop(ImageCropRect(x: 0.1, y: 0.1, w: 0.5, h: 0.5), width: 1_200, height: 900)
        #expect(m.shape == nil && m.crop != nil)
        // clear: back to as is
        m.useCrop(nil)
        #expect(m.shape == .asIs && m.crop == nil)
        // the whole picture is no crop
        m.pickShape(.square)
        m.useCrop(.whole)
        #expect(m.shape == .asIs && m.crop == nil)
    }

    @Test func aPictureOfExactlyThatShapeStaysPickedWithoutACrop() async throws {
        let m = await model(width: 800, height: 400)
        m.pickShape(.wide)
        #expect(m.crop == nil && m.shape == .wide, "nothing to cut, the shape stays picked")
        #expect(m.outputPixels?.width == 800 && m.outputPixels?.height == 400, "no crop, no size: the file as it is")
        m.pickShape(.square)
        #expect(m.shape == .square && m.cropPixels?.width == 400 && m.cropPixels?.height == 400)
    }

    @Test func theShapesAreOffUntilThePicturesSizeIsKnown() async throws {
        let m = await model(width: nil, height: nil)
        #expect(!m.canPickShape)
        m.pickShape(.wide)
        #expect(m.shape == .asIs && m.crop == nil, "nothing happens without the size")
        m.useCrop(ImageCropRect(x: 0, y: 0, w: 1, h: 600.0 / 900), width: 1_200, height: 900)   // the crop sheet opened it
        #expect(m.canPickShape && m.shape == .wide)
        let avif = await model(width: 1_200, height: 900, type: "image/avif", name: "capy.avif")
        #expect(!avif.canPickShape, "the server cannot crop an avif")
    }

    @Test func extraWideFixesAFourToOnePictureThatNeedsACrop() async throws {
        let m = await model(width: 2_000, height: 500)
        #expect(m.needsCrop && !m.canUpload)
        m.pickShape(.extraWide)
        #expect(!m.needsCrop && m.canUpload)
        #expect(m.cropPixels?.width == 1_500 && m.cropPixels?.height == 500)
    }

    @Test func aLockedThreeToOneBoxFromTheCropSheetStaysUploadable() async throws {
        let m = await model(width: 1_234, height: 987)
        m.useCrop(ImageCropRect(x: 0.1, y: 0.2, w: 3 * 0.3123 * 987 / 1_234, h: 0.3123), width: 1_234, height: 987)
        #expect(!m.needsCrop && m.canUpload, "a pixel over 3:1 is narrowed, not left to be refused")
        #expect(m.shape == .extraWide)
    }
}
