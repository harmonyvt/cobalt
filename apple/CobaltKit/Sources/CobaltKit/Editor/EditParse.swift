import Foundation

// The strict timeline parse (APP-API-CONTRACT 31.3 and 69). The Codable path reads a canonical document the server already
// accepted. This one rejects the same documents `parseTimeline` rejects, with the same code and path, and it is what the
// shared fixtures are checked against.

private enum Step<T> {
    case value(T)
    case failed(code: String, path: String)

    var failure: EditParseResult? {
        if case .failed(let code, let path) = self { return .failed(code: code, path: path) }
        return nil
    }
}

extension EditLanes {
    public static func parse(_ data: Data) -> EditParseResult {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return .failed(code: "error.edit.bad_request", path: "")
        }
        return parseJSON(any)
    }

    public static func parseJSON(_ any: Any) -> EditParseResult {
        let value = ParseValue(any)
        if case .string(let text) = value, let data = text.data(using: .utf8) { return parse(data) }
        guard case .object(let root) = value else { return .failed(code: "error.edit.bad_request", path: "") }
        if root["version"]?.int == 2 { return parseV2(root) }
        return parseV1(root)
    }

    /// A parsed version 1 timeline as version 2. Track 63 would be lane 64, which does not exist.
    public static func v1ToV2(_ timeline: EditTimeline) -> EditParseResult {
        guard timeline.version == 1 else { return .failed(code: "error.edit.bad_request", path: "version") }
        let fps = max(1, timeline.canvas.fps)
        var clips: [EditLaneClip] = []
        var frame = 0
        for clip in timeline.storedMain {
            let frames = max(1, EditMath.roundHalfUp((clip.out - clip.`in`) / max(clip.speed, 0.0001) * Double(fps)))
            clips.append(EditLaneClip(
                id: clip.id, item: clip.item, lane: 0,
                at: EditJSON.time(Double(frame) / Double(fps)), in: clip.`in`, out: clip.out, speed: clip.speed,
                crop: clip.crop, fit: clip.fit, volume: clip.volume, muted: clip.muted, pitch: clip.pitch))
            frame += frames
        }
        for (index, overlay) in timeline.storedOverlay.enumerated() {
            let lane = overlay.track + 1
            if lane >= laneLimit { return .failed(code: "error.edit.range", path: "overlay[\(index)].track") }
            clips.append(EditLaneClip(
                id: overlay.id, item: overlay.item, lane: lane, at: overlay.at, in: overlay.`in`, out: overlay.out,
                frame: overlay.frame, opacity: overlay.opacity, volume: overlay.volume, muted: overlay.muted,
                pitch: overlay.pitch, hidden: overlay.hidden, key: overlay.key, background: overlay.background))
        }
        let converted = EditTimeline(canvas: timeline.canvas, clips: clips, output: timeline.output)
        if let failure = checkTimingV2(converted) { return failure }
        return .ok(EditJSON.rounded(converted))
    }

    /// A parsed version 2 timeline as version 1, when nothing would be dropped. `kinds` maps an item id to "video",
    /// "gif" or "photo". A missing kind is not treated as a picture. Nil `kinds` skips that check.
    public static func v2ToV1(_ timeline: EditTimeline, kinds: [String: String?]? = nil) -> EditParseResult {
        guard timeline.version >= 2 else { return .failed(code: "error.edit.bad_request", path: "version") }
        let fps = max(1, timeline.canvas.fps)
        var lane0: [(index: Int, clip: EditLaneClip)] = []
        var higher: [(index: Int, clip: EditLaneClip)] = []
        for (index, clip) in timeline.clips.enumerated() {
            let path = "clips[\(index)]"
            if clip.lane == 0 {
                if clip.frame != nil { return .failed(code: "error.edit.needs_timeline_v2", path: "\(path).frame") }
                if clip.opacity != 1 { return .failed(code: "error.edit.needs_timeline_v2", path: "\(path).opacity") }
                if clip.hidden { return .failed(code: "error.edit.needs_timeline_v2", path: "\(path).hidden") }
                if clip.key != nil { return .failed(code: "error.edit.needs_timeline_v2", path: "\(path).key") }
                if clip.background != nil { return .failed(code: "error.edit.needs_timeline_v2", path: "\(path).background") }
                if let kinds, let kind = kinds[clip.item] ?? nil, kind != "video" {
                    return .failed(code: "error.edit.needs_timeline_v2", path: "\(path).item")
                }
                lane0.append((index, clip))
            } else {
                // no frame, a turned one, or one that is not inside the canvas (69.7): a version 1 overlay cannot hold it
                if !(clip.frame.map(EditGeometry.isV1Frame) ?? false) {
                    return .failed(code: "error.edit.needs_timeline_v2", path: "\(path).frame")
                }
                if clip.crop != nil { return .failed(code: "error.edit.needs_timeline_v2", path: "\(path).crop") }
                if clip.speed != 1 { return .failed(code: "error.edit.needs_timeline_v2", path: "\(path).speed") }
                if clip.fit != .fill { return .failed(code: "error.edit.needs_timeline_v2", path: "\(path).fit") }
                higher.append((index, clip))
            }
        }
        if lane0.isEmpty { return .failed(code: "error.edit.needs_timeline_v2", path: "clips") }
        lane0.sort { lhs, rhs in
            lhs.clip.at != rhs.clip.at ? lhs.clip.at < rhs.clip.at : lhs.index < rhs.index
        }
        var cursor = 0
        for entry in lane0 {
            if startFrame(entry.clip.at, fps: fps) != cursor {
                return .failed(code: "error.edit.needs_timeline_v2", path: "clips[\(entry.index)].at")
            }
            cursor += outputFrames(entry.clip, fps: fps)
        }
        higher.sort { lhs, rhs in
            lhs.clip.at != rhs.clip.at ? lhs.clip.at < rhs.clip.at : lhs.index < rhs.index
        }
        let v1 = EditTimeline(
            version: 1, canvas: timeline.canvas, main: lane0.map { asMain($0.clip) },
            overlay: higher.map { asOverlay($0.clip) }, output: timeline.output)
        if let failure = checkTimingV1(v1) {
            return .failed(code: "error.edit.needs_timeline_v2", path: failure.path)
        }
        return .ok(EditJSON.rounded(v1))
    }
}

