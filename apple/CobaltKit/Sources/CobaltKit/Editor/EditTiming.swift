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

        public init(id: String, start: Int, frames: Int, speed: Double, samples: Int) {
            self.id = id
            self.start = start
            self.frames = frames
            self.speed = speed
            self.samples = samples
        }
    }

    public static let sampleRate = 48_000

    public var fps: Int
    public var frames: Int                  // N
    public var seconds: Double              // N / F
    public var main: [Clip]
    public var overlay: [Clip]

    /// Timing of a timeline. The timeline is rounded first (31.2), as the server's parser leaves it.
    public init(_ timeline: EditTimeline) {
        let t = EditJSON.rounded(timeline)
        let fps = max(1, t.canvas.fps)
        self.fps = fps
        let samplesPerFrame = Self.sampleRate / fps
        var start = 0
        var main: [Clip] = []
        for clip in t.main {
            let span = clip.out - clip.`in`
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
        self.frames = start
        self.seconds = Double(start) / Double(fps)
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
