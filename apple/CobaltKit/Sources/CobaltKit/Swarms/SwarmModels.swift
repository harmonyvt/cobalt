import Foundation

// Swarms in the apps (apple/CONTRACT-SWARMS.md; APP-API-CONTRACT 59.5 `Swarm`, 59.6 `SwarmChange`, 61.3 `SwarmMessage` and
// `SwarmAgent`). Every shape is read leniently: a field that is not certain to be there is optional or defaulted, an
// unknown status decodes to a safe default, a missing array is empty, and one odd row never hides the others.
//
// These types are decoded with `SwarmWire.decoder()`, not `CobaltJSON.decoder()`: their keys are spelled out in snake case
// (`spec_hash`) because `convertFromSnakeCase` would also rewrite the keys *inside* the open fields (`args`, `items`,
// `result`), and `args[edit_arg]` has to find the model's own spelling.

/// The decoder and encoder of every swarm shape: timestamps are milliseconds since the epoch, keys are the wire's own.
public enum SwarmWire {
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            return Date(timeIntervalSince1970: try c.decode(Double.self) / 1000)
        }
        return d
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode((date.timeIntervalSince1970 * 1000).rounded())
        }
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

// MARK: - lenient reading

extension KeyedDecodingContainer {
    /// The value, or `fallback` when the key is missing, null or the wrong type.
    func swarmValue<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }

    /// The value, or nil when the key is missing, null or the wrong type.
    func swarmOptional<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }

    /// An array whose odd elements are dropped; missing is empty.
    func swarmList<T: Decodable>(_ key: Key, of type: T.Type = T.self) -> [T] {
        ((try? decodeIfPresent([Lossy<T>].self, forKey: key)) ?? nil)?.compactMap(\.value) ?? []
    }

    /// A Bool that may come as 0/1.
    func swarmFlag(_ key: Key, _ fallback: Bool = false) -> Bool {
        if let b = try? decodeIfPresent(Bool.self, forKey: key) { return b }
        if let n = try? decodeIfPresent(Int.self, forKey: key) { return n != 0 }
        return fallback
    }
}

extension Decoder {
    /// The string a one-value enum was written as.
    fileprivate func swarmRaw() -> String? { try? singleValueContainer().decode(String.self) }
}

extension JSONValue {
    public var stringValue: String? { if case .string(let v) = self { return v } else { return nil } }
    public var numberValue: Double? { if case .number(let v) = self { return v } else { return nil } }
    public var boolValue: Bool? { if case .bool(let v) = self { return v } else { return nil } }
    public var arrayValue: [JSONValue]? { if case .array(let v) = self { return v } else { return nil } }
    public var dictionaryValue: [String: JSONValue]? { if case .dictionary(let v) = self { return v } else { return nil } }

    /// A short plain line for lists ("CatJam", "42", "emote_id: 9, name: BONK"): what a person would read off the value.
    public var display: String {
        switch self {
        case .null: return ""
        case .bool(let v): return v ? "yes" : "no"
        case .number(let v): return v == v.rounded() && abs(v) < 1e15 ? String(Int64(v)) : String(v)
        case .string(let v): return v
        case .array(let v): return v.map(\.display).joined(separator: ", ")
        case .dictionary(let v): return v.keys.sorted().map { "\($0): \(v[$0]?.display ?? "")" }.joined(separator: ", ")
        }
    }
}

// MARK: - one agent's cell

/// One square of the grid: an agent and where it is (59.5 `tasks.cells[]`, 61.3 adds `step` and the status `waiting`).
public struct SwarmCell: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Hashable, Sendable, CaseIterable {
        case queued, running, waiting, done, failed, skipped

        /// An unknown status reads as queued: the square is grey and nothing is claimed.
        public init(from decoder: Decoder) throws {
            self = decoder.swarmRaw().flatMap(Status.init(rawValue:)) ?? .queued
        }

        /// The letter the Live Activity's `cells` string uses (61.5): q r w d f s.
        public var letter: Character {
            switch self {
            case .queued: return "q"
            case .running: return "r"
            case .waiting: return "w"
            case .done: return "d"
            case .failed: return "f"
            case .skipped: return "s"
            }
        }

