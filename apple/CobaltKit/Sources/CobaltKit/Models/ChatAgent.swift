import Foundation

// Sub-agents (APP-API-CONTRACT section 43): the chat AI starts helpers, more chat AIs that each work on one task in the
// background, report back, and message each other. A helper is a chat thread of its own (same id) that only its parent
// writes to. These are the wire shapes the app reads: `Agent` (43.4), `AgentMail`, `GET /chat/threads/<id>/agents`
// (43.6) and the `agent` a thread read carries for a helper's own thread (43.1). Everything is lenient: an odd row is
// dropped, never the list, and a status this app does not know is `.unknown`.

/// One sub-agent (43.4 `Agent`).
public struct ChatAgent: Sendable, Equatable, Identifiable, Decodable {
    public enum Status: String, Sendable, Equatable {
        /// Started or woken by a message, its reply not begun.
        case queued
        case running
        /// Its last reply ended; `result` is its report.
        case done
        /// Its reply failed; `error` holds the code.
        case error
        /// Stopped by its parent (`agents.stop`); a cancelled job reads the same.
        case stopped
        /// A status a newer server sends.
        case unknown

        /// The wire's word, `cancelled` (a stopped agent's job) included.
        public init(wire: String?) {
            guard let wire else { self = .unknown; return }
            self = wire == "cancelled" ? .stopped : (Status(rawValue: wire) ?? .unknown)
        }

        /// Queued or running: the app polls quickly while any agent is.
        public var isLive: Bool { self == .queued || self == .running }
    }

    /// The agent's id (the wire's `agent`), also the id of its own chat thread.
    public var id: String
    /// `agent:<id>`, the job `jobs.wait` / `jobs.onDone` take.
    public var job: String
    public var name: String
    public var status: Status
    /// What the parent asked it to do (its thread's first message).
    public var task: String
    /// The op of its latest call, only while running.
    public var activity: String?
    /// Its report: the text of its last reply.
    public var result: String?
    /// The posts its last reply showed.
    public var postIDs: [String]
    public var error: String?
    /// The replies it ran.
    public var turns: Int
    /// Its own unread mail.
    public var unread: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var endedAt: Date?

    public init(
        id: String, job: String? = nil, name: String, status: Status, task: String = "", activity: String? = nil,
        result: String? = nil, postIDs: [String] = [], error: String? = nil, turns: Int = 0, unread: Int = 0,
        createdAt: Date, updatedAt: Date? = nil, endedAt: Date? = nil
    ) {
        self.id = id
        self.job = job ?? "agent:\(id)"
        self.name = name
        self.status = status
        self.task = task
        self.activity = activity
        self.result = result
        self.postIDs = postIDs
        self.error = error
        self.turns = turns
        self.unread = unread
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.endedAt = endedAt
    }

    public var isLive: Bool { status.isLive }

    enum CodingKeys: String, CodingKey {
        case agent, id, job, name, status, task, activity, result, postIDs = "postIds", error, turns, unread, createdAt, updatedAt, endedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.lenient(String.self, .agent) ?? c.lenient(String.self, .id), !id.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .agent, in: c, debugDescription: "an agent needs its id")
        }
        self.id = id
        job = c.lenient(String.self, .job) ?? "agent:\(id)"
        name = c.lenient(String.self, .name) ?? ""
        status = Status(wire: c.lenient(String.self, .status))
        task = c.lenient(String.self, .task) ?? ""
        activity = c.lenient(String.self, .activity)
        result = c.lenient(String.self, .result)
        postIDs = c.lossyArray(String.self, .postIDs)
        error = c.lenient(String.self, .error)
        turns = c.lenient(Double.self, .turns).map { Int($0) } ?? 0
        unread = c.lenient(Double.self, .unread).map { Int($0) } ?? 0
        createdAt = c.lenient(Date.self, .createdAt) ?? Date(timeIntervalSince1970: 0)
        updatedAt = c.lenient(Date.self, .updatedAt) ?? createdAt
        endedAt = c.lenient(Date.self, .endedAt)
    }
}