// MARK: - values

private enum ParseValue {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ParseValue])
    case object([String: ParseValue])

    init(_ any: Any) {
        if any is NSNull { self = .null; return }
        // Bool is an NSNumber. A 0 or a 1 must stay a number, so the boolean check is the CoreFoundation type.
        if let number = any as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
            return
        }
        if let value = any as? String { self = .string(value); return }
        if let value = any as? [Any] { self = .array(value.map(ParseValue.init)); return }
        if let value = any as? [String: Any] { self = .object(value.mapValues(ParseValue.init)); return }
        self = .null
    }

    var object: [String: ParseValue]? { if case .object(let value) = self { return value }; return nil }
    var array: [ParseValue]? { if case .array(let value) = self { return value }; return nil }
    var string: String? { if case .string(let value) = self { return value }; return nil }
    var bool: Bool? { if case .bool(let value) = self { return value }; return nil }
    var number: Double? { if case .number(let value) = self { return value }; return nil }
    var int: Int? {
        guard let number, number.isFinite, abs(number) < 1e15, number == number.rounded() else { return nil }
        return Int(number)
    }
}

private let secondsBound = 1e5
private let idPattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9_-]{1,24}$")
private let itemPattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9]{16}$")
private let hexPattern = try! NSRegularExpression(pattern: "^#[0-9A-Fa-f]{6}$")

private func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
    pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
}

private func keysOK(
    _ object: [String: ParseValue], required: [String], optional: [String], prefix: String
) -> EditParseResult? {
    let dot = prefix.isEmpty ? "" : "."
    for key in object.keys where !required.contains(key) && !optional.contains(key) {
        return .failed(code: "error.edit.bad_request", path: "\(prefix)\(dot)\(key)")
    }
    for key in required where object[key] == nil {
        return .failed(code: "error.edit.bad_request", path: "\(prefix)\(dot)\(key)")
    }
    return nil
}

private func parseCanvas(_ value: ParseValue?) -> Step<EditCanvas> {
    guard let object = value?.object else { return .failed(code: "error.edit.bad_request", path: "canvas") }
    if let failure = keysOK(object, required: ["w", "h", "fps"], optional: [], prefix: "canvas") {
        return .failed(code: failure.code, path: failure.path)
    }
    guard let w = object["w"]?.int else { return .failed(code: "error.edit.bad_request", path: "canvas.w") }
    guard let h = object["h"]?.int else { return .failed(code: "error.edit.bad_request", path: "canvas.h") }
    guard let fps = object["fps"]?.int else { return .failed(code: "error.edit.bad_request", path: "canvas.fps") }
    guard EditCanvas.sizes.contains(where: { $0.w == w && $0.h == h }) else {
        return .failed(code: "error.edit.canvas", path: "canvas")
    }
    guard fps == 30 || fps == 60 else { return .failed(code: "error.edit.canvas", path: "canvas.fps") }
    return .value(EditCanvas(w: w, h: h, fps: fps))
}

