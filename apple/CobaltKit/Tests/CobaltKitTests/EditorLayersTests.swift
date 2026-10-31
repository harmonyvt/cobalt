import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import CobaltKit

// Overlay layers (APP-API-CONTRACT 39.1, apple/CONTRACT-EDITOR.md 12): `track` in the JSON, the per-layer overlap rule, the draw
// order, the composer stacking layers, the session placing overlays on a free layer, and the capability.

private let story = EditCanvas(w: 1080, h: 1920, fps: 30)
private func clip(_ out: Double = 10) -> EditClip { EditClip(id: "cAAAAAAAA", item: PreviewEditorIDs.pier, in: 0, out: out) }
private func overlay(_ id: String, at: Double, length: Double = 2, track: Int = 0, item: String = PreviewEditorIDs.photo) -> EditOverlay {
    EditOverlay(id: id, item: item, at: at, in: 0, out: length, frame: EditFrame(x: 0.1, y: 0.1, w: 0.3), track: track)
}

struct EditLayersJSONTests {
    @Test func layerZeroIsLeftOutAndOthersRoundTrip() throws {
        let t = EditTimeline(canvas: story, main: [clip()], overlay: [overlay("cO0000001", at: 1), overlay("cO0000002", at: 1, track: 3)])
        let bytes = try EditJSON.encode(t)
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.components(separatedBy: "\"track\"").count == 2)          // only the layer 3 overlay names it
        #expect(text.contains("\"track\":3"))
        let back = try EditJSON.decode(bytes)
        #expect(back.overlay.map(\.track) == [0, 3])
        #expect(try EditJSON.encode(back) == bytes)
    }

    @Test func aTimelineWithoutLayersKeepsItsBytes() throws {
        let t = EditJSON.rounded(PreviewData.editorBeachTimeline())
        #expect(!String(decoding: try EditJSON.encode(t), as: UTF8.self).contains("track"))
    }

    @Test func drawOrderIsLayerThenArrayOrder() {
        let t = EditTimeline(canvas: story, main: [clip()], overlay: [
            overlay("cO0000001", at: 0, track: 2), overlay("cO0000002", at: 1, track: 0), overlay("cO0000003", at: 2, track: 2),
            overlay("cO0000004", at: 3, track: 1),
        ])
        #expect(t.overlayDrawOrder == [1, 3, 0, 2])
        #expect(t.overlayTracks == [0, 1, 2])
        #expect(EditJSON.withoutTracks(t).overlay.allSatisfy { $0.track == 0 })
    }
}

struct EditLayersValidationTests {
    private let sources = PreviewData.editorSources()

    @Test func overlapIsAllowedAcrossLayersOnly() {
        let across = EditTimeline(canvas: story, main: [clip()], overlay: [overlay("cO0000001", at: 1), overlay("cO0000002", at: 1.5, track: 1)])
        #expect(EditValidation.check(across, sources: sources).isEmpty)
        let same = EditTimeline(canvas: story, main: [clip()], overlay: [overlay("cO0000001", at: 1, track: 1), overlay("cO0000002", at: 1.5, track: 1)])
        #expect(EditValidation.check(same, sources: sources) == [.overlayOverlap(path: "overlay[1]")])
    }

    @Test func overlaysMustStillBeSortedByStart() {
        let t = EditTimeline(canvas: story, main: [clip()], overlay: [overlay("cO0000001", at: 5), overlay("cO0000002", at: 1, track: 1)])
        #expect(EditValidation.check(t, sources: sources) == [.overlayOverlap(path: "overlay[1]")])
    }

    @Test func aLayerPastSevenIsOutOfRange() {
        let t = EditTimeline(canvas: story, main: [clip()], overlay: [overlay("cO0000001", at: 1, track: 8)])
        #expect(EditValidation.check(t, sources: sources).contains(.range(path: "overlay[0].track")))
    }
}

struct EditLayersComposerTests {
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    private func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGImage {
        let ctx = CGContext(
            data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        return ctx.makeImage()!
    }

    /// RGB at canvas pixel (x, y), top row first.
    private func pixel(_ image: CIImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        var buffer = [UInt8](repeating: 0, count: 4)
        context.render(image, toBitmap: &buffer, rowBytes: 4, bounds: CGRect(x: x, y: 1920 - 1 - y, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return (Int(buffer[0]), Int(buffer[1]), Int(buffer[2]))
    }

    @Test func aHigherLayerIsDrawnOnTopWhateverItsPlaceInTheList() {
        // green on layer 1 comes first in the list, blue on layer 0 second: green must win where they cover each other
        let t = EditTimeline(canvas: story, main: [clip()], overlay: [
            overlay("cO0000001", at: 1, length: 3, track: 1), overlay("cO0000002", at: 1, length: 3, track: 0),
        ])
        let plan = EditRenderPlan(
            timeline: t, timing: EditTiming(t),
            main: [EditRenderPlan.MainClip(display: PixelSize(w: 1280, h: 720), orientation: .up, trackID: 1)],
            overlay: [
                EditRenderPlan.OverlayClip(display: PixelSize(w: 40, h: 30), source: .photo(solid(0, 1, 0))),
                EditRenderPlan.OverlayClip(display: PixelSize(w: 40, h: 30), source: .photo(solid(0, 0, 1))),
            ])
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720))
        let up = EditFrameComposer.compose(plan: plan, frame: 60, main: red, overlayVideos: [:])
        let p = pixel(up, 250, 250)                       // inside (108, 192, 324 x 243)
        #expect(p.g > 240 && p.b < 15 && p.r < 15)
        let before = EditFrameComposer.compose(plan: plan, frame: 10, main: red, overlayVideos: [:])
        #expect(pixel(before, 250, 250).r > 240)
    }
}

@MainActor
struct EditLayersSessionTests {
    /// A session on the preview's "beach day edit" (dance.gif on layer 0 at 3 s for 3 s, frames 90...180).
    @MainActor private struct Rig {
        let h: Harness
        let session: EditSession
        let sources: [String: EditSource]

