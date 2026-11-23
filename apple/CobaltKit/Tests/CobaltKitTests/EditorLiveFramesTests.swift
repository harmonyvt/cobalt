import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import CobaltKit

// The picture follows a finger (CONTRACT-EDITOR 15.3): the seek queue a redraw rides on, which clips the session puts in
// `EditLiveFrames`, that the compositor draws them, and, on a real player over the generated preview files, that a frame
// change in the middle of a drag reaches the picture with no rebuild.

struct EditSeekChaseTests {
    private typealias Target = EditSeekChase.Target

    @Test func oneSeekInFlightAndTheLatestWins() {
        var chase = EditSeekChase()
        #expect(chase.request(Target(frame: 1, exact: false)) == Target(frame: 1, exact: false))
        #expect(chase.request(Target(frame: 2, exact: false)) == nil)
        #expect(chase.request(Target(frame: 3, exact: true)) == nil)
        #expect(chase.landed() == Target(frame: 3, exact: true))          // 2 was never sent
        #expect(chase.inFlight)
        #expect(chase.landed() == nil)
        #expect(!chase.inFlight)
        #expect(chase.landed() == nil)                                      // a stray completion changes nothing
    }

    @Test func aBurstOfRedrawsIsOneSeekNowAndOneWhenItLands() {
        var chase = EditSeekChase()
        #expect(chase.redraw(at: 30) == Target(frame: 30, exact: true, redraw: true))
        for _ in 0..<20 { #expect(chase.redraw(at: 30) == nil) }
        #expect(chase.landed() == Target(frame: 30, exact: true, redraw: true))
        #expect(chase.landed() == nil)
        #expect(!chase.inFlight)
    }

    @Test func aRedrawNeverReplacesAScrubTargetWaitingBehindTheSeekInFlight() {
        var chase = EditSeekChase()
        _ = chase.request(Target(frame: 10, exact: false))
        _ = chase.request(Target(frame: 12, exact: false))
        #expect(chase.redraw(at: 12) == nil)
        // the scrub's own target draws the frame, marked so it composes again even at a frame already shown
        #expect(chase.landed() == Target(frame: 12, exact: false, redraw: true))
    }

    @Test func aRebuildsSeekDropsWhatWaits() {
        var chase = EditSeekChase()
        _ = chase.request(Target(frame: 10, exact: true))
        _ = chase.redraw(at: 10)
        chase.dropPending()
        #expect(chase.landed() == nil)
        #expect(!chase.inFlight)
    }
}

struct EditLiveFramesTests {
    private let canvas = EditCanvas(w: 1080, h: 1920, fps: 30)

    private func timeline(_ clips: [EditLaneClip]) -> EditTimeline { EditTimeline(canvas: canvas, clips: clips) }

    @Test func onlyClipsWhoseFrameOrOpacityChangedAreLive() {
        let a = EditLaneClip(id: "a", item: "AAAAAAAAAAAAAAAA", lane: 0, at: 0, in: 0, out: 2)
        let b = EditLaneClip(id: "b", item: "AAAAAAAAAAAAAAAA", lane: 1, at: 0, in: 0, out: 2, frame: EditFrame(x: 0.1, y: 0.1, w: 0.3))
        let playing = EditJSON.rounded(timeline([a, b]))
        #expect(EditLiveFrames.overrides(playing: playing, current: playing).isEmpty)

        var moved = playing
        moved.clips[1].frame = EditFrame(x: 0.40004, y: 0.1, w: 0.3, r: 12.04)
        moved.clips[0].opacity = 0.5
        moved.clips[0].volume = 0.2                                         // not part of the picture
        let live = EditLiveFrames.overrides(playing: playing, current: moved)
        #expect(live.count == 2)
        #expect(live["a"] == EditLiveFrames.Clip(frame: nil, opacity: 0.5))
        // rounded as a build rounds it
        #expect(live["b"] == EditLiveFrames.Clip(frame: EditFrame(x: 0.4, y: 0.1, w: 0.3, r: 12), opacity: 1))

        // a frame taken away is live too: the clip goes back to fill straight away
        var reset = playing
        reset.clips[1].frame = nil
        #expect(EditLiveFrames.overrides(playing: playing, current: reset)["b"] == EditLiveFrames.Clip(frame: nil, opacity: 1))

        // a clip added since the build is not drawable without one
        var added = playing
        added.clips.append(EditLaneClip(id: "c", item: "AAAAAAAAAAAAAAAA", lane: 2, at: 0, in: 0, out: 1, frame: EditFrame(x: 0, y: 0, w: 0.2)))
        #expect(EditLiveFrames.overrides(playing: playing, current: added).isEmpty)

        // version 1 has no lanes path
        let v1 = EditTimeline.new(canvas: canvas, main: [EditClip(id: "m", item: "AAAAAAAAAAAAAAAA", in: 0, out: 2)])
        #expect(EditLiveFrames.overrides(playing: v1, current: v1).isEmpty)
    }