private func takeID(_ object: [String: ParseValue], path: String, seen: inout Set<String>) -> String? {
    guard let id = object["id"]?.string, matches(idPattern, id), !seen.contains(id) else { return nil }
    seen.insert(id)
    return id
}

private func parsePitch(_ object: [String: ParseValue], path: String) -> Step<Double> {
    guard object["pitch"] != nil else { return .value(0) }
    guard let raw = object["pitch"]?.number else { return .failed(code: "error.edit.bad_request", path: "\(path).pitch") }
    let quant = Double(EditMath.roundHalfUp(raw / 0.5)) * 0.5
    let pitch = quant == 0 ? 0 : quant
    if pitch < -12 || pitch > 12 { return .failed(code: "error.edit.range", path: "\(path).pitch") }
    return .value(pitch)
}

private func snapSpeed(_ raw: Double) -> Double {
    let snapped = Double(EditMath.roundHalfUp(raw / 0.05)) * 0.05
    let held = (snapped * 100).rounded(.toNearestOrAwayFromZero) / 100
    return held == 0 ? 0 : held
}

private func parseCrop(_ value: ParseValue?, path: String) -> Step<EditCrop> {
    guard let object = value?.object else { return .failed(code: "error.edit.bad_request", path: path) }
    if let failure = keysOK(object, required: ["aspect", "x", "y", "w", "h"], optional: [], prefix: path) {
        return .failed(code: failure.code, path: failure.path)
    }
    guard let aspect = object["aspect"]?.string, let kind = EditCrop.Aspect(rawValue: aspect) else {
        return .failed(code: "error.edit.bad_request", path: "\(path).aspect")
    }
    guard let x0 = object["x"]?.number, let y0 = object["y"]?.number, let w0 = object["w"]?.number, let h0 = object["h"]?.number else {
        return .failed(code: "error.edit.bad_request", path: path)
    }
    func held(_ raw: Double) -> Double { EditJSON.fraction(min(2, max(-1, raw))) }
    let x = held(x0), y = held(y0), w = held(w0), h = held(h0)
    if x0 < 0 { return .failed(code: "error.edit.range", path: "\(path).x") }
    if y0 < 0 { return .failed(code: "error.edit.range", path: "\(path).y") }
    if !(w > 0) { return .failed(code: "error.edit.range", path: "\(path).w") }
    if !(h > 0) { return .failed(code: "error.edit.range", path: "\(path).h") }
    if x + w > 1 + 1e-3 { return .failed(code: "error.edit.range", path: "\(path).w") }
    if y + h > 1 + 1e-3 { return .failed(code: "error.edit.range", path: "\(path).h") }
    return .value(EditCrop(aspect: kind, x: x, y: y, w: w, h: h))
}

private func parseKey(_ value: ParseValue?, path: String) -> Step<EditChromaKey?> {
    guard let value else { return .value(nil) }
    guard let object = value.object else { return .failed(code: "error.edit.bad_request", path: path) }
    if let failure = keysOK(object, required: ["color", "similarity", "blend", "spill"], optional: [], prefix: path) {
        return .failed(code: failure.code, path: failure.path)
    }
    guard let color = object["color"]?.string, matches(hexPattern, color) else {
        return .failed(code: "error.edit.bad_request", path: "\(path).color")
    }
    guard let similarity = object["similarity"]?.number, let blend = object["blend"]?.number, let spill = object["spill"]?.number else {
        return .failed(code: "error.edit.bad_request", path: path)
    }
    if similarity < 0.01 - 1e-9 || similarity > 0.6 { return .failed(code: "error.edit.range", path: "\(path).similarity") }
    if blend < 0 || blend > 0.5 { return .failed(code: "error.edit.range", path: "\(path).blend") }
    if spill < 0 || spill > 1 { return .failed(code: "error.edit.range", path: "\(path).spill") }
    return .value(EditChromaKey(
        color: "#" + color.dropFirst().uppercased(),
        similarity: EditJSON.round(similarity, to: 1_000),
        blend: EditJSON.round(blend, to: 1_000),
        spill: EditJSON.round(spill, to: 1_000)))
}

