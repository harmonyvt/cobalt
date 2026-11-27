import Foundation
import Testing
@testable import CobaltKit

struct TwitchClipTests {
    // MARK: - Split-Frame Geometry & Aspect Lock

    @Test func splitSeamSnapsToPresetDetents() {
        #expect(TwitchClipTimelineBridge.snapSplitRatio(0.485) == 0.50)
        #expect(TwitchClipTimelineBridge.snapSplitRatio(0.41) == 0.40)
        #expect(TwitchClipTimelineBridge.snapSplitRatio(0.36) == 0.35)
        #expect(TwitchClipTimelineBridge.snapSplitRatio(0.61) == 0.60)
        #expect(TwitchClipTimelineBridge.snapSplitRatio(0.64) == 0.65)
        // Far from any detent stays smooth (within clamp)
        #expect(abs(TwitchClipTimelineBridge.snapSplitRatio(0.55) - 0.55) < 0.0001)
        // Clamps to [0.25, 0.75]
        #expect(TwitchClipTimelineBridge.snapSplitRatio(0.10) == 0.25)
        #expect(TwitchClipTimelineBridge.snapSplitRatio(0.95) == 0.75)
    }

    @Test func cropRectAlwaysLocksToSlotAspectRatio() {
        let presets: [(TwitchClipLayout, Double, TwitchClipChatPlacement)] = [
            (.split, 0.50, .bottom),
            (.split, 0.40, .bottom),
            (.split, 0.35, .seam),
            (.split, 0.60, .band),
            (.pip, 0.50, .bottom),
            (.single, 0.50, .top),
        ]
        let sourceAspect = 16.0 / 9.0

        for (layout, ratio, placement) in presets {
            var config = TwitchClipEditConfig(layout: layout, splitRatio: ratio)
            config.chat.placement = placement
            for slot in TwitchClipTimelineBridge.slots(for: config) {
                let expectedAspect = TwitchClipTimelineBridge.slotAspect(for: slot.region, config: config)
                let crop = TwitchClipTimelineBridge.cropRect(
                    for: slot.region,
                    config: config,
                    sourceAspect: sourceAspect
                )
                #expect(crop.x >= -0.0001 && crop.y >= -0.0001)
                #expect(crop.x + crop.w <= 1.0001 && crop.y + crop.h <= 1.0001)
                let cropPixelAspect = (crop.w * sourceAspect) / crop.h
                #expect(abs(cropPixelAspect - expectedAspect) < 0.01, "layout=\(layout) slot=\(slot.region) got \(cropPixelAspect) expected \(expectedAspect)")
            }
        }
    }

    @Test func swapTopRegionFlipsVerticalOrder() {
        var config = TwitchClipEditConfig(layout: .split, splitRatio: 0.40, topRegion: .a)
        let slotsNormal = TwitchClipTimelineBridge.slots(for: config)
        #expect(slotsNormal.count == 2)
        #expect(slotsNormal.first(where: { $0.region == .a })?.rect.y == 0)
        #expect((slotsNormal.first(where: { $0.region == .b })?.rect.y ?? 0) > 0.35)

        config.topRegion = .b
        let slotsSwapped = TwitchClipTimelineBridge.slots(for: config)
        #expect(slotsSwapped.first(where: { $0.region == .b })?.rect.y == 0)
        #expect((slotsSwapped.first(where: { $0.region == .a })?.rect.y ?? 0) > 0.35)
    }

    // MARK: - Studio Editor v2 Timeline Handoff (Without Rendering)

