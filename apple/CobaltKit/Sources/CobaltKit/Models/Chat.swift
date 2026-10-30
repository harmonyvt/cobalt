import Foundation

// Chat (APP-API-CONTRACT section 27; `features.chat`): threads with Claude about the library. The wire shapes, the events
// of the reply stream, the errors the routes answer, and the one text rule the app and the server share. The store that
// drives them is `ChatStore`; the byte-level parser of the stream is `ChatSSEParser`.

// MARK: - the thread

/// One thread (`GET /chat/threads`, `POST`, `PATCH`, and inside a thread read).
public struct ChatThread: Sendable, Equatable, Identifiable, Decodable {
    public var id: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    /// The first 120 characters of the last message's text; empty for a new thread.
    public var preview: String
    public var messageCount: Int

    public init(id: String, title: String, createdAt: Date, updatedAt: Date, preview: String = "", messageCount: Int = 0) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.preview = preview
        self.messageCount = messageCount
    }

    enum CodingKeys: String, CodingKey { case id, title, createdAt, updatedAt, preview, messageCount }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        preview = try c.decodeIfPresent(String.self, forKey: .preview) ?? ""
        messageCount = try c.decodeIfPresent(Int.self, forKey: .messageCount) ?? 0
    }
}

// MARK: - a step

/// A code step of a reply (27.1): the JavaScript the model ran in the sandbox, what it logged and returned. The same `id`
/// again (a `step` event) replaces the earlier one.
public struct ChatStep: Sendable, Equatable, Identifiable, Decodable {
    public enum Status: String, Sendable, Equatable {
        case running, done, error
    }

    public var id: String
    /// `"code"` today; anything else is shown as a step too.
    public var kind: String
    public var status: Status
    public var code: String
    public var logs: [String]
    /// A JSON preview of what the code returned (up to 2,000 characters); nil while it runs or when it returned nothing.
    public var result: String?
    public var error: String?
    public var durationMS: Int?
    /// Kind `"job"` only (APP-API-CONTRACT 33.14): a job the chat handed to the server, which continues the chat when it
    /// ends. The step runs while the server waits for it.
    public var job: ChatJobCard?
    /// Kind `"code"`: every `cobalt.*` call of the run, in order, with its card (APP-API-CONTRACT 38); empty on older
    /// messages.
    public var calls: [ChatToolCall]

    /// The server is still waiting for this step's job: a new reply comes by itself when it ends.
    public var isWaitingJob: Bool { kind == "job" && status == .running }

    public init(
        id: String, kind: String = "code", status: Status, code: String = "", logs: [String] = [],
        result: String? = nil, error: String? = nil, durationMS: Int? = nil, job: ChatJobCard? = nil, calls: [ChatToolCall] = []
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.code = code
        self.logs = logs
        self.result = result
        self.error = error
        self.durationMS = durationMS
        self.job = job
        self.calls = calls
    }

    enum CodingKeys: String, CodingKey { case id, kind, status, code, logs, result, error, durationMS = "durationMs", job, calls }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "code"
        status = (try? c.decodeIfPresent(String.self, forKey: .status)).flatMap { $0 }.flatMap(Status.init(rawValue:)) ?? .done
        code = try c.decodeIfPresent(String.self, forKey: .code) ?? ""
        logs = try c.decodeIfPresent([String].self, forKey: .logs) ?? []
        result = try c.decodeIfPresent(String.self, forKey: .result)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        durationMS = (try? c.decodeIfPresent(Double.self, forKey: .durationMS)).flatMap { $0 }.map { Int($0.rounded()) }
        job = (try? c.decodeIfPresent(ChatJobCard.self, forKey: .job)).flatMap { $0 }
        calls = c.lossyArray(ChatToolCall.self, .calls)
    }
}