        /// The status a `cells` letter names; nil for any other character.
        public init?(letter: Character) {
            guard let match = Status.allCases.first(where: { $0.letter == letter }) else { return nil }
            self = match
        }
    }

    /// 0-based, as the server stores it.
    public var idx: Int
    /// The number a person sees: from 1.
    public var agent: Int { idx + 1 }
    public var status: Status
    public var error: String?
    /// The last step text ("read seventv.set"), when the server says.
    public var step: String?

    public init(idx: Int, status: Status, error: String? = nil, step: String? = nil) {
        self.idx = idx
        self.status = status
        self.error = error
        self.step = step
    }

    enum CodingKeys: String, CodingKey { case idx, status, error, step }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        idx = c.swarmValue(.idx, 0)
        status = c.swarmValue(.status, .queued)
        error = c.swarmOptional(.error)
        step = c.swarmOptional(.step)
    }
}

// MARK: - the swarm

public struct Swarm: Codable, Hashable, Sendable, Identifiable {
    /// What its agents do with their answers (59.1). An unknown mode reads as `read`: the one that changes nothing.
    public enum Mode: String, Codable, Hashable, Sendable, CaseIterable {
        case propose, read, act

        public init(from decoder: Decoder) throws {
            self = decoder.swarmRaw().flatMap(Mode.init(rawValue:)) ?? .read
        }
    }

    public enum Status: String, Codable, Hashable, Sendable, CaseIterable {
        case awaitingApproval = "awaiting_approval"
        case running, stopping, done, failed, stopped, declined, expired

        /// An unknown status reads as running: the screen keeps polling instead of claiming an end.
        public init(from decoder: Decoder) throws {
            self = decoder.swarmRaw().flatMap(Status.init(rawValue:)) ?? .running
        }
    }

    public struct Range2: Codable, Hashable, Sendable {
        public var low: Double
        public var high: Double

        public init(low: Double, high: Double) {
            self.low = low
            self.high = high
        }

