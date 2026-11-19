import Foundation

// Timing: frames are the unit (APP-API-CONTRACT 31.4). The same numbers as the server's `timeline.js` `timing`, so the preview
// and the render last exactly the same number of frames.

public enum EditMath {
    /// `floor(x + 0.5 + 1e-9)`: JS `Math.round` and Swift's `.rounded()` differ only at the epsilon. For `x >= 0`.
    public static func roundHalfUp(_ x: Double) -> Int {
        guard x.isFinite else { return 0 }
        return Int((x + 0.5 + 1e-9).rounded(.down))
    }

    /// `2 * roundHalfUp(x / 2)`: the nearest even number.
    public static func evenNearest(_ x: Double) -> Int { 2 * roundHalfUp(x / 2) }

    /// `2 * floor(x / 2)`: the even number at or below.
    public static func evenFloor(_ x: Double) -> Int {
        guard x.isFinite else { return 0 }
        return 2 * Int((x / 2).rounded(.down))
    }
}

public struct EditTiming: Sendable, Equatable {
    /// One clip on the output timeline. `speed` is the EFFECTIVE speed `s_i = (out - in) * F / frames` of a main clip (what the
    /// ffmpeg graph and `scaleTimeRange` both use, so the clip lasts exactly `frames` frames); 1 for an overlay.
    public struct Clip: Sendable, Equatable {
        public var id: String
        public var start: Int               // first output frame
        public var frames: Int
        public var speed: Double
        public var samples: Int             // audio samples at 48 kHz
        /// The lane, when this timing came from a version 2 timeline. 0 for a version 1 main clip.
        public var lane: Int

        public init(id: String, start: Int, frames: Int, speed: Double, samples: Int, lane: Int = 0) {
            self.id = id
            self.start = start
            self.frames = frames
            self.speed = speed
            self.samples = samples
            self.lane = lane
        }
    }

    public static let sampleRate = 48_000

    public var fps: Int
    public var frames: Int                  // N
    public var seconds: Double              // N / F
    public var main: [Clip]
    public var overlay: [Clip]
    /// One entry per `timeline.clips`, same order, when the timeline is version 2. Empty for version 1.
    public var laneClips: [Clip]

    /// Timing of a timeline. The timeline is rounded first (31.2), as the server's parser leaves it.
    /// `sourceDurations` (library file id -> seconds, as probed): a video clip's `out` is clamped to its file's length, as the
    /// renderer does (31.2 allows `out` 0.05 s past it), so later clips start where the render starts them.
    ///
    /// Version 1 packs the main track. Version 2 places every clip at its `at`, and the edit length is the latest clip end
    /// (a gap, and any time before the first clip, is black). Lane 0 is still `main` and every higher lane is `overlay`, in
    /// the same order as `timeline.main` and `timeline.overlay`, so the current timeline UI can keep using those arrays.
    public init(_ timeline: EditTimeline, sourceDurations: [String: Double] = [:]) {
        if timeline.version >= 2 {
            self = Self.lanes(timeline, sourceDurations: sourceDurations)
            return
        }
        let t = EditJSON.rounded(timeline)
        let fps = max(1, t.canvas.fps)
        self.fps = fps
        let samplesPerFrame = Self.sampleRate / fps
        var start = 0
        var main: [Clip] = []
        for clip in t.main {
            var out = clip.out
            if let limit = sourceDurations[clip.item], limit > clip.`in`, out > limit { out = limit }
            let span = out - clip.`in`
            let speed = clip.speed > 0 ? clip.speed : 1
            let frames = max(1, EditMath.roundHalfUp(span / speed * Double(fps)))
            let effective = span * Double(fps) / Double(frames)
            main.append(Clip(id: clip.id, start: start, frames: frames, speed: effective, samples: frames * samplesPerFrame))
            start += frames
        }
        var overlay: [Clip] = []
        for o in t.overlay {
            let begin = max(0, EditMath.roundHalfUp(o.at * Double(fps)))
            let frames = max(1, EditMath.roundHalfUp((o.out - o.`in`) * Double(fps)))
            overlay.append(Clip(id: o.id, start: begin, frames: frames, speed: 1, samples: frames * samplesPerFrame))
        }
        self.main = main
        self.overlay = overlay
        self.laneClips = []
        self.frames = start
        self.seconds = Double(start) / Double(fps)
    }

    /// Version 2 timing (section 69). `laneClips` lines up with `timeline.clips`.
    private static func lanes(_ timeline: EditTimeline, sourceDurations: [String: Double]) -> EditTiming {
        let t = EditJSON.rounded(timeline)
        let fps = max(1, t.canvas.fps)
        let samplesPerFrame = sampleRate / fps
        var laneClips: [Clip] = []
        var end = 0
        for clip in t.clips {
            var out = clip.out
            if let limit = sourceDurations[clip.item], limit > clip.`in`, out > limit { out = limit }
            let span = out - clip.`in`
            let nominal = clip.speed > 0 ? clip.speed : 1
            let frames = max(1, EditMath.roundHalfUp(span / nominal * Double(fps)))
            let start = max(0, EditMath.roundHalfUp(clip.at * Double(fps)))
            let effective = span * Double(fps) / Double(frames)
            laneClips.append(Clip(
                id: clip.id, start: start, frames: frames, speed: effective, samples: frames * samplesPerFrame, lane: clip.lane))
            end = max(end, start + frames)
        }
        let lane0 = t.clips.enumerated().filter { $0.element.lane == 0 }.sorted { a, b in
            a.element.at != b.element.at ? a.element.at < b.element.at : a.offset < b.offset
        }
        let higher = t.clips.enumerated().filter { $0.element.lane > 0 }.sorted { a, b in
            a.element.at != b.element.at ? a.element.at < b.element.at : a.offset < b.offset
        }
        return EditTiming(
            fps: fps, frames: end, seconds: Double(end) / Double(fps),
            main: lane0.map { laneClips[$0.offset] }, overlay: higher.map { laneClips[$0.offset] }, laneClips: laneClips)
    }

    private init(fps: Int, frames: Int, seconds: Double, main: [Clip], overlay: [Clip], laneClips: [Clip]) {
        self.fps = fps
        self.frames = frames
        self.seconds = seconds
        self.main = main
        self.overlay = overlay
        self.laneClips = laneClips
    }

    /// `k / fps`.
    public func time(ofFrame k: Int) -> Double { Double(k) / Double(fps) }

    /// The output frame at `seconds`: `roundHalfUp(seconds * fps)`, clamped to `0...frames - 1`.
    public func frame(at seconds: Double) -> Int {
        guard frames > 0 else { return 0 }
        guard seconds.isFinite else { return seconds > 0 ? frames - 1 : 0 }
        let k = EditMath.roundHalfUp(seconds * Double(fps))
        return min(max(0, k), frames - 1)
    }

    /// The main clip that shows output frame `k` and how far into it (in frames); nil past the end.
    public func clip(atFrame k: Int) -> (index: Int, offset: Int)? {
        guard k >= 0 else { return nil }
        for (i, clip) in main.enumerated() where k >= clip.start && k < clip.start + clip.frames {
            return (i, k - clip.start)
        }
        return nil
    }

    /// The source time main clip `i` shows at its frame `k`: `in_i + k / fps * s_i`.
    public func sourceTime(clip i: Int, offset k: Int, in t: EditTimeline) -> Double {
        guard main.indices.contains(i), t.main.indices.contains(i) else { return 0 }
        return t.main[i].`in` + Double(k) / Double(fps) * main[i].speed
    }
}
