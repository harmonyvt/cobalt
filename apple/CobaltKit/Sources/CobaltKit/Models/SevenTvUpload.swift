import Foundation

// Uploading a library picture as a new 7TV emote (APP-API-CONTRACT 57.9): `POST /7tv/emotes` and `GET /7tv/emotes/:id`.
// Names here stay clear of the generated `SevenTvUpload`, `SevenTvUploadAdded`, `SevenTvUploadAddError` and `SevenTvUploadFitted`.
// The fit step (57.10): an optional crop box and size; a big file is shrunk by the server (not an avif).

/// What `POST /7tv/emotes` sends. `fileID` is the library file id (or its public id).
public struct SevenTvUploadDraft: Sendable, Equatable {
    public var fileID: String
    public var name: String
    public var tags: [String]
    public var zeroWidth: Bool
    public var isPrivate: Bool
    /// Add the new emote to this set at once (`alias` = its name there; nil keeps the emote's own name).
    public var setID: String?
    public var alias: String?
    /// The box to keep (57.10), fractions of the picture from its top-left corner; nil sends the whole picture.
    public var crop: ImageCropRect?
    /// The longest side in px (32...1000); nil lets the server pick (512 when it has to fit, else the file as it is).
    public var size: Int?

    public init(
        fileID: String, name: String, tags: [String] = [], zeroWidth: Bool = false, isPrivate: Bool = false,
        setID: String? = nil, alias: String? = nil, crop: ImageCropRect? = nil, size: Int? = nil
    ) {
        self.fileID = fileID
        self.name = name
        self.tags = tags
        self.zeroWidth = zeroWidth
        self.isPrivate = isPrivate
        self.setID = setID
        self.alias = alias
        self.crop = crop
        self.size = size
    }
}

/// `fitted` of the upload's answer (57.10): what the server sent to 7TV after cropping or shrinking the picture.
public struct SevenTvFitResult: Sendable, Equatable, Decodable {
    public var width: Int
    public var height: Int
    public var frames: Int
    public var bytes: Int64
    /// The WebP quality it took (nil when the server did not say).
    public var quality: Int?

    public init(width: Int, height: Int, frames: Int = 1, bytes: Int64, quality: Int? = nil) {
        self.width = width
        self.height = height
        self.frames = frames
        self.bytes = bytes
        self.quality = quality
    }

    enum CodingKeys: String, CodingKey {
        case width, height, frames, bytes, quality
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        /// JSON numbers as whole numbers, whether the server wrote `512` or `512.0`.
        func whole(_ key: CodingKeys) -> Int? {
            if let n = try? c.decodeIfPresent(Int.self, forKey: key) { return n }
            if let d = try? c.decodeIfPresent(Double.self, forKey: key), d.isFinite { return Int(d.rounded()) }
            return nil
        }
        guard let width = whole(.width), let height = whole(.height) else {
            throw DecodingError.dataCorruptedError(forKey: .width, in: c, debugDescription: "fitted needs width and height")
        }
        self.width = width
        self.height = height
        frames = max(1, whole(.frames) ?? 1)
        bytes = Int64(whole(.bytes) ?? 0)
        quality = whole(.quality)
    }
}

/// Where the new emote went: `added` of the upload's answer.
public struct SevenTvUploadPlacement: Sendable, Equatable, Decodable {
    public var setID: String
    public var alias: String?

    public init(setID: String, alias: String? = nil) {
        self.setID = setID
        self.alias = alias
    }

    enum CodingKeys: String, CodingKey {
        case alias
        case setID = "setId"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        setID = try c.decode(String.self, forKey: .setID)
        alias = SevenTvWire.nonEmpty(try? c.decodeIfPresent(String.self, forKey: .alias))
    }
}

/// The 201 of `POST /7tv/emotes`: the emote exists on 7TV (7TV may still be processing its images, `pending`). With a
/// `set_id`, `added` says where it went, or `addError` why it did not (the upload still stands).
public struct SevenTvUploadResult: Sendable, Equatable, Decodable {
    public var emoteID: String
    public var name: String
    public var fileID: String
    public var pageURL: URL
    public var pending: Bool
    public var added: SevenTvUploadPlacement?
    public var addError: SevenTvError?
    /// What was sent when the picture was cropped or shrunk first (57.10); nil when it went as it was.
    public var fitted: SevenTvFitResult?

