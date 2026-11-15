import Foundation

// The results board (APP-API-CONTRACT 62.3, 62.4; apple/CONTRACT-SWARMS.md 6): one board for any swarm, whatever its items
// were. Rows, each agent's outcome and score, groups, media of any kind. Nothing here is specific to emotes.

/// A picture or video a row names (62.1): a capystore post or file, a 7TV emote, any other allowlisted image or video URL.
/// The error form `{ ref, error }` decodes too (the ref could not be resolved).
public struct MediaRef: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case post, file, emote, image, video

        /// An unknown kind reads as an image: it is drawn from its preview.
        public init(from decoder: Decoder) throws {
            self = (try? decoder.singleValueContainer().decode(String.self)).flatMap(Kind.init(rawValue:)) ?? .image
        }
    }

    public var ref: String
    public var kind: Kind
    public var previewURL: URL?
    public var openURL: URL?
    public var title: String?
    public var animated: Bool?
    /// Set when the ref could not be resolved; there is then no preview.
    public var error: String?

    public init(
        ref: String, kind: Kind = .image, previewURL: URL? = nil, openURL: URL? = nil, title: String? = nil, animated: Bool? = nil,
        error: String? = nil
    ) {
        self.ref = ref
        self.kind = kind
        self.previewURL = previewURL
        self.openURL = openURL
        self.title = title
        self.animated = animated
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case ref, kind, previewURL = "preview_url", openURL = "open_url", title, animated, error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ref = c.swarmValue(.ref, "")
        kind = c.swarmValue(.kind, .image)
        previewURL = c.swarmOptional(.previewURL)
        openURL = c.swarmOptional(.openURL)
        title = c.swarmOptional(.title)
        animated = c.swarmOptional(.animated)
        error = c.swarmOptional(.error)
    }

    /// Posts and files open in the app's own viewer; emotes, images and videos by URL open in the browser.
    public var opensInApp: Bool { kind == .post || kind == .file }
}

/// How one agent did (62.3 `outcome`). `score` is 0...1: answered / items × (1 − tool_errors / max(tool_calls, 1)); 0 for a
/// failed agent.
public struct SwarmOutcome: Codable, Hashable, Sendable {
    public var status: SwarmCell.Status
    public var items: Int
    /// How many of its items appear in its rows.
    public var answered: Int
    public var toolCalls: Int
    /// Calls that still failed after the server's retries.
    public var toolErrors: Int
    public var asks: Int
    public var turns: Int
    public var usd: Double
    public var ms: Int
    public var score: Double

    public init(
        status: SwarmCell.Status = .done, items: Int = 0, answered: Int = 0, toolCalls: Int = 0, toolErrors: Int = 0, asks: Int = 0,
        turns: Int = 0, usd: Double = 0, ms: Int = 0, score: Double = 0
    ) {
        self.status = status
        self.items = items
        self.answered = answered
        self.toolCalls = toolCalls
        self.toolErrors = toolErrors
        self.asks = asks
        self.turns = turns
        self.usd = usd
        self.ms = ms
        self.score = score
    }

    enum CodingKeys: String, CodingKey {
        case status, items, answered, toolCalls = "tool_calls", toolErrors = "tool_errors", asks, turns, usd, ms, score
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = c.swarmValue(.status, .done)
        items = c.swarmValue(.items, 0)
        answered = c.swarmValue(.answered, 0)
        toolCalls = c.swarmValue(.toolCalls, 0)
        toolErrors = c.swarmValue(.toolErrors, 0)
        asks = c.swarmValue(.asks, 0)
        turns = c.swarmValue(.turns, 0)
        usd = c.swarmValue(.usd, 0)
        ms = c.swarmValue(.ms, 0)
        score = c.swarmValue(.score, 0)
    }
}

/// One agent's stored result (62.3): `GET /swarms/<id>/results`. `items` is its batch, always, even when it failed.
public struct SwarmResult: Codable, Hashable, Sendable {
    /// The task, 0-based.
    public var task: Int
    public var status: SwarmCell.Status
    public var result: JSONValue?
    public var error: String?
    public var usd: Double
    public var items: [JSONValue]
    public var outcome: SwarmOutcome?

    public var agent: Int { task + 1 }

    public init(
        task: Int, status: SwarmCell.Status = .done, result: JSONValue? = nil, error: String? = nil, usd: Double = 0,
        items: [JSONValue] = [], outcome: SwarmOutcome? = nil
    ) {
        self.task = task
        self.status = status
        self.result = result
        self.error = error
        self.usd = usd
        self.items = items
        self.outcome = outcome
    }

    enum CodingKeys: String, CodingKey { case task, status, result, error, usd, items, outcome }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        task = c.swarmValue(.task, 0)
        status = c.swarmValue(.status, .queued)
        result = c.swarmOptional(.result)
        error = c.swarmOptional(.error)
        usd = c.swarmValue(.usd, 0)
        items = c.swarmValue(.items, [])
        outcome = c.swarmOptional(.outcome)
    }
}

// MARK: - the board

