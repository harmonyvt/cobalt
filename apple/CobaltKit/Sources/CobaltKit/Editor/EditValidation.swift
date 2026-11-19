import Foundation

// One validator, two callers (APP-API-CONTRACT 31.3): the app mirrors the server's `parseTimeline` + `checkSources` rule for rule,
// with the same codes and paths, so it can say the same thing before saving and disable `render`. Structure first (what
// `parseTimeline` finds), then the checks that need the library rows (`checkSources`).

public enum EditProblem: Sendable, Equatable {
    case canvas
    case empty
    case tooManyClips
    case tooLong
    case range(path: String)
    case overlayOverlap(path: String)
    case overlayPastEnd(path: String)
    case sourceMissing([String])
    case notVideo([String])
    case unsupportedSource([String])
    case pastSourceEnd(path: String)

    /// The server's code for the problem (31.12).
    public var code: String {
        switch self {
        case .canvas: return "error.edit.canvas"
        case .empty: return "error.edit.empty"
        case .tooManyClips: return "error.edit.too_many_clips"
        case .tooLong: return "error.edit.too_long"
        case .range: return "error.edit.range"
        case .overlayOverlap: return "error.edit.overlay_overlap"
        case .overlayPastEnd: return "error.edit.overlay_past_end"
        case .sourceMissing: return "error.edit.source_missing"
        case .notVideo: return "error.edit.not_video"
        case .unsupportedSource: return "error.edit.unsupported_source"
        case .pastSourceEnd: return "error.edit.past_source_end"
        }
    }

    /// The offending field in the request's own terms (`main[2].speed`, `overlay[0].frame.w`, `main`); nil for the problems that
    /// name library files instead (`items`).
    public var path: String? {
        switch self {
        case .canvas: return "canvas"
        case .empty, .tooManyClips, .tooLong: return "main"
        case .range(let path), .overlayOverlap(let path), .overlayPastEnd(let path), .pastSourceEnd(let path): return path
        case .sourceMissing, .notVideo, .unsupportedSource: return nil
        }
    }

    /// The library files a source problem names.
    public var items: [String] {
        switch self {
        case .sourceMissing(let ids), .notVideo(let ids), .unsupportedSource(let ids): return ids
        default: return []
        }
    }
}

public enum EditValidation {
    public static let maxSeconds = 600.0
    /// The clip ceiling when the server does not send `limits.edit_max_clips`. A server that sends one (200 on the
    /// companion) is used instead; `check` takes it.
    public static let maxClips = 50
    /// The layer ceiling when a caller does not pass the server's `limits.edit_overlay_tracks`. The old hard clamp of 8
    /// is this fallback, not a cap on a server that advertises more.
    public static let maxOverlayTracks = 8
    /// A capabilities payload cannot ask for a million lanes or clips. 64 and 200 pass. Above this, the number is cut.
    public static let safetyOverlayTracks = 256
    public static let safetyMaxClips = 2_000
    public static let minClipSeconds = 0.1
    /// Slack on `x + w <= 1` and `out <= duration` (31.2).
    static let frameSlack = 0.001
    static let sourceSlack = 0.05

