import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import ImageIO

// The preview composition (APP-API-CONTRACT 31.5, apple/CONTRACT-EDITOR.md 3.3): the same timeline the server renders with ffmpeg,
// built for AVFoundation. Main clips go back to back on one video track and one audio track, each inserted from `in` to `out` and
// scaled to exactly `frames_i / fps`; video overlays go on one video track (and audio track) per overlay layer (39.1) at
// `ostart / fps`; GIFs and photos have no track (the compositor draws them, layer by layer). The picture is made by `EditCompositor` (Core Image), the sound by an audio
// mix, and `audioTimePitchAlgorithm = .spectral` keeps the pitch at any speed.

/// A library file the composition can use, loaded on the device.
public enum EditSourceAsset: @unchecked Sendable {
    case video(AVURLAsset, display: PixelSize, hasAudio: Bool)
    case gif(frames: [CGImage], delays: [Double], display: PixelSize)       // decoded once with ImageIO; looped (31.5)
    case photo(CGImage, display: PixelSize)                                 // EXIF orientation applied

    public var display: PixelSize {
        switch self {
        case .video(_, let display, _), .gif(_, _, let display), .photo(_, let display): return display
        }
    }
}

/// Hints for the live effects preview. They change the picture on the device and are not saved.
public struct EditPreviewHints: Sendable, Equatable {
    public var maskOverlayID: String?
    public var splitOverlayID: String?

    public init(maskOverlayID: String? = nil, splitOverlayID: String? = nil) {
        self.maskOverlayID = maskOverlayID
        self.splitOverlayID = splitOverlayID
    }
}

/// What `EditComposition.build` makes: the composition, how the picture is made, the audio mix, and the timing it was built from.
public struct EditPlayable: @unchecked Sendable {
    public let composition: AVComposition
    /// `renderSize` W×H, `frameDuration` 1/fps, `customVideoCompositorClass` `EditCompositor`, colour = ITU-R 709 (SDR, as the server).
    public let videoComposition: AVVideoComposition
    public let audioMix: AVAudioMix
    public let timing: EditTiming
    /// The preview was drawn at half size because more than 8 videos overlap. The render on the server is full size.
    public let proxy: Bool
    /// Clips the preview left out because their file could not be read. The picture keeps the last good frame under them.
    public let skippedClipIDs: [String]
    /// Clips left out of the picture, or main clips drawn as a gap. The rest of the composition still plays.
    public let issues: [EditPreviewIssue]

    public init(
        composition: AVComposition, videoComposition: AVVideoComposition, audioMix: AVAudioMix, timing: EditTiming,
        proxy: Bool = false, skippedClipIDs: [String] = [], issues: [EditPreviewIssue] = []
    ) {
        self.composition = composition
        self.videoComposition = videoComposition
        self.audioMix = audioMix
        self.timing = timing
        self.proxy = proxy
        self.skippedClipIDs = skippedClipIDs
        self.issues = issues
    }

    /// A player item with the picture and the sound set, and the pitch kept at any speed.
    @MainActor public func playerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        item.audioMix = audioMix
        item.audioTimePitchAlgorithm = .spectral
        return item
    }
}