    public init(
        emoteID: String, name: String, fileID: String, pageURL: URL? = nil, pending: Bool = true,
        added: SevenTvUploadPlacement? = nil, addError: SevenTvError? = nil, fitted: SevenTvFitResult? = nil
    ) {
        self.emoteID = emoteID
        self.name = name
        self.fileID = fileID
        self.pageURL = pageURL ?? SevenTvEmoteRule.pageURL(emoteID)
        self.pending = pending
        self.added = added
        self.addError = addError
        self.fitted = fitted
    }

    private struct AddErrorWire: Decodable {
        var code: String
        var message: String?
    }

    enum CodingKeys: String, CodingKey {
        case name, pending, added, addError, fitted
        case emoteID = "emoteId"
        case fileID = "fileId"
        case pageURL = "pageUrl"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        emoteID = try c.decode(String.self, forKey: .emoteID)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        fileID = (try? c.decodeIfPresent(String.self, forKey: .fileID)) ?? ""
        pageURL = SevenTvWire.url(try? c.decodeIfPresent(String.self, forKey: .pageURL)) ?? SevenTvEmoteRule.pageURL(emoteID)
        pending = (try? c.decodeIfPresent(Bool.self, forKey: .pending)) ?? true
        added = try? c.decodeIfPresent(SevenTvUploadPlacement.self, forKey: .added)
        fitted = try? c.decodeIfPresent(SevenTvFitResult.self, forKey: .fitted)
        if let wire = try? c.decodeIfPresent(AddErrorWire.self, forKey: .addError) {
            addError = SevenTvError(code: wire.code, message: wire.message) ?? .rejected(SevenTvWire.nonEmpty(wire.message))
        } else {
            addError = nil
        }
    }
}

/// `GET /7tv/emotes/:id`: one emote, and whether 7TV is still processing it.
public struct SevenTvEmoteInfo: Sendable, Equatable, Identifiable, Decodable {
    public var id: String { emoteID }
    public var emoteID: String
    public var name: String
    public var ownerID: String?
    public var pending: Bool
    public var animated: Bool
    public var isPrivate: Bool
    public var zeroWidth: Bool
    public var previewURL: URL?
    public var fileURL: URL?
    public var pageURL: URL

    public init(
        emoteID: String, name: String, ownerID: String? = nil, pending: Bool = false, animated: Bool = false,
        isPrivate: Bool = false, zeroWidth: Bool = false, previewURL: URL? = nil, fileURL: URL? = nil, pageURL: URL? = nil
    ) {
        self.emoteID = emoteID
        self.name = name
        self.ownerID = ownerID
        self.pending = pending
        self.animated = animated
        self.isPrivate = isPrivate
        self.zeroWidth = zeroWidth
        self.previewURL = previewURL
        self.fileURL = fileURL
        self.pageURL = pageURL ?? SevenTvEmoteRule.pageURL(emoteID)
    }

    enum CodingKeys: String, CodingKey {
        case name, pending, animated, zeroWidth
        case emoteID = "emoteId"
        case ownerID = "ownerId"
        case isPrivate = "private"
        case previewURL = "previewUrl"
        case fileURL = "fileUrl"
        case pageURL = "pageUrl"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        emoteID = try c.decode(String.self, forKey: .emoteID)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        ownerID = SevenTvWire.nonEmpty(try? c.decodeIfPresent(String.self, forKey: .ownerID))
        pending = (try? c.decodeIfPresent(Bool.self, forKey: .pending)) ?? false
        animated = (try? c.decodeIfPresent(Bool.self, forKey: .animated)) ?? false
        isPrivate = (try? c.decodeIfPresent(Bool.self, forKey: .isPrivate)) ?? false
        zeroWidth = (try? c.decodeIfPresent(Bool.self, forKey: .zeroWidth)) ?? false
        previewURL = SevenTvWire.url(try? c.decodeIfPresent(String.self, forKey: .previewURL))
        fileURL = SevenTvWire.url(try? c.decodeIfPresent(String.self, forKey: .fileURL))
        pageURL = SevenTvWire.url(try? c.decodeIfPresent(String.self, forKey: .pageURL)) ?? SevenTvEmoteRule.pageURL(emoteID)
    }
}

