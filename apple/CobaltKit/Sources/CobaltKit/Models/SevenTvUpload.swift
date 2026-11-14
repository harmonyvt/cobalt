import Foundation

// Uploading a library picture as a new 7TV emote (APP-API-CONTRACT 57.9): `POST /7tv/emotes` and `GET /7tv/emotes/:id`.
// Names here stay clear of the generated `SevenTvUpload`, `SevenTvUploadAdded` and `SevenTvUploadAddError`.

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

    public init(
        fileID: String, name: String, tags: [String] = [], zeroWidth: Bool = false, isPrivate: Bool = false,
        setID: String? = nil, alias: String? = nil
    ) {
        self.fileID = fileID
        self.name = name
        self.tags = tags
        self.zeroWidth = zeroWidth
        self.isPrivate = isPrivate
        self.setID = setID
        self.alias = alias
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

    public init(
        emoteID: String, name: String, fileID: String, pageURL: URL? = nil, pending: Bool = true,
        added: SevenTvUploadPlacement? = nil, addError: SevenTvError? = nil
    ) {
        self.emoteID = emoteID
        self.name = name
        self.fileID = fileID
        self.pageURL = pageURL ?? SevenTvEmoteRule.pageURL(emoteID)
        self.pending = pending
        self.added = added
        self.addError = addError
    }

    private struct AddErrorWire: Decodable {
        var code: String
        var message: String?
    }

    enum CodingKeys: String, CodingKey {
        case name, pending, added, addError
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

/// 7TV's rules for a new emote (57.9), checked before asking: the name
/// `^[a-zA-Z0-9_\-():!+|.'?><\p{Emoji_Presentation}*$#]{1,100}$`, tags `^\w{3,30}$` (at most 6), the file's type and size.
public enum SevenTvEmoteRule {
    public static let nameMax = 100
    public static let tagMax = 6
    /// 7TV's 7 MiB body cap less 64 KiB for the multipart wrapping.
    public static let maxBytes: Int64 = 7 * 1024 * 1024 - 64 * 1024
    /// The types 7TV takes.
    public static let contentTypes: Set<String> = ["image/webp", "image/gif", "image/png", "image/avif", "image/jpeg"]
    static let extensions: Set<String> = ["webp", "gif", "png", "avif", "jpg", "jpeg"]
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

    /// An emote's page on 7tv.app.
    public static func pageURL(_ emoteID: String) -> URL {
        URL(string: "https://7tv.app/emotes/\(SevenTvRoute.segment(emoteID))")!
    }
}
