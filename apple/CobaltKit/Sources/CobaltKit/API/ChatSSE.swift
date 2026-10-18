import Foundation

/// The reply stream of `POST /chat/threads/<id>/messages` (APP-API-CONTRACT 27.2), parsed. Pure: feed it bytes (or
/// lines) as they arrive and it hands back the `ChatEvent`s each blank line completes.
///
/// Server-sent events: lines end in LF, CRLF or a lone CR; `event:` names the event and `data:` lines (one or more, joined
/// with a newline) carry its JSON; a line starting with `:` is a comment (the server's `: ping` every 15 s); an event
/// with no data, an unknown event name, or data that is not the event's JSON is dropped, never an error. A stream that ends
/// without its closing blank line is completed by `finish()`.
public struct ChatSSEParser: Sendable {
    private var line: [UInt8] = []
    private var sawCR = false
    private var eventName = ""
    private var dataLines: [String] = []

    public init() {}

    /// Appends the next bytes of the stream and returns the events they completed (usually none or one).
    public mutating func feed(_ bytes: some Sequence<UInt8>) -> [ChatEvent] {
        var out: [ChatEvent] = []
        for byte in bytes {
            if sawCR {
                sawCR = false
                if byte == 0x0A { continue }               // the LF of a CRLF: the CR already ended the line
            }
            switch byte {
            case 0x0D:
                sawCR = true
                endLine(into: &out)
            case 0x0A:
                endLine(into: &out)
            default:
                line.append(byte)
            }
        }
        return out
    }

    /// One whole line without its terminator (an empty line completes the event being built).
    public mutating func feed(line text: String) -> [ChatEvent] {
        var out: [ChatEvent] = []
        process(text, into: &out)
        return out
    }

    /// The stream ended: the last line, if it had no terminator, and the event being built, if its blank line never came.
    public mutating func finish() -> [ChatEvent] {
        var out: [ChatEvent] = []
        if !line.isEmpty { endLine(into: &out) }
        dispatch(into: &out)
        return out
    }

    // MARK: lines

    private mutating func endLine(into out: inout [ChatEvent]) {
        let text = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)
        process(text, into: &out)
    }

    private mutating func process(_ text: String, into out: inout [ChatEvent]) {
        if text.isEmpty {
            dispatch(into: &out)
            return
        }
        if text.hasPrefix(":") { return }                  // a comment: `: ping`
        let field: Substring
        var value: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            value = text[text.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = text[...]
            value = ""
        }
        switch field {
        case "event": eventName = String(value)
        case "data": dataLines.append(String(value))
        default: break                                     // id, retry, anything else
        }
    }

    private mutating func dispatch(into out: inout [ChatEvent]) {
        defer {
            eventName = ""
            dataLines.removeAll(keepingCapacity: true)
        }
        guard !dataLines.isEmpty else { return }
        let name = eventName.isEmpty ? "message" : eventName
        if let event = Self.event(named: name, data: Data(dataLines.joined(separator: "\n").utf8)) { out.append(event) }
    }

    // MARK: one event

    private struct MessageWire: Decodable { var message: ChatMessage }
    private struct DeltaWire: Decodable { var delta: String }
    private struct StepWire: Decodable { var step: ChatStep }
    private struct PostsWire: Decodable {
        var postIds: [String]
        var posts: [String: Lossy<LibraryPost>]?
    }
    private struct CollageWire: Decodable { var collage: ChatCollage }
    private struct TitleWire: Decodable { var thread: ChatThread }
    private struct DoneWire: Decodable { var message: ChatMessage; var thread: ChatThread }
    private struct ErrorWire: Decodable {
        var code: String
        var message: ChatMessage?
        enum CodingKeys: String, CodingKey { case code, message }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            code = try c.decode(String.self, forKey: .code)
            message = (try? c.decodeIfPresent(ChatMessage.self, forKey: .message)).flatMap { $0 }
        }
    }

    /// The event a name and its JSON make; nil for an unknown name or JSON that is not that event's.
    static func event(named name: String, data: Data) -> ChatEvent? {
        let decoder = CobaltJSON.decoder()
        switch name {
        case "user": return (try? decoder.decode(MessageWire.self, from: data)).map { .user($0.message) }
        case "assistant": return (try? decoder.decode(MessageWire.self, from: data)).map { .assistant($0.message) }
        case "text": return (try? decoder.decode(DeltaWire.self, from: data)).map { .text($0.delta) }
        case "step": return (try? decoder.decode(StepWire.self, from: data)).map { .step($0.step) }
        case "posts":
            guard let wire = try? decoder.decode(PostsWire.self, from: data) else { return nil }
            // in the order of `post_ids`; a post the map lacks is simply not there (the app draws "removed")
            var byID: [String: LibraryPost] = [:]
            for (_, lossy) in wire.posts ?? [:] { if let post = lossy.value { byID[post.id] = post } }
            let ordered = wire.postIds.compactMap { byID[$0] }
            let extra = byID.values.filter { post in !wire.postIds.contains(post.id) }
            return .posts(ids: wire.postIds, posts: ordered + extra.sorted { $0.id < $1.id })
        case "collage": return (try? decoder.decode(CollageWire.self, from: data)).map { .collage($0.collage) }
        case "title": return (try? decoder.decode(TitleWire.self, from: data)).map { .title($0.thread) }
        case "done": return (try? decoder.decode(DoneWire.self, from: data)).map { .done($0.message, $0.thread) }
        case "error": return (try? decoder.decode(ErrorWire.self, from: data)).map { .error(code: $0.code, message: $0.message) }
        default: return nil
        }
    }
}
