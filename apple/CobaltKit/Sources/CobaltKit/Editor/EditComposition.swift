import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO

// The preview composition (APP-API-CONTRACT 31.5, apple/CONTRACT-EDITOR.md 3.3): the same timeline the server renders with ffmpeg,
// built for AVFoundation. Main clips go back to back on one video track and one audio track, each inserted from `in` to `out` and
// scaled to exactly `frames_i / fps`; video overlays go on a second video track (and audio track) at `ostart / fps`; GIFs and
// photos have no track (the compositor draws them). The picture is made by `EditCompositor` (Core Image), the sound by an audio
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

/// What `EditComposition.build` makes: the composition, how the picture is made, the audio mix, and the timing it was built from.
public struct EditPlayable: @unchecked Sendable {
    public let composition: AVComposition
    /// `renderSize` W×H, `frameDuration` 1/fps, `customVideoCompositorClass` `EditCompositor`, colour = ITU-R 709 (SDR, as the server).
    public let videoComposition: AVVideoComposition
    public let audioMix: AVAudioMix
    public let timing: EditTiming

    public init(composition: AVComposition, videoComposition: AVVideoComposition, audioMix: AVAudioMix, timing: EditTiming) {
        self.composition = composition
        self.videoComposition = videoComposition
        self.audioMix = audioMix
        self.timing = timing
    }

    /// A player item with the picture and the sound set, and the pitch kept at any speed.
    public func playerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        item.audioMix = audioMix
        item.audioTimePitchAlgorithm = .spectral
        return item
    }
}

public enum EditComposition {
    /// Builds exactly 31.5. Throws `EditError.other("source:<file id>")` for a clip whose file is not on the device (or is not
    /// the kind of file the track needs), `EditError.other("empty")` for a timeline with no main clip.
    public static func build(_ t: EditTimeline, assets: [String: EditSourceAsset]) async throws -> EditPlayable {
        let t = EditJSON.rounded(t)
        let timing = EditTiming(t)
        guard !t.main.isEmpty, timing.frames > 0 else { throw EditError.other("empty") }
        let fps = Int32(timing.fps)

        let composition = AVMutableComposition()
        var mainVideo: AVMutableCompositionTrack?
        var mainAudio: AVMutableCompositionTrack?
        var overlayVideo: AVMutableCompositionTrack?
        var overlayAudio: AVMutableCompositionTrack?
        var mainInfo: [EditRenderPlan.MainClip] = []
        var overlayInfo: [EditRenderPlan.OverlayClip] = []
        var mainVolumes: [(at: CMTime, volume: Float)] = []
        var overlayVolumes: [(at: CMTime, volume: Float)] = []

        // main clips, back to back
        for (i, clip) in t.main.enumerated() {
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
            let timingClip = timing.main[i]
            let at = CMTime(value: Int64(timingClip.start), timescale: fps)
            let target = CMTime(value: Int64(timingClip.frames), timescale: fps)
            try insertScaled(
                into: videoTrack, from: sourceVideo, sourceRange: videoRange, in: clip.`in`, out: clip.out, at: at, target: target)
            if hasAudio, let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
                let audioRange = try await sourceAudio.load(.timeRange)
                if mainAudio == nil {
                    mainAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: 2)
                }
                if let audioTrack = mainAudio {
                    try insertScaled(
                        into: audioTrack, from: sourceAudio, sourceRange: audioRange, in: clip.`in`, out: clip.out, at: at,
                        target: target)
                }
            }
            mainVolumes.append((at, clip.muted ? 0 : Float(clip.volume)))
            mainInfo.append(EditRenderPlan.MainClip(
                display: display, orientation: EditRenderPlan.orientation(of: transform), trackID: videoTrack.trackID))
        }

        // overlays: videos on a second track, gifs and photos drawn by the compositor
        for (j, o) in t.overlay.enumerated() {
            guard let asset = assets[o.item] else { throw EditError.other("source:\(o.item)") }
            switch asset {
            case .video(let avAsset, let display, let hasAudio):
                guard let sourceVideo = try await avAsset.loadTracks(withMediaType: .video).first else {
                    throw EditError.other("source:\(o.item)")
                }
                let videoRange = try await sourceVideo.load(.timeRange)
                let transform = try await sourceVideo.load(.preferredTransform)
                if overlayVideo == nil {
                    overlayVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: 3)
                }
                guard let videoTrack = overlayVideo else { throw EditError.other("source:\(o.item)") }
                let clip = timing.overlay[j]
                let at = CMTime(value: Int64(clip.start), timescale: fps)
                let length = CMTime(value: Int64(clip.frames), timescale: fps)
                try insertPlain(into: videoTrack, from: sourceVideo, sourceRange: videoRange, in: o.`in`, length: length, at: at)
                if hasAudio, !o.muted, let sourceAudio = try await avAsset.loadTracks(withMediaType: .audio).first {
                    let audioRange = try await sourceAudio.load(.timeRange)
                    if overlayAudio == nil {
                        overlayAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: 4)
                    }
                    if let audioTrack = overlayAudio {
                        try insertPlain(into: audioTrack, from: sourceAudio, sourceRange: audioRange, in: o.`in`, length: length, at: at)
                        overlayVolumes.append((at, Float(o.volume)))
                    }
                }
                overlayInfo.append(EditRenderPlan.OverlayClip(
                    display: display,
                    source: .video(trackID: videoTrack.trackID, orientation: EditRenderPlan.orientation(of: transform))))
            case .gif(let frames, let delays, let display):
                overlayInfo.append(EditRenderPlan.OverlayClip(display: display, source: .gif(frames: frames, delays: delays)))
            case .photo(let image, let display):
                overlayInfo.append(EditRenderPlan.OverlayClip(display: display, source: .photo(image)))
            }
        }

        let plan = EditRenderPlan(timeline: t, timing: timing, main: mainInfo, overlay: overlayInfo)

        // the picture: one instruction per stretch with the same main clip and the same overlay
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
            let overlayIndex = timing.overlay.firstIndex { a >= $0.start && a < $0.start + $0.frames }
            let from = CMTime(value: Int64(a), timescale: fps)
            let to = b == timing.frames ? end : CMTime(value: Int64(b), timescale: fps)
            instructions.append(EditInstruction(
                timeRange: CMTimeRange(start: from, end: to), plan: plan, mainIndex: mainIndex, overlayIndex: overlayIndex))
        }
        guard !instructions.isEmpty else { throw EditError.other("empty") }

        let video = AVMutableVideoComposition()
        video.customVideoCompositorClass = EditCompositor.self
        video.frameDuration = CMTime(value: 1, timescale: fps)
        video.renderSize = CGSize(width: t.canvas.w, height: t.canvas.h)
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
        if let track = overlayAudio {
            let p = AVMutableAudioMixInputParameters(track: track)
            for entry in overlayVolumes { p.setVolume(entry.volume, at: entry.at) }
            parameters.append(p)
        }
        mix.inputParameters = parameters

        return EditPlayable(composition: composition, videoComposition: video, audioMix: mix, timing: timing)
    }

    // MARK: inserting

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
}