    @Test func studioTimelineBuildsValidV2TimelineForAllLayouts() throws {
        let videoID = "AAAAAAAAAAAAAAAA"
        let chatID = "BBBBBBBBBBBBBBBB"
        let layouts: [TwitchClipLayout] = [.split, .pip, .single]

        for layout in layouts {
            var edit = TwitchClipEditConfig(layout: layout, splitRatio: 0.40)
            edit.chat.enabled = true
            edit.chat.placement = layout == .split ? .seam : .bottom

            let draft = TwitchClipDraft(
                id: "draft-\(layout.rawValue)",
                channel: "caedrel",
                title: "caedrel clip",
                kind: .clip,
                duration: 30,
                videoFileName: "clip.mp4",
                chatFileName: "clip.chat.json",
                chatLineCount: 25,
                edit: edit
            )

            let timeline = TwitchClipTimelineBridge.buildStudioTimeline(
                draft: draft,
                videoItemID: videoID,
                chatItemID: chatID,
                fps: 30
            )
            #expect(timeline.version == 2)
            #expect(timeline.canvas.w == 1080)
            #expect(timeline.canvas.h == 1920)

            // Round-trip through the strict v2 server-parity parser (`EditLanes.parse`)
            let encoded = try JSONEncoder().encode(timeline)
            let parsed = EditLanes.parse(encoded)
            guard case .ok(let roundTripped) = parsed else {
                Issue.record("EditLanes.parse failed for \(layout): \(parsed)")
                continue
            }
            #expect(roundTripped.version == 2)
            // Lane 0 must carry audio (unmuted); Lane 1 (when present) must be muted so audio doesn't double!
            let lane0 = roundTripped.clips.filter { $0.lane == 0 }
            #expect(lane0.count == 1)
            #expect(lane0[0].muted == false)
            if layout != .single {
                let lane1 = roundTripped.clips.filter { $0.lane == 1 }
                #expect(lane1.count == 1)
                #expect(lane1[0].muted == true)
            }
            // Lane 2 carries the transparent animated chat GIF
            let lane2 = roundTripped.clips.filter { $0.lane == 2 }
            #expect(lane2.count == 1)
            #expect(lane2[0].item == chatID)
            #expect(lane2[0].frame != nil)
        }
    }

    // MARK: - Recorded Chat Log (Sync Nudge, Gaps, Density)

    @Test func recordedChatLogHandlesSyncNudgeGapsAndDensity() {
        let entries = [
            RecordedChatEntry(id: "1", t: 2.0, login: "a", displayName: "A", fragments: [.text("hello")]),
            RecordedChatEntry(id: "2", t: 2.5, login: "b", displayName: "B", fragments: [.text("pog")]),
            RecordedChatEntry(id: "3", t: 10.0, login: "c", displayName: "C", fragments: [.text("gg")]),
        ]
        let gaps = [RecordedChatGap(start: 5.0, end: 8.5)]
        let log = RecordedChatLog(channel: "caedrel", duration: 15, entries: entries, gaps: gaps)

        #expect(log.isInGap(at: 6.0) == true)
        #expect(log.isInGap(at: 3.0) == false)

        // At t = 2.6 with 0 offset, messages 1 and 2 are visible
        let visibleNow = log.visibleEntries(at: 2.6, syncOffset: 0)
        #expect(visibleNow.map(\.id) == ["1", "2"])

        // Shifting chat +1.0s later (syncOffset = +1.0) means at t = 2.6 neither has arrived yet
        let shifted = log.visibleEntries(at: 2.6, syncOffset: 1.0)
        #expect(shifted.isEmpty)

        // Density buckets capture peak at bucket 2
        let buckets = log.densityBuckets(maxBuckets: 15)
        #expect(buckets.count == 15)
        #expect(buckets[2] == 2)
        #expect(buckets[10] == 1)
    }

    @Test func chatKeyframesCaptureMessageArrivalsAndGapBoundaries() {
        let entries = [
            RecordedChatEntry(id: "1", t: 1.0, login: "a", displayName: "A", fragments: [.text("hi")]),
            RecordedChatEntry(id: "2", t: 4.0, login: "b", displayName: "B", fragments: [.text("yo")]),
        ]
        let gaps = [RecordedChatGap(start: 6.0, end: 8.0)]
        let log = RecordedChatLog(channel: "caedrel", duration: 10, entries: entries, gaps: gaps)

        let keyframes = TwitchClipRenderer.buildChatKeyframes(
            log: log,
            config: TwitchClipChatConfig(),
            duration: 10,
            maxFrames: 60
        )
        #expect(keyframes.first == 0)
        #expect(keyframes.last == 10)
        #expect(keyframes.contains(where: { abs($0 - 1.0) < 0.05 }))
        #expect(keyframes.contains(where: { abs($0 - 4.0) < 0.05 }))
        #expect(keyframes.contains(where: { abs($0 - 6.0) < 0.05 }))
        #expect(keyframes.contains(where: { abs($0 - 8.0) < 0.05 }))
    }