public enum EditComposition {
    /// Builds exactly 31.5. A main clip whose file is missing or cannot be read becomes a gap (a checker labelled "missing")
    /// instead of failing the build; an overlay that fails is left out. Both are reported on `issues` and the rest plays.
    /// Throws `EditError.other("empty")` for a timeline with no main clip.
    ///
    /// `shifted`: pre-shifted copies of clips' sound (31.16, `EditPitchShifter`, by `EditPitchKey`). A clip with a pitch whose copy
    /// is here plays the copy's sound instead of the source's (scaled for speed the same way); one whose copy is not here yet
    /// plays the source's sound unshifted.
    ///
    /// `live`: frames and opacity the compositor draws instead of the timeline's while a finger moves a clip (version 2 only,
    /// `EditLiveFrames`). The session passes its one store to every build.
    public static func build(
        _ t: EditTimeline, assets: [String: EditSourceAsset], shifted: [EditPitchKey: URL] = [:],
        preview: EditPreviewHints = EditPreviewHints(), live: EditLiveFrames? = nil
    ) async throws -> EditPlayable {
        let t = EditJSON.rounded(t)
        // a clip's `out` is clamped to its file's length, as the renderer does
        var durations: [String: Double] = [:]
        let videoItems = t.version >= 2 ? t.clips.map(\.item) : t.main.map(\.item)
        for item in videoItems where durations[item] == nil {
            if case .video(let asset, _, _)? = assets[item],
               let d = try? await asset.load(.duration).seconds, d.isFinite, d > 0 {
                durations[item] = d
            }
        }
        let timing = EditTiming(t, sourceDurations: durations)
        if t.version >= 2 {
            guard !t.clips.isEmpty, timing.frames > 0 else { throw EditError.other("empty") }
            return try await buildLanes(t, assets: assets, shifted: shifted, preview: preview, live: live, timing: timing)
        }
        guard !t.main.isEmpty, timing.frames > 0 else { throw EditError.other("empty") }
        let fps = Int32(timing.fps)

        let composition = AVMutableComposition()
        var mainVideo: AVMutableCompositionTrack?
        var mainAudio: AVMutableCompositionTrack?
        // one pair per overlay layer: overlays of one layer never overlap, so they can share a track
        var overlayVideo: [Int: AVMutableCompositionTrack] = [:]
        var overlayAudio: [Int: AVMutableCompositionTrack] = [:]
        var mainInfo: [EditRenderPlan.MainClip] = []
        var overlayInfo: [EditRenderPlan.OverlayClip] = []
        var mainVolumes: [(at: CMTime, volume: Float)] = []
        var overlayVolumes: [Int: [(at: CMTime, volume: Float)]] = [:]
        var issues: [EditPreviewIssue] = []

        // main clips, back to back. One clip's file failing leaves a gap and the others play.
        for (i, clip) in t.main.enumerated() {
            let timingClip = timing.main[i]
            let at = CMTime(value: Int64(timingClip.start), timescale: fps)
            let target = CMTime(value: Int64(timingClip.frames), timescale: fps)
            do {
                guard case .video(let asset, let display, let hasAudio)? = assets[clip.item] else {
                    throw EditError.other("source:\(clip.item)")
                }
                guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
                    throw EditError.other("source:\(clip.item)")
                }
                let videoRange = try await sourceVideo.load(.timeRange)
                let transform = try await sourceVideo.load(.preferredTransform)
                if mainVideo == nil {
                    mainVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: 1)
                }
                guard let videoTrack = mainVideo else { throw EditError.other("source:\(clip.item)") }
                try insertScaled(
                    into: videoTrack, from: sourceVideo, sourceRange: videoRange, in: clip.`in`,
                    out: min(clip.out, durations[clip.item] ?? clip.out), at: at, target: target)
                let clipOut = min(clip.out, durations[clip.item] ?? clip.out)
                // sound is separate: a clip with no readable audio still shows its picture
                do {
                    var pitched: (asset: AVURLAsset, track: AVAssetTrack, range: CMTimeRange)?
                    if hasAudio, !clip.muted, let key = EditPitchKey(clip: clip), let url = shifted[key] {
                        pitched = await shiftedTrack(url)
                    }
                    if let pitched {
                        if mainAudio == nil {
                            mainAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: 2)
                        }
                        if let audioTrack = mainAudio {
                            // the copy starts at the clip's `in`: its 0...(out - in) stands for the source's in...out
                            try insertScaled(
                                into: audioTrack, from: pitched.track, sourceRange: pitched.range, in: 0, out: clipOut - clip.`in`,
                                at: at, target: target)
                        }
                    } else if hasAudio, let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
                        let audioRange = try await sourceAudio.load(.timeRange)
                        if mainAudio == nil {
                            mainAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: 2)
                        }
                        if let audioTrack = mainAudio {
                            try insertScaled(
                                into: audioTrack, from: sourceAudio, sourceRange: audioRange, in: clip.`in`,
                                out: clipOut, at: at, target: target)
                        }
                    }
                    mainVolumes.append((at, clip.muted ? 0 : Float(clip.volume)))
                } catch {
                    mainVolumes.append((at, 0))
                }
                mainInfo.append(EditRenderPlan.MainClip(
                    display: display, orientation: EditRenderPlan.orientation(of: transform), trackID: videoTrack.trackID))
            } catch {
                if mainVideo == nil {
                    mainVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: 1)
                }
                guard let videoTrack = mainVideo else { throw error }
                videoTrack.insertEmptyTimeRange(CMTimeRange(start: at, duration: target))
                mainInfo.append(EditRenderPlan.MainClip(
                    display: PixelSize(w: 0, h: 0), orientation: .up, trackID: videoTrack.trackID, missing: true))
                issues.append(EditPreviewIssue(clipID: clip.id, lane: .main, reason: EditPreviewFailure.reason(error)))
            }
        }
        if let track = mainVideo {
            let end = CMTime(value: Int64(timing.frames), timescale: fps)
            let have = track.timeRange.end
            // empty edits at the end of a track do not count (a track of only empty edits has no length), so the tail is
            // filled with a real clip, or a missing last clip is cut off and an all-missing timeline plays 0 s
            let from = have.isNumeric ? have : .zero
            if from < end {
                let tail = CMTimeRange(start: from, duration: CMTimeSubtract(end, from))
                do {
                    try await EditGapFiller.fill(track, tail)
                } catch {
                    track.insertEmptyTimeRange(tail)
                }
            }
        }

        // overlays: videos on their layer's track, gifs and photos drawn by the compositor. One that fails is left out.
        for (j, o) in t.overlay.enumerated() {
            do {
                guard let asset = assets[o.item] else { throw EditError.other("source:\(o.item)") }
                let layer = max(0, o.track)
                switch asset {
                case .video(let avAsset, let display, let hasAudio):
                    guard let sourceVideo = try await avAsset.loadTracks(withMediaType: .video).first else {
                        throw EditError.other("source:\(o.item)")
                    }
                    let videoRange = try await sourceVideo.load(.timeRange)
                    let transform = try await sourceVideo.load(.preferredTransform)
                    if overlayVideo[layer] == nil {
                        overlayVideo[layer] = composition.addMutableTrack(
                            withMediaType: .video, preferredTrackID: CMPersistentTrackID(3 + 2 * layer))
                    }
                    guard let videoTrack = overlayVideo[layer] else { throw EditError.other("source:\(o.item)") }
                    let clip = timing.overlay[j]
                    let at = CMTime(value: Int64(clip.start), timescale: fps)
                    let length = CMTime(value: Int64(clip.frames), timescale: fps)
                    try insertPlain(into: videoTrack, from: sourceVideo, sourceRange: videoRange, in: o.`in`, length: length, at: at)
                    // the picture is in; a bad audio insert leaves this overlay silent instead of dropping it
                    do {
                        var pitched: (asset: AVURLAsset, track: AVAssetTrack, range: CMTimeRange)?
                        if hasAudio, !o.muted, let key = EditPitchKey(overlay: o), let url = shifted[key] {
                            pitched = await shiftedTrack(url)
                        }
                        func audioTrack() -> AVMutableCompositionTrack? {
                            if overlayAudio[layer] == nil {
                                overlayAudio[layer] = composition.addMutableTrack(
                                    withMediaType: .audio, preferredTrackID: CMPersistentTrackID(4 + 2 * layer))
                            }
                            return overlayAudio[layer]
                        }
                        if let pitched {
                            if let audioTrack = audioTrack() {
                                try insertPlain(into: audioTrack, from: pitched.track, sourceRange: pitched.range, in: 0, length: length, at: at)
                                overlayVolumes[layer, default: []].append((at, Float(o.volume)))
                            }
                        } else if hasAudio, !o.muted, let sourceAudio = try await avAsset.loadTracks(withMediaType: .audio).first {
                            let audioRange = try await sourceAudio.load(.timeRange)
                            if let audioTrack = audioTrack() {
                                try insertPlain(into: audioTrack, from: sourceAudio, sourceRange: audioRange, in: o.`in`, length: length, at: at)
                                overlayVolumes[layer, default: []].append((at, Float(o.volume)))
                            }
                        }
                    } catch {
                        // silent overlay; the picture stays
                    }
                    overlayInfo.append(EditRenderPlan.OverlayClip(
                        display: display,
                        source: .video(trackID: videoTrack.trackID, orientation: EditRenderPlan.orientation(of: transform))))
                case .gif(let frames, let delays, let display):
                    overlayInfo.append(EditRenderPlan.OverlayClip(display: display, source: .gif(frames: frames, delays: delays)))
                case .photo(let image, let display):
                    overlayInfo.append(EditRenderPlan.OverlayClip(display: display, source: .photo(image)))
                }
            } catch {
                overlayInfo.append(EditRenderPlan.OverlayClip(display: PixelSize(w: 0, h: 0), source: .missing))
                issues.append(EditPreviewIssue(clipID: o.id, lane: .overlay, reason: EditPreviewFailure.reason(error)))
            }
        }

        let peak = videoPeak(timing: timing, info: overlayInfo)
        let proxy = peak > EditOverlap.comfortableVideos
        let plan = EditRenderPlan(
            timeline: t, timing: timing, main: mainInfo, overlay: overlayInfo, proxy: proxy,
            previewMaskID: preview.maskOverlayID, previewSplitID: preview.splitOverlayID)

        // the picture: one instruction per stretch with the same main clip and the same overlays
        let end = CMTimeMaximum(CMTime(value: Int64(timing.frames), timescale: fps), composition.duration)
        var breaks: Set<Int> = [0, timing.frames]
        for c in timing.main { breaks.insert(c.start) }
        for c in timing.overlay {
            breaks.insert(min(timing.frames, c.start))
            breaks.insert(min(timing.frames, c.start + c.frames))
        }
        let ordered = breaks.filter { $0 >= 0 && $0 <= timing.frames }.sorted()
        var instructions: [EditInstruction] = []
        for (n, a) in ordered.enumerated() where n + 1 < ordered.count {
            let b = ordered[n + 1]
            guard b > a, let (mainIndex, _) = timing.clip(atFrame: a) else { continue }
            let overlayIndices = timing.overlay.indices.filter {
                a >= timing.overlay[$0].start && a < timing.overlay[$0].start + timing.overlay[$0].frames
            }
            let from = CMTime(value: Int64(a), timescale: fps)
            let to = b == timing.frames ? end : CMTime(value: Int64(b), timescale: fps)
            instructions.append(EditInstruction(
                timeRange: CMTimeRange(start: from, end: to), plan: plan, mainIndex: mainIndex, overlayIndices: overlayIndices))
        }
        guard !instructions.isEmpty else { throw EditError.other("empty") }

        let video = AVMutableVideoComposition()
        video.customVideoCompositorClass = EditCompositor.self
        video.frameDuration = CMTime(value: 1, timescale: fps)
        let scale = proxy ? 0.5 : 1.0
        video.renderSize = CGSize(
            width: max(2, Int(Double(t.canvas.w) * scale) / 2 * 2),
            height: max(2, Int(Double(t.canvas.h) * scale) / 2 * 2))
        video.instructions = instructions
        video.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        video.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        video.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

        // the sound: muted = 0 whatever the level says (so unmuting restores it)
        let mix = AVMutableAudioMix()
        var parameters: [AVMutableAudioMixInputParameters] = []
        if let track = mainAudio {
            let p = AVMutableAudioMixInputParameters(track: track)
            for entry in mainVolumes { p.setVolume(entry.volume, at: entry.at) }
            parameters.append(p)
        }
        for (layer, track) in overlayAudio.sorted(by: { $0.key < $1.key }) {
            let p = AVMutableAudioMixInputParameters(track: track)
            for entry in overlayVolumes[layer] ?? [] { p.setVolume(entry.volume, at: entry.at) }
            parameters.append(p)
        }
        mix.inputParameters = parameters

        return EditPlayable(
            composition: composition, videoComposition: video, audioMix: mix, timing: timing, proxy: proxy, issues: issues)
    }

    /// How many video overlays share the busiest output frame.
    private static func videoPeak(timing: EditTiming, info: [EditRenderPlan.OverlayClip]) -> Int {
        var best = 0
        for (j, slot) in timing.overlay.enumerated() where j < info.count {
            guard case .video = info[j].source else { continue }
            var n = 0
            for (k, other) in timing.overlay.enumerated() where k < info.count {
                guard case .video = info[k].source else { continue }
                if slot.start < other.start + other.frames, other.start < slot.start + slot.frames { n += 1 }
            }
            if n > best { best = n }
        }
        return best
    }

    // MARK: inserting

    /// The audio track of a pre-shifted copy and its range; nil when it cannot be read (the source's sound plays instead).
    /// The asset is returned with the track: a track does not keep its asset alive, and inserting from a track whose asset is gone
    /// fails (AVFoundation -11800 / -12780), which took the whole preview down once a copy was ready.
    static func shiftedTrack(_ url: URL) async -> (asset: AVURLAsset, track: AVAssetTrack, range: CMTimeRange)? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let range = try? await track.load(.timeRange), range.isValid, !range.isEmpty else { return nil }
        return (asset, track, range)
    }

    /// Source seconds as a CMTime (milliseconds: the timeline's own resolution, so exact).
    static func cm(_ seconds: Double) -> CMTime { CMTime(value: Int64((seconds * 1_000).rounded()), timescale: 1_000) }

    /// Inserts `in...out` of the source at `at` and scales it to exactly `target` (31.4/31.5: `frames_i / fps`). A source that ends
    /// early is stretched by the same ratio and the rest of `target` is left empty (the server holds the last frame instead; the
    /// timeline is validated against the source's duration, so this is the 0.05 s slack at most).
    private static func insertScaled(
        into track: AVMutableCompositionTrack, from source: AVAssetTrack, sourceRange: CMTimeRange, in inPoint: Double,
        out: Double, at: CMTime, target: CMTime
    ) throws {
        let wanted = CMTimeRange(start: cm(inPoint), duration: cm(out - inPoint))
        let available = wanted.intersection(sourceRange)
        guard available.isValid, !available.isEmpty, available.duration.seconds > 0.001 else {
            track.insertEmptyTimeRange(CMTimeRange(start: at, duration: target))
            return
        }
        try track.insertTimeRange(available, of: source, at: at)
        let ratio = available.duration.seconds / max(0.001, wanted.duration.seconds)
        let scaled = ratio >= 0.999999
            ? target
            : CMTime(value: Int64((Double(target.value) * ratio).rounded()), timescale: target.timescale)
        track.scaleTimeRange(CMTimeRange(start: at, duration: available.duration), toDuration: scaled)
        if scaled < target {
            track.insertEmptyTimeRange(CMTimeRange(start: CMTimeAdd(at, scaled), duration: CMTimeSubtract(target, scaled)))
        }
    }

    /// Inserts `length` of the source from `inPoint` at `at`, at speed 1 (an overlay).
    private static func insertPlain(
        into track: AVMutableCompositionTrack, from source: AVAssetTrack, sourceRange: CMTimeRange, in inPoint: Double,
        length: CMTime, at: CMTime
    ) throws {
        let wanted = CMTimeRange(start: cm(inPoint), duration: length)
        let available = wanted.intersection(sourceRange)
        guard available.isValid, !available.isEmpty else { return }
        try track.insertTimeRange(available, of: source, at: at)
    }

    /// One stretch of a version 2 preview. `clipIDs` is the clips to draw, bottom lane first. An empty list is black
    /// (a gap, the time before the first clip, or a stretch whose only clip is hidden).
    public struct LaneSpan: Sendable, Equatable {
        public var start: Int
        public var end: Int
        public var clipIDs: [String]
    }

    /// The instruction breaks for a version 2 timeline: every clip edge, including gaps. Hidden clips are not drawn.
    public static func laneSpans(_ timeline: EditTimeline, timing: EditTiming) -> [LaneSpan] {
        guard timeline.version >= 2, timing.laneClips.count == timeline.clips.count, timing.frames > 0 else { return [] }
        var breaks: Set<Int> = [0, timing.frames]
        for row in timing.laneClips {
            breaks.insert(max(0, min(timing.frames, row.start)))
            breaks.insert(max(0, min(timing.frames, row.start + row.frames)))
        }
        let ordered = breaks.filter { $0 >= 0 && $0 <= timing.frames }.sorted()
        let draw = EditLanes.drawOrder(timeline)
        var spans: [LaneSpan] = []
        for (index, start) in ordered.enumerated() where index + 1 < ordered.count {
            let end = ordered[index + 1]
            guard end > start else { continue }
            let ids = draw.compactMap { clipIndex -> String? in
                let row = timing.laneClips[clipIndex]
                let clip = timeline.clips[clipIndex]
                guard !clip.hidden, start >= row.start, start < row.start + row.frames else { return nil }
                return clip.id
            }
            spans.append(LaneSpan(start: start, end: end, clipIDs: ids))
        }
        return spans
    }

    /// Version 2 picture: a black base for the edit length, then every visible clip bottom to top. Video tracks are
    /// assigned by peak overlap (interval colouring), not one per lane. A clip whose file is missing is skipped.
    private static func buildLanes(
        _ t: EditTimeline, assets: [String: EditSourceAsset], shifted: [EditPitchKey: URL], preview: EditPreviewHints,
        live: EditLiveFrames?, timing: EditTiming
    ) async throws -> EditPlayable {
        let fps = Int32(timing.fps)
        let composition = AVMutableComposition()
        var skipped: [String] = []
        var issues: [EditPreviewIssue] = []
        func skip(_ clip: EditLaneClip, _ reason: String) {
            skipped.append(clip.id)
            issues.append(EditPreviewIssue(clipID: clip.id, lane: clip.lane == 0 ? .main : .overlay, reason: reason))
        }
        var media: [String: EditRenderPlan.LanePicture] = [:]
        var videoClips: [(id: String, start: Int, end: Int)] = []
        for (index, clip) in t.clips.enumerated() where !clip.hidden {
            guard index < timing.laneClips.count else { continue }
            let row = timing.laneClips[index]
            guard let asset = assets[clip.item] else { skip(clip, EditPreviewFailure.fileMissing); continue }
            switch asset {
            case .video(let avAsset, _, _):
                guard (try? await avAsset.loadTracks(withMediaType: .video).first) != nil else {
                    skip(clip, EditPreviewFailure.couldntRead); continue
                }
                videoClips.append((clip.id, row.start, row.start + row.frames))
            case .gif(let frames, let delays, let display):
                media[clip.id] = .gif(
                    frames: frames, delays: delays, display: display, images: frames.map(EditFrameComposer.ciImage))
            case .photo(let image, let display):
                media[clip.id] = .photo(image, display: display, imageCI: EditFrameComposer.ciImage(image))
            }
        }
        let colored = EditLanes.colorTracks(videoClips)
        var trackOf: [String: Int] = [:]
        for item in colored { trackOf[item.id] = item.track }
        let trackCount = (colored.map(\.track).max() ?? -1) + 1
        var videoTracks: [AVMutableCompositionTrack] = []
        var audioTracks: [AVMutableCompositionTrack] = []
        for index in 0..<max(trackCount, 1) {
            if let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: CMPersistentTrackID(1 + index * 2)) {
                videoTracks.append(video)
            }
            if let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: CMPersistentTrackID(2 + index * 2)) {
                audioTracks.append(audio)
            }
        }
        var volumes: [Int: [(at: CMTime, volume: Float)]] = [:]
        for (index, clip) in t.clips.enumerated() where !clip.hidden && trackOf[clip.id] != nil {
            guard index < timing.laneClips.count, case .video(let avAsset, let display, let hasAudio) = assets[clip.item],
                  let sourceVideo = try? await avAsset.loadTracks(withMediaType: .video).first else { continue }
            let trackIndex = trackOf[clip.id] ?? 0
            guard trackIndex < videoTracks.count else { continue }
            let row = timing.laneClips[index]
            let at = CMTime(value: Int64(row.start), timescale: fps)
            let target = CMTime(value: Int64(row.frames), timescale: fps)
            let videoRange = (try? await sourceVideo.load(.timeRange)) ?? .invalid
            let transform = (try? await sourceVideo.load(.preferredTransform)) ?? .identity
            if videoRange.isValid {
                try insertScaled(
                    into: videoTracks[trackIndex], from: sourceVideo, sourceRange: videoRange, in: clip.`in`,
                    out: clip.out, at: at, target: target)
            }
            media[clip.id] = .video(
                trackID: videoTracks[trackIndex].trackID, orientation: EditRenderPlan.orientation(of: transform), display: display)
            let clipOut = clip.out
            var pitched: (asset: AVURLAsset, track: AVAssetTrack, range: CMTimeRange)?
            if hasAudio, !clip.muted, let key = EditPitchKey(lane: clip), let url = shifted[key] {
                pitched = await shiftedTrack(url)
            }
            if trackIndex < audioTracks.count {
                if let pitched {
                    try insertScaled(
                        into: audioTracks[trackIndex], from: pitched.track, sourceRange: pitched.range, in: 0,
                        out: clipOut - clip.`in`, at: at, target: target)
                    volumes[trackIndex, default: []].append((at, Float(clip.volume)))
                } else if hasAudio, let sourceAudio = try? await avAsset.loadTracks(withMediaType: .audio).first,
                          let audioRange = try? await sourceAudio.load(.timeRange) {
                    try insertScaled(
                        into: audioTracks[trackIndex], from: sourceAudio, sourceRange: audioRange, in: clip.`in`,
                        out: clipOut, at: at, target: target)
                    volumes[trackIndex, default: []].append((at, clip.muted ? 0 : Float(clip.volume)))
                }
            }
        }
        // A photo-only edit still needs a timeline long enough for the compositor. An empty range holds the duration.
        // A player may not call the compositor until a real video sample exists; the instruction list is still complete.
        let full = CMTime(value: Int64(timing.frames), timescale: fps)
        if let base = videoTracks.first {
            let covered = base.timeRange.isValid && !base.timeRange.isEmpty ? base.timeRange.end : .zero
            if covered < full {
                base.insertEmptyTimeRange(CMTimeRange(start: covered, duration: CMTimeSubtract(full, covered)))
            }
        }
        let peak = Set(trackOf.values).count == 0 ? 0 : (videoClips.reduce(0) { partial, clip in
            let overlapping = videoClips.filter { $0.start < clip.end && clip.start < $0.end }.count
            return max(partial, overlapping)
        })
        let proxy = peak > EditOverlap.comfortableVideos
        let plan = EditRenderPlan(
            timeline: t, timing: timing, main: [], overlay: [], proxy: proxy,
            previewMaskID: preview.maskOverlayID, previewSplitID: preview.splitOverlayID, lanes: media, live: live)
        let spans = laneSpans(t, timing: timing)
        let end = CMTimeMaximum(full, composition.duration)
        var instructions: [EditInstruction] = []
        for span in spans {
            let from = CMTime(value: Int64(span.start), timescale: fps)
            let to = span.end == timing.frames ? end : CMTime(value: Int64(span.end), timescale: fps)
            let ids = span.clipIDs.compactMap { id -> CMPersistentTrackID? in
                if case .video(let trackID, _, _) = media[id] { return trackID }
                return nil
            }
            instructions.append(EditInstruction(timeRange: CMTimeRange(start: from, end: to), plan: plan, laneIDs: span.clipIDs, trackIDs: ids))
        }
        guard !instructions.isEmpty else { throw EditError.other("empty") }
        let video = AVMutableVideoComposition()
        video.customVideoCompositorClass = EditCompositor.self
        video.frameDuration = CMTime(value: 1, timescale: fps)
        let scale = proxy ? 0.5 : 1.0
        video.renderSize = CGSize(
            width: max(2, Int(Double(t.canvas.w) * scale) / 2 * 2),
            height: max(2, Int(Double(t.canvas.h) * scale) / 2 * 2))
        video.instructions = instructions
        video.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        video.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        video.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        let mix = AVMutableAudioMix()
        var parameters: [AVMutableAudioMixInputParameters] = []
        for (index, track) in audioTracks.enumerated() {
            let entries = volumes[index] ?? []
            guard !entries.isEmpty else { continue }
            let parameter = AVMutableAudioMixInputParameters(track: track)
            for entry in entries { parameter.setVolume(entry.volume, at: entry.at) }
            parameters.append(parameter)
        }
        mix.inputParameters = parameters
        return EditPlayable(
            composition: composition, videoComposition: video, audioMix: mix, timing: timing, proxy: proxy,
            skippedClipIDs: skipped, issues: issues)
    }
}