    /// Every problem the server would find in `t`, given the library rows it names; `[]` = ok. `sources` is by library file id;
    /// an id missing from it (or one that is not `available`) is a deleted file.
    /// `maxClips` and `maxOverlayTracks` are the server's limits when the session has them, otherwise the old 50 and 8.
    public static func check(
        _ t: EditTimeline, sources: [String: EditSource], maxClips: Int = maxClips, maxOverlayTracks: Int = maxOverlayTracks
    ) -> [EditProblem] {
        if t.version >= 2 { return checkLanes(t, sources: sources, maxClips: maxClips) }
        var problems: [EditProblem] = []
        let t = EditJSON.rounded(t)

        // canvas
        let canvasOK = t.canvas.isValidSize && EditCanvas.fpsChoices.contains(t.canvas.fps)
        if !canvasOK { problems.append(.canvas) }

        // counts
        if t.main.isEmpty { problems.append(.empty) }
        if t.main.count + t.overlay.count > maxClips { problems.append(.tooManyClips) }

        // main clips
        for (i, clip) in t.main.enumerated() {
            let p = "main[\(i)]"
            if !(clip.speed >= 0.25 && clip.speed <= 4) { problems.append(.range(path: "\(p).speed")) }
            if !(clip.`in` >= 0) {
                problems.append(.range(path: "\(p).in"))
            } else if !(clip.out > clip.`in`) {
                problems.append(.range(path: "\(p).out"))
            } else if clip.speed > 0, (clip.out - clip.`in`) / clip.speed < minClipSeconds - 1e-9 {
                problems.append(.range(path: "\(p).out"))
            }
            if !(clip.volume >= 0 && clip.volume <= 1) { problems.append(.range(path: "\(p).volume")) }
            if !EditJSON.pitchRange.contains(clip.pitch) { problems.append(.range(path: "\(p).pitch")) }
            if let crop = clip.crop, !cropIsValid(crop) { problems.append(.range(path: "\(p).crop")) }
            // a crop under 64 px on a side is checked where the source's size is known
            if let crop = clip.crop, cropIsValid(crop), let display = sources[clip.item]?.display,
               EditGeometry.cropPixels(crop, display: display) == nil {
                problems.append(.range(path: "\(p).crop"))
            }
        }

        // length
        let timing = EditTiming(t)
        if canvasOK, timing.seconds > maxSeconds { problems.append(.tooLong) }

        // overlays: ranges, order, overlap (per layer, 39.1), the end
        let layerLimit = max(1, maxOverlayTracks)
        var previousEnd: [Int: Int] = [:]
        for (j, o) in t.overlay.enumerated() {
            let p = "overlay[\(j)]"
            let source = sources[o.item]
            let trackOK = (0..<layerLimit).contains(o.track)
            if !trackOK { problems.append(.range(path: "\(p).track")) }
            if !(o.at >= 0) { problems.append(.range(path: "\(p).at")) }
            if !(o.`in` >= 0) {
                problems.append(.range(path: "\(p).in"))
            } else if !(o.out > o.`in`) || o.out - o.`in` < minClipSeconds - 1e-9 {
                problems.append(.range(path: "\(p).out"))
            } else if let kind = source?.kind, kind == .gif || kind == .photo, (o.`in` != 0 || o.out > maxSeconds) {
                problems.append(.range(path: "\(p).out"))
            }
            if !(o.opacity >= 0.1 && o.opacity <= 1) { problems.append(.range(path: "\(p).opacity")) }
            if !(o.volume >= 0 && o.volume <= 1) { problems.append(.range(path: "\(p).volume")) }
            if !EditJSON.pitchRange.contains(o.pitch) { problems.append(.range(path: "\(p).pitch")) }
            let f = o.frame
            if !(f.w >= 0.05 && f.w <= 1) {
                problems.append(.range(path: "\(p).frame.w"))
            } else if !(f.x >= 0) || f.x + f.w > 1 + frameSlack {
                problems.append(.range(path: "\(p).frame.x"))
            } else if !(f.y >= 0) {
                problems.append(.range(path: "\(p).frame.y"))
            } else if let display = source?.display, canvasOK,
                      f.y + EditGeometry.overlayHeightFraction(display: display, frame: f, canvas: t.canvas) > 1 + frameSlack {
                problems.append(.range(path: "\(p).frame.y"))
            }
            guard j < timing.overlay.count else { continue }
            let clip = timing.overlay[j]
            let k = trackOK ? o.track : 0
            if (j > 0 && o.at < t.overlay[j - 1].at) || clip.start < (previousEnd[k] ?? 0) {
                problems.append(.overlayOverlap(path: p))
            }
            if canvasOK, clip.start + clip.frames > timing.frames {
                problems.append(.overlayPastEnd(path: p))
            }
            previousEnd[k] = max(previousEnd[k] ?? 0, clip.start + clip.frames)
        }

        problems.append(contentsOf: checkSources(t, sources: sources))
        return problems
    }

    /// `checkSources`: the checks that need the library rows. One problem per kind, naming every file it concerns.
    static func checkSources(_ t: EditTimeline, sources: [String: EditSource]) -> [EditProblem] {
        var missing: [String] = [], notVideo: [String] = [], unsupported: [String] = []
        var problems: [EditProblem] = []
        func note(_ id: String, in list: inout [String]) { if !list.contains(id) { list.append(id) } }

        for (i, clip) in t.main.enumerated() {
            guard let source = sources[clip.item], source.available else { note(clip.item, in: &missing); continue }
            switch source.kind {
            case .video:
                if let duration = source.duration, clip.out > duration + sourceSlack {
                    problems.append(.pastSourceEnd(path: "main[\(i)].out"))
                }
            case .unsupported: note(clip.item, in: &unsupported)
            case .gif, .photo: note(clip.item, in: &notVideo)
            }
        }
        for (j, o) in t.overlay.enumerated() {
            guard let source = sources[o.item], source.available else { note(o.item, in: &missing); continue }
            switch source.kind {
            case .video:
                if let duration = source.duration, o.out > duration + sourceSlack {
                    problems.append(.pastSourceEnd(path: "overlay[\(j)].out"))
                }
            case .unsupported: note(o.item, in: &unsupported)
            case .gif, .photo: break
            }
        }
        var out: [EditProblem] = []
        if !missing.isEmpty { out.append(.sourceMissing(missing)) }
        if !notVideo.isEmpty { out.append(.notVideo(notVideo)) }
        if !unsupported.isEmpty { out.append(.unsupportedSource(unsupported)) }
        out.append(contentsOf: problems)
        return out
    }

