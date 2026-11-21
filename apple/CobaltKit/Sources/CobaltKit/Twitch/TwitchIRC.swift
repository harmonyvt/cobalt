import Foundation

// Twitch chat speaks IRC over a WebSocket (wss://irc-ws.chat.twitch.tv), with IRCv3 tags carrying the badges, the name
// colour, the emote positions and the reply parent (APP-API-CONTRACT 70). Pure and Sendable: the engine parses off main.

/// One IRC line: `@tags :prefix COMMAND params :trailing`.
public struct IRCMessage: Sendable, Equatable {
    public var tags: [String: String]
    public var prefix: String?
    public var command: String
    /// Middle params, then the trailing one last when there is one.
    public var params: [String]

    /// The text after ` :` (a PRIVMSG's message).
    public var trailing: String? { hasTrailing ? params.last : nil }
    var hasTrailing = false

    /// The nick of `nick!user@host`.
    public var nick: String? {
        guard let prefix else { return nil }
        return prefix.split(separator: "!", maxSplits: 1).first.map(String.init)
    }

    /// The channel of a channel command (`#name` → `name`).
    public var channel: String? {
        guard let first = params.first, first.hasPrefix("#") else { return nil }
        return String(first.dropFirst())
    }
}

public enum TwitchIRC {
    /// Parses one line (without the CRLF). Nil for an empty or broken line.
    public static func parse(_ raw: String) -> IRCMessage? {
        var rest = Substring(raw)
        while rest.last?.isNewline == true { rest = rest.dropLast() }  // "\r\n" is one Character
        guard !rest.isEmpty else { return nil }

        var tags: [String: String] = [:]
        if rest.hasPrefix("@") {
            guard let space = rest.firstIndex(of: " ") else { return nil }
            for pair in rest[rest.index(after: rest.startIndex)..<space].split(separator: ";", omittingEmptySubsequences: true) {
                if let eq = pair.firstIndex(of: "=") {
                    tags[String(pair[..<eq])] = unescape(pair[pair.index(after: eq)...])
                } else {
                    tags[String(pair)] = ""
                }
            }
            rest = rest[space...].drop(while: { $0 == " " })
        }

        var prefix: String?
        if rest.hasPrefix(":") {
            guard let space = rest.firstIndex(of: " ") else { return nil }
            prefix = String(rest[rest.index(after: rest.startIndex)..<space])
            rest = rest[space...].drop(while: { $0 == " " })
        }

        var params: [String] = []
        var hasTrailing = false
        let command: String
        if let space = rest.firstIndex(of: " ") {
            command = String(rest[..<space])
            rest = rest[space...].drop(while: { $0 == " " })
            while !rest.isEmpty {
                if rest.hasPrefix(":") {
                    params.append(String(rest.dropFirst()))
                    hasTrailing = true
                    break
                }
                if let next = rest.firstIndex(of: " ") {
                    params.append(String(rest[..<next]))
                    rest = rest[next...].drop(while: { $0 == " " })
                } else {
                    params.append(String(rest))
                    break
                }
            }
        } else {
            command = String(rest)
        }
        guard !command.isEmpty else { return nil }
        var message = IRCMessage(tags: tags, prefix: prefix, command: command.uppercased(), params: params)
        message.hasTrailing = hasTrailing
        return message
    }

    /// IRCv3 tag value escapes: `\:` `;`, `\s` space, `\\` `\`, `\r`, `\n`; a lone trailing `\` is dropped.
    public static func unescape<S: StringProtocol>(_ value: S) -> String {
        guard value.contains("\\") else { return String(value) }
        var out = ""
        out.reserveCapacity(value.count)
        var escaping = false
        for ch in value {
            if escaping {
                switch ch {
                case ":": out.append(";")
                case "s": out.append(" ")
                case "\\": out.append("\\")
                case "r": out.append("\r")
                case "n": out.append("\n")
                default: out.append(ch)
                }
                escaping = false
            } else if ch == "\\" {
                escaping = true
            } else {
                out.append(ch)
            }
        }
        return out
    }

    /// Escapes a tag value for sending.
    public static func escape(_ value: String) -> String {
        var out = ""
        for ch in value {
            switch ch {
            case ";": out += "\\:"
            case " ": out += "\\s"
            case "\\": out += "\\\\"
            case "\r": out += "\\r"
            case "\n": out += "\\n"
            default: out.append(ch)
            }
        }
        return out
    }

    /// `badges=broadcaster/1,subscriber/12` → [(broadcaster, 1), (subscriber, 12)].
    public static func badges(_ tag: String?) -> [TwitchBadgeRef] {
        guard let tag, !tag.isEmpty else { return [] }
        return tag.split(separator: ",").compactMap { part in
            let bits = part.split(separator: "/", maxSplits: 1)
            guard let set = bits.first, !set.isEmpty else { return nil }
            return TwitchBadgeRef(set: String(set), version: bits.count > 1 ? String(bits[1]) : "1")
        }
    }

    /// `color=#FF7AD9` → 0xFF7AD9.
    public static func color(_ tag: String?) -> UInt32? {
        guard var hex = tag, !hex.isEmpty else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        return v
    }

    /// `emotes=25:0-4,12-16/1902:6-10` → ranges in Unicode scalars (Twitch counts code points), sorted by start.
    public static func emoteRanges(_ tag: String?) -> [TwitchEmoteRange] {
        guard let tag, !tag.isEmpty else { return [] }
        var out: [TwitchEmoteRange] = []
        for emote in tag.split(separator: "/") {
            guard let colon = emote.firstIndex(of: ":") else { continue }
            let id = String(emote[..<colon])
            for span in emote[emote.index(after: colon)...].split(separator: ",") {
                let ends = span.split(separator: "-")
                guard ends.count == 2, let a = Int(ends[0]), let b = Int(ends[1]), a >= 0, b >= a else { continue }
                out.append(TwitchEmoteRange(id: id, start: a, end: b))
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    // MARK: lines to send

    public static func capabilities() -> String { "CAP REQ :twitch.tv/tags twitch.tv/commands" }
    public static func pass(_ token: String) -> String { "PASS oauth:\(token)" }
    public static func nick(_ login: String) -> String { "NICK \(login.lowercased())" }
    public static func join(_ channel: String) -> String { "JOIN #\(channel.lowercased())" }
    public static func part(_ channel: String) -> String { "PART #\(channel.lowercased())" }

    /// A chat message; `replyTo` is the parent message id. Line breaks are folded to spaces (IRC is one line).
    public static func privmsg(channel: String, text: String, replyTo: String? = nil) -> String {
        let flat = text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        let tags = replyTo.map { "@reply-parent-msg-id=\(escape($0)) " } ?? ""
        return "\(tags)PRIVMSG #\(channel.lowercased()) :\(flat)"
    }

    /// A read-only login for watching without an account (Twitch's anonymous `justinfan` nick).
    public static func anonymousNick(_ n: Int = Int.random(in: 10_000...99_999)) -> String { "justinfan\(n)" }
}

public struct TwitchBadgeRef: Sendable, Hashable {
    public var set: String
    public var version: String
    public init(set: String, version: String) {
        self.set = set
        self.version = version
    }
}

public struct TwitchEmoteRange: Sendable, Equatable {
    public var id: String
    /// Inclusive, in Unicode scalars.
    public var start: Int
    public var end: Int
}
