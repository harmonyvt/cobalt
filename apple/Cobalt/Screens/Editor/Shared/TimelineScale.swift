import CobaltKit
import SwiftUI

/// Shared (Mac, iPad and iPhone timelines): how many points a second of output takes, and the maths around it.
///
/// A timeline view lays its blocks out with `x(seconds)` and reads gestures back with `seconds(at:)`. Zooming makes a new
/// scale with `zoomed(by:)` (clamped); `labelStep` and `minorStep` say where the ruler puts its ticks so the labels never
/// crowd. The Mac board's scale is 36 pt a second (180 pt per 5 s).
struct TimelineScale: Equatable, Sendable {
    var pointsPerSecond: CGFloat

    static let minimum: CGFloat = 6
    static let maximum: CGFloat = 480
    static let standard = TimelineScale(pointsPerSecond: 36)

    init(pointsPerSecond: CGFloat = 36) {
        self.pointsPerSecond = min(max(pointsPerSecond, Self.minimum), Self.maximum)
    }

    /// The scale that fits `duration` seconds into `width` points (clamped).
    static func fitting(duration: Double, width: CGFloat) -> TimelineScale {
        guard duration > 0, width > 0 else { return .standard }
        return TimelineScale(pointsPerSecond: width / CGFloat(duration))
    }

    func x(_ seconds: Double) -> CGFloat { CGFloat(seconds) * pointsPerSecond }
    func seconds(at x: CGFloat) -> Double { Double(x / pointsPerSecond) }
    func width(of seconds: Double) -> CGFloat { max(0, x(seconds)) }

    /// A scale `factor` times as wide (1.25 zooms in a step, 0.8 out), clamped.
    func zoomed(by factor: CGFloat) -> TimelineScale { TimelineScale(pointsPerSecond: pointsPerSecond * factor) }

    var isAtMinimum: Bool { pointsPerSecond <= Self.minimum + 0.001 }
    var isAtMaximum: Bool { pointsPerSecond >= Self.maximum - 0.001 }

    private static let steps: [(label: Double, minors: Int)] = [
        (0.1, 2), (0.2, 2), (0.5, 5), (1, 5), (2, 2), (5, 5), (10, 5), (15, 3), (30, 3), (60, 6), (120, 4), (300, 5),
    ]

    private var entry: (label: Double, minors: Int) {
        Self.steps.first { CGFloat($0.label) * pointsPerSecond >= 64 } ?? Self.steps[Self.steps.count - 1]
    }

    /// Seconds between two labelled ticks: the first step that leaves 64 pt between labels.
    var labelStep: Double { entry.label }
    /// Seconds between the small ticks between two labels.
    var minorStep: Double { entry.label / Double(entry.minors) }
    var minorCount: Int { entry.minors }
}

/// A block of the timeline in output seconds.
struct TimelineSpan: Identifiable, Equatable, Sendable {
    let id: String
    let start: Double
    let length: Double
    var end: Double { start + length }
}

extension EditSession {
    /// The main clips' places on the output timeline, in track order (the same order as `timeline.main`).
    var mainSpans: [TimelineSpan] {
        timing.main.map {
            TimelineSpan(id: $0.id, start: timing.time(ofFrame: $0.start), length: Double($0.frames) / Double(timing.fps))
        }
    }

    /// The overlays' places on the output timeline (the same order as `timeline.overlay`).
    var overlaySpans: [TimelineSpan] {
        timing.overlay.map {
            TimelineSpan(id: $0.id, start: timing.time(ofFrame: $0.start), length: Double($0.frames) / Double(timing.fps))
        }
    }

    /// The playhead in seconds.
    var playheadSeconds: Double { timing.time(ofFrame: playhead) }

    /// The selected main clip and its index in the track.
    var selectedMain: (index: Int, clip: EditClip)? {
        guard case .main(let id) = selection, let index = timeline.main.firstIndex(where: { $0.id == id }) else { return nil }
        return (index, timeline.main[index])
    }

    /// The selected overlay.
    var selectedOverlay: EditOverlay? {
        guard case .overlay(let id) = selection else { return nil }
        return timeline.overlay.first { $0.id == id }
    }

    /// The library file behind a clip or overlay (nil while unknown).
    func source(for item: String) -> EditSource? { sources[item] }

    /// The file was deleted from the library (or never came back from the server).
    func isMissing(item: String) -> Bool {
        guard let source = sources[item] else { return true }
        return !source.available
    }

    /// Some clip or overlay names a file that is gone: rendering waits until it is removed.
    var hasMissingSources: Bool {
        let items = Set(timeline.main.map(\.item) + timeline.overlay.map(\.item))
        return items.contains { isMissing(item: $0) }
    }

    /// The main clip under the playhead.
    var clipUnderPlayhead: (index: Int, clip: EditClip)? {
        guard let hit = timing.clip(atFrame: playhead), timeline.main.indices.contains(hit.index) else { return nil }
        return (hit.index, timeline.main[hit.index])
    }

    /// The playhead is strictly inside a main clip (a split there leaves two clips).
    var canSplitAtPlayhead: Bool {
        guard let hit = timing.clip(atFrame: playhead) else { return false }
        return hit.offset > 0
    }

    /// 0...1 of every file still downloading, averaged; nil when none is.
    var loadingFraction: Double? {
        guard !loadingSources.isEmpty else { return nil }
        return loadingSources.values.reduce(0, +) / Double(loadingSources.count)
    }

    /// The save line of the top bar (`saved · 4 clips · 0:26`, `saving…`, `not saved · retrying`, `changed on another device`).
    var saveLine: String {
        switch saveState {
        case .saved: return Copy.Editor.saveSaved(clips: timeline.main.count, duration: Copy.Editor.clock(timing.seconds))
        case .saving, .unsaved: return Copy.Editor.saveSaving
        case .failed: return Copy.Editor.saveRetrying
        case .conflict: return Copy.Editor.saveConflict
        }
    }

    /// The first thing wrong with the timeline, in words (also what `render` says when it is disabled).
    var problemLine: String? {
        guard let first = problems.first else { return nil }
        return Copy.Editor.problem(first, duration: timing.seconds)
    }

    /// `1080p · 30` for the timeline's canvas.
    var qualityLine: String { Copy.Editor.qualityLabel(timeline.canvas.resolution.rawValue, timeline.canvas.fps) }
}

/// What buttons need to know of the playhead: the main clip under it and whether a split there works.
struct EditorPlayheadSpot: Equatable {
    var clipID: String?
    var canSplit: Bool

    @MainActor init(_ session: EditSession) {
        clipID = session.clipUnderPlayhead?.clip.id
        canSplit = session.canSplitAtPlayhead
    }
}

/// Reads the playhead in a view of its own and reports `EditorPlayheadSpot` only when it changes, so a toolbar using it does
/// not redraw on every frame while playing.
struct EditorPlayheadSpotReader: View {
    let session: EditSession
    let onChange: (EditorPlayheadSpot) -> Void

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: EditorPlayheadSpot(session), initial: true) { _, spot in onChange(spot) }
    }
}
