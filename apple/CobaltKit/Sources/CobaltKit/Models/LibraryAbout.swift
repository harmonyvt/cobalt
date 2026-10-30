import Foundation

// "What it's about" (APP-API-CONTRACT 34; `features.about`): `GET /library/about?key=<post key>` says how the server
// describes one post in plain words (a sentence from three frames, tags, the sound it heard), the words its vector reads
// closest to, and the posts nearest to it; `PATCH /library/about` replaces the tags the owner keeps. Every field but the
// key is optional on the wire, so an older server (no migration, no description yet) decodes too.

/// One answer of `GET /library/about` or `PATCH /library/about`.
public struct LibraryAbout: Sendable, Equatable, Decodable {
    /// Where the server's cutting of frames and sound stands for this post.
    public enum Probe: String, Sendable, Equatable {
        /// Waiting for its turn ("cutting frames…").
        case pending
        /// Frames and sound are cut.
        case done
        /// Nothing to cut (an image, no video file): described from its poster.
        case none
        /// The cut failed; retried later.
        case failed
        /// A state this app does not know yet.
        case unknown
    }

    /// The words written for the post.
    public struct About: Sendable, Equatable, Decodable {
        public var sentence: String?
        /// What Haiku wrote, or the owner's tags once `edited`.
        public var tags: [String]
        /// The tags are the owner's (`user_tags` set); false: Haiku's.
        public var edited: Bool
        public var soundTags: [String]
        /// What was said, at most 4,000 characters; nil without speech or sound.
        public var transcript: String?
        public var language: String?
        /// Frame pictures cut, 0 to 3.
        public var frames: Int
        public var hasAudio: Bool
        public var model: String?
        public var writtenAt: Date?

        public init(
            sentence: String? = nil, tags: [String] = [], edited: Bool = false, soundTags: [String] = [],
            transcript: String? = nil, language: String? = nil, frames: Int = 0, hasAudio: Bool = false,
            model: String? = nil, writtenAt: Date? = nil
        ) {
            self.sentence = sentence
            self.tags = tags
            self.edited = edited
            self.soundTags = soundTags
            self.transcript = transcript
            self.language = language
            self.frames = frames
            self.hasAudio = hasAudio
            self.model = model
            self.writtenAt = writtenAt
        }

        enum CodingKeys: String, CodingKey {
            case sentence, tags, edited, soundTags, transcript, language, frames, hasAudio, model, writtenAt
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sentence = Self.clean((try? c.decodeIfPresent(String.self, forKey: .sentence)) ?? nil)
            tags = ((try? c.decodeIfPresent([String].self, forKey: .tags)) ?? nil) ?? []
            edited = ((try? c.decodeIfPresent(Bool.self, forKey: .edited)) ?? nil) ?? false
            soundTags = ((try? c.decodeIfPresent([String].self, forKey: .soundTags)) ?? nil) ?? []
            transcript = Self.clean((try? c.decodeIfPresent(String.self, forKey: .transcript)) ?? nil)
            language = Self.clean((try? c.decodeIfPresent(String.self, forKey: .language)) ?? nil)
            frames = ((try? c.decodeIfPresent(Int.self, forKey: .frames)) ?? nil) ?? 0
            hasAudio = ((try? c.decodeIfPresent(Bool.self, forKey: .hasAudio)) ?? nil) ?? false
            model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? nil
            writtenAt = (try? c.decodeIfPresent(Date.self, forKey: .writtenAt)) ?? nil
        }

        private static func clean(_ raw: String?) -> String? {
            guard let text = raw else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// A word the post's vector reads close to, with how much closer than the word's average (rounded to 2 places).
    public struct Word: Sendable, Equatable, Identifiable, Decodable {
        public var word: String
        public var score: Double
        public var id: String { word }

        public init(word: String, score: Double) {
            self.word = word
            self.score = score
        }

        enum CodingKeys: String, CodingKey { case word, score }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            word = try c.decode(String.self, forKey: .word)
            score = ((try? c.decodeIfPresent(Double.self, forKey: .score)) ?? nil) ?? 0
        }
    }

