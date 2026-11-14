import Foundation

// The 7tv tab (APP-API-CONTRACT 57.7, mockup `7tv-tab/`): what capystore uploaded (`GET /7tv/uploads`), and the name clash an
// add or a copy can hit (`409 error.seventv.name_taken`, or the app's own check against the loaded set first) with the three
// ways out: another name for the new one, another name for the one already there, or replacing it (`override_conflicts`).

// MARK: - your uploads

/// One emote capystore uploaded (57.9), from `GET /7tv/uploads`: which library file it came from, and the set it went into
/// when the upload added it to one. Whether 7TV is still processing it is `GET /7tv/emotes/<id>`'s `pending`.
public struct SevenTvUploadedEmote: Sendable, Equatable, Identifiable, Decodable {
    public var id: String { emoteID }
    /// The library file id it was uploaded from (the "on 7tv" mark of the upload grid matches it).
    public var fileID: String
    public var emoteID: String
    public var name: String
    public var createdAt: Date?
    /// The set the upload put it in; nil when it went in none.
    public var setID: String?

    public init(fileID: String, emoteID: String, name: String, createdAt: Date? = nil, setID: String? = nil) {
        self.fileID = fileID
        self.emoteID = emoteID
        self.name = name
        self.createdAt = createdAt
        self.setID = setID
    }

    /// The emote's page on 7tv.app.
    public var pageURL: URL { SevenTvEmoteRule.pageURL(emoteID) }

    enum CodingKeys: String, CodingKey {
        case name, createdAt
        case fileID = "fileId"
        case emoteID = "emoteId"
        case setID = "setId"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        emoteID = try c.decode(String.self, forKey: .emoteID)
        fileID = (try? c.decodeIfPresent(String.self, forKey: .fileID)) ?? ""
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
        setID = SevenTvWire.nonEmpty(try? c.decodeIfPresent(String.self, forKey: .setID))
    }
}

/// `GET /7tv/uploads`: `{uploads: [...]}`, newest first, at most 100. A row without an emote id is dropped, not the answer.
struct SevenTvUploadList: Decodable {
    var uploads: [SevenTvUploadedEmote]

    enum CodingKeys: String, CodingKey { case uploads }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rows = (try? c.decodeIfPresent([Lossy<SevenTvUploadedEmote>].self, forKey: .uploads)) ?? []
        uploads = SevenTvUploadList.ordered(rows.compactMap(\.value))
    }

    /// Newest first (rows without a time keep their place after the dated ones), at most 100.
    static func ordered(_ rows: [SevenTvUploadedEmote]) -> [SevenTvUploadedEmote] {
        let sorted = rows.enumerated().sorted { a, b in
            switch (a.element.createdAt, b.element.createdAt) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.offset < b.offset
            }
        }
        return Array(sorted.map(\.element).prefix(100))
    }
}

/// Where an upload stands, for "your uploads".
public enum SevenTvUploadState: Sendable, Equatable {
    /// Not read yet.
    case unknown
    /// 7TV is still making its sizes.
    case processing
    case ready
    /// 7TV no longer has it.
    case gone
}

// MARK: - name clashes

/// An add (or a copy) into a set that already has an emote under the name (57.4 `error.seventv.name_taken`), as the clash
/// sheet shows it: the emote there now (when known), the one being added, and a free name for each way out.
public struct SevenTvNameClash: Sendable, Equatable, Identifiable {
    /// The set the emote was going into.
    public let setID: String
    public let setName: String
    /// The name that is taken.
    public let alias: String
    /// The emote being added (its own 7TV name in `name`).
    public let incoming: EmoteHit
    /// The emote holding the name, when the loaded set has it.
    public let existing: SevenTvSetItem?
    /// Its 7TV id: the loaded set's, else the server's `conflict`. Nil: "rename the one in the set" is not offered.
    public let existingEmoteID: String?
    /// A free name for the new one (`catJam` → `catJam2`).
    public let suggestion: String
    /// A free name for the one already there (`catJamOld`).
    public let renameSuggestion: String

    public init(
        setID: String, setName: String, alias: String, incoming: EmoteHit, existing: SevenTvSetItem?, existingEmoteID: String?,
        suggestion: String, renameSuggestion: String
    ) {
        self.setID = setID
        self.setName = setName
        self.alias = alias
        self.incoming = incoming
        self.existing = existing
        self.existingEmoteID = existingEmoteID ?? existing?.emoteID
        self.suggestion = suggestion
        self.renameSuggestion = renameSuggestion
    }

    public var id: String { setID + "/" + alias + "/" + incoming.id }

    /// The one in the set can be renamed: its id is known.
    public var canRenameExisting: Bool { existingEmoteID != nil }

    /// The clash for adding `incoming` as `alias` into a set whose names (as far as loaded) are `taken`.
    static func make(
        setID: String, setName: String, alias: String, incoming: EmoteHit, existing: SevenTvSetItem?, conflictEmoteID: String?,
        taken: Set<String>
    ) -> SevenTvNameClash {
        var names = taken
        names.insert(alias)
        let old = String((alias + "Old").prefix(SevenTvRule.nameMax))
        return SevenTvNameClash(
            setID: setID, setName: setName, alias: alias, incoming: incoming, existing: existing,
            existingEmoteID: existing?.emoteID ?? conflictEmoteID,
            suggestion: SevenTvRule.suggestAlias(for: alias, taken: names),
            renameSuggestion: SevenTvRule.freeAlias(old, taken: names))
    }
}

/// The way out of a name clash the owner picked.
public enum SevenTvClashChoice: Sendable, Equatable {
    /// Add the new one under another name.
    case addAs(String)
    /// Rename the one already in the set, then add the new one under the name.
    case renameExisting(to: String)
    /// The old one leaves the set (`override_conflicts: true`).
    case replace
}

/// What a copy or remove of several emotes came to.
public struct SevenTvBulkResult: Sendable, Equatable {
    public var done = 0
    /// Copies whose name the target set already had (none of them were sent again).
    public var clashes: [SevenTvNameClash] = []
    public var failed = 0
    /// The last refusal, for the status line.
    public var lastError: SevenTvError?

    public init(done: Int = 0, clashes: [SevenTvNameClash] = [], failed: Int = 0, lastError: SevenTvError? = nil) {
        self.done = done
        self.clashes = clashes
        self.failed = failed
        self.lastError = lastError
    }
}

extension SevenTvSetItem {
    /// The emote as a search hit (its own 7TV name), for adding it to another set; CDN pictures when the set had none.
    public var asHit: EmoteHit {
        EmoteHit(
            id: emoteID, name: name, animated: animated,
            previewURL: previewURL ?? SevenTvEmoteRule.cdnURL(emoteID, size: "2x"),
            fileURL: fileURL ?? SevenTvEmoteRule.cdnURL(emoteID, size: "4x"))
    }
}

extension SevenTvEmoteRule {
    /// An emote's webp on 7TV's CDN (`2x` for a grid, `4x` for the largest).
    public static func cdnURL(_ emoteID: String, size: String) -> URL {
        URL(string: "https://cdn.7tv.app/emote/\(SevenTvRoute.segment(emoteID))/\(size).webp")!
    }
}