/// A job the chat handed to the server with `cobalt.jobs.onDone` (APP-API-CONTRACT 33.14) and what became of it.
public struct ChatJobCard: Sendable, Equatable, Decodable {
    /// "waiting", "done", "error", "cancelled" or "timeout"
    public var status: String
    /// What the chat meant to do with the result.
    public var note: String?

    public init(status: String, note: String? = nil) {
        self.status = status
        self.note = note
    }

    enum CodingKeys: String, CodingKey { case status, note }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "waiting"
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }
}

// MARK: - a collage

/// The big result set a reply attaches (27.5): up to 500 posts, paged by `GET /chat/threads/<id>/messages/<id>/collage`.
/// The message only carries what to title the grid with and how many posts it holds.
public struct ChatCollage: Sendable, Equatable, Codable {
    /// "every cat"; nil when the model gave none.
    public var title: String?
    /// The search words, for "open in library"; nil when the model gave none.
    public var query: String?
    /// How many posts the collage holds.
    public var total: Int

    public init(title: String? = nil, query: String? = nil, total: Int) {
        self.title = title
        self.query = query
        self.total = total
    }

    enum CodingKeys: String, CodingKey { case title, query, total }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = Self.clean(try? c.decodeIfPresent(String.self, forKey: .title))
        query = Self.clean(try? c.decodeIfPresent(String.self, forKey: .query))
        total = max(0, (try? c.decodeIfPresent(Int.self, forKey: .total)) ?? 0)
    }

    /// An empty or blank string is the same as none.
    private static func clean(_ raw: String?) -> String? {
        guard let text = raw else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// One page of a collage (`GET .../collage?offset=&limit=`): the ids in order, minus posts deleted since (so a page can be
/// shorter than the limit while `total` stays), and the posts they name.
public struct ChatCollagePage: Sendable, Equatable, Decodable {
    public var title: String?
    public var query: String?
    public var total: Int
    public var offset: Int
    /// The offset to ask for next; nil on the last page.
    public var next: Int?
    public var postIDs: [String]
    public var posts: [String: LibraryPost]

    public init(
        title: String? = nil, query: String? = nil, total: Int, offset: Int = 0, next: Int? = nil,
        postIDs: [String] = [], posts: [String: LibraryPost] = [:]
    ) {
        self.title = title
        self.query = query
        self.total = total
        self.offset = offset
        self.next = next
        self.postIDs = postIDs
        self.posts = posts
    }

    enum CodingKeys: String, CodingKey { case title, query, total, offset, next, postIDs = "postIds", posts }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil
        query = (try? c.decodeIfPresent(String.self, forKey: .query)) ?? nil
        total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
        offset = try c.decodeIfPresent(Int.self, forKey: .offset) ?? 0
        next = (try? c.decodeIfPresent(Int.self, forKey: .next)) ?? nil
        postIDs = try c.decodeIfPresent([String].self, forKey: .postIDs) ?? []
        posts = ChatThreadDetail.decodePosts(from: c)
    }
}

// MARK: - a ranked list

/// The scored list a reply attaches under its text (APP-API-CONTRACT 34.6, `cobalt.rank`): up to 50 posts, best first, each
/// with the search score and up to 4 words of why. Every field is optional on the wire so an older or newer server decodes.
public struct ChatRanked: Sendable, Equatable, Decodable {
    public struct Hit: Sendable, Equatable, Identifiable, Decodable {
        public var postID: String
        /// The search score (a cosine, plus the plain-text bonus); nil when the model gave none.
        public var score: Double?
        /// The post's own tags or sound tags closest to the query; empty when it has no words yet.
        public var why: [String]
        public var id: String { postID }

        public init(postID: String, score: Double? = nil, why: [String] = []) {
            self.postID = postID
            self.score = score
            self.why = why
        }

