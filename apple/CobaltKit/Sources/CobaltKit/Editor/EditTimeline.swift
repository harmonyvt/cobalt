import CoreGraphics
import Foundation

// The editor's timeline (APP-API-CONTRACT 31.2, apple/CONTRACT-EDITOR.md 3.1): the JSON document a project is. The app writes
// and reads exactly the server's canonical form: numbers rounded as 31.2 says, keys sorted, no whitespace, `crop` left out when
// absent. `EditJSON.encode(EditJSON.decode(bytes)) == bytes` for any canonical document.

/// One timeline: a main track of video clips, one overlay track.
public struct EditTimeline: Sendable, Equatable, Codable {
    public var version: Int                     // 1
    public var canvas: EditCanvas
    public var main: [EditClip]
    public var overlay: [EditOverlay]

    public init(version: Int = 1, canvas: EditCanvas, main: [EditClip], overlay: [EditOverlay] = []) {
        self.version = version
        self.canvas = canvas
        self.main = main
        self.overlay = overlay
    }

    /// Version 1, no overlay.
    public static func new(canvas: EditCanvas, main: [EditClip]) -> EditTimeline {
        EditTimeline(version: 1, canvas: canvas, main: main, overlay: [])
    }
}

/// The output picture: one of the six sizes of 31.2 at 30 or 60 frames a second.
public struct EditCanvas: Sendable, Equatable, Codable {
    public var w: Int, h: Int, fps: Int

    public enum Shape: String, Sendable, CaseIterable { case story = "9:16", square = "1:1", wide = "16:9" }
    /// The short side.
    public enum Resolution: Int, Sendable, CaseIterable { case p720 = 720, p1080 = 1080 }

    public static let fpsChoices = [30, 60]

    public init(w: Int, h: Int, fps: Int) {
        self.w = w
        self.h = h
        self.fps = fps
    }

    /// 9:16 1080 is 1080×1920, 16:9 720 is 1280×720, and so on.
    public init(shape: Shape, resolution: Resolution, fps: Int) {
        let short = resolution.rawValue
        let long = resolution == .p1080 ? 1920 : 1280
        switch shape {
        case .story: self.init(w: short, h: long, fps: fps)
        case .square: self.init(w: short, h: short, fps: fps)
        case .wide: self.init(w: long, h: short, fps: fps)
        }
    }

    public var shape: Shape {
        if h > w { return .story }
        if w > h { return .wide }
        return .square
    }

    public var resolution: Resolution { min(w, h) <= 720 ? .p720 : .p1080 }

    /// 31.2.1: `h > 1.1 w` is 9:16, `w > 1.1 h` is 16:9, else 1:1; 1080p, 30 fps.
    public static func forFirstVideo(width: Int, height: Int) -> EditCanvas {
        let w = Double(width), h = Double(height)
        let shape: Shape
        if h > 1.1 * w { shape = .story } else if w > 1.1 * h { shape = .wide } else { shape = .square }
        return EditCanvas(shape: shape, resolution: .p1080, fps: 30)
    }

    /// The six sizes the server accepts, as (w, h).
    public static let sizes: [(w: Int, h: Int)] = [(1080, 1920), (720, 1280), (1080, 1080), (720, 720), (1920, 1080), (1280, 720)]

    public var isValidSize: Bool { Self.sizes.contains { $0.w == w && $0.h == h } }
}

/// A clip of the main track.
public struct EditClip: Sendable, Equatable, Codable, Identifiable {
    public var id: String                       // "c" + 8 base62
    public var item: String                     // the library file id (16 base62)
    public var `in`: Double, out: Double        // seconds of the source
    public var speed: Double                    // 0.25...4, a multiple of 0.05
    public var crop: EditCrop?                  // nil = the whole frame (left out of the JSON)
    public var fit: EditFit
    public var volume: Double                   // 0...1
    public var muted: Bool

    public init(
        id: String, item: String, in inPoint: Double, out: Double, speed: Double = 1, crop: EditCrop? = nil,
        fit: EditFit = .fill, volume: Double = 1, muted: Bool = false
    ) {
        self.id = id
        self.item = item
        self.`in` = inPoint
        self.out = out
        self.speed = speed
        self.crop = crop
        self.fit = fit
        self.volume = volume
        self.muted = muted
    }

