import Foundation

// The emote editor's wire models and rules (APP-API-CONTRACT 71): `POST /7tv/emotes/make` makes a draft from a library file,
// `GET`/`DELETE /7tv/drafts/<id>` read and drop it, `POST /7tv/drafts/<id>/save` keeps it as a library item, and `POST
// /7tv/emotes` takes `draft` instead of `file` (`SevenTvUploadDraft.draftID`). Names stay clear of the generated `SevenTv…`
// ones. The limits are 7TV's (57.10): 7 MiB, 1000 px, 1000 frames, width:height 1:32..3:1.

/// The made file's format (71.1): webp (animated when the source is), gif (animated, 256 colours) or png (one still frame).
public enum EmoteFormat: String, Sendable, Equatable, CaseIterable, Codable {
    case webp, gif, png

    /// The file extension of a draft in this format.
    public var fileExtension: String { rawValue }
    /// This format can move.
    public var animates: Bool { self != .png }
}

/// Squash or stretch after the crop (71.1): each way on its own, 0.25 to 4, 1 = unchanged.
public struct EmoteStretch: Sendable, Equatable {
    public static let range: ClosedRange<Double> = 0.25...4
    public static let identity = EmoteStretch(w: 1, h: 1)

    public var w: Double
    public var h: Double

    public init(w: Double, h: Double) {
        self.w = w
        self.h = h
    }

    /// Both ways inside the range (a value that is not a number counts as 1).
    public var clamped: EmoteStretch {
        func fit(_ v: Double) -> Double { v.isFinite ? min(max(v, Self.range.lowerBound), Self.range.upperBound) : 1 }
        return EmoteStretch(w: fit(w), h: fit(h))
    }

    /// Unchanged (within a thousandth), so nothing is sent.
    public var isNone: Bool { abs(w - 1) < 0.001 && abs(h - 1) < 0.001 }
}

/// What `POST /7tv/emotes/make` sends. Fields that do not apply are nil and stay out of the body.
public struct EmoteMakeRequest: Sendable, Equatable {
    /// The library file id, public id or post id.
    public var fileID: String
    /// The box to keep (fractions of the picture); nil = the whole picture.
    public var crop: ImageCropRect?
    public var stretch: EmoteStretch?
    /// The longest side of the result (32...1000); nil lets the server pick (512).
    public var size: Int?
    public var format: EmoteFormat
    /// 1...100: one encode at that quality. Nil = auto (the server's ladder until the file is under the cap).
    public var quality: Int?
    /// 5...50: frames are thinned, or a video sampled, to at most this rate.
    public var fps: Int?
    /// Seconds, video only: the moment (`end - start` 0.2 to 10).
    public var start: Double?
    public var end: Double?
    /// Frames play forward then back.
    public var bounce: Bool
    /// Seconds into the source: the still of a png.
    public var frame: Double?
    /// A draft of this key to delete first (each remake replaces the last).
    public var replace: String?

    public init(
        fileID: String, crop: ImageCropRect? = nil, stretch: EmoteStretch? = nil, size: Int? = nil, format: EmoteFormat = .webp,
        quality: Int? = nil, fps: Int? = nil, start: Double? = nil, end: Double? = nil, bounce: Bool = false, frame: Double? = nil,
        replace: String? = nil
    ) {
        self.fileID = fileID
        self.crop = crop
        self.stretch = stretch
        self.size = size
        self.format = format
        self.quality = quality
        self.fps = fps
        self.start = start
        self.end = end
        self.bounce = bounce
        self.frame = frame
        self.replace = replace
    }
}

/// The 201 of `POST /7tv/emotes/make` (71.1): the made file, which lives 24 hours on the server and is not a library item.
public struct EmoteDraft: Sendable, Equatable, Decodable, Identifiable {
    public var id: String { draftID }
    public var draftID: String
    public var format: EmoteFormat
    public var contentType: String
    public var width: Int
    public var height: Int
    public var frames: Int
    public var durationMs: Int
    public var bytes: Int64
    /// The quality the encode took (auto ends on the first rung that fit).
    public var quality: Int?
    /// A fixed quality went over the cap: the editor shows it amber and offers auto.
    public var overCap: Bool
    /// The path `/7tv/drafts/<id>` on the API host.
    public var path: String
    public var expiresAt: Date?

