import Foundation

// 7TV's public v3 API and its EventAPI, as chat needs them (APP-API-CONTRACT 70): a channel's emote set by Twitch id, the
// global set, live set changes, and the cosmetics (paints and badges) of the people chatting. No account needed, nothing
// stored. Decoded off main (`TwitchChatEngine`); every field is optional so one odd entry never loses the rest.

enum SevenTvChatWire {
    static let api = URL(string: "https://7tv.io/v3")!
    static let events = URL(string: "wss://events.7tv.io/v3")!

    static func userURL(twitchID: String) -> URL { api.appendingPathComponent("users/twitch/\(twitchID)") }
    static let globalURL = api.appendingPathComponent("emote-sets/global")

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    // MARK: emote sets

    struct File: Decodable {
        var name: String?
        var width: Double?
        var height: Double?
        var format: String?
    }

    struct Host: Decodable {
        var url: String?
        var files: [File]?

        /// `//cdn.7tv.app/emote/<id>` + the 2x webp (or the first 2x file, else the first file).
        func picture(prefer: String = "2x") -> (URL, Double)? {
            guard let base = url, !base.isEmpty else { return nil }
            let files = files ?? []
            let pick = files.first { ($0.name ?? "").hasPrefix(prefer) && ($0.format ?? "").uppercased() == "WEBP" }
                ?? files.first { ($0.name ?? "").hasPrefix(prefer) }
                ?? files.first
            let name = pick?.name ?? "\(prefer).webp"
            let full = (base.hasPrefix("//") ? "https:" + base : base) + "/" + name
            guard let u = URL(string: full) else { return nil }
            var aspect = 1.0
            if let w = pick?.width, let h = pick?.height, h > 0 { aspect = w / h }
            return (u, aspect)
        }
    }

    struct EmoteData: Decodable {
        var id: String?
        var name: String?
        var flags: Int?
        var animated: Bool?
        var host: Host?
    }

    struct ActiveEmote: Decodable {
        var id: String?
        var name: String?
        var flags: Int?
        var data: EmoteData?

        func emote(global: Bool) -> ChatEmote? {
            guard let id = id ?? data?.id, let name, !name.isEmpty, let (url, aspect) = data?.host?.picture() else { return nil }
            // the set entry's flag 1 or the emote's own flag 256 (1 << 8): zero-width
            let zero = ((flags ?? 0) & 1) != 0 || ((data?.flags ?? 0) & 256) != 0
            return ChatEmote(
                id: id, name: name, url: url, animated: data?.animated ?? false, zeroWidth: zero, aspect: aspect,
                source: global ? .sevenTvGlobal : .sevenTv)
        }
    }

    struct EmoteSet: Decodable {
        var id: String?
        var name: String?
        var emotes: [ActiveEmote]?
    }

    struct User: Decodable {
        struct Inner: Decodable { var id: String? }
        var id: String?
        var emoteSet: EmoteSet?
        var user: Inner?
    }

    // MARK: EventAPI

    struct Envelope: Decodable {
        var op: Int
        var d: Payload?
    }

    struct Payload: Decodable {
        // hello (op 1)
        var heartbeatInterval: Double?
        var sessionId: String?
        // dispatch (op 0)
        var type: String?
        var body: Body?
    }

    struct Body: Decodable {
        var id: String?
        var object: Object?
        var pushed: [Change]?
        var pulled: [Change]?
        var updated: [Change]?
    }

    struct Change: Decodable {
        var key: String?
        var value: ActiveEmote?
        var oldValue: ActiveEmote?
    }

    struct Object: Decodable {
        var id: String?
        var kind: String?
        /// entitlement: the cosmetic it grants.
        var refId: String?
        var user: EventUser?
        /// cosmetic: the paint or badge.
        var data: CosmeticData?
    }

    struct Connection: Decodable {
        var platform: String?
        var id: String?
        var username: String?
    }

    struct EventUser: Decodable {
        var id: String?
        var username: String?
        var connections: [Connection]?

        var twitchLogin: String? {
            connections?.first { ($0.platform ?? "").uppercased() == "TWITCH" }?.username?.lowercased()
        }
    }

    struct Stop: Decodable {
        var at: Double?
        var color: Int64?
    }

    struct CosmeticData: Decodable {
        var id: String?
        var name: String?
        var tooltip: String?
        var function: String?
        var color: Int64?
        var angle: Double?
        var stops: [Stop]?
        var host: Host?
    }

    /// 7TV colours are signed 32-bit RGBA ints.
    static func rgba(_ v: Int64?) -> UInt32? {
        guard let v else { return nil }
        return UInt32(truncatingIfNeeded: v)
    }

    static func paint(_ data: CosmeticData, id: String) -> SevenTvPaint? {
        let fn = (data.function ?? "").uppercased()
        let kind: SevenTvPaint.Kind = fn.contains("RADIAL") ? .radial : fn.contains("LINEAR") ? .linear : .plain
        let stops = (data.stops ?? []).compactMap { s -> SevenTvPaint.Stop? in
            guard let c = rgba(s.color) else { return nil }
            return SevenTvPaint.Stop(at: max(0, min(1, s.at ?? 0)), rgba: c)
        }
        let color = rgba(data.color) ?? stops.first?.rgba
        // an image paint (`URL`) has no stops: drawn in its colour, when it has one
        if kind != .plain && stops.count < 2 && color == nil { return nil }
        return SevenTvPaint(
            id: id, name: data.name ?? "", kind: stops.count >= 2 ? kind : .plain, angle: data.angle ?? 90, stops: stops, color: color)
    }

    static func badge(_ data: CosmeticData, id: String) -> ChatBadge? {
        guard let (url, _) = data.host?.picture() else { return nil }
        return ChatBadge(id: "7tv:\(id)", title: data.tooltip ?? data.name ?? "7tv", url: url)
    }

    static func subscribe(type: String, condition: [String: String]) -> String {
        let cond = condition.map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",")
        return "{\"op\":35,\"d\":{\"type\":\"\(type)\",\"condition\":{\(cond)}}}"
    }
}

// MARK: - Helix (Twitch's API), as the signed-in user

enum HelixWire {
    static let base = URL(string: "https://api.twitch.tv/helix")!

    struct Page<T: Decodable>: Decodable {
        var data: [T]?
    }

    struct CursorPage<T: Decodable>: Decodable {
        struct Pagination: Decodable { var cursor: String? }
        var data: [T]?
        var pagination: Pagination?
    }

    struct User: Decodable {
        var id: String
        var login: String
        var displayName: String?
        var profileImageUrl: String?
    }

    struct Stream: Decodable {
        var userId: String
        var userLogin: String
        var userName: String?
        var gameName: String?
        var title: String?
        var viewerCount: Int?
        var startedAt: String?
        var thumbnailUrl: String?
    }

    struct BadgeSet: Decodable {
        struct Version: Decodable {
            var id: String
            var title: String?
            var imageUrl2x: String?
        }
        var setId: String
        var versions: [Version]
    }

    struct UserEmote: Decodable {
        var id: String
        var name: String
        var format: [String]?
    }

    struct Clip: Decodable {
        var id: String
        var editUrl: String?
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }
}