        enum CodingKeys: String, CodingKey { case postID = "postId", score, why }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let s = try? c.decode(String.self, forKey: .postID) {
                postID = s
            } else {
                postID = String(try c.decode(Int64.self, forKey: .postID))
            }
            score = (try? c.decodeIfPresent(Double.self, forKey: .score)) ?? nil
            why = ((try? c.decodeIfPresent([String].self, forKey: .why)) ?? nil) ?? []
        }
    }

    /// "furry videos"; nil when the model gave none.
    public var title: String?
    /// The words searched; nil when the model gave none.
    public var query: String?
    /// What the search was limited to, "lia share 11"; nil when it was the whole library.
    public var within: String?
    public var hits: [Hit]

    public init(title: String? = nil, query: String? = nil, within: String? = nil, hits: [Hit] = []) {
        self.title = title
        self.query = query
        self.within = within
        self.hits = hits
    }

    enum CodingKeys: String, CodingKey { case title, query, within, hits }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = Self.clean((try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil)
        query = Self.clean((try? c.decodeIfPresent(String.self, forKey: .query)) ?? nil)
        within = Self.clean((try? c.decodeIfPresent(String.self, forKey: .within)) ?? nil)
        hits = ((try? c.decodeIfPresent([Lossy<Hit>].self, forKey: .hits)) ?? nil)?.compactMap(\.value) ?? []
    }

    /// The highest score in the list, for the bars (nil when no hit has one).
    public var topScore: Double? { hits.compactMap(\.score).max() }

    /// An empty or blank string is the same as none.
    private static func clean(_ raw: String?) -> String? {
        guard let text = raw else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - a confirm card

/// What a confirm card says will happen (APP-API-CONTRACT 33.7): every field is optional and the card shows what is there.
public struct ChatConfirmEffect: Sendable, Equatable, Decodable {
    /// Up to 5 post titles.
    public var titles: [String]
    public var posts: Int?
    public var files: Int?
    public var bytes: Int64?
    /// Public file links that stop working.
    public var publicLinks: Int?
    /// Live gallery share links that show any of these files.
    public var shareLinks: Int?

    public init(titles: [String] = [], posts: Int? = nil, files: Int? = nil, bytes: Int64? = nil, publicLinks: Int? = nil, shareLinks: Int? = nil) {
        self.titles = titles
        self.posts = posts
        self.files = files
        self.bytes = bytes
        self.publicLinks = publicLinks
        self.shareLinks = shareLinks
    }

    enum CodingKeys: String, CodingKey { case titles, title, posts, files, bytes, publicLinks, shareLinks }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func int(_ key: CodingKeys) -> Int? { (try? c.decodeIfPresent(Double.self, forKey: key)).flatMap { $0 }.map { Int($0) } }
        var titles = ((try? c.decodeIfPresent([Lossy<String>].self, forKey: .titles)) ?? nil)?.compactMap(\.value) ?? []
        if titles.isEmpty, let one = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil { titles = [one] }
        self.titles = titles
        posts = int(.posts)
        files = int(.files)
        bytes = (try? c.decodeIfPresent(Double.self, forKey: .bytes)).flatMap { $0 }.map { Int64($0) }
        publicLinks = int(.publicLinks)
        shareLinks = int(.shareLinks)
    }
}

/// A confirm card (APP-API-CONTRACT 33.5, 33.7): a call the chat made that waits for the owner's yes, such as deleting
/// posts or making them private. It rides on the assistant message that asked (`confirm`), and the `confirm` event of a
/// reply stream sets or updates it.
public struct ChatConfirm: Sendable, Equatable, Identifiable, Decodable {
    public enum Status: String, Sendable, Equatable {
        case waiting, yes, no, expired
    }

    /// What the red button does, from the op the card runs.
    public enum Action: Sendable, Equatable {
        /// `library.delete` / `library.deleteFile`: "delete N" (N = files).
        case delete(files: Int)
        /// `library.visibility`: "make private".
        case makePrivate
        /// Any other op: "yes".
        case other
    }