    /// Version 2 (section 69): pictures and GIFs are allowed on every lane, including lane 0. A gap is allowed. Two clips
    /// on one lane may not share a frame. The edit length is the latest clip end.
    static func checkLanes(_ raw: EditTimeline, sources: [String: EditSource], maxClips: Int) -> [EditProblem] {
        var problems: [EditProblem] = []
        let t = EditJSON.rounded(raw)
        let canvasOK = t.canvas.isValidSize && EditCanvas.fpsChoices.contains(t.canvas.fps)
        if !canvasOK { problems.append(.canvas) }
        if t.clips.isEmpty { problems.append(.empty) }
        if t.clips.count > maxClips { problems.append(.tooManyClips) }
        for (index, clip) in t.clips.enumerated() {
            let path = "clips[\(index)]"
            if !(0..<EditLanes.laneLimit).contains(clip.lane) { problems.append(.range(path: "\(path).lane")) }
            if !(clip.speed >= 0.25 && clip.speed <= 4) { problems.append(.range(path: "\(path).speed")) }
            if !(clip.at >= 0) { problems.append(.range(path: "\(path).at")) }
            if !(clip.`in` >= 0) {
                problems.append(.range(path: "\(path).in"))
            } else if !(clip.out > clip.`in`) {
                problems.append(.range(path: "\(path).out"))
            } else if clip.speed > 0, (clip.out - clip.`in`) / clip.speed < minClipSeconds - 1e-9 {
                problems.append(.range(path: "\(path).out"))
            }
            if !(clip.volume >= 0 && clip.volume <= 1) { problems.append(.range(path: "\(path).volume")) }
            if !(clip.opacity >= 0.1 && clip.opacity <= 1) { problems.append(.range(path: "\(path).opacity")) }
            if !EditJSON.pitchRange.contains(clip.pitch) { problems.append(.range(path: "\(path).pitch")) }
            if let crop = clip.crop, !cropIsValid(crop) { problems.append(.range(path: "\(path).crop")) }
            if let crop = clip.crop, cropIsValid(crop), let display = sources[clip.item]?.display,
               EditGeometry.cropPixels(crop, display: display) == nil {
                problems.append(.range(path: "\(path).crop"))
            }
            if let frame = clip.frame {
                if !(frame.w >= 0.05 && frame.w <= 1) {
                    problems.append(.range(path: "\(path).frame.w"))
                } else if !(frame.x >= 0) || frame.x + frame.w > 1 + frameSlack {
                    problems.append(.range(path: "\(path).frame.x"))
                } else if !(frame.y >= 0) {
                    problems.append(.range(path: "\(path).frame.y"))
                } else if let display = sources[clip.item]?.display, canvasOK,
                          frame.y + EditGeometry.overlayHeightFraction(display: display, frame: frame, canvas: t.canvas) > 1 + frameSlack {
                    problems.append(.range(path: "\(path).frame.y"))
                }
            }
            if let kind = sources[clip.item]?.kind, kind == .gif || kind == .photo {
                if clip.`in` != 0 || clip.out > maxSeconds { problems.append(.range(path: "\(path).out")) }
            }
        }
        let timing = EditTiming(t)
        if canvasOK, timing.seconds > maxSeconds { problems.append(.tooLong) }
        var lanes: [Int: [(index: Int, start: Int, end: Int)]] = [:]
        for (index, row) in timing.laneClips.enumerated() {
            lanes[row.lane, default: []].append((index, row.start, row.start + row.frames))
        }
        for list in lanes.values {
            let sorted = list.sorted { lhs, rhs in
                lhs.start != rhs.start ? lhs.start < rhs.start : lhs.index < rhs.index
            }
            for index in sorted.indices.dropFirst() where sorted[index].start < sorted[index - 1].end {
                problems.append(.overlayOverlap(path: "clips[\(sorted[index].index)]"))
            }
        }
        problems.append(contentsOf: checkLaneSources(t, sources: sources))
        return problems
    }

    static func checkLaneSources(_ t: EditTimeline, sources: [String: EditSource]) -> [EditProblem] {
        var missing: [String] = [], unsupported: [String] = []
        var problems: [EditProblem] = []
        func note(_ id: String, in list: inout [String]) { if !list.contains(id) { list.append(id) } }
        for (index, clip) in t.clips.enumerated() {
            guard let source = sources[clip.item], source.available else { note(clip.item, in: &missing); continue }
            switch source.kind {
            case .video:
                if let duration = source.duration, clip.out > duration + sourceSlack {
                    problems.append(.pastSourceEnd(path: "clips[\(index)].out"))
                }
            case .unsupported: note(clip.item, in: &unsupported)
            case .gif, .photo: break
            }
        }
        var out: [EditProblem] = []
        if !missing.isEmpty { out.append(.sourceMissing(missing)) }
        if !unsupported.isEmpty { out.append(.unsupportedSource(unsupported)) }
        out.append(contentsOf: problems)
        return out
    }

    /// `parseCrop` of section 10: `x, y >= 0` (and at most 1), `w, h > 0`, `x + w <= 1.001`, `y + h <= 1.001`.
    static func cropIsValid(_ c: EditCrop) -> Bool {
        guard c.x.isFinite, c.y.isFinite, c.w.isFinite, c.h.isFinite else { return false }
        if c.x < 0 || c.y < 0 || c.x > 1 || c.y > 1 { return false }
        if !(c.w > 0) || !(c.h > 0) { return false }
        return c.x + c.w <= 1 + frameSlack && c.y + c.h <= 1 + frameSlack
    }
}