        enum CodingKeys: String, CodingKey { case low, high }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            low = c.swarmValue(.low, 0)
            high = c.swarmValue(.high, c.swarmValue(.low, 0))
        }
    }

    public struct Tasks: Codable, Hashable, Sendable {
        public var total: Int
        public var queued: Int
        public var running: Int
        public var done: Int
        public var failed: Int
        /// Agents parked on a question (61.3).
        public var waiting: Int
        public var cells: [SwarmCell]

        public init(total: Int = 0, queued: Int = 0, running: Int = 0, done: Int = 0, failed: Int = 0, waiting: Int = 0, cells: [SwarmCell] = []) {
            self.total = total
            self.queued = queued
            self.running = running
            self.done = done
            self.failed = failed
            self.waiting = waiting
            self.cells = cells
        }

        enum CodingKeys: String, CodingKey { case total, queued, running, done, failed, waiting, cells }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let cells: [SwarmCell] = c.swarmList(.cells)
            self.cells = cells
            total = c.swarmValue(.total, cells.count)
            queued = c.swarmValue(.queued, 0)
            running = c.swarmValue(.running, 0)
            done = c.swarmValue(.done, 0)
            failed = c.swarmValue(.failed, 0)
            waiting = c.swarmValue(.waiting, 0)
        }
    }

    /// Propose mode only: the changes the agents found (59.5 `changes`).
    public struct ChangeCounts: Codable, Hashable, Sendable {
        public var total: Int
        public var kept: Int
        public var done: Int
        public var failed: Int

        public init(total: Int = 0, kept: Int = 0, done: Int = 0, failed: Int = 0) {
            self.total = total
            self.kept = kept
            self.done = done
            self.failed = failed
        }

        enum CodingKeys: String, CodingKey { case total, kept, done, failed }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            total = c.swarmValue(.total, 0)
            kept = c.swarmValue(.kept, 0)
            done = c.swarmValue(.done, 0)
            failed = c.swarmValue(.failed, 0)
        }
    }

    public struct Apply: Codable, Hashable, Sendable {
        public enum Status: String, Codable, Hashable, Sendable, CaseIterable {
            case none, ready, applying, applied, failed

            public init(from decoder: Decoder) throws {
                self = decoder.swarmRaw().flatMap(Status.init(rawValue:)) ?? .none
            }
        }

        public var status: Status
        public var done: Int
        public var failed: Int
        /// The kept changes.
        public var total: Int

        public init(status: Status = .none, done: Int = 0, failed: Int = 0, total: Int = 0) {
            self.status = status
            self.done = done
            self.failed = failed
            self.total = total
        }

        enum CodingKeys: String, CodingKey { case status, done, failed, total }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            status = c.swarmValue(.status, .none)
            done = c.swarmValue(.done, 0)
            failed = c.swarmValue(.failed, 0)
            total = c.swarmValue(.total, 0)
        }
    }

    /// What the approve screen shows of the program (59.5 `spec_preview`).
    public struct SpecPreview: Codable, Hashable, Sendable {
        public struct Source: Codable, Hashable, Sendable {
            public var call: String
            public var args: [String: JSONValue]
            public var path: String?

            public init(call: String, args: [String: JSONValue] = [:], path: String? = nil) {
                self.call = call
                self.args = args
                self.path = path
            }

            enum CodingKeys: String, CodingKey { case call, args, path }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                call = c.swarmValue(.call, "")
                args = c.swarmValue(.args, [:])
                path = c.swarmOptional(.path)
            }
        }

        /// The first ten items.
        public var itemsSample: [JSONValue]
        public var source: Source?
        public var outputSchema: JSONValue?
        public var reducePrompt: String?
        public var turnsPerTask: Int
        public var attempts: Int
        public var stopAfterFailedTasks: Int

        public init(
            itemsSample: [JSONValue] = [], source: Source? = nil, outputSchema: JSONValue? = nil, reducePrompt: String? = nil,
            turnsPerTask: Int = 0, attempts: Int = 0, stopAfterFailedTasks: Int = 0
        ) {
            self.itemsSample = itemsSample
            self.source = source
            self.outputSchema = outputSchema
            self.reducePrompt = reducePrompt
            self.turnsPerTask = turnsPerTask
            self.attempts = attempts
            self.stopAfterFailedTasks = stopAfterFailedTasks
        }

        enum CodingKeys: String, CodingKey {
            case itemsSample = "items_sample", source, outputSchema = "output_schema", reducePrompt = "reduce_prompt"
            case turnsPerTask = "turns_per_task", attempts, stopAfterFailedTasks = "stop_after_failed_tasks"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            itemsSample = c.swarmValue(.itemsSample, [])
            source = c.swarmOptional(.source)
            outputSchema = c.swarmOptional(.outputSchema)
            reducePrompt = c.swarmOptional(.reducePrompt)
            turnsPerTask = c.swarmValue(.turnsPerTask, 0)
            attempts = c.swarmValue(.attempts, 0)
            stopAfterFailedTasks = c.swarmValue(.stopAfterFailedTasks, 0)
        }
    }

    /// Messages between the agents and the owner (61.3 `messages`): `waiting` is the open questions.
    public struct MessageCounts: Codable, Hashable, Sendable {
        public var total: Int
        public var waiting: Int

        public init(total: Int = 0, waiting: Int = 0) {
            self.total = total
            self.waiting = waiting
        }

        enum CodingKeys: String, CodingKey { case total, waiting }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            total = c.swarmValue(.total, 0)
            waiting = c.swarmValue(.waiting, 0)
        }
    }

    /// JSON `swarm`.
    public var id: String
    public var name: String
    public var mode: Mode
    public var status: Status
    public var specHash: String
    public var prompt: String
    public var tools: [String]
    public var writes: [String]
    /// The scope the writes are limited to (59.1): open JSON, shown by the "see exactly what it's told" screen.
    public var scope: JSONValue?
    /// The item count (the server's `items`).
    public var items: Int
    public var batchSize: Int
    public var concurrency: Int
    public var tasks: Tasks
    public var estimateUSD: Range2?
    public var capUSD: Double
    public var spentUSD: Double
    public var createdAt: Date
    public var approvedAt: Date?
    public var finishedAt: Date?
    /// Only while the plan awaits approval.
    public var expiresAt: Date?
    public var reduce: String?
    public var error: String?
    public var changes: ChangeCounts?
    public var apply: Apply
    public var preview: SpecPreview?
    public var messages: MessageCounts?
    /// "claude code", "chat", "mcp": who asked.
    public var planner: String?
    /// The mean of its agents' scores, 0...1 (62.3); nil until an agent has ended.
    public var score: Double?
    /// Writes no scope key limits (59.5 `unscoped_writes`).
    public var unscopedWrites: [String]
    public var approveURL: URL?
    /// `swarm:<id>`.
    public var job: String?
    /// The kept changes that look like duplicates. Not on the wire: the store counts them from the change list it read.
    public var clashCount: Int

    /// Waiting for the owner: a plan to approve, or finished changes to apply.
    public var waitsForYou: Bool { status == .awaitingApproval || apply.status == .ready }

    /// Agents or changes are being worked on right now (the poll goes to 3 s).
    public var isWorking: Bool { status == .running || status == .stopping || apply.status == .applying }

    /// What "apply" would send: the kept changes without the clashes.
    public var applyCount: Int { max(0, apply.total - clashCount) }

    public init(
        id: String, name: String, mode: Mode = .propose, status: Status = .awaitingApproval, specHash: String = "", prompt: String = "",
        tools: [String] = [], writes: [String] = [], scope: JSONValue? = nil, items: Int = 0, batchSize: Int = 0, concurrency: Int = 0,
        tasks: Tasks = Tasks(), estimateUSD: Range2? = nil, capUSD: Double = 0, spentUSD: Double = 0, createdAt: Date,
        approvedAt: Date? = nil, finishedAt: Date? = nil, expiresAt: Date? = nil, reduce: String? = nil, error: String? = nil,
        changes: ChangeCounts? = nil, apply: Apply = Apply(), preview: SpecPreview? = nil, messages: MessageCounts? = nil,
        planner: String? = nil, score: Double? = nil, unscopedWrites: [String] = [], approveURL: URL? = nil, job: String? = nil,
        clashCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.status = status
        self.specHash = specHash
        self.prompt = prompt
        self.tools = tools
        self.writes = writes
        self.scope = scope
        self.items = items
        self.batchSize = batchSize
        self.concurrency = concurrency
        self.tasks = tasks
        self.estimateUSD = estimateUSD
        self.capUSD = capUSD
        self.spentUSD = spentUSD
        self.createdAt = createdAt
        self.approvedAt = approvedAt
        self.finishedAt = finishedAt
        self.expiresAt = expiresAt
        self.reduce = reduce
        self.error = error
        self.changes = changes
        self.apply = apply
        self.preview = preview
        self.messages = messages
        self.planner = planner
        self.score = score
        self.unscopedWrites = unscopedWrites
        self.approveURL = approveURL
        self.job = job
        self.clashCount = clashCount
    }

    enum CodingKeys: String, CodingKey {
        case id = "swarm", name, mode, status, specHash = "spec_hash", prompt, tools, writes, scope, items
        case batchSize = "batch_size", concurrency, tasks, estimateUSD = "estimate_usd", capUSD = "cap_usd", spentUSD = "spent_usd"
        case createdAt = "created_at", approvedAt = "approved_at", finishedAt = "finished_at", expiresAt = "expires_at"
        case reduce, error, changes, apply, preview = "spec_preview", messages, planner, score
        case unscopedWrites = "unscoped_writes", approveURL = "approve_url", job
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.swarmValue(.name, "")
        mode = c.swarmValue(.mode, .read)
        status = c.swarmValue(.status, .running)
        specHash = c.swarmValue(.specHash, "")
        prompt = c.swarmValue(.prompt, "")
        tools = c.swarmValue(.tools, [])
        writes = c.swarmValue(.writes, [])
        scope = c.swarmOptional(.scope)
        items = c.swarmValue(.items, 0)
        batchSize = c.swarmValue(.batchSize, 0)
        concurrency = c.swarmValue(.concurrency, 0)
        tasks = c.swarmValue(.tasks, Tasks())
        estimateUSD = c.swarmOptional(.estimateUSD)
        capUSD = c.swarmValue(.capUSD, 0)
        spentUSD = c.swarmValue(.spentUSD, 0)
        createdAt = c.swarmValue(.createdAt, Date(timeIntervalSince1970: 0))
        approvedAt = c.swarmOptional(.approvedAt)
        finishedAt = c.swarmOptional(.finishedAt)
        expiresAt = c.swarmOptional(.expiresAt)
        reduce = c.swarmOptional(.reduce)
        error = c.swarmOptional(.error)
        changes = c.swarmOptional(.changes)
        apply = c.swarmValue(.apply, Apply())
        preview = c.swarmOptional(.preview)
        messages = c.swarmOptional(.messages)
        planner = c.swarmOptional(.planner)
        score = c.swarmOptional(.score)
        unscopedWrites = c.swarmValue(.unscopedWrites, [])
        approveURL = c.swarmOptional(.approveURL)
        job = c.swarmOptional(.job)
        clashCount = 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(mode, forKey: .mode)
        try c.encode(status, forKey: .status)
        try c.encode(specHash, forKey: .specHash)
        try c.encode(prompt, forKey: .prompt)
        try c.encode(tools, forKey: .tools)
        try c.encode(writes, forKey: .writes)
        try c.encodeIfPresent(scope, forKey: .scope)
        try c.encode(items, forKey: .items)
        try c.encode(batchSize, forKey: .batchSize)
        try c.encode(concurrency, forKey: .concurrency)
        try c.encode(tasks, forKey: .tasks)
        try c.encodeIfPresent(estimateUSD, forKey: .estimateUSD)
        try c.encode(capUSD, forKey: .capUSD)
        try c.encode(spentUSD, forKey: .spentUSD)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(approvedAt, forKey: .approvedAt)
        try c.encodeIfPresent(finishedAt, forKey: .finishedAt)
        try c.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try c.encodeIfPresent(reduce, forKey: .reduce)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encodeIfPresent(changes, forKey: .changes)
        try c.encode(apply, forKey: .apply)
        try c.encodeIfPresent(preview, forKey: .preview)
        try c.encodeIfPresent(messages, forKey: .messages)
        try c.encodeIfPresent(planner, forKey: .planner)
        try c.encodeIfPresent(score, forKey: .score)
        try c.encode(unscopedWrites, forKey: .unscopedWrites)
        try c.encodeIfPresent(approveURL, forKey: .approveURL)
        try c.encodeIfPresent(job, forKey: .job)
    }
}

