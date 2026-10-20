import Foundation

// Library search (APP-API-CONTRACT 21; `features.search`): `GET /library/search` ranks the library's posts by meaning
// (EmbeddingGemma on the server) and `GET /library/search/post` says how one post sits in the index. The library model
// drives the search (`LibraryModel+Search.swift`); the detail shows a post's index state.

// MARK: - GET /library/search

/// One answer of `GET /library/search`: the posts, best first, each with its `score`, and the index's size.
public struct LibrarySearchResult: Sendable, Equatable {
    public struct Hit: Sendable, Equatable, Identifiable {
        public var post: LibraryPost
        /// The cosine, plus 0.3 when the query is found as plain text in the post's title or text. No cut-off: the
        /// order is what counts. 0 when the server sent none.
        public var score: Double
        public var id: String { post.id }

        public init(post: LibraryPost, score: Double) {
            self.post = post
            self.score = score
        }
    }

    /// The query as the server read it (the one sent, when it echoes none).
    public var query: String
    /// `model`, e.g. `google/embeddinggemma-2`; nil when absent.
    public var model: String?
    /// Best first, as the server ordered them.
    public var hits: [Hit]
    /// `index.posts`: posts with a vector; nil when the server sent no `index`.
    public var indexed: Int?
    /// `index.pending`: posts whose vector is missing or out of date (found by name only, for now); nil when absent.
    public var pending: Int?

    public init(query: String, model: String? = nil, hits: [Hit], indexed: Int? = nil, pending: Int? = nil) {
        self.query = query
        self.model = model
        self.hits = hits
        self.indexed = indexed
        self.pending = pending
    }

    /// The posts in score order.
    public var posts: [LibraryPost] { hits.map(\.post) }
}

/// Where the library's server search is (the quiet line under the search field).
public enum LibrarySearchState: Sendable, Equatable {
    /// No server search: no query, a query under two letters, or a server without `features.search`.
    case idle
    /// Waiting out the typing pause, or the request is out. The local name filter answers meanwhile.
    case searching
    /// The server answered: `count` posts, and `pending` posts it could only find by name so far.
    case results(count: Int, pending: Int)
    /// `503 error.search.waking`: the Space is asleep or booting. Retries follow every `LibraryModel.wakingRetry` s, up to
    /// `LibraryModel.wakingRetries`; still waking after them → `.failed`.
    case waking
    /// `503 error.search.off`: the server has no Space configured. Name matches only until the server changes.
    case off
    /// Anything else (`502 error.search.failed`, offline, a bad answer): name matches only.
    case failed
}

/// The wire of `GET /library/search`. A post decodes exactly as `GET /library` decodes it (`LibraryPost`); a post that
/// does not decode is dropped (`Lossy`), never the whole answer.
struct LibrarySearchWire: Decodable {
    struct Index: Decodable { var posts: Int?; var pending: Int? }

    /// A `GET /library` post plus its `score`.
    struct Scored: Decodable {
        var post: LibraryPost
        var score: Double

        private enum Keys: String, CodingKey { case score }

        init(from decoder: Decoder) throws {
            post = try LibraryPost(from: decoder)
            let c = try decoder.container(keyedBy: Keys.self)
            score = ((try? c.decodeIfPresent(Double.self, forKey: .score)) ?? nil) ?? 0
        }
    }

    var query: String?
    var model: String?
    var posts: [Lossy<Scored>]?
    var index: Index?

    func result(asked query: String) -> LibrarySearchResult {
        LibrarySearchResult(
            query: self.query ?? query, model: model,
            hits: (posts ?? []).compactMap(\.value).map { .init(post: $0.post, score: $0.score) },
            indexed: index?.posts, pending: index?.pending)
    }

    /// Decodes an answer body (snake case, dates in ms) the way the HTTP client does.
    static func decode(_ data: Data, asked query: String) throws -> LibrarySearchResult {
        try CobaltJSON.decoder().decode(LibrarySearchWire.self, from: data).result(asked: query)
    }
}

// MARK: - GET /library/search/post