    /// 31.2.1: a clip added to the main track: its whole length, speed 1, no crop, fill, full volume.
    public static func added(item: String, duration: Double) -> EditClip {
        EditClip(id: EditID.mint(), item: item, in: 0, out: duration)
    }

    /// The seconds of source this clip plays.
    public var sourceSeconds: Double { out - `in` }

    private enum CodingKeys: String, CodingKey { case id, item, `in`, out, speed, crop, fit, volume, muted }
}

/// A crop of the source's display frame, as fractions. `aspect` is a memory for the UI; the server checks only that it is a known
/// word.
public struct EditCrop: Sendable, Equatable, Codable {
    public enum Aspect: String, Sendable, Codable, CaseIterable {
        case free, story = "9:16", square = "1:1", portrait = "4:5", wide = "16:9"

        /// Width over height; nil for `free`.
        public var ratio: Double? {
            switch self {
            case .free: return nil
            case .story: return 9.0 / 16.0
            case .square: return 1
            case .portrait: return 4.0 / 5.0
            case .wide: return 16.0 / 9.0
            }
        }
    }

    public var aspect: Aspect
    public var x: Double, y: Double, w: Double, h: Double       // fractions of the DISPLAY frame

    public init(aspect: Aspect, x: Double, y: Double, w: Double, h: Double) {
        self.aspect = aspect
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    /// The largest centred rectangle of `aspect` in a source of this display size (`free`: the whole frame).
    public static func centred(_ aspect: Aspect, display: CGSize) -> EditCrop {
        guard let r = aspect.ratio, display.width > 0, display.height > 0 else {
            return EditCrop(aspect: aspect, x: 0, y: 0, w: 1, h: 1)
        }
        let sourceRatio = Double(display.width / display.height)
        var w = 1.0, h = 1.0
        if sourceRatio > r { w = r / sourceRatio } else { h = sourceRatio / r }
        w = EditJSON.round(w, to: 10_000)
        h = EditJSON.round(h, to: 10_000)
        return EditCrop(
            aspect: aspect, x: EditJSON.round((1 - w) / 2, to: 10_000), y: EditJSON.round((1 - h) / 2, to: 10_000), w: w, h: h)
    }

    /// Covers the whole frame (within a thousandth).
    public var isFull: Bool { abs(x) < 0.001 && abs(y) < 0.001 && abs(w - 1) < 0.001 && abs(h - 1) < 0.001 }
}

public enum EditFit: String, Sendable, Codable, CaseIterable { case fill, fit }

/// A video, GIF or photo drawn over the main track.
public struct EditOverlay: Sendable, Equatable, Codable, Identifiable {
    public var id: String, item: String
    public var at: Double                       // output seconds
    public var `in`: Double, out: Double        // video: source seconds; gif and photo: 0 and how long it stays up
    public var frame: EditFrame
    public var opacity: Double                  // 0.1...1
    public var volume: Double
    public var muted: Bool                      // true by default

    public init(
        id: String, item: String, at: Double, in inPoint: Double, out: Double, frame: EditFrame, opacity: Double = 1,
        volume: Double = 1, muted: Bool = true
    ) {
        self.id = id
        self.item = item
        self.at = at
        self.`in` = inPoint
        self.out = out
        self.frame = frame
        self.opacity = opacity
        self.volume = volume
        self.muted = muted
    }

    /// 31.2: video `0` and min(duration, the rest of the timeline); a gif or photo `0` and 3 s (held to the rest of the
    /// timeline, 0.1 s at least). The frame is `x 0.6 y 0.05 w 0.35`: `EditSession` clamps it inside the canvas, where the
    /// source's size is known.
    public static func added(item: String, kind: EditSourceKind, duration: Double?, at: Double, remaining: Double) -> EditOverlay {
        let rest = max(0.1, remaining)
        let out: Double
        switch kind {
        case .video: out = min(max(0.1, duration ?? 3), rest)
        case .gif, .photo, .unsupported: out = min(3, rest)
        }
        return EditOverlay(
            id: EditID.mint(), item: item, at: at, in: 0, out: out, frame: EditFrame(x: 0.6, y: 0.05, w: 0.35),
            opacity: 1, volume: 1, muted: true)
    }