    @Test func replaceSaysWhetherAnythingChanged() {
        let store = EditLiveFrames()
        #expect(!store.replace([:]))
        let one = ["a": EditLiveFrames.Clip(frame: EditFrame(x: 0, y: 0, w: 0.5), opacity: 1)]
        #expect(store.replace(one))
        #expect(!store.replace(one))
        #expect(store.snapshot() == one)
        #expect(store.replace([:]))
    }

    @Test func theStoreIsSafeToWriteWhileItIsRead() async {
        let store = EditLiveFrames()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for i in 0..<2_000 { store.replace(["a": .init(frame: EditFrame(x: Double(i % 10) / 10, y: 0, w: 0.2), opacity: 1)]) }
            }
            group.addTask {
                for _ in 0..<2_000 { _ = store.snapshot()["a"]?.frame?.w }
            }
        }
        #expect(store.snapshot()["a"]?.frame?.w == 0.2)
    }

    // MARK: the compositor reads it

    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    private func pixels(_ image: CIImage) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: 1080 * 1920 * 4)
        context.render(image, toBitmap: &buffer, rowBytes: 1080 * 4, bounds: CGRect(x: 0, y: 0, width: 1080, height: 1920),
                       format: .RGBA8, colorSpace: nil)
        return buffer
    }

    private func red(at p: [UInt8], _ x: Int, _ y: Int) -> Bool {
        let i = (y * 1080 + x) * 4
        return p[i] > 200 && p[i + 1] < 40 && p[i + 2] < 40
    }

    private func redPhoto() -> (CGImage, CIImage) {
        let ctx = CGContext(
            data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let image = ctx.makeImage()!
        return (image, EditFrameComposer.ciImage(image))
    }

    @Test func theCompositorDrawsTheLiveFrameAndOpacityNotThePlans() {
        let clip = EditLaneClip(id: "p", item: "PPPPPPPPPPPPPPPP", lane: 0, at: 0, in: 0, out: 2, frame: EditFrame(x: 0, y: 0, w: 0.25))
        let t = EditJSON.rounded(timeline([clip]))
        let (cg, ci) = redPhoto()
        let store = EditLiveFrames()
        let plan = EditRenderPlan(
            timeline: t, timing: EditTiming(t), main: [], overlay: [],
            lanes: ["p": .photo(cg, display: PixelSize(w: 100, h: 100), imageCI: ci)], live: store)

        // as built: a red square in the top-left corner only
        var p = pixels(EditFrameComposer.composeLanes(plan: plan, frame: 5, videos: [:]))
        #expect(red(at: p, 50, 50))
        #expect(!red(at: p, 1030, 50))

        // moved to the top-right while the plan is unchanged
        store.replace(["p": .init(frame: EditFrame(x: 0.75, y: 0, w: 0.25), opacity: 1)])
        p = pixels(EditFrameComposer.composeLanes(plan: plan, frame: 5, videos: [:]))
        #expect(!red(at: p, 50, 50))
        #expect(red(at: p, 1030, 50))

        // the frame taken away: fill covers the canvas
        store.replace(["p": .init(frame: nil, opacity: 1)])
        p = pixels(EditFrameComposer.composeLanes(plan: plan, frame: 5, videos: [:]))
        #expect(red(at: p, 540, 960) && red(at: p, 60, 1800) && red(at: p, 1020, 120))

        // lane 0 at half opacity over the black base
        store.replace(["p": .init(frame: nil, opacity: 0.5)])
        p = pixels(EditFrameComposer.composeLanes(plan: plan, frame: 5, videos: [:]))
        let i = (960 * 1080 + 540) * 4
        #expect(abs(Int(p[i]) - 128) < 12 && p[i + 1] < 20)

        // an override for another clip does nothing here
        store.replace(["other": .init(frame: nil, opacity: 0.1)])
        p = pixels(EditFrameComposer.composeLanes(plan: plan, frame: 5, videos: [:]))
        #expect(red(at: p, 50, 50) && !red(at: p, 1030, 50))
    }
}

// MARK: - a real player

/// The beach project over the generated preview files, version 2 in memory, with a server that saves version 2. The harness
/// clock does not move, so a rebuild scheduled with a delay (the one a drag holds back) never runs: any change in the picture
/// during the drag comes from the live path.
@MainActor
private final class PictureFollowRig {
    let h: Harness
    let session: EditSession

    init() async throws {
        h = Harness(.happy)
        h.ctx.capabilities.limits.editTimelineVersion = 2
        h.ctx.capabilities.limits.editOverlayTracks = 64
        let client = h.ctx.client as! PreviewClient
        let (full, named) = try await client.editProject(id: PreviewEditorIDs.beach)
        var summary = full
        summary.timeline = nil
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("edit-live-\(UUID().uuidString)", isDirectory: true)
        let cache = EditSourceCache(
            directory: dir, client: { [ctx = h.ctx] in ctx.client },
            provider: { await PreviewEditorMedia.shared.url(forFile: $0) })
        session = EditSession(
            project: summary, timeline: try #require(full.timeline), sources: named, context: h.ctx, cache: cache,
            onProject: { _ in }, onRender: { _ in })
    }