    /// 16 letters and digits.
    public var id: String
    /// The op the card runs (`library.delete`, `library.visibility`, ...).
    public var op: String
    /// One lowercase line: `delete “cat jumps” (3 files)`.
    public var summary: String
    public var effect: ChatConfirmEffect
    public var status: Status
    /// When a waiting card stops being answerable (the server reads it as expired after this).
    public var expiresAt: Date?

    public init(id: String, op: String, summary: String, effect: ChatConfirmEffect = ChatConfirmEffect(), status: Status = .waiting, expiresAt: Date? = nil) {
        self.id = id
        self.op = op
        self.summary = summary
        self.effect = effect
        self.status = status
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey { case id, op, summary, effect, status, expiresAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        op = try c.decodeIfPresent(String.self, forKey: .op) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        effect = ((try? c.decodeIfPresent(ChatConfirmEffect.self, forKey: .effect)) ?? nil) ?? ChatConfirmEffect()
        status = (try? c.decodeIfPresent(String.self, forKey: .status)).flatMap { $0 }.flatMap(Status.init(rawValue:)) ?? .expired
        expiresAt = (try? c.decodeIfPresent(Date.self, forKey: .expiresAt)) ?? nil
    }

    public var action: Action {
        switch op {
        case "library.delete", "library.deleteFile": return .delete(files: max(1, effect.files ?? 1))
        case "library.visibility": return .makePrivate
        default: return .other
        }
    }

    /// The card can still be answered: waiting, and not past its time.
    public func isOpen(at now: Date) -> Bool {
        status == .waiting && (expiresAt.map { $0 > now } ?? true)
    }
}

// MARK: - a message

/// One message (27.1). A user message carries the files the owner attached; an assistant message carries the files the
/// model chose to show, its code steps, and whether it is still being written.
public struct ChatMessage: Sendable, Equatable, Identifiable, Decodable {
    public enum Role: String, Sendable, Equatable {
        case user, assistant
    }

    public enum Status: String, Sendable, Equatable {
        case done, running, error
    }

    /// The server's id (a number as a string); `local-…` for the user message the app shows before the server answers.
    public var id: String
    public var role: Role
    /// Markdown.
    public var text: String
    /// Library post ids: attached (user) or shown (assistant, at most 12, in order).
    public var postIDs: [String]
    public var steps: [ChatStep]
    public var status: Status
    /// The error code of a failed message (`error.chat.model`, `error.chat.interrupted`, `error.api.generic`).
    public var error: String?
    /// The big result set the reply attached (27.5); nil when it has none (always nil on a user message).
    public var collage: ChatCollage?
    /// The confirm card the reply stopped on (33.5); nil when it asked nothing.
    public var confirm: ChatConfirm?
    /// The scored list the reply attached (34.6); nil when it has none (always nil on a user message).
    public var ranked: ChatRanked?
    public var createdAt: Date

    public init(
        id: String, role: Role, text: String = "", postIDs: [String] = [], steps: [ChatStep] = [],
        status: Status = .done, error: String? = nil, collage: ChatCollage? = nil, confirm: ChatConfirm? = nil,
        ranked: ChatRanked? = nil, createdAt: Date
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.postIDs = postIDs
        self.steps = steps
        self.status = status
        self.error = error
        self.collage = collage
        self.confirm = confirm
        self.ranked = ranked
        self.createdAt = createdAt
    }

    /// Whether this is the app's own stand-in for a user message the server has not confirmed yet.
    public var isLocal: Bool { id.hasPrefix(ChatMessage.localPrefix) }
    static let localPrefix = "local-"