/// How the board is ordered (`?sort=`).
public enum BoardSort: String, Codable, Hashable, Sendable, CaseIterable {
    case agent, score, title
}

/// One key and value of a row, as text: numbers, bools and null are written out ("0.75", "yes", "none").
public struct BoardField: Codable, Hashable, Sendable {
    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }

    /// A plain JSON value as the text a card shows.
    static func text(_ value: JSONValue) -> String {
        switch value {
        case .null: return "none"
        case .bool(let b): return b ? "yes" : "no"
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .string(let s): return s
        case .array, .dictionary: return value.display
        }
    }
}

public struct BoardGroup: Codable, Hashable, Sendable {
    public var value: String
    public var count: Int

    public init(value: String, count: Int) {
        self.value = value
        self.count = count
    }

    enum CodingKeys: String, CodingKey { case value, count }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = c.swarmValue(.value, "")
        count = c.swarmValue(.count, 0)
    }
}

/// One cell of the agent strip: every agent, with how it did.
public struct BoardAgent: Codable, Hashable, Sendable, Identifiable {
    public var agent: Int
    public var id: Int { agent }
    public var status: SwarmCell.Status
    public var outcome: SwarmOutcome?
    public var error: String?

    public init(agent: Int, status: SwarmCell.Status = .done, outcome: SwarmOutcome? = nil, error: String? = nil) {
        self.agent = agent
        self.status = status
        self.outcome = outcome
        self.error = error
    }

    enum CodingKeys: String, CodingKey { case agent, status, outcome, error }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agent = try c.decode(Int.self, forKey: .agent)
        status = c.swarmValue(.status, .queued)
        outcome = c.swarmOptional(.outcome)
        error = c.swarmOptional(.error)
    }

    /// 0...1 for the strip's colour; a failed or unfinished agent has none (it is drawn red or grey).
    public var score: Double? { status == .done ? outcome?.score : nil }
}

/// One card of the board.
public struct BoardRow: Decodable, Hashable, Sendable, Identifiable {
    /// From 1.
    public var agent: Int
    public var n: Int
    public var id: String { "\(agent)-\(n)" }
    public var title: String?
    /// 0...1, or nil when the row has none.
    public var score: Double?
    public var group: String?
    /// The other plain values, in the order the server wrote them (at most 12).
    public var fields: [BoardField]
    /// At most 4, resolved.
    public var media: [MediaRef]
    public var links: [URL]

    public init(
        agent: Int, n: Int, title: String? = nil, score: Double? = nil, group: String? = nil, fields: [BoardField] = [],
        media: [MediaRef] = [], links: [URL] = []
    ) {
        self.agent = agent
        self.n = n
        self.title = title
        self.score = score
        self.group = group
        self.fields = fields
        self.media = media
        self.links = links
    }

    enum CodingKeys: String, CodingKey { case agent, n, title, score, group, fields, media, links }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agent = c.swarmValue(.agent, 0)
        n = c.swarmValue(.n, 0)
        title = c.swarmOptional(.title)
        score = c.swarmOptional(.score)
        group = c.swarmOptional(.group)
        media = c.swarmList(.media)
        links = (c.swarmOptional(.links) as [String]? ?? []).filter { !$0.isEmpty }.compactMap { URL(string: $0) }
        // `fields` is a JSON object: its keys in the order the server wrote them, when `SwarmBoard.decode` scanned them
        // (a plain decoder cannot know the order and falls back to sorted keys). Numbers, bools and null become text.
        let object: [String: JSONValue] = c.swarmValue(.fields, [:])
        var order: [String] = []
        if let orders = decoder.userInfo[SwarmBoard.fieldOrderKey] as? [[String]], let index = decoder.codingPath.last?.intValue,
            orders.indices.contains(index)
        {
            order = orders[index].filter { object[$0] != nil }
        }
        let rest = object.keys.filter { !order.contains($0) }.sorted()
        fields = (order + rest).compactMap { key in object[key].map { BoardField(key: key, value: BoardField.text($0)) } }
    }

    /// The text of a field.
    public func field(_ key: String) -> String? { fields.first { $0.key == key }?.value }

    /// A failed or skipped agent's row (62.4): its items sit in `fields.items`.
    public var isFailedAgent: Bool { title?.hasPrefix("agent \(agent) failed") == true || title?.hasPrefix("agent \(agent) skipped") == true }
}

/// `GET /swarms/<id>/board`: one page of rows, every agent, and the groups.
public struct SwarmBoard: Decodable, Hashable, Sendable {
    public var swarm: Swarm
    public var total: Int
    public var offset: Int
    public var groups: [BoardGroup]
    public var agents: [BoardAgent]
    public var rows: [BoardRow]

    public init(swarm: Swarm, total: Int = 0, offset: Int = 0, groups: [BoardGroup] = [], agents: [BoardAgent] = [], rows: [BoardRow] = []) {
        self.swarm = swarm
        self.total = total
        self.offset = offset
        self.groups = groups
        self.agents = agents
        self.rows = rows
    }