private func parseBackground(_ value: ParseValue?, path: String) -> Step<EditOverlayBackground?> {
    guard let value else { return .value(nil) }
    guard let object = value.object else { return .failed(code: "error.edit.bad_request", path: path) }
    switch object["type"]?.string {
    case "transparent":
        return .value(nil)
    case "clip":
        if let failure = keysOK(object, required: ["type"], optional: [], prefix: path) {
            return .failed(code: failure.code, path: failure.path)
        }
        return .value(.clip)
    case "color":
        if let failure = keysOK(object, required: ["type", "color"], optional: [], prefix: path) {
            return .failed(code: failure.code, path: failure.path)
        }
        guard let color = object["color"]?.string, matches(hexPattern, color) else {
            return .failed(code: "error.edit.bad_request", path: "\(path).color")
        }
        return .value(.color("#" + color.dropFirst().uppercased()))
    default:
        return .failed(code: "error.edit.bad_request", path: "\(path).type")
    }
}

private func parseFrame(_ value: ParseValue?, path: String) -> Step<EditFrame> {
    guard let object = value?.object else { return .failed(code: "error.edit.bad_request", path: path) }
    if let failure = keysOK(object, required: ["x", "y", "w"], optional: [], prefix: path) {
        return .failed(code: failure.code, path: failure.path)
    }
    guard let x0 = object["x"]?.number, let y0 = object["y"]?.number, let w0 = object["w"]?.number else {
        return .failed(code: "error.edit.bad_request", path: path)
    }
    if x0 < 0 { return .failed(code: "error.edit.range", path: "\(path).x") }
    if y0 < 0 { return .failed(code: "error.edit.range", path: "\(path).y") }
    let frame = EditFrame(
        x: EditJSON.fraction(min(2, max(0, x0))), y: EditJSON.fraction(min(2, max(0, y0))),
        w: EditJSON.fraction(min(2, max(-1, w0))))
    if frame.w < 0.05 || frame.w > 1 { return .failed(code: "error.edit.range", path: "\(path).w") }
    if frame.x + frame.w > 1 + 1e-3 { return .failed(code: "error.edit.range", path: "\(path).x") }
    return .value(frame)
}

/// A version 2 clip's `frame` (69.7): `x`, `y`, `w` as fractions of the canvas and an optional `r` (degrees, clockwise).
/// The box may hang past any edge and be up to 4 canvases wide as long as part of it is on the canvas (`x < 1`,
/// `x + w > 0`, `y < 1`; `y + h > 0` needs the picture's size and is `EditValidation`'s). `r` is -180...180, rounded to 0.1,
/// and left out when 0, so a frame saved before 69.7 is the same document. Mirrors `parseLaneFrame` in `timeline.js`.
private func parseLaneFrame(_ value: ParseValue?, path: String) -> Step<EditFrame> {
    guard let object = value?.object else { return .failed(code: "error.edit.bad_request", path: path) }
    if let failure = keysOK(object, required: ["x", "y", "w"], optional: ["r"], prefix: path) {
        return .failed(code: failure.code, path: failure.path)
    }
    for key in ["x", "y", "w"] where object[key]?.number == nil {
        return .failed(code: "error.edit.bad_request", path: "\(path).\(key)")
    }
    let fx = object["x"]!.number!, fy = object["y"]!.number!, fw = object["w"]!.number!
    let w = EditJSON.fraction(min(8, max(0, fw)))
    if fw < 0 || w < 0.05 || w > EditValidation.frameMaxWidth { return .failed(code: "error.edit.range", path: "\(path).w") }
    let x = EditJSON.fraction(min(8, max(-8, fx)))
    if x >= 1 || x + w <= 0 { return .failed(code: "error.edit.range", path: "\(path).x") }
    let y = EditJSON.fraction(min(8, max(-8, fy)))
    if y >= 1 || y < -EditValidation.frameMaxWidth * 4 { return .failed(code: "error.edit.range", path: "\(path).y") }
    var frame = EditFrame(x: x, y: y, w: w)
    if object["r"] != nil {
        guard let raw = object["r"]?.number else { return .failed(code: "error.edit.bad_request", path: "\(path).r") }
        let r = EditJSON.angle(raw)
        if r < -180 || r > 180 { return .failed(code: "error.edit.range", path: "\(path).r") }
        frame.r = r
    }
    return .value(frame)
}