    /// Real time: AVFoundation decodes off the harness clock. 20 s at most.
    func wait(_ seconds: Double = 20, until condition: @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() >= end { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }
}

/// The centre pixel of the newest frame the player item put out, as RGB.
@MainActor
private func centre(_ output: AVPlayerItemVideoOutput, at time: CMTime) -> (r: Int, g: Int, b: Int)? {
    guard output.hasNewPixelBuffer(forItemTime: time),
          let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return nil }
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
    let row = base.advanced(by: (h / 2) * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: UInt8.self)
    let i = (w / 2) * 4
    return (Int(row[i + 2]), Int(row[i + 1]), Int(row[i]))                 // BGRA
}

@MainActor
struct EditLivePlayerTests {
    @Test func aDragMovesThePausedPictureWithNoRebuild() async throws {
        let rig = try await PictureFollowRig()
        defer { rig.session.tearDown() }
        let s = rig.session
        #expect(s.timeline.isV2)
        #expect(await rig.wait { s.isPlayerReady && s.playable != nil })
        let item = try #require(s.player.currentItem)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        ])
        item.add(output)
        s.seek(frame: 30)                                                   // 1 s into pier, which fills the canvas
        let time = CMTime(value: 30, timescale: 30)
        var last: (r: Int, g: Int, b: Int)?
        let drawn = await rig.wait {
            if let px = centre(output, at: time) { last = px }
            return (last?.b ?? 0) > 60                                      // pier is #3b5b73
        }
        #expect(drawn, "the paused player never put out the first frame: \(String(describing: last))")
        let builds = s.builds
        let pier = try #require(s.timeline.clips.first { $0.lane == 0 && $0.at == 0 })

        // a drag: the pier clip shrinks into the top-left corner, finger still down
        s.beginGesture()
        #expect(s.setClipFrame(id: pier.id, EditFrame(x: 0, y: 0, w: 0.2)))
        #expect(s.liveFrames.snapshot()[pier.id]?.frame == EditFrame(x: 0, y: 0, w: 0.2))
        let followed = await rig.wait(5) {
            if let px = centre(output, at: time) { last = px }
            return (last?.b ?? 255) < 12 && (last?.r ?? 255) < 12           // the centre is the black base now
        }
        #expect(followed, "the picture did not follow the drag: \(String(describing: last))")
        #expect(s.builds == builds)                                         // no rebuild: the live path drew it

        // more ticks of the same drag: each lands (the same frame again is nudged, so it is composed again)
        #expect(s.setClipFrame(id: pier.id, EditFrame(x: 0.1, y: 0.4, w: 0.8)))    // covers the centre again
        let back = await rig.wait(5) {
            if let px = centre(output, at: time) ?? centre(output, at: CMTime(value: 30_001, timescale: 30_000)) { last = px }
            return (last?.b ?? 0) > 60
        }
        #expect(back, "the second tick did not reach the picture: \(String(describing: last))")
        #expect(s.builds == builds)

        // control: the store changed with no redraw asked for, and a paused player does not compose again by itself
        s.liveFrames.replace([pier.id: .init(frame: EditFrame(x: 0, y: 0, w: 0.2), opacity: 1)])
        try await Task.sleep(for: .milliseconds(800))
        #expect(!output.hasNewPixelBuffer(forItemTime: time))
        #expect(!output.hasNewPixelBuffer(forItemTime: CMTime(value: 30_001, timescale: 30_000)))
        s.endGesture()
    }

    @Test func aDragWhilePlayingIsPickedUpByTheNextFrames() async throws {
        let rig = try await PictureFollowRig()
        defer { rig.session.tearDown() }
        let s = rig.session
        #expect(await rig.wait { s.isPlayerReady && s.playable != nil })
        let item = try #require(s.player.currentItem)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        ])
        item.add(output)
        let pier = try #require(s.timeline.clips.first { $0.lane == 0 && $0.at == 0 })
        s.play()
        var last: (r: Int, g: Int, b: Int)?
        func newest() -> (r: Int, g: Int, b: Int)? { centre(output, at: item.currentTime()) }
        #expect(await rig.wait { if let px = newest() { last = px }; return (last?.b ?? 0) > 60 })
        let builds = s.builds
        s.beginGesture()
        #expect(s.setClipFrame(id: pier.id, EditFrame(x: 0, y: 0, w: 0.2)))
        let followed = await rig.wait(5) {
            if let px = newest() { last = px }
            return (last?.b ?? 255) < 12 && (last?.r ?? 255) < 12
        }
        #expect(followed, "playing frames did not pick the drag up: \(String(describing: last))")
        #expect(s.builds == builds)
        s.endGesture()
        s.pause()
    }

    @Test func undoDuringTheHeldRebuildPutsThePictureBackLive() async throws {
        let rig = try await PictureFollowRig()
        defer { rig.session.tearDown() }
        let s = rig.session
        #expect(await rig.wait { s.isPlayerReady && s.playable != nil })
        let pier = try #require(s.timeline.clips.first { $0.lane == 0 && $0.at == 0 })
        #expect(s.setClipOpacity(id: pier.id, 0.3))
        #expect(s.liveFrames.snapshot()[pier.id]?.opacity == 0.3)
        s.undo()
        #expect(s.liveFrames.snapshot().isEmpty)
    }
}