// MARK: - What the compositor reads

/// Everything the compositor needs about a timeline, immutable once built. Shared by every instruction of a composition.
final class EditRenderPlan: @unchecked Sendable {
    struct MainClip {
        let display: PixelSize
        let orientation: CGImagePropertyOrientation
        let trackID: CMPersistentTrackID
        /// No picture for this span: the compositor draws a checker labelled "missing" and does not ask the track for a frame.
        var missing: Bool = false
    }

    enum OverlaySource {
        case video(trackID: CMPersistentTrackID, orientation: CGImagePropertyOrientation)
        case gif(frames: [CGImage], delays: [Double])
        case photo(CGImage)
        /// Left out of the picture. The slot stays so indices still match the timeline.
        case missing
    }

    /// One version 2 clip's picture. Videos name the composition track interval colouring assigned them.
    enum LanePicture {
        case video(trackID: CMPersistentTrackID, orientation: CGImagePropertyOrientation, display: PixelSize)
        case gif(frames: [CGImage], delays: [Double], display: PixelSize, images: [CIImage])
        case photo(CGImage, display: PixelSize, imageCI: CIImage)

        var display: PixelSize {
            switch self {
            case .video(_, _, let display), .gif(_, _, let display, _), .photo(_, let display, _): return display
            }
        }
    }