private func readOutput(_ root: [String: ParseValue]) -> Step<EditKeyedOutput?> {
    switch root["output"] {
    case nil: return .value(nil)
    case .string("mp4"): return .value(nil)
    case .string("webm"): return .value(.webm)
    case .string("prores"): return .value(.prores)
    case .string("webp"): return .value(.webp)
    default: return .failed(code: "error.edit.bad_request", path: "output")
    }
}

private func parseV1(_ root: [String: ParseValue]) -> EditParseResult {
    if let failure = keysOK(root, required: ["version", "canvas", "main", "overlay"], optional: ["output"], prefix: "") {
        return failure
    }
    guard root["version"]?.int == 1 else { return .failed(code: "error.edit.bad_request", path: "version") }
    guard case .value(let output) = readOutput(root) else { return readOutput(root).failure! }
    guard case .value(let canvas) = parseCanvas(root["canvas"]) else { return parseCanvas(root["canvas"]).failure! }
    guard let mainValues = root["main"]?.array else { return .failed(code: "error.edit.bad_request", path: "main") }
    guard let overlayValues = root["overlay"]?.array else { return .failed(code: "error.edit.bad_request", path: "overlay") }
    if mainValues.isEmpty { return .failed(code: "error.edit.empty", path: "main") }
    if mainValues.count + overlayValues.count > 200 { return .failed(code: "error.edit.too_many_clips", path: "main") }
    var seen: Set<String> = []
    var main: [EditClip] = []
    for (index, value) in mainValues.enumerated() {
        switch parseMain(value, path: "main[\(index)]", seen: &seen) {
        case .value(let clip): main.append(clip)
        case .failed(let code, let path): return .failed(code: code, path: path)
        }
    }
    var overlay: [EditOverlay] = []
    for (index, value) in overlayValues.enumerated() {
        switch parseOverlay(value, path: "overlay[\(index)]", seen: &seen) {
        case .value(let clip): overlay.append(clip)
        case .failed(let code, let path): return .failed(code: code, path: path)
        }
    }
    let timeline = EditTimeline(version: 1, canvas: canvas, main: main, overlay: overlay, output: output)
    if let failure = checkTimingV1(timeline) { return failure }
    return .ok(timeline)
}

private func parseV2(_ root: [String: ParseValue]) -> EditParseResult {
    if let failure = keysOK(root, required: ["version", "canvas", "clips"], optional: ["output"], prefix: "") {
        return failure
    }
    guard case .value(let output) = readOutput(root) else { return readOutput(root).failure! }
    guard case .value(let canvas) = parseCanvas(root["canvas"]) else { return parseCanvas(root["canvas"]).failure! }
    guard let values = root["clips"]?.array else { return .failed(code: "error.edit.bad_request", path: "clips") }
    if values.isEmpty { return .failed(code: "error.edit.empty", path: "clips") }
    if values.count > 200 { return .failed(code: "error.edit.too_many_clips", path: "clips") }
    var seen: Set<String> = []
    var clips: [EditLaneClip] = []
    for (index, value) in values.enumerated() {
        switch parseLane(value, path: "clips[\(index)]", seen: &seen) {
        case .value(let clip): clips.append(clip)
        case .failed(let code, let path): return .failed(code: code, path: path)
        }
    }
    let timeline = EditTimeline(canvas: canvas, clips: clips, output: output)
    if let failure = checkTimingV2(timeline) { return failure }
    return .ok(timeline)
}