    enum CodingKeys: String, CodingKey { case id, role, text, postIDs = "postIds", steps, status, error, collage, confirm, ranked, createdAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // "a number as a string": a bare number is read too
        if let s = try? c.decode(String.self, forKey: .id) {
            id = s
        } else {
            id = String(try c.decode(Int64.self, forKey: .id))
        }
        let rawRole = try c.decode(String.self, forKey: .role)
        guard let role = Role(rawValue: rawRole) else {
            throw DecodingError.dataCorruptedError(forKey: .role, in: c, debugDescription: "unknown role \(rawRole)")
        }
        self.role = role
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        postIDs = try c.decodeIfPresent([String].self, forKey: .postIDs) ?? []
        steps = (try? c.decodeIfPresent([Lossy<ChatStep>].self, forKey: .steps)).flatMap { $0 }?.compactMap(\.value) ?? []
        status = (try? c.decodeIfPresent(String.self, forKey: .status)).flatMap { $0 }.flatMap(Status.init(rawValue:)) ?? .done
        error = try c.decodeIfPresent(String.self, forKey: .error)
        collage = (try? c.decodeIfPresent(ChatCollage.self, forKey: .collage)) ?? nil
        confirm = (try? c.decodeIfPresent(ChatConfirm.self, forKey: .confirm)) ?? nil
        ranked = (try? c.decodeIfPresent(ChatRanked.self, forKey: .ranked)) ?? nil
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
    }
}

// MARK: - a thread read

/// `GET /chat/threads/<id>`: the thread, every message oldest first, and the library posts they reference (as
/// `GET /library?v=3` shapes; a post that was deleted is missing, the app shows a "removed" tile).
public struct ChatThreadDetail: Sendable, Equatable, Decodable {
    public var thread: ChatThread
    public var messages: [ChatMessage]
    /// Keyed by the post's own id.
    public var posts: [String: LibraryPost]

    public init(thread: ChatThread, messages: [ChatMessage], posts: [String: LibraryPost] = [:]) {
        self.thread = thread
        self.messages = messages
        self.posts = posts
    }

    enum CodingKeys: String, CodingKey { case thread, messages, posts }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        thread = try c.decode(ChatThread.self, forKey: .thread)
        messages = (try c.decodeIfPresent([Lossy<ChatMessage>].self, forKey: .messages) ?? []).compactMap(\.value)
        posts = Self.decodePosts(from: c)
    }

    /// The `posts` map. A post that does not decode is dropped, never the thread; entries are keyed by the post's own id
    /// (the dictionary key is only a fallback), so a key strategy never touches an id.
    static func decodePosts<K: CodingKey>(from container: KeyedDecodingContainer<K>) -> [String: LibraryPost] {
        guard let key = K(stringValue: "posts"),
              let raw = (try? container.decodeIfPresent([String: Lossy<LibraryPost>].self, forKey: key)) ?? nil
        else { return [:] }
        var out: [String: LibraryPost] = [:]
        for (_, lossy) in raw {
            if let post = lossy.value { out[post.id] = post }
        }
        return out
    }
}

// MARK: - the reply stream

/// One event of `POST /chat/threads/<id>/messages` (27.2). Unknown events never reach this type.
public enum ChatEvent: Sendable, Equatable {
    /// The saved user message (first).
    case user(ChatMessage)
    /// The assistant message row, `running`, empty text.
    case assistant(ChatMessage)
    /// Text to append to the running message, in order.
    case text(String)
    /// A code step started or finished; the same id replaces the earlier one.
    case step(ChatStep)
    /// Files the model chose to show: appended to the message's `postIDs`, with their shapes.
    case posts(ids: [String], posts: [LibraryPost])
    /// The posts a step's tool cards draw (38.3): merged into the thread's map, shown nowhere by themselves.
    case cardPosts([LibraryPost])
    /// The reply attached a collage (27.5): set on the running message; `done` carries it too.
    case collage(ChatCollage)
    /// The reply attached a scored list (34.6): set on the running message (a later one replaces it); `done` carries it
    /// too. `posts` are the shapes the event came with, if any (the thread read has them all).
    case ranked(ChatRanked, posts: [LibraryPost])
    /// The model renamed the thread (after the first reply only).
    case title(ChatThread)
    /// A confirm card (33.5): set on the message `messageID` (nil: the running assistant message), or its new status
    /// after an answer (the first event of `POST .../confirm/<cid>`).
    case confirm(messageID: String?, ChatConfirm)
    /// The final, saved assistant message and the thread as it is now. Last event.
    case done(ChatMessage, ChatThread)
    /// The reply failed: `error.chat.model`, `error.chat.interrupted` or `error.api.generic`; the message is saved with
    /// `status: error` and whatever text it had (nil when the server sent none). Last event.
    case error(code: String, message: ChatMessage?)

