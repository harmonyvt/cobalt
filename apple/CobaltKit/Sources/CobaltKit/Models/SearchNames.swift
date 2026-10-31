import Foundation

// Search names (APP-API-CONTRACT 48; `features.names`). A name is a word the owner teaches search: `Lia` (also called
// `lia-chan`) means "pink-haired cat girl with cat ears", with optional example posts ("this is Lia") and not posts ("this
// isn't"). A search that says a name looks for what it means. These are the wire shapes and the plain values the screens
// read; the routes are on `CobaltClient`, the state on `SearchNamesModel` (the list) and `SearchNameEditor` (one name).

/// A post's mark on a name (`search_name_posts.kind`, 48.1): an example of it, or not it.
public enum NameMark: String, Sendable, Equatable, CaseIterable {
    case yes, no
}

/// One name (`Name` in 48.4). Named `TaughtName` and not `SearchName` because the generated `Endpoints.swift` already
/// declares an internal `struct SearchName` (its wire row) in this module.
public struct TaughtName: Sendable, Equatable, Identifiable {
    public var id: String
    /// As typed (1...40 characters after trimming).
    public var name: String
    /// Other words for it, normalized by the server (lower case, trimmed, one space), at most 8.
    public var aliases: [String]
    /// What it means (1...300 characters).
    public var meaning: String
    /// 0...1: how much the examples count against the words (the "listen to" slider).
    public var strength: Double
    /// 0...1: the cosine a post needs to carry the name (the "cut-off" slider).
    public var cutoff: Double
    public var enabled: Bool
    /// Example post keys, newest mark first.
    public var yes: [String]
    /// Not-it post keys, newest mark first.
    public var no: [String]
    /// Posts that carry it now.
    public var posts: Int
    /// The meaning has a vector for the current model and meaning (false: the Space could not answer yet).
    public var embedded: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String, name: String, aliases: [String] = [], meaning: String, strength: Double = TaughtName.defaultStrength,
        cutoff: Double = TaughtName.defaultCutoff, enabled: Bool = true, yes: [String] = [], no: [String] = [], posts: Int = 0,
        embedded: Bool = true, createdAt: Date = Date(timeIntervalSince1970: 0), updatedAt: Date = Date(timeIntervalSince1970: 0)
    ) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.meaning = meaning
        self.strength = strength
        self.cutoff = cutoff
        self.enabled = enabled
        self.yes = yes
        self.no = no
        self.posts = posts
        self.embedded = embedded
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // The limits of 48.1.
    public static let defaultStrength = 0.5
    public static let defaultCutoff = 0.5
    public static let maxNameLength = 40
    public static let maxMeaningLength = 300
    public static let maxAliases = 8
    public static let maxNames = 100
    public static let maxMarks = 200
    /// `mark` entries in one `PATCH` (48.4).
    public static let maxMarkChanges = 50

    /// The post's mark on this name, if any.
    public func mark(of postKey: String) -> NameMark? {
        if yes.contains(postKey) { return .yes }
        if no.contains(postKey) { return .no }
        return nil
    }

    /// A word as the server keys it (48.1): lower case, trimmed, inner whitespace one space.
    public static func normalize(_ word: String) -> String {
        word.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
}

/// A name being written: the editor's values, and the body of a create (48.4). Starts from a saved name or from nothing.
public struct SearchNameDraft: Sendable, Equatable {
    public var name: String
    public var aliases: [String]
    public var meaning: String
    public var strength: Double
    public var cutoff: Double
    public var enabled: Bool
    /// Newest mark first, as the server lists them.
    public var yes: [String]
    public var no: [String]

    public init(
        name: String = "", aliases: [String] = [], meaning: String = "", strength: Double = TaughtName.defaultStrength,
        cutoff: Double = TaughtName.defaultCutoff, enabled: Bool = true, yes: [String] = [], no: [String] = []
    ) {
        self.name = name
        self.aliases = aliases
        self.meaning = meaning
        self.strength = strength
        self.cutoff = cutoff
        self.enabled = enabled
        self.yes = yes
        self.no = no
    }