    enum CodingKeys: String, CodingKey { case swarm, total, offset, groups, agents, rows }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        swarm = try c.decode(Swarm.self, forKey: .swarm)
        let rows: [BoardRow] = c.swarmList(.rows)
        self.rows = rows
        total = c.swarmValue(.total, rows.count)
        offset = c.swarmValue(.offset, 0)
        groups = c.swarmList(.groups)
        agents = c.swarmList(.agents)
    }

    /// More rows can be read after these.
    public var hasMore: Bool { offset + rows.count < total }

    /// This page and the next together (the next page's agents and groups are the same as ever).
    public func appending(_ next: SwarmBoard) -> SwarmBoard {
        var out = next
        out.offset = offset
        out.rows = rows + next.rows
        return out
    }

    // MARK: decoding with the fields in the server's order

    static let fieldOrderKey = CodingUserInfoKey(rawValue: "swarm.board.fieldOrder")!

    /// Decodes a board answer keeping each row's `fields` in the order the server wrote them (a JSON object has an order, a
    /// Swift dictionary does not, so the keys are read off the text first).
    public static func decode(_ data: Data) throws -> SwarmBoard {
        let decoder = SwarmWire.decoder()
        decoder.userInfo[fieldOrderKey] = BoardFieldOrder.scan(data)
        return try decoder.decode(SwarmBoard.self, from: data)
    }
}

// MARK: - reading the order of a row's fields

/// A minimal JSON reader that keeps what `JSONDecoder` loses: the order of an object's keys. It reads the whole text into a
/// tree (scalars are not kept) and returns, for each element of the top-level `rows` array, the keys of its `fields` object.
enum BoardFieldOrder {
    private indirect enum Node {
        case object([(String, Node)])
        case array([Node])
        case scalar
    }

    static func scan(_ data: Data) -> [[String]] {
        var parser = Parser(bytes: [UInt8](data))
        guard case .object(let top)? = parser.value() else { return [] }
        guard case .array(let rows)? = top.first(where: { $0.0 == "rows" })?.1 else { return [] }
        return rows.map { row in
            guard case .object(let members) = row, case .object(let fields)? = members.first(where: { $0.0 == "fields" })?.1 else { return [] }
            return fields.map(\.0)
        }
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func skip() {
            while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x0A || bytes[i] == 0x0D || bytes[i] == 0x09 { i += 1 }
        }

        mutating func value() -> Node? {
            skip()
            guard i < bytes.count else { return nil }
            switch bytes[i] {
            case UInt8(ascii: "{"):
                i += 1
                var members: [(String, Node)] = []
                skip()
                if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
                while i < bytes.count {
                    skip()
                    guard let key = string() else { return nil }
                    skip()
                    guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { return nil }
                    i += 1
                    guard let v = value() else { return nil }
                    members.append((key, v))
                    skip()
                    guard i < bytes.count else { return nil }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
                    return nil
                }
                return nil
            case UInt8(ascii: "["):
                i += 1
                var items: [Node] = []
                skip()
                if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                while i < bytes.count {
                    guard let v = value() else { return nil }
                    items.append(v)
                    skip()
                    guard i < bytes.count else { return nil }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                    return nil
                }
                return nil
            case UInt8(ascii: "\""):
                return string() == nil ? nil : .scalar
            default:
                // a number, true, false or null: up to the next delimiter
                let start = i
                while i < bytes.count, ![0x2C, 0x7D, 0x5D, 0x20, 0x0A, 0x0D, 0x09].contains(bytes[i]) { i += 1 }
                return i > start ? .scalar : nil
            }
        }

        /// A string with its escapes read (a key's spelling must match what `JSONDecoder` makes of it).
        mutating func string() -> String? {
            guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { return nil }
            i += 1
            var out = [UInt8]()
            var units: [UInt16] = []
            func flush() {
                if !units.isEmpty {
                    out.append(contentsOf: Array(String(decoding: units, as: UTF16.self).utf8))
                    units = []
                }
            }
            while i < bytes.count {
                let b = bytes[i]
                if b == UInt8(ascii: "\"") {
                    i += 1
                    flush()
                    return String(decoding: out, as: UTF8.self)
                }
                if b == UInt8(ascii: "\\") {
                    i += 1
                    guard i < bytes.count else { return nil }
                    let e = bytes[i]
                    i += 1
                    switch e {
                    case UInt8(ascii: "u"):
                        guard i + 4 <= bytes.count, let v = UInt16(String(decoding: bytes[i..<i + 4], as: UTF8.self), radix: 16) else { return nil }
                        units.append(v)
                        i += 4
                    default:
                        flush()
                        switch e {
                        case UInt8(ascii: "n"): out.append(0x0A)
                        case UInt8(ascii: "t"): out.append(0x09)
                        case UInt8(ascii: "r"): out.append(0x0D)
                        case UInt8(ascii: "b"): out.append(0x08)
                        case UInt8(ascii: "f"): out.append(0x0C)
                        default: out.append(e)             // " \ /
                        }
                    }
                } else {
                    flush()
                    out.append(b)
                    i += 1
                }
            }
            return nil
        }
    }
}