/// 7TV's rules for a new emote (57.9, 57.10), checked before asking: the name
/// `^[a-zA-Z0-9_\-():!+|.'?><\p{Emoji_Presentation}*$#]{1,100}$`, tags `^\w{3,30}$` (at most 6), the file's type, size and
/// shape. A file over the byte cap or 1000 px a side is shrunk by the server unless it is an avif; a shape outside
/// width:height 1:32..3:1 needs a crop box.
public enum SevenTvEmoteRule {
    public static let nameMax = 100
    public static let tagMax = 6
    /// 7TV's 7 MiB body cap less 64 KiB for the multipart wrapping.
    public static let maxBytes: Int64 = 7 * 1024 * 1024 - 64 * 1024
    /// 7TV's largest side in px.
    public static let maxSide = 1000
    /// The `size` the fit takes (the longest side in px).
    public static let sizeRange = 32...1000
    /// The size chips of the upload sheet (nil = auto).
    public static let sizeChoices: [Int?] = [nil, 128, 256, 512, 1000]
    /// 7TV's shape limits, width over height: 1:32 to 3:1.
    public static let minAspect = 1.0 / 32
    public static let maxAspect = 3.0
    /// The types 7TV takes.
    public static let contentTypes: Set<String> = ["image/webp", "image/gif", "image/png", "image/avif", "image/jpeg"]
    static let extensions: Set<String> = ["webp", "gif", "png", "avif", "jpg", "jpeg"]
    /// The types the server's fit can crop and shrink (not avif).
    public static let fittableTypes: Set<String> = ["image/webp", "image/gif", "image/png", "image/jpeg", "image/jpg"]
    static let fittableExtensions: Set<String> = ["webp", "gif", "png", "jpg", "jpeg"]
    private static let fileExtensions = extensions.union(["mp4", "mov", "webm", "heic"])
    private static let punctuation = Set("_-():!+|.'?><*$#".unicodeScalars)

    /// One character of a name is fine: ASCII letters and digits, `_-():!+|.'?><*$#`, or an emoji shown as an emoji.
    static func isNameScalar(_ s: Unicode.Scalar) -> Bool {
        if s.isASCII {
            return (s >= "a" && s <= "z") || (s >= "A" && s <= "Z") || (s >= "0" && s <= "9") || punctuation.contains(s)
        }
        return s.properties.isEmojiPresentation
    }

    /// The name 7TV would take: 1–100 allowed characters (no spaces). Emoji count per code point, like 7TV's regex; a
    /// joined emoji (ZWJ, VS16) fails there too.
    public static func isValidName(_ raw: String) -> Bool {
        let scalars = raw.unicodeScalars
        guard (1...nameMax).contains(scalars.count) else { return false }
        return scalars.allSatisfy(isNameScalar)
    }