    public init(
        draftID: String, format: EmoteFormat = .webp, contentType: String? = nil, width: Int, height: Int, frames: Int = 1,
        durationMs: Int = 0, bytes: Int64, quality: Int? = nil, overCap: Bool = false, path: String? = nil, expiresAt: Date? = nil
    ) {
        self.draftID = draftID
        self.format = format
        self.contentType = contentType ?? "image/\(format.rawValue)"
        self.width = width
        self.height = height
        self.frames = frames
        self.durationMs = durationMs
        self.bytes = bytes
        self.quality = quality
        self.overCap = overCap
        self.path = path ?? "/7tv/drafts/\(draftID)"
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case format, width, height, frames, bytes, quality
        case draftID = "draftId"
        case contentType, durationMs, overCap
        case path = "url"
        case expiresAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        /// JSON numbers as whole numbers, whether the server wrote `512` or `512.0`.
        func whole(_ key: CodingKeys) -> Int? {
            if let n = try? c.decodeIfPresent(Int.self, forKey: key) { return n }
            if let d = try? c.decodeIfPresent(Double.self, forKey: key), d.isFinite { return Int(d.rounded()) }
            return nil
        }
        draftID = try c.decode(String.self, forKey: .draftID)
        let rawFormat = (try? c.decodeIfPresent(String.self, forKey: .format)) ?? nil
        format = rawFormat.flatMap(EmoteFormat.init(rawValue:)) ?? .webp
        contentType = ((try? c.decodeIfPresent(String.self, forKey: .contentType)) ?? nil) ?? "image/\(format.rawValue)"
        guard let width = whole(.width), let height = whole(.height) else {
            throw DecodingError.dataCorruptedError(forKey: .width, in: c, debugDescription: "a draft needs width and height")
        }
        self.width = width
        self.height = height
        frames = max(1, whole(.frames) ?? 1)
        durationMs = max(0, whole(.durationMs) ?? 0)
        bytes = Int64(whole(.bytes) ?? 0)
        quality = whole(.quality)
        overCap = ((try? c.decodeIfPresent(Bool.self, forKey: .overCap)) ?? nil) ?? false
        path = ((try? c.decodeIfPresent(String.self, forKey: .path)) ?? nil) ?? "/7tv/drafts/\(draftID)"
        expiresAt = (try? c.decodeIfPresent(Date.self, forKey: .expiresAt)) ?? nil
    }

    /// The draft plays (more than one frame, in a format that moves).
    public var isAnimated: Bool { format.animates && frames > 1 }
    /// Seconds one loop takes.
    public var seconds: Double { Double(durationMs) / 1000 }
    /// Frames per second the draft plays at (0 for a still).
    public var fps: Double { seconds > 0 && frames > 1 ? Double(frames) / seconds : 0 }
}

/// The 201 of `POST /7tv/drafts/<id>/save` (71.2): a private library item made from the draft (the draft is kept).
public struct EmoteDraftSaved: Sendable, Equatable, Decodable {
    public var itemID: String
    public var fileID: String

    public init(itemID: String, fileID: String) {
        self.itemID = itemID
        self.fileID = fileID
    }

    enum CodingKeys: String, CodingKey {
        case itemID = "itemId"
        case fileID = "fileId"
    }
}

/// The library file an emote is made from, and what the editor needs to know about it.
public struct EmoteSource: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// One picture (png, jpeg).
        case still
        /// A webp or gif (it may still be one frame: only the server knows).
        case animated
        /// A clip: the frames tab picks its moment.
        case video
    }

    /// The most a video may weigh for the make route (71.1).
    public static let maxVideoBytes: Int64 = 64 * 1024 * 1024
    static let videoTypes: Set<String> = ["video/mp4", "video/webm", "video/quicktime"]
    static let stillTypes: Set<String> = ["image/png", "image/jpeg", "image/jpg"]
    static let animatedTypes: Set<String> = ["image/webp", "image/gif"]

    public var fileID: String
    public var title: String
    public var contentType: String?
    public var fileName: String?
    public var width: Int?
    public var height: Int?
    /// Seconds (a video's length; an animated picture's loop when known).
    public var duration: Double?
    public var bytes: Int64?

    public init(
        fileID: String, title: String?, contentType: String? = nil, fileName: String? = nil, width: Int? = nil, height: Int? = nil,
        duration: Double? = nil, bytes: Int64? = nil
    ) {
        self.fileID = fileID
        self.title = title ?? ""
        self.contentType = contentType
        self.fileName = fileName
        self.width = width.flatMap { $0 > 0 ? $0 : nil }
        self.height = height.flatMap { $0 > 0 ? $0 : nil }
        self.duration = duration.flatMap { $0 > 0 ? $0 : nil }
        self.bytes = bytes
    }

    public init(file: LibraryFile, title: String?) {
        self.init(
            fileID: file.id, title: title, contentType: file.contentType, fileName: file.name, width: file.width,
            height: file.height, duration: file.duration, bytes: file.bytes)
    }

    /// The content type without parameters, lowercased; else a guess from the file name's extension.
    var normalizedType: String? {
        if let type = contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased(), !type.isEmpty {
            return type
        }
        guard let name = fileName, name.contains("."), let ext = name.split(separator: ".").last?.lowercased() else { return nil }
        switch ext {
        case "mp4", "m4v": return "video/mp4"
        case "webm": return "video/webm"
        case "mov": return "video/quicktime"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        default: return nil
        }
    }

    /// The file the make route takes: a picture (not avif or heic), a webp, a gif, or a clip up to 64 MiB.
    public var isSupported: Bool {
        guard !fileID.isEmpty, let type = normalizedType else { return false }
        if Self.videoTypes.contains(type) { return (bytes ?? 0) <= Self.maxVideoBytes }
        return Self.stillTypes.contains(type) || Self.animatedTypes.contains(type)
    }

    public static func isSupported(_ file: LibraryFile?) -> Bool {
        guard let file else { return false }
        return EmoteSource(file: file, title: nil).isSupported
    }

    public var kind: Kind {
        guard let type = normalizedType else { return .still }
        if Self.videoTypes.contains(type) { return .video }
        if Self.animatedTypes.contains(type) {
            // a webp known to be one frame (a duration of 0 in the library) is a picture
            if let duration, duration <= 0 { return .still }
            return .animated
        }
        return .still
    }

    public var isVideo: Bool { kind == .video }
    /// The frames tab (fps, bounce, a video's moment) applies.
    public var hasFrames: Bool { kind != .still }
    /// The name an emote made from this starts with (`SevenTvEmoteRule.suggestName`).
    public var suggestedName: String { SevenTvEmoteRule.suggestName(from: title.isEmpty ? fileName : title) }
}

