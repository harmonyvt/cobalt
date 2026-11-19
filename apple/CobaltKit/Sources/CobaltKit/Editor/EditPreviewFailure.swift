import AVFoundation
import Foundation

// What the preview says when a composition cannot be built, or one clip of it cannot. Short and plain: the canvas shows the
// words, and the same words go to the log (warn and error lines become PostHog `app_log`). Never a path or a file name.

public enum EditPreviewFailure {
    public static let couldntUpdate = "couldn't update the preview"
    public static let fileMissing = "this clip's file is missing"
    public static let couldntRead = "couldn't read this clip"
    public static let nothingToPlay = "nothing to play"

    /// A short reason for `error`. Codes and domains stay in the log; the canvas gets one of the lines above.
    public static func reason(_ error: Error) -> String {
        if let edit = error as? EditError {
            switch edit {
            case .other(let word) where word.hasPrefix("source:"): return fileMissing
            case .other("empty"): return nothingToPlay
            case .offline: return "offline, so the preview couldn't update"
            default: return couldntUpdate
            }
        }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError {
            return fileMissing
        }
        if ns.domain == AVFoundationErrorDomain { return couldntRead }
        return couldntUpdate
    }
}

/// One clip the preview left out or replaced with a gap. The timeline still shows it, with `reason`.
public struct EditPreviewIssue: Sendable, Equatable {
    public enum Lane: String, Sendable, Equatable { case main, overlay }

    public var clipID: String
    public var lane: Lane
    public var reason: String

    public init(clipID: String, lane: Lane, reason: String) {
        self.clipID = clipID
        self.lane = lane
        self.reason = reason
    }
}

/// A video overlay that hides the whole picture: full frame, fully opaque, no greenscreen. The canvas offers to open its effects.
public enum EditPreviewCover {
    /// The topmost overlay covering the canvas at `frame`, or nil. `blocked` skips a clip the preview already marked broken.
    public static func id(
        in timeline: EditTimeline, timing: EditTiming, at frame: Int,
        display: (String) -> PixelSize?,
        isVideo: (String) -> Bool,
        blocked: @escaping (String) -> Bool = { _ in false }
    ) -> String? {
        guard timing.clip(atFrame: frame) != nil else { return nil }
        let canvas = timeline.canvas
        var found: String?
        for j in timeline.overlayDrawOrder {
            guard j < timeline.overlay.count, j < timing.overlay.count else { continue }
            let overlay = timeline.overlay[j]
            guard !overlay.hidden, !blocked(overlay.id), isVideo(overlay.item), !overlay.hasKey else { continue }
            guard overlay.opacity >= 0.999 else { continue }
            let slot = timing.overlay[j]
            guard frame >= slot.start, frame < slot.start + slot.frames else { continue }
            guard let size = display(overlay.item), size.w > 0, size.h > 0 else { continue }
            let rect = EditGeometry.overlay(display: size, frame: overlay.frame, canvas: canvas)
            let covers = rect.x <= 2 && rect.y <= 2
                && rect.x + rect.w >= canvas.w - 2 && rect.y + rect.h >= canvas.h - 2
            if covers { found = overlay.id }
        }
        return found
    }
}