/// How one post sits in the search index (`GET /library/search/post?key=<post key>`), for the detail's "search index"
/// section. Every field but the key and the state is optional on the wire.
public struct LibrarySearchStatus: Sendable, Equatable, Decodable {
    public enum State: String, Sendable, Equatable {
        /// Its vector matches what the post says now.
        case indexed
        /// It has a vector, but the title or poster changed since: the next pass re-embeds it.
        case stale
        /// Never embedded yet: the next passes take it.
        case pending
        /// The Space refused it; it is retried at `retryAt`.
        case failed
        /// Refused three times: left alone until its title or poster changes.
        case gaveUp = "gave_up"
        /// A state this app does not know yet.
        case unknown
    }

    /// What the post is (or will be) embedded from.
    public struct Input: Sendable, Equatable, Decodable {
        public var title: String?
        public var text: String?
        /// The poster sent with the text; nil when the post has none on the media domain.
        public var imageURL: URL?

        public init(title: String? = nil, text: String? = nil, imageURL: URL? = nil) {
            self.title = title
            self.text = text
            self.imageURL = imageURL
        }

        private enum CodingKeys: String, CodingKey {
            case title, text
            case imageURL = "imageUrl"                 // `image_url` after convertFromSnakeCase
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil
            text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? nil
            imageURL = (try? c.decodeIfPresent(URL.self, forKey: .imageURL)) ?? nil
        }
    }

    public var postKey: String
    public var state: State
    public var model: String?
    public var dims: Int?
    public var embeddedAt: Date?
    public var failedAt: Date?
    public var retryAt: Date?
    public var attempts: Int
    /// The vector was made with the poster as well as the text.
    public var hasImage: Bool?
    public var input: Input?
    /// The stored vector was made from exactly `input` (false: a re-embed is due).
    public var embeddedMatchesInput: Bool?
    /// False when the server answered with search turned off (`search_enabled: false`); true otherwise.
    public var searchEnabled: Bool

    public init(
        postKey: String, state: State, model: String? = nil, dims: Int? = nil, embeddedAt: Date? = nil,
        failedAt: Date? = nil, retryAt: Date? = nil, attempts: Int = 0, hasImage: Bool? = nil, input: Input? = nil,
        embeddedMatchesInput: Bool? = nil, searchEnabled: Bool = true
    ) {
        self.postKey = postKey
        self.state = state
        self.model = model
        self.dims = dims
        self.embeddedAt = embeddedAt
        self.failedAt = failedAt
        self.retryAt = retryAt
        self.attempts = attempts
        self.hasImage = hasImage
        self.input = input
        self.embeddedMatchesInput = embeddedMatchesInput
        self.searchEnabled = searchEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case postKey, state, model, dims, embeddedAt, failedAt, retryAt, attempts, hasImage, input
        case embeddedMatchesInput, searchEnabled
    }

    /// Lenient: only `post_key` is required; an odd field reads as absent, an unknown state as `.unknown`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        postKey = try c.decode(String.self, forKey: .postKey)
        let raw = (try? c.decodeIfPresent(String.self, forKey: .state)) ?? nil
        state = raw.flatMap(State.init(rawValue:)) ?? .unknown
        model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? nil
        dims = (try? c.decodeIfPresent(Int.self, forKey: .dims)) ?? nil
        embeddedAt = (try? c.decodeIfPresent(Date.self, forKey: .embeddedAt)) ?? nil
        failedAt = (try? c.decodeIfPresent(Date.self, forKey: .failedAt)) ?? nil
        retryAt = (try? c.decodeIfPresent(Date.self, forKey: .retryAt)) ?? nil
        attempts = ((try? c.decodeIfPresent(Int.self, forKey: .attempts)) ?? nil) ?? 0
        hasImage = (try? c.decodeIfPresent(Bool.self, forKey: .hasImage)) ?? nil
        input = (try? c.decodeIfPresent(Input.self, forKey: .input)) ?? nil
        embeddedMatchesInput = (try? c.decodeIfPresent(Bool.self, forKey: .embeddedMatchesInput)) ?? nil
        searchEnabled = ((try? c.decodeIfPresent(Bool.self, forKey: .searchEnabled)) ?? nil) ?? true
    }

    /// Decodes an answer body (snake case, dates in ms) the way the HTTP client does.
    static func decode(_ data: Data) throws -> LibrarySearchStatus {
        try CobaltJSON.decoder().decode(LibrarySearchStatus.self, from: data)
    }
}