        init(layers: Int = 8) async throws {
            h = Harness(.happy)
            h.ctx.capabilities.limits.editOverlayTracks = layers
            let client = h.ctx.client as! PreviewClient
            let (full, named) = try await client.editProject(id: PreviewEditorIDs.beach)
            var summary = full
            summary.timeline = nil
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("edit-layers-\(UUID().uuidString)", isDirectory: true)
            let cache = EditSourceCache(directory: dir, client: { [ctx = h.ctx] in ctx.client }, provider: { _ in nil })
            sources = PreviewData.editorSources()
            session = EditSession(
                project: summary, timeline: try #require(full.timeline), sources: named, context: h.ctx, cache: cache,
                onProject: { _ in }, onRender: { _ in })
        }

        func finish() { session.tearDown() }
        var photo: EditSource { sources[PreviewEditorIDs.photo]! }
    }

    @Test func aBusySpotGoesOnTheNextFreeLayer() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        #expect(rig.session.addOverlay(rig.photo, atFrame: 100))
        let added = try #require(rig.session.timeline.overlay.first { $0.item == PreviewEditorIDs.photo })
        #expect(added.track == 1)
        #expect(rig.session.addOverlay(rig.photo, atFrame: 100))
        #expect(rig.session.timeline.overlay.filter { $0.item == PreviewEditorIDs.photo }.map(\.track).sorted() == [1, 2])
        #expect(rig.session.problems.isEmpty)
    }

    @Test func anOlderServerKeepsOneLayer() async throws {
        let rig = try await Rig(layers: 1)
        defer { rig.finish() }
        #expect(rig.session.overlayTrackLimit == 1)
        #expect(!rig.session.addOverlay(rig.photo, atFrame: 100))
        #expect(!rig.session.addOverlay(rig.photo, atFrame: 100, track: 1))
        #expect(rig.session.timeline.overlay.count == 1)
    }

    @Test func changingLayerNeedsRoomThere() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        #expect(rig.session.addOverlay(rig.photo, atFrame: 100))           // layer 1, 100...190
        let photo = try #require(rig.session.timeline.overlay.first { $0.item == PreviewEditorIDs.photo }).id
        let dance = try #require(rig.session.timeline.overlay.first { $0.item == PreviewEditorIDs.dance }).id
        #expect(!rig.session.setOverlayTrack(id: photo, 0))                // dance is there
        #expect(rig.session.setOverlayTrack(id: photo, 4))
        #expect(rig.session.timeline.overlay.first { $0.id == photo }?.track == 4)
        #expect(rig.session.setOverlayTrack(id: dance, 2))
        #expect(rig.session.problems.isEmpty)
    }

    @Test func movingWithinALayerStopsAtItsNeighboursOnly() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        #expect(rig.session.addOverlay(rig.photo, atFrame: 100))           // layer 1: the dance on layer 0 is no neighbour
        let photo = try #require(rig.session.timeline.overlay.first { $0.item == PreviewEditorIDs.photo }).id
        rig.session.moveOverlay(id: photo, toFrame: 0)
        #expect(rig.session.timeline.overlay.first { $0.id == photo }?.at == 0)
        rig.session.endGesture()
        // onto layer 0 inside the dance: it goes in the gap after it
        #expect(rig.session.moveOverlay(id: photo, toFrame: 120, track: 0))
        let moved = try #require(rig.session.timeline.overlay.first { $0.id == photo })
        #expect(moved.track == 0 && moved.at == 6)
        #expect(rig.session.problems.isEmpty)
    }

    @Test func theTimelineStaysSortedAfterAMoveAcrossOthers() async throws {
        let rig = try await Rig()
        defer { rig.finish() }
        #expect(rig.session.addOverlay(rig.photo, atFrame: 300))           // layer 0, after the dance
        let photo = try #require(rig.session.timeline.overlay.first { $0.item == PreviewEditorIDs.photo }).id
        #expect(rig.session.moveOverlay(id: photo, toFrame: 30, track: 1))
        let ats = rig.session.timeline.overlay.map(\.at)
        #expect(ats == ats.sorted())
        #expect(rig.session.timeline.overlay.first?.id == photo)
        #expect(rig.session.problems.isEmpty)
    }
}

struct EditLayersCapabilityTests {
    private func caps(_ rest: String) throws -> Capabilities {
        let json = #"{"server":"cobalt-cloudflare"\#(rest),"key":"valid"}"#
        return try #require(HTTPCobaltClient.parseForkCapabilities(Data(json.utf8)))
    }

    @Test func layersAndCutoutsAreReadAndOffWhenAbsent() throws {
        let on = try caps(#","features":{"editor":true,"cutout":true,"cutout_auto":true},"limits":{"edit_overlay_tracks":8}"#)
        #expect(on.limits.editOverlayTracks == 8 && on.cutout && on.cutoutAuto)
        let off = try caps(#","features":{"editor":true}"#)
        #expect(off.limits.editOverlayTracks == 1 && !off.cutout && !off.cutoutAuto)
        let odd = try caps(#","features":{"cutout_auto":true},"limits":{"edit_overlay_tracks":99}"#)
        #expect(odd.limits.editOverlayTracks == 8 && !odd.cutoutAuto)
    }
}