/// One message between agents (43.4 `AgentMail`): the parent and its sub-agents, or sub-agents among themselves.
public struct ChatAgentMail: Sendable, Equatable, Identifiable, Decodable {
    /// What `from` / `to` say for the parent thread.
    public static let parent = "parent"

    /// A number on the wire, as a string.
    public var id: String
    /// `"parent"` or an agent id.
    public var from: String
    public var fromName: String
    public var to: String
    public var toName: String
    public var text: String
    public var createdAt: Date
    public var read: Bool

    public init(
        id: String, from: String, fromName: String? = nil, to: String, toName: String? = nil, text: String, createdAt: Date,
        read: Bool = true
    ) {
        self.id = id
        self.from = from
        self.fromName = fromName ?? from
        self.to = to
        self.toName = toName ?? to
        self.text = text
        self.createdAt = createdAt
        self.read = read
    }

    public var isFromParent: Bool { from == Self.parent }

    /// Between the parent and this agent, either way.
    public func isWithParent(_ agentID: String) -> Bool {
        (from == Self.parent && to == agentID) || (from == agentID && to == Self.parent)
    }

    enum CodingKeys: String, CodingKey { case id, from, fromName, to, toName, text, createdAt, read }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = c.lenient(String.self, .id) {
            id = s
        } else if let n = c.lenient(Double.self, .id) {
            id = String(Int64(n))
        } else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "a message needs its id")
        }
        from = c.lenient(String.self, .from) ?? ""
        fromName = c.lenient(String.self, .fromName) ?? from
        to = c.lenient(String.self, .to) ?? ""
        toName = c.lenient(String.self, .toName) ?? to
        text = c.lenient(String.self, .text) ?? ""
        createdAt = c.lenient(Date.self, .createdAt) ?? Date(timeIntervalSince1970: 0)
        read = c.lenient(Bool.self, .read) ?? true
    }
}

/// `GET /chat/threads/<id>/agents` (43.6): a thread's sub-agents and the last 50 messages between the thread and them,
/// oldest first. Empty lists on a server before migration 0027.
public struct ChatAgentList: Sendable, Equatable, Decodable {
    public var agents: [ChatAgent]
    public var mail: [ChatAgentMail]

    public init(agents: [ChatAgent] = [], mail: [ChatAgentMail] = []) {
        self.agents = agents
        self.mail = mail
    }

    enum CodingKeys: String, CodingKey { case agents, mail }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agents = c.lossyArray(ChatAgent.self, .agents)
        mail = c.lossyArray(ChatAgentMail.self, .mail)
    }

    public var isEmpty: Bool { agents.isEmpty }
    /// Any agent queued or running.
    public var isLive: Bool { agents.contains(where: \.isLive) }

    public func agent(_ id: String) -> ChatAgent? { agents.first { $0.id == id } }

    /// The messages between the parent and one agent, oldest first.
    public func mail(with agentID: String) -> [ChatAgentMail] { mail.filter { $0.isWithParent(agentID) } }

    /// The agent sent the parent a message the parent has not read yet ("asked" on its chip).
    public func hasAsked(_ agentID: String) -> Bool {
        mail.contains { $0.from == agentID && $0.to == ChatAgentMail.parent && !$0.read }
    }
}

/// What a thread read says about a sub-agent's own thread (43.1 `agent`): the thread is read-only in the app.
public struct ChatAgentRef: Sendable, Equatable, Decodable {
    public var id: String
    /// The chat thread (or MCP thread) that started it.
    public var parent: String
    public var name: String
    public var status: ChatAgent.Status
    public var task: String

    public init(id: String, parent: String, name: String, status: ChatAgent.Status, task: String = "") {
        self.id = id
        self.parent = parent
        self.name = name
        self.status = status
        self.task = task
    }

    enum CodingKeys: String, CodingKey { case id, parent, name, status, task }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        parent = c.lenient(String.self, .parent) ?? ""
        name = c.lenient(String.self, .name) ?? ""
        status = ChatAgent.Status(wire: c.lenient(String.self, .status))
        task = c.lenient(String.self, .task) ?? ""
    }
}
