import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CobaltKit

// The repost tools' renderer (apple/CONTRACT-GALLERY.md 1.22-1.24, wave A7): the plan's arithmetic, the spec's wire form, and
// rendered pixels from generated test images (JPEG 0.9, sRGB, 1080 on the short side, never upscaled).

// MARK: - test pictures

private struct RGB: Equatable { var r: Int, g: Int, b: Int }

private let red = RGB(r: 235, g: 40, b: 40), blue = RGB(r: 40, g: 60, b: 235)
private let green = RGB(r: 40, g: 200, b: 70), yellow = RGB(r: 240, g: 210, b: 40)

/// A picture of `width`×`height` made of coloured rectangles (`fills`: normalised rect, top-left origin, then the colour),
/// written as a PNG or a JPEG, with an optional EXIF orientation.
private func picture(
    _ name: String, width: Int, height: Int, fills: [(CGRect, RGB)], type: UTType = .png, orientation: Int? = nil
) throws -> URL {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    for (rect, color) in fills {
        context.setFillColor(CGColor(srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1))
        // CoreGraphics' origin is bottom-left; the fills are given top-left
        context.fill(CGRect(
            x: rect.minX * CGFloat(width), y: CGFloat(height) - rect.maxY * CGFloat(height),
            width: rect.width * CGFloat(width), height: rect.height * CGFloat(height)))
    }
    let url = try makeTempDirectory().appendingPathComponent(name)
    let sink = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
    var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 1.0]
    if let orientation { properties[kCGImagePropertyOrientation] = orientation }
    CGImageDestinationAddImage(sink, context.makeImage()!, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(sink))
    return url
}

/// Top half red, bottom half blue.
private func halves(_ width: Int, _ height: Int, type: UTType = .png) throws -> URL {
    try picture("halves.\(type == .png ? "png" : "jpg")", width: width, height: height, fills: [
        (CGRect(x: 0, y: 0, width: 1, height: 0.5), red), (CGRect(x: 0, y: 0.5, width: 1, height: 0.5), blue),
    ], type: type)
}

/// Four quadrants: red, blue (top row), green, yellow (bottom row).
private func quadrants(_ side: Int) throws -> URL {
    try picture("quadrants.png", width: side, height: side, fills: [
        (CGRect(x: 0, y: 0, width: 0.5, height: 0.5), red), (CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5), blue),
        (CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5), green), (CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5), yellow),
    ])
}

private struct Pixels {
    var width: Int, height: Int
    var data: [UInt8]

    init(_ url: URL) throws {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        width = image.width
        height = image.height
        data = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// The colour at (x, y), top-left origin.
    func at(_ x: Int, _ y: Int) -> RGB {
        let i = (y * width + x) * 4
        return RGB(r: Int(data[i]), g: Int(data[i + 1]), b: Int(data[i + 2]))
    }
}

/// True when `a` is within `slack` of `b` on every channel (a JPEG is lossy).
private func near(_ a: RGB, _ b: RGB, slack: Int = 30) -> Bool {
    abs(a.r - b.r) <= slack && abs(a.g - b.g) <= slack && abs(a.b - b.b) <= slack
}

private func output(_ name: String = "out.jpg") throws -> URL { try makeTempDirectory().appendingPathComponent(name) }

// MARK: - the plan

@Suite struct FramePlanTests {
    private let post = CGSize(width: 1080, height: 1350)           // an Instagram carousel photo (4:5)

    @Test func aStoryBlurOfAFourFiveIsTenEightyByNineteenTwentyWithBarsAbove() {
        let plan = FrameRenderer.plan(source: post, spec: FrameSpec(aspect: .story, fill: .blur))
        #expect(plan.output == CGSize(width: 1080, height: 1920))
        #expect(plan.photo == CGRect(x: 0, y: 285, width: 1080, height: 1350), "centred: 285 px of bar above and below")
        #expect(plan.blurRadius == 24, "24 at 1080 px")
    }

    @Test func aSquareBlurKeepsTheWholePhotoAndPillarsIt() {
        let plan = FrameRenderer.plan(source: post, spec: FrameSpec(aspect: .square, fill: .blur))
        #expect(plan.output == CGSize(width: 1080, height: 1080))
        #expect(plan.photo == CGRect(x: 108, y: 0, width: 864, height: 1080))
    }