private func parseMain(_ value: ParseValue, path: String, seen: inout Set<String>) -> Step<EditClip> {
    guard let object = value.object else { return .failed(code: "error.edit.bad_request", path: path) }
    if let failure = keysOK(
        object, required: ["id", "item", "in", "out", "speed", "fit", "volume", "muted"], optional: ["crop", "pitch"], prefix: path
    ) { return .failed(code: failure.code, path: failure.path) }
    guard let id = takeID(object, path: path, seen: &seen) else {
        return .failed(code: "error.edit.bad_request", path: "\(path).id")
    }
    guard let item = object["item"]?.string, matches(itemPattern, item) else {
        return .failed(code: "error.edit.bad_request", path: "\(path).item")
    }
    guard object["in"]?.number != nil else { return .failed(code: "error.edit.bad_request", path: "\(path).in") }
    guard object["out"]?.number != nil else { return .failed(code: "error.edit.bad_request", path: "\(path).out") }
    guard let speedIn = object["speed"]?.number else { return .failed(code: "error.edit.bad_request", path: "\(path).speed") }
    guard let volumeIn = object["volume"]?.number else { return .failed(code: "error.edit.bad_request", path: "\(path).volume") }
    guard object["fit"]?.string == "fill" || object["fit"]?.string == "fit" else {
        return .failed(code: "error.edit.bad_request", path: "\(path).fit")
    }
    guard let muted = object["muted"]?.bool else { return .failed(code: "error.edit.bad_request", path: "\(path).muted") }
    let inn = object["in"]!.number!, out = object["out"]!.number!
    if inn < 0 || inn > secondsBound { return .failed(code: "error.edit.range", path: "\(path).in") }
    if out < 0 || out > secondsBound { return .failed(code: "error.edit.range", path: "\(path).out") }
    if speedIn < 0 { return .failed(code: "error.edit.range", path: "\(path).speed") }
    let cin = EditJSON.time(inn), cout = EditJSON.time(out), speed = snapSpeed(speedIn)
    if speed < 0.25 || speed > 4 { return .failed(code: "error.edit.range", path: "\(path).speed") }
    if !(cin < cout) || (cout - cin) / speed < 0.1 - 1e-9 { return .failed(code: "error.edit.range", path: "\(path).out") }
    if volumeIn < 0 || volumeIn > 1 { return .failed(code: "error.edit.range", path: "\(path).volume") }
    let pitch: Double
    switch parsePitch(object, path: path) {
    case .value(let value): pitch = value
    case .failed(let code, let failPath): return .failed(code: code, path: failPath)
    }
    var crop: EditCrop?
    if object["crop"] != nil {
        switch parseCrop(object["crop"], path: "\(path).crop") {
        case .value(let value): crop = value
        case .failed(let code, let failPath): return .failed(code: code, path: failPath)
        }
    }
    return .value(EditClip(
        id: id, item: item, in: cin, out: cout, speed: speed, crop: crop,
        fit: object["fit"]?.string == "fit" ? .fit : .fill, volume: EditJSON.level(volumeIn), muted: muted, pitch: pitch))
}

private func parseOverlay(_ value: ParseValue, path: String, seen: inout Set<String>) -> Step<EditOverlay> {
    guard let object = value.object else { return .failed(code: "error.edit.bad_request", path: path) }
    if let failure = keysOK(
        object, required: ["id", "item", "at", "in", "out", "frame", "opacity", "volume", "muted"],
        optional: ["pitch", "track", "hidden", "key", "background"], prefix: path
    ) { return .failed(code: failure.code, path: failure.path) }
    guard let id = takeID(object, path: path, seen: &seen) else {
        return .failed(code: "error.edit.bad_request", path: "\(path).id")
    }
    guard let item = object["item"]?.string, matches(itemPattern, item) else {
        return .failed(code: "error.edit.bad_request", path: "\(path).item")
    }
    guard let at = object["at"]?.number else { return .failed(code: "error.edit.bad_request", path: "\(path).at") }
    guard let inn = object["in"]?.number else { return .failed(code: "error.edit.bad_request", path: "\(path).in") }
    guard let out = object["out"]?.number else { return .failed(code: "error.edit.bad_request", path: "\(path).out") }
    guard let opacity = object["opacity"]?.number else { return .failed(code: "error.edit.bad_request", path: "\(path).opacity") }
    guard let volume = object["volume"]?.number else { return .failed(code: "error.edit.bad_request", path: "\(path).volume") }
    guard let muted = object["muted"]?.bool else { return .failed(code: "error.edit.bad_request", path: "\(path).muted") }
    if at < 0 || at > secondsBound { return .failed(code: "error.edit.range", path: "\(path).at") }
    if inn < 0 || inn > secondsBound { return .failed(code: "error.edit.range", path: "\(path).in") }
    if out < 0 || out > secondsBound { return .failed(code: "error.edit.range", path: "\(path).out") }
    let cin = EditJSON.time(inn), cout = EditJSON.time(out)
    if !(cin < cout) || cout - cin < 0.1 - 1e-9 { return .failed(code: "error.edit.range", path: "\(path).out") }
    let frame: EditFrame
    switch parseFrame(object["frame"], path: "\(path).frame") {
    case .value(let value): frame = value
    case .failed(let code, let failPath): return .failed(code: code, path: failPath)
    }
    if opacity < 0.1 - 1e-9 || opacity > 1 { return .failed(code: "error.edit.range", path: "\(path).opacity") }
    if volume < 0 || volume > 1 { return .failed(code: "error.edit.range", path: "\(path).volume") }
    let pitch: Double
    switch parsePitch(object, path: path) {
    case .value(let value): pitch = value
    case .failed(let code, let failPath): return .failed(code: code, path: failPath)
    }
    let key: EditChromaKey?
    switch parseKey(object["key"], path: "\(path).key") {
    case .value(let value): key = value
    case .failed(let code, let failPath): return .failed(code: code, path: failPath)
    }
    let background: EditOverlayBackground?
    switch parseBackground(object["background"], path: "\(path).background") {
    case .value(let value): background = value
    case .failed(let code, let failPath): return .failed(code: code, path: failPath)
    }
    var track = 0
    if object["track"] != nil {
        guard let raw = object["track"]?.int else { return .failed(code: "error.edit.bad_request", path: "\(path).track") }
        track = raw
        if track < 0 || track >= EditLanes.laneLimit { return .failed(code: "error.edit.range", path: "\(path).track") }
    }
    if object["hidden"] != nil, object["hidden"]?.bool == nil {
        return .failed(code: "error.edit.bad_request", path: "\(path).hidden")
    }
    return .value(EditOverlay(
        id: id, item: item, at: EditJSON.time(at), in: cin, out: cout, frame: frame, opacity: EditJSON.level(opacity),
        volume: EditJSON.level(volume), muted: muted, pitch: pitch, track: track, hidden: object["hidden"]?.bool == true,
        key: key, background: background))
}

