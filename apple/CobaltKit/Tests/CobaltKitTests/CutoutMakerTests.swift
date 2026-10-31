import CoreGraphics
import Foundation
import Testing
@testable import CobaltKit

// Cutouts on the device (APP-API-CONTRACT 39.3, apple/CONTRACT-EDITOR.md 12): the same flood fill as the server's
// `cutout-core.ts` (edges only keeps white inside, tolerance, trim), the PNG, colour helpers, and the session's server fallback.

/// A white 12 x 9 picture with a red 6 x 3 box at (3, 3) and a white 2 x 1 "eye" in the middle of it.
private func sticker(background: (CGFloat, CGFloat, CGFloat) = (1, 1, 1)) -> CGImage {
    let ctx = CGContext(
        data: nil, width: 12, height: 9, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(red: background.0, green: background.1, blue: background.2, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: 12, height: 9))
    ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    ctx.fill(CGRect(x: 3, y: 3, width: 6, height: 3))           // CG's origin is the bottom-left: rows 3...5 either way
    ctx.setFillColor(red: background.0, green: background.1, blue: background.2, alpha: 1)
    ctx.fill(CGRect(x: 5, y: 4, width: 2, height: 1))
    return ctx.makeImage()!
}

private func alpha(_ image: CGImage, _ x: Int, _ y: Int) -> UInt8 {
    RGBA(image)!.pixels[(y * image.width + x) * 4 + 3]
}

struct CutoutMakerTests {
    @Test func whiteFromTheEdgesKeepsTheEyeAndTrims() throws {
        let out = try CutoutMaker.make(sticker(), .init(mode: .white, soften: 0))
        #expect(out.width == 6 && out.height == 3)
        #expect(alpha(out, 0, 0) == 255)                                // red corner
        #expect(alpha(out, 2, 1) == 255 && alpha(out, 3, 1) == 255)     // the white eye stays
    }

    @Test func whiteEverywhereTakesTheEyeToo() throws {
        let out = try CutoutMaker.make(sticker(), .init(mode: .white, edgesOnly: false, soften: 0))
        #expect(out.width == 6 && out.height == 3)
        #expect(alpha(out, 2, 1) == 0 && alpha(out, 3, 1) == 0)
    }

    @Test func untrimmedKeepsTheSizeAndClearsTheBackground() throws {
        let out = try CutoutMaker.make(sticker(), .init(mode: .white, soften: 0, trim: false))
        #expect(out.width == 12 && out.height == 9)
        #expect(alpha(out, 0, 0) == 0 && alpha(out, 4, 3) == 255)
    }

    @Test func aColourIsTakenOutWithinTheTolerance() throws {
        let green = sticker(background: (0, 0.8, 0))
        let out = try CutoutMaker.make(green, .init(mode: .color, key: (0, 204, 0), tolerance: 10, soften: 0))
        #expect(out.width == 6 && out.height == 3)
        // a key far from the background takes nothing out, so nothing is trimmed
        let none = try CutoutMaker.make(green, .init(mode: .color, key: (0, 0, 255), tolerance: 5, soften: 0))
        #expect(none.width == 12 && none.height == 9)
    }

    @Test func nothingLeftIsEmpty() {
        let white = sticker(background: (1, 0, 0))                      // red on red: everything goes
        #expect(throws: CutoutError.empty) {
            try CutoutMaker.make(white, .init(mode: .color, key: (255, 0, 0), tolerance: 10, edgesOnly: false, soften: 0))
        }
    }

    @Test func softeningDimsTheEdgeOnly() throws {
        let out = try CutoutMaker.make(sticker(), .init(mode: .white, soften: 1, trim: false))
        let edge = alpha(out, 3, 3), inner = alpha(out, 4, 4)
        #expect(edge < 255 && edge > 0)
        #expect(inner == 255 || inner > edge)
    }

    @Test func thePngRoundTrips() throws {
        let out = try CutoutMaker.make(sticker(), .init(mode: .white, soften: 0))
        let png = try #require(CutoutMaker.png(out))
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let back = try #require(CGImageSourceCreateWithData(png as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(back.width == 6 && back.height == 3)
    }

    @Test func coloursParseAndPick() {
        #expect(CutoutMaker.parseHex("#0f0")! == (0, 255, 0))
        #expect(CutoutMaker.parseHex("00cc00")! == (0, 204, 0))
        #expect(CutoutMaker.parseHex("#12345") == nil)
        #expect(CutoutMaker.hex((0, 204, 0)) == "#00cc00")
        let picture = sticker(background: (0, 0.8, 0))
        #expect(CutoutMaker.colour(at: CGPoint(x: 0.02, y: 0.02), in: picture)! == (0, 204, 0))
        #expect(CutoutMaker.colour(at: CGPoint(x: 0.3, y: 0.4), in: picture)! == (255, 0, 0))
        let edge = CutoutMaker.edgeColour(picture)!
        #expect(abs(Int(edge.g) - 204) < 8 && edge.r < 8 && edge.b < 8)
    }
}

@MainActor
struct CutoutSessionTests {
    @Test func withoutThePictureTheServerMakesItAndItGoesOnAFreeLayer() async throws {
        let h = Harness(.happy)
        let client = h.ctx.client as! PreviewClient
        let (full, named) = try await client.editProject(id: PreviewEditorIDs.beach)
        var summary = full
        summary.timeline = nil
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutout-\(UUID().uuidString)", isDirectory: true)
        let cache = EditSourceCache(directory: dir, client: { [ctx = h.ctx] in ctx.client }, provider: { _ in nil })
        let session = EditSession(
            project: summary, timeline: try #require(full.timeline), sources: named, context: h.ctx, cache: cache,
            onProject: { _ in }, onRender: { _ in })
        defer { session.tearDown() }
        #expect(session.canCutout && session.canServerCutout(mode: .auto))
        session.seek(frame: 100)                                        // inside the dance on layer 0
        let photo = PreviewData.editorSources()[PreviewEditorIDs.photo]!
        let made = try await session.makeCutout(of: photo, options: .init(mode: .auto))
        #expect(made.kind == .photo && made.contentType == "image/png")
        let placed = try #require(session.timeline.overlay.first { $0.item == made.id })
        #expect(placed.track == 1)
        #expect(client.editorState.calls.contains("POST /library/items/\(PreviewEditorIDs.photo)/cutout"))
        #expect(session.problems.isEmpty)
    }

    @Test func aCutoutCanReplaceAnOverlaysPicture() async throws {
        let h = Harness(.happy)
        let client = h.ctx.client as! PreviewClient
        let (full, named) = try await client.editProject(id: PreviewEditorIDs.beach)
        var summary = full
        summary.timeline = nil
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutout-\(UUID().uuidString)", isDirectory: true)
        let cache = EditSourceCache(directory: dir, client: { [ctx = h.ctx] in ctx.client }, provider: { _ in nil })
        let session = EditSession(
            project: summary, timeline: try #require(full.timeline), sources: named, context: h.ctx, cache: cache,
            onProject: { _ in }, onRender: { _ in })
        defer { session.tearDown() }
        let dance = try #require(session.timeline.overlay.first)
        let gif = PreviewData.editorSources()[PreviewEditorIDs.dance]!
        let made = try await session.makeCutout(of: gif, options: .init(mode: .white), replacing: dance.id)
        #expect(session.timeline.overlay.count == 1)
        #expect(session.timeline.overlay[0].item == made.id && session.timeline.overlay[0].id == dance.id)
        #expect(session.timeline.overlay[0].at == dance.at && session.timeline.overlay[0].track == dance.track)
    }
}