    @Test func aBlurOfThePhotosOwnShapeHasNoBars() {
        let plan = FrameRenderer.plan(source: post, spec: FrameSpec(aspect: .portrait, fill: .blur))
        #expect(plan.output == CGSize(width: 1080, height: 1350) && plan.photo == CGRect(x: 0, y: 0, width: 1080, height: 1350))
    }

    @Test func aBiggerSourceIsScaledDownToTheShortSide() {
        let plan = FrameRenderer.plan(source: CGSize(width: 3024, height: 4032), spec: FrameSpec(aspect: .story, fill: .blur))
        #expect(plan.output == CGSize(width: 1080, height: 1920))
        let cut = FrameRenderer.plan(source: CGSize(width: 3024, height: 4032), spec: FrameSpec(aspect: .classic, fill: .cut))
        #expect(cut.output == CGSize(width: 1080, height: 1440), "3:4 of a 3:4 photo is the whole photo, at 1080")
        #expect(cut.region == CGRect(x: 0, y: 0, width: 3024, height: 4032))
    }

    @Test func aSmallSourceIsNeverUpscaled() {
        let small = CGSize(width: 600, height: 750)
        #expect(FrameRenderer.plan(source: small, spec: FrameSpec(aspect: .story, fill: .blur)).output == CGSize(width: 600, height: 1067))
        let cut = FrameRenderer.plan(source: CGSize(width: 600, height: 600), spec: FrameSpec(aspect: .square, fill: .cut))
        #expect(cut.output == CGSize(width: 600, height: 600))
        #expect(FrameRenderer.plan(source: small, spec: FrameSpec(aspect: .story, fill: .blur)).blurRadius < 24, "the blur follows the output's size")
    }

    @Test func aCutWithoutARectIsTheLargestCentredFrame() {
        let plan = FrameRenderer.plan(source: post, spec: FrameSpec(aspect: .story, fill: .cut))
        #expect(plan.photo == nil)
        #expect(plan.region.height == 1350 && abs(plan.region.width - 759) <= 1 && abs(plan.region.midX - 540) <= 1)
        #expect(plan.output.width == plan.region.width && abs(plan.output.height - plan.region.width * 16 / 9) <= 1)
    }

    @Test func aCutWithARectKeepsThatRegionReshapedToTheAspect() {
        // the owner's rectangle, 600×600 at (100, 200) of a 1000×1000 photo, locked to 9:16: the largest 9:16 inside it
        let spec = FrameSpec(aspect: .story, fill: .cut, rect: CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.6))
        let region = FrameRenderer.cutRegion(source: CGSize(width: 1000, height: 1000), spec: spec)
        #expect(region.height == 600 && abs(region.width - 337) <= 1 && abs(region.midX - 400) <= 1 && region.minY == 200)
    }

    @Test func aFreeCropKeepsItsOwnShape() {
        let spec = FrameSpec(aspect: .free, fill: .blur, rect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        let plan = FrameRenderer.plan(source: CGSize(width: 2000, height: 1000), spec: spec)
        #expect(spec.effectiveFill == .cut, "there are no bars around a free crop")
        #expect(plan.region == CGRect(x: 500, y: 250, width: 1000, height: 500))
        #expect(plan.output == CGSize(width: 1000, height: 500))
        let big = FrameRenderer.plan(source: CGSize(width: 4000, height: 2000), spec: FrameSpec(aspect: .free))
        #expect(big.output == CGSize(width: 2160, height: 1080), "scaled to 1080 on the short side")
    }

    @Test func aRectOutsideThePhotoIsClampedAndNonsenseFallsBackToTheWholePhoto() {
        let source = CGSize(width: 800, height: 600)
        let over = FrameRenderer.cutRegion(source: source, spec: FrameSpec(aspect: .free, fill: .cut, rect: CGRect(x: 0.9, y: 0.9, width: 0.5, height: 0.5)))
        #expect(CGRect(origin: .zero, size: source).contains(over) && over.width >= 1)
        let empty = FrameRenderer.cutRegion(source: source, spec: FrameSpec(aspect: .free, fill: .cut, rect: CGRect(x: 2, y: 2, width: 1, height: 1)))
        #expect(empty == CGRect(origin: .zero, size: source))
    }

    @Test func aPreviewAtASmallerShortSideFollowsTheSameShape() {
        let plan = FrameRenderer.plan(source: post, spec: FrameSpec(aspect: .story, fill: .blur), shortSide: 270)
        #expect(plan.output == CGSize(width: 270, height: 480) && plan.blurRadius == 6)
    }
}

// MARK: - the spec

@Suite struct FrameSpecTests {
    @Test func theWireIsTheMadeSpecOfACrop() throws {
        let blur = FrameSpec(aspect: .story, fill: .blur, rect: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.5))
        #expect(String(decoding: blur.wireData, as: UTF8.self) == #"{"aspect":"9:16","fill":"blur"}"#, "a blur has no rectangle")
        let cut = FrameSpec(aspect: .portrait, fill: .cut, rect: CGRect(x: 0.123456, y: 0.2, width: 0.5, height: 0.75))
        #expect(String(decoding: cut.wireData, as: UTF8.self) == #"{"aspect":"4:5","fill":"cut","rect":[0.1235,0.2,0.5,0.75]}"#)
        #expect(cut.wireData.count <= 512)
    }