private func parseLane(_ value: ParseValue, path: String, seen: inout Set<String>) -> Step<EditLaneClip> {
    guard let object = value.object else { return .failed(code: "error.edit.bad_request", path: path) }
    if let failure = keysOK(
        object, required: ["id", "item", "lane", "at", "in", "out"],
        optional: ["speed", "crop", "fit", "frame", "opacity", "volume", "muted", "pitch", "key", "background", "hidden"],
        prefix: path
    ) { return .failed(code: failure.code, path: failure.path) }
    guard let id = takeID(object, path: path, seen: &seen) else {
        return .failed(code: "error.edit.bad_request", path: "\(path).id")
    }
    guard let item = object["item"]?.string, matches(itemPattern, item) else {
        return .failed(code: "error.edit.bad_request", path: "\(path).item")
    }
    guard let lane = object["lane"]?.int else { return .failed(code: "error.edit.bad_request", path: "\(path).lane") }
    if lane < 0 || lane >= EditLanes.laneLimit { return .failed(code: "error.edit.range", path: "\(path).lane") }
    guard let at = object["at"]?.number else { return .failed(code: "error.edit.bad_request", path: "\(path).at") }
    guard let inn = object["in"]?.number else { return .failed(code: "error.edit.bad_request", path: "\(path).in") }
    guard let out = object["out"]?.number else { return .failed(code: "error.edit.bad_request", path: "\(path).out") }
    if at < 0 || at > secondsBound { return .failed(code: "error.edit.range", path: "\(path).at") }
    if inn < 0 || inn > secondsBound { return .failed(code: "error.edit.range", path: "\(path).in") }
    if out < 0 || out > secondsBound { return .failed(code: "error.edit.range", path: "\(path).out") }
    let cin = EditJSON.time(inn), cout = EditJSON.time(out)
    if !(cin < cout) { return .failed(code: "error.edit.range", path: "\(path).out") }
    var speed = 1.0
    if object["speed"] != nil {
        guard let raw = object["speed"]?.number else { return .failed(code: "error.edit.bad_request", path: "\(path).speed") }
        if raw < 0 { return .failed(code: "error.edit.range", path: "\(path).speed") }
        speed = snapSpeed(raw)
        if speed < 0.25 || speed > 4 { return .failed(code: "error.edit.range", path: "\(path).speed") }
    }
    if (cout - cin) / speed < 0.1 - 1e-9 { return .failed(code: "error.edit.range", path: "\(path).out") }
    var fit = EditFit.fill
    if object["fit"] != nil {
        guard object["fit"]?.string == "fill" || object["fit"]?.string == "fit" else {
            return .failed(code: "error.edit.bad_request", path: "\(path).fit")
        }
        if object["fit"]?.string == "fit" { fit = .fit }
    }
    var crop: EditCrop?
    if object["crop"] != nil {
        switch parseCrop(object["crop"], path: "\(path).crop") {
        case .value(let value): crop = value
        case .failed(let code, let failPath): return .failed(code: code, path: failPath)
        }
    }
    var frame: EditFrame?
    if object["frame"] != nil {
        switch parseLaneFrame(object["frame"], path: "\(path).frame") {
        case .value(let value): frame = value
        case .failed(let code, let failPath): return .failed(code: code, path: failPath)
        }
    }
    var opacity = 1.0
    if object["opacity"] != nil {
        guard let raw = object["opacity"]?.number else { return .failed(code: "error.edit.bad_request", path: "\(path).opacity") }
        if raw < 0.1 - 1e-9 || raw > 1 { return .failed(code: "error.edit.range", path: "\(path).opacity") }
        opacity = EditJSON.level(raw)
    }
    var volume = 1.0
    if object["volume"] != nil {
        guard let raw = object["volume"]?.number else { return .failed(code: "error.edit.bad_request", path: "\(path).volume") }
        if raw < 0 || raw > 1 { return .failed(code: "error.edit.range", path: "\(path).volume") }
        volume = EditJSON.level(raw)
    }
    if object["muted"] != nil, object["muted"]?.bool == nil {
        return .failed(code: "error.edit.bad_request", path: "\(path).muted")
    }
    let pitch: Double
    switch parsePitch(object, path: path) {
    case .value(let value): pitch = value
    case .failed(let code, let failPath): return .failed(code: code, path: failPath)
    }
    let key: EditChromaKey?
    switch parseKey(object["key"], path: "\(path).key") {
    case .value(let value): key = value
    case .failed(let code, let failPath): return .failed(code: code, path: failPath)
    }
    let background: EditOverlayBackground?
    switch parseBackground(object["background"], path: "\(path).background") {
    case .value(let value): background = value
    case .failed(let code, let failPath): return .failed(code: code, path: failPath)
    }
    if object["hidden"] != nil, object["hidden"]?.bool == nil {
        return .failed(code: "error.edit.bad_request", path: "\(path).hidden")
    }
    return .value(EditLaneClip(
        id: id, item: item, lane: lane, at: EditJSON.time(at), in: cin, out: cout, speed: speed, crop: crop, fit: fit,
        frame: frame, opacity: opacity, volume: volume, muted: object["muted"]?.bool == true, pitch: pitch,
        hidden: object["hidden"]?.bool == true, key: key, background: background))
}