    struct OverlayClip {
        let display: PixelSize
        let source: OverlaySource
        /// A gif's frames or a photo as Core Image images, made once here instead of on every output frame (`[]` for a video).
        let images: [CIImage]

        init(display: PixelSize, source: OverlaySource) {
            self.display = display
            self.source = source
            switch source {
            case .video, .missing: images = []
            case .gif(let frames, _): images = frames.map(EditFrameComposer.ciImage)
            case .photo(let image): images = [EditFrameComposer.ciImage(image)]
            }
        }
    }

    let timeline: EditTimeline                  // rounded
    let timing: EditTiming
    let main: [MainClip]
    let overlay: [OverlayClip]
    /// Draw overlay video frames smaller before they are placed. Set when more than 8 videos overlap.
    let proxy: Bool
    /// The overlay whose greenscreen preview shows the mask instead of the picture.
    let previewMaskID: String?
    /// The overlay whose preview is split, original on the left and the effect on the right.
    let previewSplitID: String?
    /// Version 2 pictures by clip id. Empty for a version 1 plan.
    let lanes: [String: LanePicture]
    /// One plate for every missing main span, made once. Nil when every main clip has a picture.
    let missingPlate: CIImage?
    /// Version 2: frames and opacity drawn instead of `timeline`'s while the session waits to rebuild (`EditLiveFrames`).
    let live: EditLiveFrames?