/// The limits and numbers the editor's live ticks use (71.4), pure so they are tested without a screen.
public enum EmoteLimits {
    /// 7TV's cap shown on the meter: 7 MiB (the server's auto stops 64 KiB under it).
    public static let capBytes: Int64 = 7 * 1024 * 1024
    public static let maxSide = SevenTvEmoteRule.maxSide
    public static let maxFrames = 1000
    public static let minAspect = SevenTvEmoteRule.minAspect
    public static let maxAspect = SevenTvEmoteRule.maxAspect
    public static let sizeRange = SevenTvEmoteRule.sizeRange
    public static let sizeChoices = [128, 256, 512, 1000]
    public static let fpsRange = 5...50
    public static let fpsChoices = [10, 15, 20, 25, 30]
    public static let defaultFps = 20
    public static let defaultSize = 512
    public static let qualityRange = 1...100
    /// A video moment is 0.2 to 10 seconds long.
    public static let momentRange: ClosedRange<Double> = 0.2...10
    public static let defaultMoment = 3.0

    /// Width over height is inside 1:32..3:1.
    public static func shapeFits(width: Double, height: Double) -> Bool {
        guard width > 0, height > 0, width.isFinite, height.isFinite else { return false }
        let ratio = width / height
        return ratio >= minAspect - 1e-9 && ratio <= maxAspect + 1e-9
    }

    /// The picture's box in px after the crop and the stretch (fractions of `width` x `height`); nil without a size.
    public static func stretchedPixels(
        width: Int?, height: Int?, crop: ImageCropRect?, stretch: EmoteStretch
    ) -> (width: Double, height: Double)? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        let box = crop?.clamped ?? .whole
        let s = stretch.clamped
        return (Double(width) * box.w * s.w, Double(height) * box.h * s.h)
    }

    /// What the server makes of it: the longest side is `size` (default 512), never larger than the stretched crop; both
    /// sides at least 1.
    public static func outputPixels(stretched: (width: Double, height: Double), size: Int?) -> (width: Int, height: Int) {
        let longest = max(stretched.width, stretched.height)
        guard longest > 0 else { return (1, 1) }
        let target = Double(min(max(size ?? defaultSize, sizeRange.lowerBound), sizeRange.upperBound))
        let scale = min(1, target / longest)
        return (max(1, Int((stretched.width * scale).rounded())), max(1, Int((stretched.height * scale).rounded())))
    }

    /// "3:2", "1:1", "2:1": the shape as the smallest whole ratio within a few percent, else one decimal ("1.7:1").
    public static func ratioLabel(width: Double, height: Double) -> String {
        guard width > 0, height > 0 else { return "-" }
        let r = width / height
        for d in 1...8 {
            let n = (r * Double(d)).rounded()
            if n >= 1, n <= 32, abs(n / Double(d) - r) / r < 0.02 { return "\(Int(n)):\(d)" }
        }
        return r >= 1 ? String(format: "%.1f:1", r) : String(format: "1:%.1f", 1 / r)
    }

    /// Frames a video moment makes at `fps` (bounce plays forward then back, the end frames once).
    public static func estimatedFrames(seconds: Double, fps: Int, bounce: Bool) -> Int {
        let n = max(1, Int((seconds * Double(fps)).rounded(.up)))
        return bounce && n > 2 ? n * 2 - 2 : n
    }
}