    // MARK: - Rolling Buffer & Chat Gap Capture in TwitchClipRecorder

    @Test func recorderTracksBufferedSecondsAndChatGaps() async {
        let recorder = TwitchClipRecorder()
        await recorder.reset(for: "caedrel")
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        // Feed 10 seconds of synthetic video samples (1 keyframe every 2 seconds)
        let sps = Data([0x67, 0x42, 0x00, 0x1E])
        let pps = Data([0x68, 0xCE, 0x38, 0x80])
        for sec in 0...10 {
            let pts = Int64(sec) * 90_000
            let frame = DemuxedVideoFrame(
                avccData: Data([0x00, 0x00, 0x00, 0x02, 0x65, 0x88]),
                pts90k: pts,
                dts90k: pts,
                isKeyframe: sec % 2 == 0,
                sps: sec % 2 == 0 ? sps : nil,
                pps: sec % 2 == 0 ? pps : nil
            )
            await recorder.ingestSamples([.video(frame)], now: base.addingTimeInterval(Double(sec)))
        }

        let buffered = await recorder.bufferedSeconds()
        #expect(abs(buffered - 10.0) < 0.05)

        // Simulate chat connected -> reconnecting -> joined
        var joined = TwitchChatSnapshot(channel: "caedrel")
        joined.status = .joined(canSend: true)
        var dropped = TwitchChatSnapshot(channel: "caedrel")
        dropped.status = .reconnecting(retryIn: 3)
        await recorder.ingestChatSnapshot(joined, now: base.addingTimeInterval(1))
        await recorder.ingestChatSnapshot(dropped, now: base.addingTimeInterval(3))
        await recorder.ingestChatSnapshot(joined, now: base.addingTimeInterval(7))

        let state = await recorder.currentState(now: base.addingTimeInterval(10))
        #expect(state.channel == "caedrel")
        #expect(abs(state.bufferedSeconds - 10.0) < 0.05)
        #expect(state.isRecording == false)
    }

    // MARK: - Off-Main Storage Persistence

    @Test func storagePersistsAndReloadsDrafts() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("twitch-clip-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage = TwitchClipStorage(directory: tempDir)
        try await storage.ensureDirectory()

        // Create a dummy video file so existence filter keeps the draft
        let videoURL = tempDir.appendingPathComponent("clip1.mp4")
        try Data([0x00, 0x00, 0x00, 0x18]).write(to: videoURL)

        var edit = TwitchClipEditConfig(layout: .split, splitRatio: 0.35, topRegion: .b)
        edit.chat.look = .clearText
        edit.chat.syncOffset = -0.25

        let draft = TwitchClipDraft(
            id: "clip1",
            channel: "caedrel",
            title: "baron steal",
            kind: .clip,
            duration: 28.5,
            videoFileName: "clip1.mp4",
            chatFileName: "clip1.chat.json",
            chatLineCount: 42,
            chatGaps: [RecordedChatGap(start: 10, end: 14)],
            density: [1, 3, 8, 2],
            edit: edit
        )

        await storage.saveDrafts([draft])
        let loaded = await storage.loadDrafts()
        #expect(loaded.count == 1)
        #expect(loaded[0].id == "clip1")
        #expect(loaded[0].title == "baron steal")
        #expect(loaded[0].edit.splitRatio == 0.35)
        #expect(loaded[0].edit.topRegion == .b)
        #expect(loaded[0].edit.chat.look == .clearText)
        #expect(loaded[0].edit.chat.syncOffset == -0.25)
        #expect(loaded[0].totalChatGapSeconds == 4.0)
    }
}