    /// One of the nearest posts by vector.
    public struct Neighbour: Sendable, Equatable, Identifiable, Decodable {
        public var postID: String
        public var score: Double
        public var id: String { postID }

        public init(postID: String, score: Double) {
            self.postID = postID
            self.score = score
        }

        enum CodingKeys: String, CodingKey { case postID = "postId", score }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            postID = try c.decode(String.self, forKey: .postID)
            score = ((try? c.decodeIfPresent(Double.self, forKey: .score)) ?? nil) ?? 0
        }
    }

    public var postKey: String
    public var probe: Probe
    /// Nil until a description is written (or before the server's migration).
    public var about: About?
    /// Best first; empty without a vector or a word list.
    public var words: [Word]
    /// The nearest posts, best first (4); empty with search off.
    public var neighbours: [Neighbour]
    /// The neighbours' posts as `GET /library?v=3` shapes, keyed by the post's own id.
    public var posts: [String: LibraryPost]
    /// How the post sits in the search index (what `GET /library/search/post` says); nil when the server sent none.
    public var index: LibrarySearchStatus?

    public init(
        postKey: String, probe: Probe = .pending, about: About? = nil, words: [Word] = [], neighbours: [Neighbour] = [],
        posts: [String: LibraryPost] = [:], index: LibrarySearchStatus? = nil
    ) {
        self.postKey = postKey
        self.probe = probe
        self.about = about
        self.words = words
        self.neighbours = neighbours
        self.posts = posts
        self.index = index
    }

    enum CodingKeys: String, CodingKey { case postKey, probe, about, words, neighbours, posts, index }

    /// Lenient: only `post_key` is required; an odd field reads as absent, an unknown probe as `.unknown`, a word or
    /// neighbour or post that does not decode is dropped.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        postKey = try c.decode(String.self, forKey: .postKey)
        let raw = (try? c.decodeIfPresent(String.self, forKey: .probe)) ?? nil
        probe = raw.flatMap(Probe.init(rawValue:)) ?? .unknown
        about = (try? c.decodeIfPresent(About.self, forKey: .about)) ?? nil
        words = ((try? c.decodeIfPresent([Lossy<Word>].self, forKey: .words)) ?? nil)?.compactMap(\.value) ?? []
        neighbours = ((try? c.decodeIfPresent([Lossy<Neighbour>].self, forKey: .neighbours)) ?? nil)?.compactMap(\.value) ?? []
        posts = ChatThreadDetail.decodePosts(from: c)
        index = (try? c.decodeIfPresent(LibrarySearchStatus.self, forKey: .index)) ?? nil
    }

    /// The neighbours that have a post, in order (a neighbour deleted since has none and is skipped).
    public var neighbourPosts: [(post: LibraryPost, score: Double)] {
        neighbours.compactMap { n in posts[n.postID].map { (post: $0, score: n.score) } }
    }

    /// Decodes an answer body (snake case, dates in ms) the way the HTTP client does.
    static func decode(_ data: Data) throws -> LibraryAbout {
        try CobaltJSON.decoder().decode(LibraryAbout.self, from: data)
    }

    // MARK: tags

    /// The most tags the server keeps (34.6).
    public static let maxTags = 16
    /// The longest tag, in characters.
    public static let maxTagLength = 30

    /// A tag as the server keeps it: trimmed, lowercased, inner whitespace collapsed; nil when empty or too long.
    public static func cleanTag(_ raw: String) -> String? {
        let words = raw.lowercased().split(whereSeparator: { $0.isWhitespace })
        let tag = words.joined(separator: " ")
        guard !tag.isEmpty, tag.count <= maxTagLength else { return nil }
        return tag
    }

    /// `tags` cleaned, without duplicates, at most `maxTags`, in order.
    public static func cleanTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in tags {
            guard let tag = cleanTag(raw), seen.insert(tag).inserted else { continue }
            out.append(tag)
            if out.count == maxTags { break }
        }
        return out
    }
}