    init(
        timeline: EditTimeline, timing: EditTiming, main: [MainClip], overlay: [OverlayClip], proxy: Bool = false,
        previewMaskID: String? = nil, previewSplitID: String? = nil, lanes: [String: LanePicture] = [:],
        live: EditLiveFrames? = nil
    ) {
        self.timeline = timeline
        self.timing = timing
        self.main = main
        self.overlay = overlay
        self.proxy = proxy
        self.previewMaskID = previewMaskID
        self.previewSplitID = previewSplitID
        self.lanes = lanes
        self.live = live
        self.missingPlate = main.contains(where: \.missing) ? EditFrameComposer.missingPlate(canvas: timeline.canvas) : nil
    }

    /// The EXIF orientation a track's `preferredTransform` stands for (a portrait iPhone clip is `(0, 1, -1, 0)`: `.right`).
    static func orientation(of t: CGAffineTransform) -> CGImagePropertyOrientation {
        func near(_ x: CGFloat, _ y: CGFloat) -> Bool { abs(x - y) < 0.001 }
        switch (t.a, t.b, t.c, t.d) {
        case let (a, b, c, d) where near(a, 0) && near(b, 1) && near(c, -1) && near(d, 0): return .right
        case let (a, b, c, d) where near(a, 0) && near(b, -1) && near(c, 1) && near(d, 0): return .left
        case let (a, b, c, d) where near(a, 1) && near(b, 0) && near(c, 0) && near(d, 1): return .up
        case let (a, b, c, d) where near(a, -1) && near(b, 0) && near(c, 0) && near(d, -1): return .down
        case let (a, b, c, d) where near(a, -1) && near(b, 0) && near(c, 0) && near(d, 1): return .upMirrored
        case let (a, b, c, d) where near(a, 1) && near(b, 0) && near(c, 0) && near(d, -1): return .downMirrored
        case let (a, b, c, d) where near(a, 0) && near(b, 1) && near(c, 1) && near(d, 0): return .leftMirrored
        case let (a, b, c, d) where near(a, 0) && near(b, -1) && near(c, -1) && near(d, 0): return .rightMirrored
        default: return .up
        }
    }
}

