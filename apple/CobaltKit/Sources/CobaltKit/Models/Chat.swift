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

    public init(
        id: String, kind: String = "code", status: Status, code: String = "", logs: [String] = [],
        result: String? = nil, error: String? = nil, durationMS: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.code = code
        self.logs = logs
        self.result = result
        self.error = error
        self.durationMS = durationMS
    }

    enum CodingKeys: String, CodingKey { case id, kind, status, code, logs, result, error, durationMS = "durationMs" }

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
    public var createdAt: Date

    public init(
        id: String, role: Role, text: String = "", postIDs: [String] = [], steps: [ChatStep] = [],
        status: Status = .done, error: String? = nil, createdAt: Date
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.postIDs = postIDs
        self.steps = steps
        self.status = status
        self.error = error
        self.createdAt = createdAt
    }

    /// Whether this is the app's own stand-in for a user message the server has not confirmed yet.
    public var isLocal: Bool { id.hasPrefix(ChatMessage.localPrefix) }
    static let localPrefix = "local-"

    enum CodingKeys: String, CodingKey { case id, role, text, postIDs = "postIds", steps, status, error, createdAt }

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
    /// The model renamed the thread (after the first reply only).
    case title(ChatThread)
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