    @Test func aStoredSpecReadsBackAsAFrameAndNamesTheTab() throws {
        let cut = FrameSpec(aspect: .classic, fill: .cut, rect: CGRect(x: 0.25, y: 0, width: 0.5, height: 0.9))
        let made = try #require(MadeSpec(data: cut.wireData))
        let back = try #require(made.frame)
        #expect(back.aspect == .classic && back.fill == .cut && back.rect == CGRect(x: 0.25, y: 0, width: 0.5, height: 0.9))
        #expect(back.tabName == "crop 3:4" && FrameSpec(aspect: .free).tabName == "crop")
        #expect(MadeSpec(data: Data(#"{"kind":"gallery"}"#.utf8))?.frame == nil, "not a crop's spec")
        #expect(MadeSpec(data: Data(#"{"aspect":"7:5","fill":"cut"}"#.utf8))?.frame == nil, "a shape this build does not know")
    }

    @Test func aCropTabIsNamedByItsAspect() {
        let spec = MadeSpec(data: FrameSpec(aspect: .story, fill: .blur).wireData)
        let crop = Rendition(id: "m:1", kind: .crop(of: 2, spec: spec), createdAt: Date())
        #expect(crop.tabName == "crop 9:16")
        #expect(Rendition(id: "m:2", kind: .crop(of: 2, spec: nil), createdAt: Date()).tabName == "crop", "a row with no spec says just crop")
        #expect(Rendition(id: "m:3", kind: .crop(of: 0, spec: MadeSpec(data: FrameSpec(aspect: .free).wireData)), createdAt: Date()).tabName == "crop")
    }

    @Test func theRepostShapesAreNineSixteenSquareAndFourFive() {
        #expect(FrameSpec.Aspect.repost.map(\.label) == ["9:16", "1:1", "4:5"])
        #expect(FrameSpec.Aspect.allCases.map(\.label) == ["1:1", "4:5", "9:16", "3:4", "free"])
    }
}

// MARK: - rendered pixels

@Suite struct FrameRenderTests {
    @Test func aStoryBlurOfAFourFiveIsTenEightyByNineteenTwentyWithABlurredBarNotBlack() async throws {
        let source = try halves(1080, 1350)
        let out = try output()
        let made = try await FrameRenderer.render(source, spec: FrameSpec(aspect: .story, fill: .blur), to: out)
        let onDisk = (try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? NSNumber)?.int64Value
        #expect(made.width == 1080 && made.height == 1920 && made.bytes > 0 && made.bytes == onDisk)
        let p = try Pixels(out)
        #expect(p.width == 1080 && p.height == 1920)
        // the bars are the photo, blurred and a touch darker: red above, blue below, never black
        let top = p.at(540, 60), bottom = p.at(540, 1860)
        #expect(top.r > 150 && top.g < 90 && top.b < 90, "red bar: \(top)")
        #expect(bottom.b > 150 && bottom.r < 90, "blue bar: \(bottom)")
        // the photo itself sits whole in the middle, sharp: red over blue, split at the middle of the frame
        #expect(near(p.at(540, 700), red) && near(p.at(540, 1250), blue))
        #expect(near(p.at(540, 940), red) && near(p.at(540, 980), blue), "the split stays sharp (the photo is not blurred)")
    }

    @Test func theOutputIsAJpegAndAPhotoOfTheFramesOwnShapeIsNotBlurred() async throws {
        let out = try output()
        try await FrameRenderer.render(try halves(1080, 1080), spec: FrameSpec(aspect: .square, fill: .cut), to: out)
        let source = try #require(CGImageSourceCreateWithURL(out as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect((props[kCGImagePropertyPixelWidth] as? Int) == 1080)
        // a photo of the frame's own shape has no bars and is not blurred: its pixels are the photo's
        let p = try Pixels(out)
        #expect(near(p.at(540, 200), red) && near(p.at(540, 880), blue))
    }