    public init(_ saved: TaughtName) {
        self.init(
            name: saved.name, aliases: saved.aliases, meaning: saved.meaning, strength: saved.strength, cutoff: saved.cutoff,
            enabled: saved.enabled, yes: saved.yes, no: saved.no)
    }

    public var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var trimmedMeaning: String { meaning.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// What 48.1 takes: a name of 1...40 characters and a meaning of 1...300 once trimmed.
    public var isValid: Bool {
        (1...TaughtName.maxNameLength).contains(trimmedName.count)
            && (1...TaughtName.maxMeaningLength).contains(trimmedMeaning.count)
    }

    public func mark(of postKey: String) -> NameMark? {
        if yes.contains(postKey) { return .yes }
        if no.contains(postKey) { return .no }
        return nil
    }

    /// Gives the post `mark` (nil takes it off); a new mark goes first, like the server's newest-first lists.
    public mutating func set(_ mark: NameMark?, for postKey: String) {
        yes.removeAll { $0 == postKey }
        no.removeAll { $0 == postKey }
        switch mark {
        case .yes?: yes.insert(postKey, at: 0)
        case .no?: no.insert(postKey, at: 0)
        case nil: break
        }
    }

    /// A tap in "who's in": no mark → example → not → no mark (48.6).
    public mutating func cycle(_ postKey: String) {
        switch mark(of: postKey) {
        case nil: set(.yes, for: postKey)
        case .yes?: set(.no, for: postKey)
        case .no?: set(nil, for: postKey)
        }
    }

    /// Adds an "also called" word, normalized; one that is empty, the name itself, already there or past 8 is dropped.
    /// True when it was added.
    @discardableResult
    public mutating func addAlias(_ word: String) -> Bool {
        let w = TaughtName.normalize(word)
        guard (1...TaughtName.maxNameLength).contains(w.count), w != TaughtName.normalize(name), !aliases.contains(w),
              aliases.count < TaughtName.maxAliases else { return false }
        aliases.append(w)
        return true
    }

    public mutating func removeAlias(_ word: String) {
        aliases.removeAll { $0 == word }
    }

    /// The JSON of `POST /library/names` (and of a full `PATCH`): every field, the lists replacing the marks.
    var body: [String: Any] {
        [
            "name": trimmedName, "meaning": trimmedMeaning, "aliases": aliases, "strength": strength, "cutoff": cutoff,
            "enabled": enabled, "yes": yes, "no": no,
        ]
    }
}

/// One `mark` entry of `PATCH /library/names/:id` (48.4): `kind` nil takes the post's mark off.
public struct NameMarkChange: Sendable, Equatable {
    public var postKey: String
    public var kind: NameMark?

    public init(postKey: String, kind: NameMark?) {
        self.postKey = postKey
        self.kind = kind
    }
}

/// `PATCH /library/names/:id`: only the fields that are set go (the lists replace the marks), then `mark`.
public struct SearchNamePatch: Sendable, Equatable {
    public var name: String?
    public var meaning: String?
    public var aliases: [String]?
    public var strength: Double?
    public var cutoff: Double?
    public var enabled: Bool?
    public var yes: [String]?
    public var no: [String]?
    public var mark: [NameMarkChange]

    public init(
        name: String? = nil, meaning: String? = nil, aliases: [String]? = nil, strength: Double? = nil, cutoff: Double? = nil,
        enabled: Bool? = nil, yes: [String]? = nil, no: [String]? = nil, mark: [NameMarkChange] = []
    ) {
        self.name = name
        self.meaning = meaning
        self.aliases = aliases
        self.strength = strength
        self.cutoff = cutoff
        self.enabled = enabled
        self.yes = yes
        self.no = no
        self.mark = mark
    }

    /// Every field of a draft (what the editor's save sends).
    public init(_ draft: SearchNameDraft) {
        self.init(
            name: draft.trimmedName, meaning: draft.trimmedMeaning, aliases: draft.aliases, strength: draft.strength,
            cutoff: draft.cutoff, enabled: draft.enabled, yes: draft.yes, no: draft.no)
    }