// MARK: - one proposed change

/// One change an agent proposes (propose mode, 59.6). `n` numbers them in the order stored.
public struct SwarmChange: Codable, Hashable, Sendable, Identifiable {
    public enum Status: String, Codable, Hashable, Sendable, CaseIterable {
        case proposed, applying, done, failed, skipped

        public init(from decoder: Decoder) throws {
            self = decoder.swarmRaw().flatMap(Status.init(rawValue:)) ?? .proposed
        }
    }

    public var n: Int
    public var id: Int { n }
    /// The agent's task (0-based).
    public var task: Int
    public var op: String
    public var args: JSONValue?
    /// What it is done to: "capybaraharmony".
    public var target: String?
    /// The old value, as shown ("CatJam").
    public var before: String?
    /// The new value, as shown ("catjam"); what the owner edits.
    public var after: String?
    /// The arg `after` is written into ("alias"); nil when the change cannot be edited.
    public var editArg: String?
    public var previewURL: URL?
    public var keep: Bool
    public var status: Status
    public var error: String?
    /// "duplicate name: also proposed by #118", "duplicate: the same change as #5", "invalid: …".
    public var clash: String?

    /// The agent that proposed it (1-based).
    public var agent: Int { task + 1 }
    public var canEdit: Bool { editArg != nil }