    @Test func aCutWithARectGivesThatRegion() async throws {
        let source = try quadrants(1000)
        let out = try output()
        // the bottom right quarter, free: 500×500, all yellow
        let spec = FrameSpec(aspect: .free, fill: .cut, rect: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        let made = try await FrameRenderer.render(source, spec: spec, to: out)
        #expect(made.width == 500 && made.height == 500, "not upscaled: the region is smaller than 1080")
        let p = try Pixels(out)
        #expect([(20, 20), (480, 20), (20, 480), (480, 480), (250, 250)].allSatisfy { near(p.at($0.0, $0.1), yellow) })
        // the top left quarter is red
        let other = try output("other.jpg")
        try await FrameRenderer.render(source, spec: FrameSpec(aspect: .free, fill: .cut, rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5)), to: other)
        #expect(near(try Pixels(other).at(250, 250), red))
    }

    @Test func aCutKeepsTheMiddleOfAFreeCropsShape() async throws {
        // a rectangle straddling the middle: green left, yellow right (bottom row), 600×300 of a 1000×1000 photo
        let spec = FrameSpec(aspect: .free, fill: .cut, rect: CGRect(x: 0.2, y: 0.55, width: 0.6, height: 0.3))
        let out = try output()
        let made = try await FrameRenderer.render(try quadrants(1000), spec: spec, to: out)
        #expect(made.width == 600 && made.height == 300)
        let p = try Pixels(out)
        #expect(near(p.at(100, 150), green) && near(p.at(500, 150), yellow))
    }

    @Test func aSmallSourceKeepsItsSize() async throws {
        let out = try output()
        let made = try await FrameRenderer.render(try halves(600, 600), spec: FrameSpec(aspect: .square, fill: .cut), to: out)
        #expect(made.width == 600 && made.height == 600)
        let blur = try await FrameRenderer.render(try halves(600, 750), spec: FrameSpec(aspect: .story, fill: .blur), to: try output("b.jpg"))
        #expect(made.width == 600 && blur.width == 600 && blur.height == 1067)
    }

    @Test func aBiggerSourceIsMadeTenEighty() async throws {
        let made = try await FrameRenderer.render(
            try halves(3000, 4000), spec: FrameSpec(aspect: .classic, fill: .cut), to: try output())
        #expect(made.width == 1080 && made.height == 1440)
    }

    @Test func theFileIsReadUprightWhateverItsRotation() async throws {
        // 200 wide by 100 tall, tagged "rotate 90 clockwise" (orientation 6): the owner sees it 100 wide by 200 tall
        let source = try picture("rotated.jpg", width: 200, height: 100, fills: [
            (CGRect(x: 0, y: 0, width: 0.5, height: 1), red), (CGRect(x: 0.5, y: 0, width: 0.5, height: 1), blue),
        ], type: .jpeg, orientation: 6)
        #expect(FrameRenderer.sourceSize(of: source) == CGSize(width: 100, height: 200))
        let out = try output()
        let made = try await FrameRenderer.render(source, spec: FrameSpec(aspect: .free), to: out)
        #expect(made.width == 100 && made.height == 200)
        // the left half (red) became the top, the right half (blue) the bottom
        let p = try Pixels(out)
        #expect(near(p.at(50, 40), red) && near(p.at(50, 160), blue))
    }

    @Test func aFileThatIsNotAPictureThrows() async throws {
        let junk = try makeTempFile("not-a-photo.jpg")
        await #expect(throws: FrameRenderer.Failure.unreadable) {
            try await FrameRenderer.render(junk, spec: FrameSpec(aspect: .story), to: try output())
        }
        #expect(FrameRenderer.sourceSize(of: junk) == nil)
    }

    @Test func aRenderReplacesAnExistingFile() async throws {
        let out = try output()
        try await FrameRenderer.render(try halves(300, 300), spec: FrameSpec(aspect: .square, fill: .cut), to: out)
        let first = (try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? NSNumber)?.int64Value
        try await FrameRenderer.render(try halves(900, 900), spec: FrameSpec(aspect: .square, fill: .cut), to: out)
        let second = (try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? NSNumber)?.int64Value
        #expect(first != nil && second != nil && second! > first!)
        #expect(try Pixels(out).width == 900)
    }
}