    /// A tag 7TV takes: 3–30 letters, digits or `_`.
    public static func isValidTag(_ raw: String) -> Bool {
        (3...30).contains(raw.count) && raw.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// Tags trimmed (a leading `#` dropped), the ones 7TV would refuse dropped, no repeats, at most 6.
    public static func cleanTags(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for tag in raw {
            var t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("#") { t.removeFirst() }
            guard isValidTag(t), seen.insert(t.lowercased()).inserted else { continue }
            out.append(t)
            if out.count == tagMax { break }
        }
        return out
    }

    /// A name from a post's title: accents folded, everything but ASCII letters and digits dropped, the words run together
    /// with each one after the first capitalized ("cat jam!" → `catJam`), at most 100 characters; `emote` when nothing is left.
    /// A file name's extension goes first.
    public static func suggestName(from title: String?) -> String {
        var title = title ?? ""
        if let dot = title.lastIndex(of: "."), fileExtensions.contains(title[title.index(after: dot)...].lowercased()) {
            title = String(title[..<dot])       // "dance.webp" names the emote dance
        }
        let folded = title.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var words: [String] = []
        var current = ""
        for scalar in folded.unicodeScalars {
            if scalar.isASCII && (scalar.properties.isAlphabetic || scalar.properties.numericType != nil) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        guard let first = words.first else { return "emote" }
        var joined = first
        for word in words.dropFirst() {
            joined += word.prefix(1).uppercased()
            joined += word.dropFirst()
        }
        return String(joined.prefix(nameMax))
    }

    /// A file 7TV takes, by its content type (parameters ignored), else by its name's extension.
    public static func isUploadable(contentType: String?, name: String?) -> Bool {
        if let type = contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased(), !type.isEmpty {
            return contentTypes.contains(type) || type == "image/jpg"
        }
        guard let ext = name?.split(separator: ".").last, name?.contains(".") == true else { return false }
        return extensions.contains(ext.lowercased())
    }

    /// The file as the detail page has it: a library file 7TV takes.
    public static func isUploadable(_ file: LibraryFile?) -> Bool {
        guard let file, !file.id.isEmpty else { return false }
        return isUploadable(contentType: file.contentType, name: file.name)
    }

    /// Over 7TV's cap (unknown sizes pass; the server checks again).
    public static func isTooBig(_ bytes: Int64?) -> Bool {
        guard let bytes else { return false }
        return bytes > maxBytes
    }

    /// A file the server can crop and shrink for 7TV (57.10): webp, gif, png or jpeg by its content type, else by its name's
    /// extension. An unknown type passes (the server checks again).
    public static func isFittable(contentType: String?, name: String?) -> Bool {
        if let type = contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased(), !type.isEmpty {
            return fittableTypes.contains(type)
        }
        guard let name, name.contains("."), let ext = name.split(separator: ".").last else { return true }
        return fittableExtensions.contains(ext.lowercased())
    }

    /// Over 1000 px a side (unknown sizes pass).
    public static func isOverSide(width: Int?, height: Int?) -> Bool {
        max(width ?? 0, height ?? 0) > maxSide
    }

    /// A shape 7TV keeps: width:height from 1:32 to 3:1 (unknown or empty sizes pass).
    public static func shapeFits(width: Double, height: Double) -> Bool {
        guard width > 0, height > 0, width.isFinite, height.isFinite else { return true }
        let ratio = width / height
        return ratio >= minAspect - 1e-9 && ratio <= maxAspect + 1e-9
    }

    /// The box the server cuts, in whole px, as its fit rounds it (`helper/emote-fit.js` `planFit`): `x`/`y` rounded, then
    /// `w`/`h` rounded and held inside the picture, at least 1 px. Nil when the picture's size is unknown.
    public static func cropPixels(width: Int?, height: Int?, crop: ImageCropRect?) -> (x: Int, y: Int, w: Int, h: Int)? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        guard let crop else { return (0, 0, width, height) }
        let box = crop.clamped
        let x = min(max(0, Int((box.x * Double(width)).rounded())), width - 1)
        let y = min(max(0, Int((box.y * Double(height)).rounded())), height - 1)
        let w = max(1, min(width - x, Int((box.w * Double(width)).rounded())))
        let h = max(1, min(height - y, Int((box.h * Double(height)).rounded())))
        return (x, y, w, h)
    }

    /// The shape of a `width` x `height` picture once `crop` (fractions) is taken out of it, in whole px as the server cuts
    /// it; nil when the size is unknown.
    public static func croppedSize(width: Int?, height: Int?, crop: ImageCropRect?) -> (width: Int, height: Int)? {
        cropPixels(width: width, height: height, crop: crop).map { ($0.w, $0.h) }
    }

    /// What 7TV gets, in px: the picture (or its box) with its longest side brought to `size`, never larger than the picture,
    /// each side rounded (`planFit`). The fit runs when a crop or a `size` is set, when the picture is over 1000 px a side or
    /// `overBytes`; its default longest side is 512. Without the fit the file goes as it is. Nil when the size is unknown.
    public static func outputSize(
        width: Int?, height: Int?, crop: ImageCropRect?, size: Int?, overBytes: Bool = false
    ) -> (width: Int, height: Int)? {
        guard let box = croppedSize(width: width, height: height, crop: crop) else { return nil }
        let fits = crop != nil || size != nil || overBytes || isOverSide(width: width, height: height)
        guard fits else { return box }
        let target = Double(clampSize(size ?? 512) ?? 512)
        let scale = min(1, target / Double(max(box.width, box.height)))
        return (max(1, Int((Double(box.width) * scale).rounded())), max(1, Int((Double(box.height) * scale).rounded())))
    }

    /// A crop box a pixel or two over 3:1 (a locked 3:1 box drawn in floats, rounded by the server one side at a time) brought
    /// back to exactly 3:1 by narrowing it, so the server's shape check passes. A box clearly wider, any smaller than 64 px
    /// high, or with the size unknown is returned as it is.
    public static func snappedToLimit(_ crop: ImageCropRect, width: Int?, height: Int?) -> ImageCropRect {
        guard let px = cropPixels(width: width, height: height, crop: crop), let width, let height, px.h >= 64 else { return crop }
        let limit = Int((Double(px.h) * maxAspect + 1e-9).rounded(.down))
        guard px.w > limit, px.w - limit <= 2 else { return crop }
        let x = Double(px.x) / Double(width)
        return ImageCropRect(
            x: x, y: Double(px.y) / Double(height), w: min(Double(limit) / Double(width), 1 - x), h: Double(px.h) / Double(height))
    }

    /// The `size` as the route takes it: 32...1000, nil left out.
    public static func clampSize(_ size: Int?) -> Int? {
        size.map { min(max($0, sizeRange.lowerBound), sizeRange.upperBound) }
    }

    /// An emote's page on 7tv.app.
    public static func pageURL(_ emoteID: String) -> URL {
        URL(string: "https://7tv.app/emotes/\(SevenTvRoute.segment(emoteID))")!
    }
}