    public init(
        n: Int, task: Int = 0, op: String = "", args: JSONValue? = nil, target: String? = nil, before: String? = nil,
        after: String? = nil, editArg: String? = nil, previewURL: URL? = nil, keep: Bool = true, status: Status = .proposed,
        error: String? = nil, clash: String? = nil
    ) {
        self.n = n
        self.task = task
        self.op = op
        self.args = args
        self.target = target
        self.before = before
        self.after = after
        self.editArg = editArg
        self.previewURL = previewURL
        self.keep = keep
        self.status = status
        self.error = error
        self.clash = clash
    }

    enum CodingKeys: String, CodingKey {
        case n, task, op, args, target, before, after, editArg = "edit_arg", previewURL = "preview_url", keep, status, error, clash
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        n = try c.decode(Int.self, forKey: .n)
        task = c.swarmValue(.task, 0)
        op = c.swarmValue(.op, "")
        args = c.swarmOptional(.args)
        target = c.swarmOptional(.target)
        before = c.swarmOptional(.before)
        after = c.swarmOptional(.after)
        editArg = c.swarmOptional(.editArg)
        previewURL = c.swarmOptional(.previewURL)
        keep = c.swarmFlag(.keep, true)
        status = c.swarmValue(.status, .proposed)
        error = c.swarmOptional(.error)
        clash = c.swarmOptional(.clash)
    }
}

/// `GET /swarms/<id>/changes`: `{ changes, total, offset }`.
public struct SwarmChangePage: Codable, Hashable, Sendable {
    public var changes: [SwarmChange]
    public var total: Int
    public var offset: Int

    public init(changes: [SwarmChange] = [], total: Int = 0, offset: Int = 0) {
        self.changes = changes
        self.total = total
        self.offset = offset
    }