    var body: [String: Any] {
        var b: [String: Any] = [:]
        if let name { b["name"] = name }
        if let meaning { b["meaning"] = meaning }
        if let aliases { b["aliases"] = aliases }
        if let strength { b["strength"] = strength }
        if let cutoff { b["cutoff"] = cutoff }
        if let enabled { b["enabled"] = enabled }
        if let yes { b["yes"] = yes }
        if let no { b["no"] = no }
        if !mark.isEmpty {
            b["mark"] = mark.prefix(TaughtName.maxMarkChanges).map { change -> [String: Any] in
                ["post_key": change.postKey, "kind": change.kind.map { $0.rawValue as Any } ?? NSNull()]
            }
        }
        return b
    }
}

/// `POST /library/names/preview` (48.4): a name as it would be with these values, saving nothing. Missing fields come from
/// the saved name `id`, else the defaults; `meaning` is required without `id`.
public struct SearchNamePreviewRequest: Sendable, Equatable {
    public var id: String?
    public var name: String?
    public var meaning: String?
    public var strength: Double?
    public var cutoff: Double?
    public var yes: [String]?
    public var no: [String]?
    /// 1...100 (the server's default 60).
    public var limit: Int?

    public init(
        id: String? = nil, name: String? = nil, meaning: String? = nil, strength: Double? = nil, cutoff: Double? = nil,
        yes: [String]? = nil, no: [String]? = nil, limit: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.meaning = meaning
        self.strength = strength
        self.cutoff = cutoff
        self.yes = yes
        self.no = no
        self.limit = limit
    }

    /// The editor's draft as it stands (with the saved name's id when there is one).
    public init(id: String?, draft: SearchNameDraft, limit: Int? = nil) {
        let meaning = draft.trimmedMeaning
        let name = draft.trimmedName
        self.init(
            id: id, name: name.isEmpty ? nil : name, meaning: meaning.isEmpty ? nil : meaning, strength: draft.strength,
            cutoff: draft.cutoff, yes: draft.yes, no: draft.no, limit: limit)
    }

    var body: [String: Any] {
        var b: [String: Any] = [:]
        if let id { b["id"] = id }
        if let name { b["name"] = name }
        if let meaning { b["meaning"] = meaning }
        if let strength { b["strength"] = strength }
        if let cutoff { b["cutoff"] = cutoff }
        if let yes { b["yes"] = yes }
        if let no { b["no"] = no }
        if let limit { b["limit"] = max(1, min(100, limit)) }
        return b
    }
}

/// What `POST /library/names/preview` answers: who would carry the name with these values.
public struct SearchNamePreview: Sendable, Equatable {
    public struct Entry: Sendable, Equatable, Identifiable {
        public var postKey: String
        /// The cosine with the name's point (4 places); 1 for an example with no vector.
        public var score: Double
        public var mark: NameMark?
        public var carries: Bool
        /// The post in the `GET /library?v=3` shape; nil when it no longer exists.
        public var post: LibraryPost?
        public var id: String { postKey }

        public init(postKey: String, score: Double, mark: NameMark? = nil, carries: Bool, post: LibraryPost? = nil) {
            self.postKey = postKey
            self.score = score
            self.mark = mark
            self.carries = carries
            self.post = post
        }
    }

    /// The meaning has a vector (false: the Space could not answer, the point is the examples alone).
    public var embedded: Bool
    /// Posts that would carry it.
    public var carries: Int
    /// Posts with a vector.
    public var indexed: Int
    /// Marked posts first (examples, then not), then the rest by score, cut to the limit.
    public var posts: [Entry]

    public init(embedded: Bool, carries: Int, indexed: Int, posts: [Entry]) {
        self.embedded = embedded
        self.carries = carries
        self.indexed = indexed
        self.posts = posts
    }
}

/// A name a post carries or is marked for (`GET /library/names/post`, 48.4): the detail's "names" row.
public struct PostName: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// The cosine with the name's point; nil when the post has no vector.
    public var score: Double?
    public var mark: NameMark?
    public var carries: Bool

    public init(id: String, name: String, score: Double? = nil, mark: NameMark? = nil, carries: Bool) {
        self.id = id
        self.name = name
        self.score = score
        self.mark = mark
        self.carries = carries
    }
}