    /// How long it is up, in output seconds.
    public var length: Double { out - `in` }

    private enum CodingKeys: String, CodingKey { case id, item, at, `in`, out, frame, opacity, volume, muted }
}

/// An overlay's rectangle as fractions of the canvas: `x`, `y` the top-left corner, `w` the width. The height follows the
/// overlay's own aspect (`EditGeometry.overlayHeightFraction`).
public struct EditFrame: Sendable, Equatable, Codable {
    public var x: Double, y: Double, w: Double

    public init(x: Double, y: Double, w: Double) {
        self.x = x
        self.y = y
        self.w = w
    }
}

// MARK: - Canonical JSON (31.2)

public enum EditJSON {
    /// `x` rounded to the nearest `1 / scale` (half away from zero), the way the server's `Math.round(x * scale) / scale`
    /// does for the non-negative values a timeline holds.
    static func round(_ x: Double, to scale: Double) -> Double {
        guard x.isFinite else { return x }
        return (x * scale).rounded(.toNearestOrAwayFromZero) / scale
    }

    /// Times and lengths to 0.001.
    static func time(_ x: Double) -> Double { round(x, to: 1_000) }
    /// Volume and opacity to 0.01.
    static func level(_ x: Double) -> Double { round(x, to: 100) }
    /// Crop and frame fractions to 0.0001.
    static func fraction(_ x: Double) -> Double { round(x, to: 10_000) }
    /// Speed to the nearest multiple of 0.05 (then 2 decimals: `n / 20` is the double nearest that decimal).
    static func speed(_ x: Double) -> Double {
        guard x.isFinite else { return x }
        return (x * 20).rounded(.toNearestOrAwayFromZero) / 20
    }

    /// Every number rounded as 31.2 says: times 0.001, speed to 0.05, volume and opacity 0.01, fractions 0.0001.
    public static func rounded(_ t: EditTimeline) -> EditTimeline {
        var out = t
        for i in out.main.indices {
            out.main[i].`in` = time(out.main[i].`in`)
            out.main[i].out = time(out.main[i].out)
            out.main[i].speed = speed(out.main[i].speed)
            out.main[i].volume = level(out.main[i].volume)
            if var crop = out.main[i].crop {
                crop.x = fraction(crop.x); crop.y = fraction(crop.y); crop.w = fraction(crop.w); crop.h = fraction(crop.h)
                out.main[i].crop = crop
            }
        }
        for i in out.overlay.indices {
            out.overlay[i].at = time(out.overlay[i].at)
            out.overlay[i].`in` = time(out.overlay[i].`in`)
            out.overlay[i].out = time(out.overlay[i].out)
            out.overlay[i].volume = level(out.overlay[i].volume)
            out.overlay[i].opacity = level(out.overlay[i].opacity)
            out.overlay[i].frame.x = fraction(out.overlay[i].frame.x)
            out.overlay[i].frame.y = fraction(out.overlay[i].frame.y)
            out.overlay[i].frame.w = fraction(out.overlay[i].frame.w)
        }
        return out
    }

    /// The canonical bytes: rounded, keys sorted, no whitespace, a nil `crop` left out.
    public static func encode(_ t: EditTimeline) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(rounded(t))
    }

    public static func decode(_ data: Data) throws -> EditTimeline {
        try JSONDecoder().decode(EditTimeline.self, from: data)
    }
}

// MARK: - Ids

public enum EditID {
    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    /// "c" + 8 characters of base62: 62^8 is plenty for the 50 clips of one timeline.
    public static func mint() -> String {
        var generator = SystemRandomNumberGenerator()
        var id = "c"
        for _ in 0..<8 { id.append(alphabet[Int.random(in: 0..<alphabet.count, using: &generator)]) }
        return id
    }
}