/// One stretch of the output with the same main clip and the same overlays: what `requiredSourceTrackIDs` and the compositor key on.
final class EditInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    /// The picture changes with time even when the source frames do not (a GIF, an overlay appearing).
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    let plan: EditRenderPlan
    let mainIndex: Int
    /// The overlays up in this stretch (indices into the timeline's `overlay`), at most one per layer.
    let overlayIndices: [Int]
    /// Version 2 clips to draw, bottom lane first. Empty means this instruction is the version 1 path.
    let laneIDs: [String]
    /// True for a version 2 stretch, including a black gap (no clips).
    let rendersLanes: Bool

    init(timeRange: CMTimeRange, plan: EditRenderPlan, mainIndex: Int, overlayIndices: [Int]) {
        self.timeRange = timeRange
        self.plan = plan
        self.mainIndex = mainIndex
        self.overlayIndices = overlayIndices
        self.laneIDs = []
        self.rendersLanes = false
        var ids: [NSValue] = []
        if mainIndex < plan.main.count, !plan.main[mainIndex].missing {
            ids.append(NSNumber(value: plan.main[mainIndex].trackID))
        }
        for j in overlayIndices where j < plan.overlay.count {
            if case .video(let trackID, _) = plan.overlay[j].source { ids.append(NSNumber(value: trackID)) }
        }
        self.requiredSourceTrackIDs = ids
        super.init()
    }

    init(timeRange: CMTimeRange, plan: EditRenderPlan, laneIDs: [String], trackIDs: [CMPersistentTrackID]) {
        self.timeRange = timeRange
        self.plan = plan
        self.mainIndex = 0
        self.overlayIndices = []
        self.laneIDs = laneIDs
        self.rendersLanes = true
        self.requiredSourceTrackIDs = trackIDs.map { NSNumber(value: $0) }
        super.init()
    }
}