/// A name a search said and used (`names` of `GET /library/search`, 48.3).
public struct SearchNameRef: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// `409 error.names.taken` (48.4): `word` is the word another name already has.
public struct SearchNameTaken: Error, Sendable, Equatable {
    public var word: String?

    public init(word: String?) {
        self.word = word
    }
}

// MARK: - the wire

/// The JSON of the names routes, decoded with `CobaltJSON.decoder()` (snake case, millisecond dates). Lenient: only the id
/// and the words are required; an odd field reads as its default, an odd row is dropped, never the list.
enum NamesWire {
    struct Name: Decodable {
        var value: TaughtName

        private enum Keys: String, CodingKey {
            case id, name, aliases, meaning, strength, cutoff, enabled, yes, no, posts, embedded, createdAt, updatedAt
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            func opt<T: Decodable>(_ type: T.Type, _ key: Keys) -> T? {
                (try? c.decodeIfPresent(type, forKey: key)) ?? nil
            }
            value = TaughtName(
                id: try c.decode(String.self, forKey: .id),
                name: try c.decode(String.self, forKey: .name),
                aliases: opt([String].self, .aliases) ?? [],
                meaning: opt(String.self, .meaning) ?? "",
                strength: opt(Double.self, .strength) ?? TaughtName.defaultStrength,
                cutoff: opt(Double.self, .cutoff) ?? TaughtName.defaultCutoff,
                enabled: opt(Bool.self, .enabled) ?? true,
                yes: opt([String].self, .yes) ?? [],
                no: opt([String].self, .no) ?? [],
                posts: opt(Int.self, .posts) ?? 0,
                embedded: opt(Bool.self, .embedded) ?? false,
                createdAt: opt(Date.self, .createdAt) ?? Date(timeIntervalSince1970: 0),
                updatedAt: opt(Date.self, .updatedAt) ?? Date(timeIntervalSince1970: 0))
        }
    }

    struct List: Decodable {
        var names: [Lossy<Name>]?
        var value: [TaughtName] { (names ?? []).compactMap { $0.value?.value } }
    }

    struct Saved: Decodable {
        var name: Name
    }

    struct Preview: Decodable {
        struct Entry: Decodable {
            var value: SearchNamePreview.Entry

            private enum Keys: String, CodingKey { case postKey, score, mark, carries, post }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: Keys.self)
                let mark = ((try? c.decodeIfPresent(String.self, forKey: .mark)) ?? nil).flatMap(NameMark.init(rawValue:))
                value = SearchNamePreview.Entry(
                    postKey: try c.decode(String.self, forKey: .postKey),
                    score: ((try? c.decodeIfPresent(Double.self, forKey: .score)) ?? nil) ?? 0,
                    mark: mark,
                    carries: ((try? c.decodeIfPresent(Bool.self, forKey: .carries)) ?? nil) ?? (mark == .yes),
                    post: (try? c.decodeIfPresent(LibraryPost.self, forKey: .post)) ?? nil)
            }
        }

        var embedded: Bool?
        var carries: Int?
        var indexed: Int?
        var posts: [Lossy<Entry>]?

        var value: SearchNamePreview {
            let entries = (posts ?? []).compactMap { $0.value?.value }
            return SearchNamePreview(
                embedded: embedded ?? false, carries: carries ?? entries.filter(\.carries).count, indexed: indexed ?? 0,
                posts: entries)
        }
    }

    struct ForPost: Decodable {
        struct Entry: Decodable {
            var id: String
            var name: String
            var score: Double?
            var mark: String?
            var carries: Bool?

            var value: PostName {
                let m = mark.flatMap(NameMark.init(rawValue:))
                return PostName(id: id, name: name, score: score, mark: m, carries: carries ?? (m == .yes))
            }
        }

        var names: [Lossy<Entry>]?
        var value: [PostName] { (names ?? []).compactMap { $0.value?.value } }
    }

    struct Ref: Decodable {
        var id: String
        var name: String
    }

    /// The body of a refusal: `error.code`, and the clashing `word` of `error.names.taken` (top level or in `error`).
    struct Refusal: Decodable {
        struct Inner: Decodable { var code: String?; var word: String? }
        var error: Inner?
        var word: String?
    }
}
