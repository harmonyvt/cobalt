import CoreGraphics
import Foundation

// Lock Screen wallpapers made from a post (apple/CONTRACT-WALLPAPER.md). Everything runs on the device: the server is
// never asked. iOS lets no app set the wallpaper, so the result is a Live Photo (or a still) saved to Photos, which the
// owner picks in Photos with "use as wallpaper".

/// One brush stroke on the subject mask, in the picture's own unit square (0...1 on both axes, top left origin).
public struct WallpaperStroke: Sendable, Equatable, Codable {
    /// The points the brush passed through, in order.
    public var points: [CGPoint]
    /// The brush's radius, as a share of the picture's shorter side.
    public var radius: Double
    /// `true` paints the subject in (near), `false` paints it out (far).
    public var adds: Bool

    public init(points: [CGPoint], radius: Double, adds: Bool) {
        self.points = points
        self.radius = radius
        self.adds = adds
    }
}

/// How the wallpaper's depth looks: the owner's strokes and three sliders. The defaults are the "nothing changed" look.
public struct WallpaperLook: Sendable, Equatable, Codable {
    /// Background blur, 0...1 (1 is a radius of 2.5% of the picture's shorter side). The subject stays sharp.
    public var blur: Double
    /// How far the background drifts sideways during a Live Photo, 0...1 (1 is 3% of the width each way). The drift
    /// ends where it started, so the still the clip lands on is the picture as it is.
    public var parallax: Double
    /// How soft the subject's edge is, 0...1 (1 is 1% of the shorter side).
    public var softness: Double
    /// Use the subject mask at all. Off: blur and parallax act on the whole picture and the strokes are kept but unused.
    public var findsSubject: Bool
    public var strokes: [WallpaperStroke]

    public init(blur: Double = 0, parallax: Double = 0, softness: Double = 0.25, findsSubject: Bool = true,
                strokes: [WallpaperStroke] = []) {
        self.blur = blur
        self.parallax = parallax
        self.softness = softness
        self.findsSubject = findsSubject
        self.strokes = strokes
    }

    /// Nothing about the picture changes: the frames are written as they are.
    public var isPlain: Bool { blur <= 0.001 && parallax <= 0.001 }
}

/// What a make is for.
public enum WallpaperTarget: String, Sendable, CaseIterable, Codable {
    /// One Live Photo (or still) for this iPhone's Lock Screen.
    case lockScreen
    /// The Duo's two screens: the picture cut into a left and a right half, minus the hinge, two Live Photos.
    case duoPair
}

/// The limits a make keeps to.
public enum WallpaperLimits {
    /// The Lock Screen plays a Live Photo once when the phone wakes; longer clips are cut by iOS or refused.
    public static let maxClip: Double = 3.0
    public static let minClip: Double = 1.0
    /// Frames per second of the Live Photo's video.
    public static let fps: Double = 30
    /// The longest side of the written frames, in pixels.
    public static let maxSide: CGFloat = 1920
    /// The Duo's hinge, as a share of the spread's width (18 pt of a 762 pt spread in the design).
    public static let hingeShare: CGFloat = 18.0 / 762.0
}

/// One saved wallpaper: the files a Live Photo is made of (`video` nil for a still), ready for Photos.
public struct WallpaperFiles: Sendable, Equatable {
    public var still: URL
    public var video: URL?

    public init(still: URL, video: URL?) {
        self.still = still
        self.video = video
    }

    /// Removes the files (after Photos has copied them, or when the make is abandoned).
    public func remove() {
        try? FileManager.default.removeItem(at: still)
        if let video { try? FileManager.default.removeItem(at: video) }
    }
}

public enum WallpaperError: Error, Equatable {
    /// The file is neither a video, an animated picture nor a picture this device can read.
    case unreadable
    /// Writing the Live Photo failed.
    case writeFailed
}