    /// The last event of a reply: nothing follows it.
    public var isFinal: Bool {
        switch self {
        case .done, .error: return true
        default: return false
        }
    }
}

// MARK: - the errors

/// What the chat routes refuse with (mapped from the wire in `HTTPCobaltClient`), and what a failed reply says.
public enum ChatError: Error, Sendable, Equatable {
    /// `400 error.chat.bad_request`: bad JSON, empty or long text, bad ids.
    case badRequest
    /// `404 error.chat.not_found`: the thread is not (or no longer) there.
    case notFound
    /// `404 error.chat.off`: the server has chat off (no Anthropic key or no sandbox loader).
    case off
    /// `409 error.chat.busy`: a reply is still being written in this thread.
    case busy
    /// `409 error.chat.full`: 200 messages in the thread.
    case full
    /// `409 error.chat.too_many`: 200 threads.
    case tooMany
    /// `404 error.chat.confirm_gone`: the confirm card was already answered, expired, or replaced.
    case confirmGone
    /// `error.chat.model`: the model failed to answer (an `error` event).
    case model
    /// `error.chat.interrupted`: the reply was cut off (an `error` event, or a reply still running after 3 minutes).
    case interrupted
    /// `503 error.api.generic`: the server cannot take it right now.
    case unavailable

    /// The error a wire code names; nil for any other code.
    public init?(code: String) {
        switch code {
        case "error.chat.bad_request": self = .badRequest
        case "error.chat.not_found": self = .notFound
        case "error.chat.off": self = .off
        case "error.chat.busy": self = .busy
        case "error.chat.full": self = .full
        case "error.chat.too_many": self = .tooMany
        case "error.chat.confirm_gone": self = .confirmGone
        case "error.chat.model": self = .model
        case "error.chat.interrupted": self = .interrupted
        default: return nil
        }
    }

    /// The wire code of the error (`unavailable` is the generic one).
    public var code: String {
        switch self {
        case .badRequest: return "error.chat.bad_request"
        case .notFound: return "error.chat.not_found"
        case .off: return "error.chat.off"
        case .busy: return "error.chat.busy"
        case .full: return "error.chat.full"
        case .tooMany: return "error.chat.too_many"
        case .confirmGone: return "error.chat.confirm_gone"
        case .model: return "error.chat.model"
        case .interrupted: return "error.chat.interrupted"
        case .unavailable: return "error.api.generic"
        }
    }
}

// MARK: - the rules

/// The text rules of chat, shared by the composer, the rename sheet, the store and the tests (the server enforces the same).
public enum ChatRule {
    /// A message is 1..4000 characters.
    public static let messageLimit = 4000
    /// A thread title is 1..60 code points after trimming.
    public static let titleLimit = 60
    /// At most 20 files attached to one message.
    public static let attachmentLimit = 20
    /// At most 200 messages in a thread, 200 threads.
    public static let messageCap = 200
    public static let threadCap = 200
    /// Posts per collage page: the server allows 1...60, the app asks for 30 (27.5).
    public static let collagePage = 30
    /// The title a thread has before its first message names it.
    public static let defaultTitle = "new chat"

    /// The text to send: trimmed; nil when empty or over `messageLimit` characters.
    public static func cleanMessage(_ raw: String) -> String? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= messageLimit else { return nil }
        return cleaned
    }

    /// The title to send: the collection naming rule (trimmed, control characters removed, 1..60 code points).
    public static func cleanTitle(_ raw: String) -> String? { ShareCollectionRule.cleanName(raw) }
}