// MARK: - What the compositor reads

/// Everything the compositor needs about a timeline, immutable once built. Shared by every instruction of a composition.
final class EditRenderPlan: @unchecked Sendable {
    struct MainClip {
        let display: PixelSize
        let orientation: CGImagePropertyOrientation
        let trackID: CMPersistentTrackID
    }

    enum OverlaySource {
        case video(trackID: CMPersistentTrackID, orientation: CGImagePropertyOrientation)
        case gif(frames: [CGImage], delays: [Double])
        case photo(CGImage)
    }

    struct OverlayClip {
        let display: PixelSize
        let source: OverlaySource
    }

    let timeline: EditTimeline                  // rounded
    let timing: EditTiming
    let main: [MainClip]
    let overlay: [OverlayClip]

    init(timeline: EditTimeline, timing: EditTiming, main: [MainClip], overlay: [OverlayClip]) {
        self.timeline = timeline
        self.timing = timing
        self.main = main
        self.overlay = overlay
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

/// One stretch of the output with the same main clip and the same overlay: what `requiredSourceTrackIDs` and the compositor key on.
final class EditInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    /// The picture changes with time even when the source frames do not (a GIF, an overlay appearing).
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    let plan: EditRenderPlan
    let mainIndex: Int
    let overlayIndex: Int?

    init(timeRange: CMTimeRange, plan: EditRenderPlan, mainIndex: Int, overlayIndex: Int?) {
        self.timeRange = timeRange
        self.plan = plan
        self.mainIndex = mainIndex
        self.overlayIndex = overlayIndex
        var ids: [NSValue] = [NSNumber(value: plan.main[mainIndex].trackID)]
        if let overlayIndex, case .video(let trackID, _) = plan.overlay[overlayIndex].source {
            ids.append(NSNumber(value: trackID))
        }
        self.requiredSourceTrackIDs = ids
        super.init()
    }
}
