import Foundation

// 7TV's public v3 API and its EventAPI, as chat needs them (APP-API-CONTRACT 70): a channel's emote set by Twitch id, the
// global set, live set changes, and the cosmetics (paints and badges) of the people chatting. No account needed, nothing
// stored. Decoded off main (`TwitchChatEngine`); every field is optional so one odd entry never loses the rest.

enum SevenTvChatWire {
    static let api = URL(string: "https://7tv.io/v3")!
    static let gqlURL = URL(string: "https://7tv.io/v3/gql")!
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
        var frameCount: Int?
    }

    struct Host: Decodable {
        var url: String?
        var files: [File]?

        /// `//cdn.7tv.app/emote/<id>` + the 2x webp (or the first 2x file, else the first file).
        func picture(prefer: String = "2x") -> (URL, Double)? {
            guard let picked = pickFile(prefer: prefer) else { return nil }
            return (picked.url, picked.aspect)
        }

        /// Badge URL and whether it is animated (`frame_count > 1`).
        func badgePicture(prefer: String = "2x") -> (url: URL, animated: Bool)? {
            guard let picked = pickFile(prefer: prefer) else { return nil }
            return (picked.url, picked.animated)
        }

        private func pickFile(prefer: String) -> (url: URL, aspect: Double, animated: Bool)? {
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
            let animated = (pick?.frameCount ?? 1) > 1
            return (u, aspect, animated)
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

    /// Decodes either a 7TV v3 signed 32-bit RGBA integer or a v4 hex color (`"#RRGGBB"`, `"#RRGGBBAA"`, or `{"hex": "..."}`).
    struct WireColor: Decodable {
        let rgba: UInt32?

        private struct HexBox: Decodable { var hex: String? }

        init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let intVal = try? single.decode(Int64.self) {
                self.rgba = UInt32(truncatingIfNeeded: intVal)
            } else if let hex = try? single.decode(String.self) {
                self.rgba = Self.parseHex(hex)
            } else if let box = try? single.decode(HexBox.self), let hex = box.hex {
                self.rgba = Self.parseHex(hex)
            } else {
                self.rgba = nil
            }
        }

        static func parseHex(_ raw: String) -> UInt32? {
            let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
            if clean.count == 6, let rgb = UInt32(clean, radix: 16) {
                return (rgb << 8) | 0xFF
            }
            if clean.count == 8, let rgba = UInt32(clean, radix: 16) {
                return rgba
            }
            return nil
        }
    }

    struct Stop: Decodable {
        var at: Double?
        var color: WireColor?
    }

    struct Shadow: Decodable {
        var xOffset: Double?
        var yOffset: Double?
        var offsetX: Double?
        var offsetY: Double?
        var radius: Double?
        var blur: Double?
        var color: WireColor?
    }

    struct LayerImage: Decodable {
        var url: String?
        var mime: String?
        var frameCount: Int?
        var scale: Int?
    }

    struct PaintLayerTypeWire: Decodable {
        var __typename: String?
        var angle: Double?
        var repeating: Bool?
        var `repeat`: Bool?
        var shape: String?
        var color: WireColor?
        var stops: [Stop]?
        var images: [LayerImage]?
        var imageUrl: String?
    }

    struct PaintLayerWire: Decodable {
        var id: String?
        var opacity: Double?
        var function: String?
        var color: WireColor?
        var angle: Double?
        var `repeat`: Bool?
        var repeating: Bool?
        var shape: String?
        var imageUrl: String?
        var stops: [Stop]?
        var ty: PaintLayerTypeWire?
    }

    struct AnimationWire: Decodable {
        var mode: String?
        var speed: Double?
        var intensity: Double?
    }

    struct CosmeticData: Decodable {
        var id: String?
        var name: String?
        var tooltip: String?
        var function: String?
        var color: WireColor?
        var angle: Double?
        var `repeat`: Bool?
        var shape: String?
        var imageUrl: String?
        var stops: [Stop]?
        var shadows: [Shadow]?
        var layers: [PaintLayerWire]?
        var animation: AnimationWire?
        var host: Host?
    }

    // MARK: v3 GraphQL batch user cosmetics

    struct GQLUserStyle: Decodable {
        var paint: CosmeticData?
        var badge: CosmeticData?
    }

    struct GQLUser: Decodable {
        var style: GQLUserStyle?
    }

    struct GQLCosmeticsResponse: Decodable {
        var data: [String: GQLUser?]?
    }

    private struct GQLBody: Encodable {
        var query: String
    }

    /// Batched `userByConnection` query for up to ~8 Twitch user IDs (stays well under 7TV's GQL complexity cap).
    static func cosmeticsQueryBody(userIDs: [String]) -> Data? {
        let safe = userIDs.filter { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
        guard !safe.isEmpty else { return nil }
        let fields = """
            style { \
            paint { id name color function repeat angle shape image_url stops { at color } shadows { x_offset y_offset radius color } } \
            badge { id name tooltip host { url files { name format frame_count } } } \
            }
            """
        let aliases = safe.enumerated().map { idx, id in
            "u\(idx): userByConnection(platform: TWITCH, id: \"\(id)\") { \(fields) }"
        }.joined(separator: " ")
        return try? JSONEncoder().encode(GQLBody(query: "query { \(aliases) }"))
    }

    /// 7TV colours are signed 32-bit RGBA ints.
    static func rgba(_ v: Int64?) -> UInt32? {
        guard let v else { return nil }
        return UInt32(truncatingIfNeeded: v)
    }

    private static func nonZeroRGBA(_ c: WireColor?) -> UInt32? {
        guard let v = c?.rgba, v != 0 else { return nil }
        return v
    }

    private static func normalizeURL(_ raw: String?) -> URL? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed.hasPrefix("//") ? "https:" + trimmed : trimmed)
    }

    private static func decodeStops(_ wire: [Stop]?) -> [SevenTvPaint.Stop] {
        (wire ?? []).compactMap { s -> SevenTvPaint.Stop? in
            guard let c = s.color?.rgba else { return nil }
            return SevenTvPaint.Stop(at: max(0, min(1, s.at ?? 0)), rgba: c)
        }
    }

    private static func decodeLayer(_ wire: PaintLayerWire) -> SevenTvPaint.Layer? {
        let opacity = max(0, min(1, wire.opacity ?? 1))
        if let ty = wire.ty {
            let kindName = (ty.__typename ?? "").uppercased()
            let stops = decodeStops(ty.stops)
            let repeats = ty.repeating ?? ty.repeat ?? false
            let shape = SevenTvPaint.RadialShape(wireValue: ty.shape)
            if kindName.contains("IMAGE") {
                let images = ty.images ?? []
                let picked = images.first { ($0.frameCount ?? 1) > 1 && ($0.scale ?? 1) == 2 && ($0.mime ?? "").contains("webp") }
                    ?? images.first { ($0.frameCount ?? 1) > 1 && ($0.mime ?? "").contains("webp") }
                    ?? images.first { ($0.frameCount ?? 1) > 1 }
                    ?? images.first { ($0.scale ?? 1) == 2 }
                    ?? images.first
                let url = normalizeURL(picked?.url ?? ty.imageUrl)
                guard let url else { return nil }
                let animated = picked.map { ($0.frameCount ?? 1) > 1 } ?? SevenTvPaint.Layer.inferAnimatedImage(url: url)
                return SevenTvPaint.Layer(
                    kind: .image,
                    color: nonZeroRGBA(ty.color),
                    imageURL: url,
                    opacity: opacity,
                    animatedImage: animated
                )
            }
            if kindName.contains("RADIAL"), stops.count >= 2 {
                return SevenTvPaint.Layer(
                    kind: .radial,
                    angle: ty.angle ?? 0,
                    shape: shape,
                    repeats: repeats,
                    stops: stops,
                    color: nonZeroRGBA(ty.color) ?? stops.first?.rgba,
                    opacity: opacity
                )
            }
            if kindName.contains("LINEAR"), stops.count >= 2 {
                return SevenTvPaint.Layer(
                    kind: .linear,
                    angle: ty.angle ?? 90,
                    shape: shape,
                    repeats: repeats,
                    stops: stops,
                    color: nonZeroRGBA(ty.color) ?? stops.first?.rgba,
                    opacity: opacity
                )
            }
            guard let color = nonZeroRGBA(ty.color) ?? stops.first?.rgba else { return nil }
            return SevenTvPaint.Layer(kind: .plain, color: color, opacity: opacity)
        }

        let fn = (wire.function ?? "").uppercased()
        let stops = decodeStops(wire.stops)
        let repeats = wire.repeat ?? wire.repeating ?? false
        let shape = SevenTvPaint.RadialShape(wireValue: wire.shape)
        if fn == "URL" || fn == "IMAGE", let url = normalizeURL(wire.imageUrl) {
            return SevenTvPaint.Layer(
                kind: .image,
                color: nonZeroRGBA(wire.color),
                imageURL: url,
                opacity: opacity,
                animatedImage: SevenTvPaint.Layer.inferAnimatedImage(url: url)
            )
        }
        if fn.contains("RADIAL"), stops.count >= 2 {
            return SevenTvPaint.Layer(
                kind: .radial,
                angle: wire.angle ?? 0,
                shape: shape,
                repeats: repeats,
                stops: stops,
                color: nonZeroRGBA(wire.color) ?? stops.first?.rgba,
                opacity: opacity
            )
        }
        if fn.contains("LINEAR"), stops.count >= 2 {
            return SevenTvPaint.Layer(
                kind: .linear,
                angle: wire.angle ?? 90,
                shape: shape,
                repeats: repeats,
                stops: stops,
                color: nonZeroRGBA(wire.color) ?? stops.first?.rgba,
                opacity: opacity
            )
        }
        guard let color = nonZeroRGBA(wire.color) ?? stops.first?.rgba else { return nil }
        return SevenTvPaint.Layer(kind: .plain, color: color, opacity: opacity)
    }

    private static func decodeAnimation(_ wire: AnimationWire?) -> SevenTvPaint.Animation? {
        guard let wire, let rawMode = wire.mode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let mode = SevenTvPaint.Animation.Mode(rawValue: rawMode)
        else { return nil }
        return SevenTvPaint.Animation(
            mode: mode,
            speed: wire.speed ?? 0.18,
            intensity: wire.intensity ?? 0.5
        )
    }

    static func paint(_ data: CosmeticData, id: String) -> SevenTvPaint? {
        let shadows = (data.shadows ?? []).compactMap { s -> SevenTvPaint.Shadow? in
            guard let c = s.color?.rgba, (c & 0xFF) > 0 else { return nil }
            return SevenTvPaint.Shadow(
                xOffset: s.xOffset ?? s.offsetX ?? 0,
                yOffset: s.yOffset ?? s.offsetY ?? 0,
                radius: max(0, s.radius ?? s.blur ?? 0),
                rgba: c
            )
        }
        let baseColor = nonZeroRGBA(data.color)
        let explicitAnimation = decodeAnimation(data.animation)

        // Multi-layer paint (v4 or extended EventAPI/GQL payload)
        if let rawLayers = data.layers, !rawLayers.isEmpty {
            let layers = rawLayers.compactMap(decodeLayer)
            if let primary = layers.last ?? layers.first {
                return SevenTvPaint(
                    id: id,
                    name: data.name ?? "",
                    kind: primary.kind,
                    angle: primary.angle,
                    shape: primary.shape,
                    repeats: primary.repeats,
                    stops: primary.stops,
                    color: baseColor ?? primary.color ?? shadows.first?.rgba,
                    imageURL: primary.imageURL,
                    shadows: shadows,
                    layers: layers,
                    animation: explicitAnimation
                )
            }
        }

        let fn = (data.function ?? "").uppercased()
        let stops = decodeStops(data.stops)
        let shape = SevenTvPaint.RadialShape(wireValue: data.shape)
        let imageURL = normalizeURL(data.imageUrl)

        if fn == "URL", let imageURL {
            return SevenTvPaint(
                id: id, name: data.name ?? "", kind: .image, angle: 0, shape: shape, repeats: false, stops: [],
                color: baseColor ?? shadows.first?.rgba, imageURL: imageURL, shadows: shadows,
                animation: explicitAnimation)
        }
        if fn.contains("RADIAL"), stops.count >= 2 {
            return SevenTvPaint(
                id: id, name: data.name ?? "", kind: .radial, angle: data.angle ?? 90, shape: shape,
                repeats: data.repeat ?? false, stops: stops, color: baseColor ?? stops.first?.rgba,
                imageURL: nil, shadows: shadows, animation: explicitAnimation)
        }
        if fn.contains("LINEAR"), stops.count >= 2 {
            return SevenTvPaint(
                id: id, name: data.name ?? "", kind: .linear, angle: data.angle ?? 90, shape: shape,
                repeats: data.repeat ?? false, stops: stops, color: baseColor ?? stops.first?.rgba,
                imageURL: nil, shadows: shadows, animation: explicitAnimation)
        }
        guard let color = baseColor ?? stops.first?.rgba else { return nil }
        return SevenTvPaint(
            id: id, name: data.name ?? "", kind: .plain, angle: data.angle ?? 90, shape: shape, repeats: false,
            stops: stops, color: color, imageURL: nil, shadows: shadows, animation: explicitAnimation)
    }

    static func badge(_ data: CosmeticData, id: String) -> ChatBadge? {
        guard let picked = data.host?.badgePicture() else { return nil }
        return ChatBadge(id: "7tv:\(id)", title: data.tooltip ?? data.name ?? "7tv", url: picked.url, animated: picked.animated)
    }

    static func subscribe(type: String, condition: [String: String]) -> String {
        let cond = condition.sorted { $0.key < $1.key }.map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",")
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
            // `convertFromSnakeCase` turns `image_url_2x` into `imageUrl2X` (capital X).
            var imageUrl1X: String?
            var imageUrl2X: String?
            var imageUrl4X: String?

            var bestURL: URL? {
                (imageUrl2X ?? imageUrl4X ?? imageUrl1X).flatMap(URL.init(string:))
            }
        }
        var setId: String
        var versions: [Version]
    }

    struct UserEmote: Decodable {
        var id: String
        var name: String
        var format: [String]?
        var emoteType: String?
        var ownerId: String?
    }

    /// `chat/emotes?broadcaster_id=`: every emote the channel has, whether or not the user can send it.
    struct ChannelEmote: Decodable {
        var id: String
        var name: String
        var format: [String]?
        var emoteType: String?
        var tier: String?
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

// MARK: - Twitch GQL badges (public fallback when read-only / unauthenticated)

enum TwitchBadgeGQL {
    static let url = URL(string: "https://gql.twitch.tv/gql")!

    struct Badge: Decodable {
        var setID: String
        var version: String
        var title: String?
        var imageURL: String?
    }

    struct GlobalResponse: Decodable {
        struct Payload: Decodable { var badges: [Badge]? }
        var data: Payload?
    }

    struct ChannelResponse: Decodable {
        struct User: Decodable {
            var id: String?
            var broadcastBadges: [Badge]?
        }
        struct Payload: Decodable { var user: User? }
        var data: Payload?
    }

    private struct GlobalRequest: Encodable {
        var query: String
    }

    private struct ChannelRequest: Encodable {
        struct Variables: Encodable { var login: String }
        var query: String
        var variables: Variables
    }

    static func globalRequestBody() -> Data? {
        try? JSONEncoder().encode(GlobalRequest(
            query: "query { badges { setID version title imageURL(size: DOUBLE) } }"))
    }

    static func channelRequestBody(login: String) -> Data? {
        try? JSONEncoder().encode(ChannelRequest(
            query: "query ChannelBadges($login: String!) { user(login: $login) { id broadcastBadges { setID version title imageURL(size: DOUBLE) } } }",
            variables: .init(login: login.lowercased())))
    }

    static func map(_ badges: [Badge]) -> [String: ChatBadge] {
        var out: [String: ChatBadge] = [:]
        for b in badges {
            guard let raw = b.imageURL, let url = URL(string: raw) else { continue }
            let key = "\(b.setID)/\(b.version)"
            out[key] = ChatBadge(id: key, title: b.title ?? b.setID, url: url)
        }
        return out
    }
}