    enum CodingKeys: String, CodingKey { case changes, total, offset }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let list: [SwarmChange] = c.swarmList(.changes)
        changes = list
        total = c.swarmValue(.total, list.count)
        offset = c.swarmValue(.offset, 0)
    }
}

/// One line of `POST /swarms/<id>/changes`: tick or untick, and/or a new `after`. `after` nil leaves it as is;
/// `clearAfter` sends null (the server clears the field).
public struct SwarmDecision: Hashable, Sendable {
    public var n: Int
    public var keep: Bool?
    public var after: String?
    public var clearAfter: Bool

    public init(n: Int, keep: Bool? = nil, after: String? = nil, clearAfter: Bool = false) {
        self.n = n
        self.keep = keep
        self.after = after
        self.clearAfter = clearAfter
    }

    /// The wire object: `{ n, keep?, after? }`, `after` null when cleared.
    public var wire: [String: Any] {
        var out: [String: Any] = ["n": n]
        if let keep { out["keep"] = keep }
        if clearAfter { out["after"] = NSNull() } else if let after { out["after"] = after }
        return out
    }
}

/// `POST /swarms/<id>/changes`: the swarm and the changes named, after the update.
public struct SwarmDecided: Codable, Hashable, Sendable {
    public var swarm: Swarm
    public var changes: [SwarmChange]

    public init(swarm: Swarm, changes: [SwarmChange] = []) {
        self.swarm = swarm
        self.changes = changes
    }

    enum CodingKeys: String, CodingKey { case swarm, changes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        swarm = try c.decode(Swarm.self, forKey: .swarm)
        changes = c.swarmList(.changes)
    }
}

// MARK: - messages

/// Who a message goes to: one agent (from 1) or every agent.
public enum SwarmRecipient: Codable, Hashable, Sendable {
    case agent(Int)
    case all

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int.self) { self = .agent(n) } else { self = .all }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .agent(let n): try c.encode(n)
        case .all: try c.encode("all")
        }
    }

    /// The wire value of `to`: a number or "all".
    public var wire: Any {
        switch self {
        case .agent(let n): return n
        case .all: return "all"
        }
    }
}

/// One message between an agent and the owner (61.3).
public struct SwarmMessage: Codable, Hashable, Sendable, Identifiable {
    public enum Dir: String, Codable, Hashable, Sendable {
        /// An agent to its owner.
        case up
        /// The owner (or you) to the agents.
        case down

        public init(from decoder: Decoder) throws { self = decoder.swarmRaw().flatMap(Dir.init(rawValue:)) ?? .up }
    }

    public enum Kind: String, Codable, Hashable, Sendable {
        case ask, tell, reply, note

        public init(from decoder: Decoder) throws { self = decoder.swarmRaw().flatMap(Kind.init(rawValue:)) ?? .note }
    }

    public enum Sender: String, Codable, Hashable, Sendable {
        case agent, owner, you

        public init(from decoder: Decoder) throws { self = decoder.swarmRaw().flatMap(Sender.init(rawValue:)) ?? .agent }
    }

    public var id: Int
    public var swarm: String
    /// The agent it is from or to (from 1); nil is every agent.
    public var agent: Int?
    public var dir: Dir
    public var kind: Kind
    public var sender: Sender
    public var text: String
    public var at: Date
    /// An `ask` that has its answer.
    public var answered: Bool

    public init(
        id: Int, swarm: String, agent: Int? = nil, dir: Dir = .up, kind: Kind = .note, sender: Sender = .agent, text: String,
        at: Date, answered: Bool = false
    ) {
        self.id = id
        self.swarm = swarm
        self.agent = agent
        self.dir = dir
        self.kind = kind
        self.sender = sender
        self.text = text
        self.at = at
        self.answered = answered
    }

    enum CodingKeys: String, CodingKey { case id, swarm, agent, dir, kind, sender, text, at, answered }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        swarm = c.swarmValue(.swarm, "")
        agent = c.swarmOptional(.agent)
        dir = c.swarmValue(.dir, .up)
        kind = c.swarmValue(.kind, .note)
        sender = c.swarmValue(.sender, .agent)
        text = c.swarmValue(.text, "")
        at = c.swarmValue(.at, Date(timeIntervalSince1970: 0))
        answered = c.swarmFlag(.answered)
    }

    /// An open question: an `ask` from an agent nobody has answered.
    public var isOpenAsk: Bool { kind == .ask && dir == .up && !answered }
}

