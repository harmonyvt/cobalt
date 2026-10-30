import Foundation

// Hidden posts and auto-hide rules (APP-API-CONTRACT 37). A post can be hidden: it leaves the library, can never be
// shared until it is unhidden, and its files are all off. The owner hides by hand (one post, or many with the bulk
// status route) and rules hide new saves. These are the wire shapes and the plain values the screens read; the routes
// are on `CobaltClient`, the state on `LibraryModel` (the album) and `HiddenRulesModel` (the rules).

/// What a post's links are, in one word (`POST /library/status`, 37.4): `off` no link, `public` its public link,
/// `private` each file's own private link, `hidden` out of the library and unshareable.
public enum PostStatus: String, Sendable, CaseIterable, Equatable {
    case off, `public`, `private`, hidden
}

/// What a rule looks at (37.3): the post's source site, words in its title / name / link, a word in what it is about, or
/// "was uploaded".
public enum HiddenRuleKind: String, Sendable, CaseIterable, Equatable {
    case site, words, about, upload
}

/// One auto-hide rule (`<rule>` in 37.4). Named `HideRule` and not `HiddenRule` because the generated `Endpoints.swift`
/// already declares an internal `struct HiddenRule` (its wire row) in this module.
public struct HideRule: Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: HiddenRuleKind
    /// Normalized by the server: lower case, trimmed; empty for `upload`.
    public var value: String
    public var enabled: Bool
    /// Posts this rule has hidden.
    public var hits: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String, kind: HiddenRuleKind, value: String, enabled: Bool = true, hits: Int = 0,
        createdAt: Date = Date(timeIntervalSince1970: 0), updatedAt: Date = Date(timeIntervalSince1970: 0)
    ) {
        self.id = id
        self.kind = kind
        self.value = value
        self.enabled = enabled
        self.hits = hits
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// `GET /hidden/rules`: the rules (oldest first), how many posts are hidden, and how many wait on an `about` rule.
public struct HiddenRules: Sendable, Equatable {
    public var rules: [HideRule]
    public var hidden: Int
    public var held: Int

    public init(rules: [HideRule] = [], hidden: Int = 0, held: Int = 0) {
        self.rules = rules
        self.hidden = hidden
        self.held = held
    }
}

/// `POST /hidden/rules/preview`: what a rule would hide now (nothing changes) and up to 6 post keys.
public struct HiddenRulePreview: Sendable, Equatable {
    public var matches: Int
    public var sample: [String]

    public init(matches: Int, sample: [String] = []) {
        self.matches = matches
        self.sample = sample
    }
}

/// `POST /library/status`: the posts that took the status and the ids that did not.
public struct StatusChange: Sendable, Equatable {
    public struct File: Sendable, Equatable {
        public var id: String
        /// `public` or `private` (a hidden post's files are `private`: off).
        public var visibility: String
        /// The file's live private link, when the status is `private`.
        public var privateURL: URL?

        public init(id: String, visibility: String, privateURL: URL? = nil) {
            self.id = id
            self.visibility = visibility
            self.privateURL = privateURL
        }
    }

    public struct Post: Sendable, Equatable {
        /// The id that was sent (a file or a post id).
        public var id: String
        public var postKey: String
        public var status: PostStatus
        public var files: [File]

        public init(id: String, postKey: String, status: PostStatus, files: [File] = []) {
            self.id = id
            self.postKey = postKey
            self.status = status
            self.files = files
        }
    }

    public struct Failure: Sendable, Equatable {
        public var id: String
        /// An error code, e.g. `error.library.not_found`, `error.share.off`.
        public var error: String

        public init(id: String, error: String) {
            self.id = id
            self.error = error
        }
    }

    public var posts: [Post]
    public var failed: [Failure]

    public init(posts: [Post] = [], failed: [Failure] = []) {
        self.posts = posts
        self.failed = failed
    }
}

/// What `LibraryModel.setStatus` did: how many posts took the status, the posts the server refused (`failed`, by id) and
/// the files of posts that did take it but could not be switched (`fileFailures`: the server hid the post and could not
/// take a public copy off, `error.library.not_toggleable`). The two are kept apart: a count of "couldn't change" is of
/// posts.
public struct StatusOutcome: Sendable, Equatable {
    public var changed: Int
    public var failed: [StatusChange.Failure]
    public var fileFailures: [StatusChange.Failure]

    public init(changed: Int = 0, failed: [StatusChange.Failure] = [], fileFailures: [StatusChange.Failure] = []) {
        self.changed = changed
        self.failed = failed
        self.fileFailures = fileFailures
    }
}

// MARK: - the wire

/// The JSON of the hidden routes, decoded with `CobaltJSON.decoder()` (snake case, millisecond dates). Separate from the
/// generated response types, which take rules as strings and have no status request.
enum HiddenWire {
    struct Rule: Decodable {
        var id: String
        var kind: String
        var value: String
        var enabled: Bool
        var hits: Int
        var createdAt: Date
        var updatedAt: Date

        /// Nil for a kind this build does not know: the rule is dropped, never the list.
        var rule: HideRule? {
            HiddenRuleKind(rawValue: kind).map {
                HideRule(id: id, kind: $0, value: value, enabled: enabled, hits: hits, createdAt: createdAt, updatedAt: updatedAt)
            }
        }
    }

    struct List: Decodable {
        var rules: [Lossy<Rule>]?
        var hidden: Int?
        var held: Int?

        var value: HiddenRules {
            HiddenRules(rules: (rules ?? []).compactMap { $0.value?.rule }, hidden: hidden ?? 0, held: held ?? 0)
        }
    }

    struct Saved: Decodable {
        var rule: Rule
        var applied: Int?
    }

    struct Preview: Decodable {
        var matches: Int
        var sample: [String]?
    }

    struct Status: Decodable {
        struct File: Decodable {
            var id: String
            var visibility: String?
            var privateUrl: String?
        }

        struct Post: Decodable {
            var id: String
            var postKey: String?
            var status: String
            var files: [Lossy<File>]?
        }

        struct Failure: Decodable {
            var id: String
            var error: String?
        }

        var posts: [Lossy<Post>]?
        var failed: [Lossy<Failure>]?

        var value: StatusChange {
            StatusChange(
                posts: (posts ?? []).compactMap(\.value).compactMap { p in
                    guard let status = PostStatus(rawValue: p.status) else { return nil }
                    let files = (p.files ?? []).compactMap(\.value).map {
                        StatusChange.File(id: $0.id, visibility: $0.visibility ?? "private", privateURL: $0.privateUrl.flatMap(URL.init(string:)))
                    }
                    return StatusChange.Post(id: p.id, postKey: p.postKey ?? p.id, status: status, files: files)
                },
                failed: (failed ?? []).compactMap(\.value).map { StatusChange.Failure(id: $0.id, error: $0.error ?? "error.api.generic") })
        }
    }
}