func checkTimingV1(_ timeline: EditTimeline) -> EditParseResult? {
    let timing = EditTiming(timeline)
    if timing.frames > Int(EditLanes.maxSeconds) * timing.fps {
        return .failed(code: "error.edit.too_long", path: "main")
    }
    var maxEnd = Array(repeating: 0, count: EditLanes.laneLimit)
    for (index, overlay) in timeline.storedOverlay.enumerated() {
        guard index < timing.overlay.count else { continue }
        let row = timing.overlay[index]
        let track = overlay.track
        if index > 0 && overlay.at < timeline.storedOverlay[index - 1].at {
            return .failed(code: "error.edit.overlay_overlap", path: "overlay[\(index)]")
        }
        if row.start < maxEnd[track] { return .failed(code: "error.edit.overlay_overlap", path: "overlay[\(index)]") }
        if row.start + row.frames > timing.frames {
            return .failed(code: "error.edit.overlay_past_end", path: "overlay[\(index)]")
        }
        maxEnd[track] = max(maxEnd[track], row.start + row.frames)
    }
    return nil
}

func checkTimingV2(_ timeline: EditTimeline) -> EditParseResult? {
    let fps = max(1, timeline.canvas.fps)
    var end = 0
    var lanes: [Int: [(index: Int, start: Int, end: Int)]] = [:]
    for (index, clip) in timeline.clips.enumerated() {
        let start = EditLanes.startFrame(clip.at, fps: fps)
        let frames = EditLanes.outputFrames(clip, fps: fps)
        end = max(end, start + frames)
        lanes[clip.lane, default: []].append((index, start, start + frames))
    }
    if end > Int(EditLanes.maxSeconds) * fps { return .failed(code: "error.edit.too_long", path: "clips") }
    for list in lanes.values {
        let sorted = list.sorted { lhs, rhs in
            lhs.start != rhs.start ? lhs.start < rhs.start : lhs.index < rhs.index
        }
        for index in sorted.indices.dropFirst() where sorted[index].start < sorted[index - 1].end {
            return .failed(code: "error.edit.overlay_overlap", path: "clips[\(sorted[index].index)]")
        }
    }
    return nil
}

private extension EditParseResult {
    var code: String { if case .failed(let code, _) = self { return code }; return "" }
    var path: String { if case .failed(_, let path) = self { return path }; return "" }
}