/// `POST /swarms/<id>/messages`: `{ sent, to, woke }`.
public struct SwarmSent: Codable, Hashable, Sendable {
    public var sent: Int
    public var to: SwarmRecipient
    /// An agent waiting on a question was woken.
    public var woke: Bool

    public init(sent: Int = 1, to: SwarmRecipient, woke: Bool = false) {
        self.sent = sent
        self.to = to
        self.woke = woke
    }

    enum CodingKeys: String, CodingKey { case sent, to, woke }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let n = try? c.decodeIfPresent(Int.self, forKey: .sent) {
            sent = n
        } else if let b = try? c.decodeIfPresent(Bool.self, forKey: .sent) {
            sent = b ? 1 : 0
        } else {
            sent = 1
        }
        to = c.swarmValue(.to, .all)
        woke = c.swarmFlag(.woke)
    }
}

// MARK: - one agent

public struct SwarmAgent: Codable, Hashable, Sendable {
    /// One line of what the agent did ("read seventv.set", "proposed 17 changes").
    public struct Step: Codable, Hashable, Sendable {
        public var at: Date
        public var text: String

        public init(at: Date, text: String) {
            self.at = at
            self.text = text
        }

        enum CodingKeys: String, CodingKey { case at, text }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            at = c.swarmValue(.at, Date(timeIntervalSince1970: 0))
            text = c.swarmValue(.text, "")
        }
    }

    public var swarm: String
    /// From 1.
    public var agent: Int
    public var status: SwarmCell.Status
    /// The items it was given.
    public var items: [JSONValue]
    public var attempts: Int
    public var inTokens: Int
    public var outTokens: Int
    public var usd: Double
    public var startedAt: Date?
    public var endedAt: Date?
    public var error: String?
    public var result: JSONValue?
    public var steps: [Step]
    public var messages: [SwarmMessage]
    /// Propose mode: the changes this agent found.
    public var changes: [SwarmChange]

    public init(
        swarm: String, agent: Int, status: SwarmCell.Status = .queued, items: [JSONValue] = [], attempts: Int = 0, inTokens: Int = 0,
        outTokens: Int = 0, usd: Double = 0, startedAt: Date? = nil, endedAt: Date? = nil, error: String? = nil,
        result: JSONValue? = nil, steps: [Step] = [], messages: [SwarmMessage] = [], changes: [SwarmChange] = []
    ) {
        self.swarm = swarm
        self.agent = agent
        self.status = status
        self.items = items
        self.attempts = attempts
        self.inTokens = inTokens
        self.outTokens = outTokens
        self.usd = usd
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.error = error
        self.result = result
        self.steps = steps
        self.messages = messages
        self.changes = changes
    }

    enum CodingKeys: String, CodingKey {
        case swarm, agent, status, items, attempts, inTokens = "in_tokens", outTokens = "out_tokens", usd
        case startedAt = "started_at", endedAt = "ended_at", error, result, steps, messages, changes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        swarm = c.swarmValue(.swarm, "")
        agent = try c.decode(Int.self, forKey: .agent)
        status = c.swarmValue(.status, .queued)
        items = c.swarmValue(.items, [])
        attempts = c.swarmValue(.attempts, 0)
        inTokens = c.swarmValue(.inTokens, 0)
        outTokens = c.swarmValue(.outTokens, 0)
        usd = c.swarmValue(.usd, 0)
        startedAt = c.swarmOptional(.startedAt)
        endedAt = c.swarmOptional(.endedAt)
        error = c.swarmOptional(.error)
        result = c.swarmOptional(.result)
        steps = c.swarmList(.steps)
        messages = c.swarmList(.messages)
        changes = c.swarmList(.changes)
    }

    /// How long it ran, when both ends are known.
    public var seconds: Double? {
        guard let startedAt, let endedAt else { return nil }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }
}

// MARK: - list answers

/// `GET /swarms`: `{ swarms }`.
struct SwarmListWire: Decodable {
    var swarms: [Swarm]

    enum CodingKeys: String, CodingKey { case swarms }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        swarms = c.swarmList(.swarms)
    }
}

/// `GET /swarms/<id>/messages`: `{ messages }`.
struct SwarmMessagesWire: Decodable {
    var messages: [SwarmMessage]

    enum CodingKeys: String, CodingKey { case messages }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = c.swarmList(.messages)
    }
}
