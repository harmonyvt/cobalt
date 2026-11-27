import Foundation
import Testing
@testable import CobaltKit

// The twitch tab's chat (APP-API-CONTRACT 70): IRC parsing, splitting a message into emotes, 7TV wire and paints.

struct TwitchIRCTests {
    @Test func aPrivmsgWithTagsParses() throws {
        let line = "@badge-info=subscriber/12;badges=broadcaster/1,subscriber/12;color=#FF7AD9;display-name=Capy;emotes=25:6-10;id=abc-1;tmi-sent-ts=1700000000000 :capy!capy@capy.tmi.twitch.tv PRIVMSG #capy :hello Kappa there\r\n"
        let m = try #require(TwitchIRC.parse(line))
        #expect(m.command == "PRIVMSG")
        #expect(m.nick == "capy")
        #expect(m.channel == "capy")
        #expect(m.trailing == "hello Kappa there")
        #expect(m.tags["display-name"] == "Capy")
        #expect(TwitchIRC.badges(m.tags["badges"]) == [TwitchBadgeRef(set: "broadcaster", version: "1"), TwitchBadgeRef(set: "subscriber", version: "12")])
        #expect(TwitchIRC.color(m.tags["color"]) == 0xFF7AD9)
        #expect(TwitchIRC.emoteRanges(m.tags["emotes"]) == [TwitchEmoteRange(id: "25", start: 6, end: 10)])
    }

    @Test func pingAndTagEscapes() throws {
        let ping = try #require(TwitchIRC.parse("PING :tmi.twitch.tv"))
        #expect(ping.command == "PING" && ping.trailing == "tmi.twitch.tv")
        let notice = try #require(TwitchIRC.parse("@system-msg=5\\sraiders\\:\\shi :tmi.twitch.tv USERNOTICE #c"))
        #expect(notice.tags["system-msg"] == "5 raiders; hi")
        #expect(notice.trailing == nil)
        #expect(TwitchIRC.escape("a b;c") == "a\\sb\\:c")
    }

    @Test func sendingLines() {
        #expect(TwitchIRC.privmsg(channel: "Capy", text: "hi\nthere") == "PRIVMSG #capy :hi there")
        #expect(TwitchIRC.privmsg(channel: "capy", text: "yes", replyTo: "m 1") == "@reply-parent-msg-id=m\\s1 PRIVMSG #capy :yes")
        #expect(TwitchIRC.anonymousNick(12345) == "justinfan12345")
    }
}

struct ChatFragmenterTests {
    private func seven(_ name: String, zero: Bool = false) -> ChatEmote {
        ChatEmote(id: name, name: name, url: URL(string: "https://cdn.7tv.app/emote/\(name)/2x.webp")!, animated: true, zeroWidth: zero, source: .sevenTv)
    }

    @Test func twitchRangesThenSevenTvWordsMentionsAndLinks() {
        let named = ["liaBox": seven("liaBox")]
        let f = ChatFragmenter.fragments(
            text: "hi Kappa liaBox @Capy see https://x.com/a ok",
            ranges: [TwitchEmoteRange(id: "25", start: 3, end: 7)], named: named)
        #expect(f == [
            .text("hi"),
            .emote(.twitch(id: "25", name: "Kappa")),
            .emote(seven("liaBox")),
            .mention("Capy"),
            .text("see"),
            .link(URL(string: "https://x.com/a")!),
            .text("ok"),
        ])
    }

    @Test func rangesCountUnicodeScalarsNotCharacters() {
        // the flag is two scalars, so Kappa starts at scalar 3
        let f = ChatFragmenter.fragments(text: "🇦🇺 Kappa", ranges: [TwitchEmoteRange(id: "25", start: 3, end: 7)], named: [:])
        #expect(f == [.text("🇦🇺"), .emote(.twitch(id: "25", name: "Kappa"))])
    }

    @Test func zeroWidthStacksOnTheEmoteBefore() {
        let named = ["liaBox": seven("liaBox"), "SnowTime": seven("SnowTime", zero: true), "Hat": seven("Hat", zero: true)]
        let f = ChatFragmenter.fragments(text: "liaBox SnowTime Hat Hat", ranges: [], named: named)
        #expect(f == [.stack(seven("liaBox"), [seven("SnowTime", zero: true), seven("Hat", zero: true), seven("Hat", zero: true)])])
        // nothing before it: drawn on its own
        #expect(ChatFragmenter.fragments(text: "Hat", ranges: [], named: named) == [.emote(seven("Hat", zero: true))])
    }

    @Test func mentionsAreWholeWords() {
        #expect(ChatFragmenter.mentions("hey @CapybaraHarmony!", login: "capybaraharmony"))
        #expect(!ChatFragmenter.mentions("capybaraharmonyfan", login: "capybaraharmony"))
    }

    @Test func completionsPutExactFirst() {
        let list = TwitchEmoteList(emotes: [seven("liaBoxing"), seven("liaBox"), seven("other")])
        #expect(list.completions(for: "liabox").map(\.name) == ["liaBox", "liaBoxing"])
        #expect(list.completions(for: "l").isEmpty)
    }

    @Test func completionsThenNamesHoldingIt() {
        let list = TwitchEmoteList(emotes: [seven("PETTHECAT"), seven("catJAM"), seven("other")])
        #expect(list.completions(for: "cat").map(\.name) == ["catJAM", "PETTHECAT"])
    }

    @Test func emoteLowercasedNameStaysInSyncOnRename() {
        var emote = seven("CatJAM")
        #expect(emote.lowercasedName == "catjam")
        emote.name = "PogU"
        #expect(emote.lowercasedName == "pogu")
    }

    @Test func chatLinePreTokenizesRenderPiecesAndSyncsOnFragmentUpdate() throws {
        let link = try #require(URL(string: "https://twitch.tv/caedrel"))
        let base = seven("liaBox")
        let hat = seven("Hat", zero: true)
        var line = TwitchChatLine(
            id: "m1",
            channel: "caedrel",
            kind: .message,
            login: "harmony",
            displayName: "harmony",
            color: nil,
            badges: [],
            fragments: [
                .text("hello   world"),
                .emote(base),
                .stack(base, [hat]),
                .mention("caedrel"),
                .link(link),
            ],
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            mentionsMe: false,
            mine: true,
            replyTo: nil
        )
        #expect(line.renderPieces == [
            .word("hello"),
            .word("world"),
            .emote(base, []),
            .emote(base, [hat]),
            .mention("caedrel"),
            .link(link),
        ])

        line.fragments = [.text("updated line")]
        #expect(line.renderPieces == [.word("updated"), .word("line")])
    }
}

struct SevenTvChatWireTests {
    @Test func aChannelSetDecodes() throws {
        let json = """
        {"id":"u1","user":{"id":"7tvuser"},"emote_set":{"id":"set1","name":"main","emotes":[
          {"id":"e1","name":"liaBox","flags":0,"data":{"id":"e1","flags":0,"animated":true,
            "host":{"url":"//cdn.7tv.app/emote/e1","files":[{"name":"1x.webp","width":32,"height":32,"format":"WEBP"},{"name":"2x.webp","width":112,"height":64,"format":"WEBP"}]}}},
          {"id":"e2","name":"Hat","flags":1,"data":{"id":"e2","animated":false,"host":{"url":"//cdn.7tv.app/emote/e2","files":[]}}},
          {"id":"e3","name":"","data":{}}
        ]}}
        """
        let user = try SevenTvChatWire.decoder().decode(SevenTvChatWire.User.self, from: Data(json.utf8))
        #expect(user.emoteSet?.id == "set1")
        let emotes = (user.emoteSet?.emotes ?? []).compactMap { $0.emote(global: false) }
        #expect(emotes.count == 2)
        #expect(emotes[0].url.absoluteString == "https://cdn.7tv.app/emote/e1/2x.webp")
        #expect(emotes[0].aspect == 112.0 / 64.0 && emotes[0].animated && !emotes[0].zeroWidth)
        #expect(emotes[1].zeroWidth && emotes[1].url.absoluteString == "https://cdn.7tv.app/emote/e2/2x.webp")
    }

    @Test func paintsAndEntitlements() throws {
        let paint = """
        {"op":0,"d":{"type":"cosmetic.create","body":{"object":{"id":"p1","kind":"PAINT","data":{"id":"p1","name":"sunset",
          "function":"LINEAR_GRADIENT","angle":45,"color":null,"stops":[{"at":0,"color":-16776961},{"at":1,"color":16711935}]}}}}}
        """
        let env = try SevenTvChatWire.decoder().decode(SevenTvChatWire.Envelope.self, from: Data(paint.utf8))
        let data = try #require(env.d?.body?.object?.data)
        let p = try #require(SevenTvChatWire.paint(data, id: "p1"))
        #expect(p.kind == .linear && p.angle == 45)
        #expect(p.stops.map(\.rgba) == [0xFF0000FF, 0x00FF00FF])

        let ent = """
        {"op":0,"d":{"type":"entitlement.create","body":{"object":{"id":"x","kind":"PAINT","ref_id":"p1",
          "user":{"id":"u","username":"capy","connections":[{"platform":"TWITCH","id":"1","username":"CapyBara"}]}}}}}
        """
        let e = try SevenTvChatWire.decoder().decode(SevenTvChatWire.Envelope.self, from: Data(ent.utf8))
        #expect(e.d?.body?.object?.refId == "p1")
        #expect(e.d?.body?.object?.user?.twitchLogin == "capybara")
        #expect(SevenTvChatWire.subscribe(type: "emote_set.update", condition: ["object_id": "s"])
            == "{\"op\":35,\"d\":{\"type\":\"emote_set.update\",\"condition\":{\"object_id\":\"s\"}}}")
    }

    @Test func helixBadgesDecodeImageUrlsWithSnakeCase() throws {
        let json = """
        {"data":[
          {"set_id":"subscriber","versions":[
            {"id":"0","image_url_1x":"https://static-cdn.jtvnw.net/badges/v1/a/1","image_url_2x":"https://static-cdn.jtvnw.net/badges/v1/a/2","image_url_4x":"https://static-cdn.jtvnw.net/badges/v1/a/3","title":"Subscriber"},
            {"id":"3","image_url_1x":"https://static-cdn.jtvnw.net/badges/v1/b/1","image_url_4x":"https://static-cdn.jtvnw.net/badges/v1/b/3","title":"3-Month"}
          ]}
        ]}
        """
        let page = try HelixWire.decoder().decode(HelixWire.Page<HelixWire.BadgeSet>.self, from: Data(json.utf8))
        let versions = try #require(page.data?.first?.versions)
        #expect(versions.count == 2)
        #expect(versions[0].bestURL?.absoluteString == "https://static-cdn.jtvnw.net/badges/v1/a/2")
        #expect(versions[1].bestURL?.absoluteString == "https://static-cdn.jtvnw.net/badges/v1/b/3")
    }

    @Test func twitchGQLBadgesDecodeGlobalAndChannel() throws {
        let globalJSON = """
        {"data":{"badges":[
          {"setID":"vip","version":"1","title":"VIP","imageURL":"https://static-cdn.jtvnw.net/badges/v1/vip/2"},
          {"setID":"broadcaster","version":"1","title":null,"imageURL":"https://static-cdn.jtvnw.net/badges/v1/b/2"}
        ]}}
        """
        let global = try JSONDecoder().decode(TwitchBadgeGQL.GlobalResponse.self, from: Data(globalJSON.utf8))
        let globalMap = TwitchBadgeGQL.map(global.data?.badges ?? [])
        #expect(globalMap["vip/1"]?.title == "VIP")
        #expect(globalMap["vip/1"]?.url.absoluteString == "https://static-cdn.jtvnw.net/badges/v1/vip/2")
        #expect(globalMap["broadcaster/1"]?.title == "broadcaster")

        let channelJSON = """
        {"data":{"user":{"id":"71092938","broadcastBadges":[
          {"setID":"subscriber","version":"12","title":"1-Year Subscriber","imageURL":"https://static-cdn.jtvnw.net/badges/v1/sub12/2"}
        ]}}}
        """
        let channel = try JSONDecoder().decode(TwitchBadgeGQL.ChannelResponse.self, from: Data(channelJSON.utf8))
        #expect(channel.data?.user?.id == "71092938")
        let channelMap = TwitchBadgeGQL.map(channel.data?.user?.broadcastBadges ?? [])
        #expect(channelMap["subscriber/12"]?.title == "1-Year Subscriber")
        #expect(TwitchBadgeGQL.globalRequestBody() != nil)
        #expect(TwitchBadgeGQL.channelRequestBody(login: "xqc") != nil)
    }

    @Test func sevenTvAnimatedBadgesImagePaintsShadowsAndRepeatingStops() throws {
        // Animated badge (frame_count > 1)
        let badgeJSON = """
        {"op":0,"d":{"type":"cosmetic.create","body":{"object":{"id":"b1","kind":"BADGE","data":{
          "id":"b1","name":"7TV Sub","tooltip":"7TV Subscriber",
          "host":{"url":"//cdn.7tv.app/badge/b1","files":[
            {"name":"1x.webp","format":"WEBP","frame_count":60},
            {"name":"2x.webp","format":"WEBP","frame_count":60}
          ]}
        }}}}}
        """
        let badgeEnv = try SevenTvChatWire.decoder().decode(SevenTvChatWire.Envelope.self, from: Data(badgeJSON.utf8))
        let badgeData = try #require(badgeEnv.d?.body?.object?.data)
        let badge = try #require(SevenTvChatWire.badge(badgeData, id: "b1"))
        #expect(badge.url.absoluteString == "https://cdn.7tv.app/badge/b1/2x.webp")
        #expect(badge.title == "7TV Subscriber")
        #expect(badge.animated)

        // Repeating linear gradient with shadows
        let repeatPaintJSON = """
        {"op":0,"d":{"type":"cosmetic.create","body":{"object":{"id":"p2","kind":"PAINT","data":{
          "id":"p2","name":"Bismuth","function":"LINEAR_GRADIENT","angle":90,"repeat":true,"color":null,
          "stops":[{"at":0,"color":-16776961},{"at":0.5,"color":16711935}],
          "shadows":[{"x_offset":0,"y_offset":0,"radius":2,"color":-16776961}]
        }}}}}
        """
        let repEnv = try SevenTvChatWire.decoder().decode(SevenTvChatWire.Envelope.self, from: Data(repeatPaintJSON.utf8))
        let repData = try #require(repEnv.d?.body?.object?.data)
        let repPaint = try #require(SevenTvChatWire.paint(repData, id: "p2"))
        #expect(repPaint.kind == .linear && repPaint.repeats)
        #expect(repPaint.shadows == [SevenTvPaint.Shadow(xOffset: 0, yOffset: 0, radius: 2, rgba: 0xFF0000FF)])
        let tiled = repPaint.resolvedStops
        #expect(tiled.first?.at == 0 && tiled.last?.at == 1)
        #expect(tiled.count == 4)

        // URL image paint
        let imagePaintJSON = """
        {"op":0,"d":{"type":"cosmetic.create","body":{"object":{"id":"p3","kind":"PAINT","data":{
          "id":"p3","name":"Galaxy","function":"URL","image_url":"https://cdn.7tv.app/paint/p3/layer/l1/1x.webp","stops":[],"shadows":[]
        }}}}}
        """
        let imgEnv = try SevenTvChatWire.decoder().decode(SevenTvChatWire.Envelope.self, from: Data(imagePaintJSON.utf8))
        let imgData = try #require(imgEnv.d?.body?.object?.data)
        let imgPaint = try #require(SevenTvChatWire.paint(imgData, id: "p3"))
        #expect(imgPaint.kind == .image)
        #expect(imgPaint.imageURL?.absoluteString == "https://cdn.7tv.app/paint/p3/layer/l1/1x.webp")
    }

    @Test func sevenTvGQLCosmeticsBatchQueryAndDecode() throws {
        #expect(SevenTvChatWire.cosmeticsQueryBody(userIDs: []) == nil)
        let body = try #require(SevenTvChatWire.cosmeticsQueryBody(userIDs: ["101", "202"]))
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains("u0: userByConnection(platform: TWITCH, id: \\\"101\\\")"))
        #expect(text.contains("u1: userByConnection(platform: TWITCH, id: \\\"202\\\")"))

        let responseJSON = """
        {"data":{
          "u0":{"style":{
            "paint":{"id":"p1","name":"Neon","function":"LINEAR_GRADIENT","angle":90,"repeat":false,"color":null,
              "stops":[{"at":0,"color":-16711681},{"at":1,"color":-65281}],
              "shadows":[{"x_offset":0,"y_offset":0,"radius":1,"color":-16711681}]},
            "badge":{"id":"b1","name":"Sub","tooltip":"7TV Sub","host":{"url":"//cdn.7tv.app/badge/b1","files":[{"name":"2x.webp","format":"WEBP","frame_count":1}]}}
          }},
          "u1":null
        }}
        """
        let decoded = try SevenTvChatWire.decoder().decode(SevenTvChatWire.GQLCosmeticsResponse.self, from: Data(responseJSON.utf8))
        let u0 = try #require(decoded.data?["u0"]??.style)
        let paintData = try #require(u0.paint)
        let badgeData = try #require(u0.badge)
        let paint = try #require(SevenTvChatWire.paint(paintData, id: "p1"))
        let badge = try #require(SevenTvChatWire.badge(badgeData, id: "b1"))
        #expect(paint.kind == .linear && paint.stops.count == 2)
        #expect(!badge.animated && badge.url.absoluteString == "https://cdn.7tv.app/badge/b1/2x.webp")
        #expect((decoded.data?["u1"] ?? nil) == nil)
    }
}

struct TwitchSessionTests {
    @Test func theSessionAnswerDecodes() throws {
        let json = """
        {"status":"success","connected":true,"client_id":"cid","user_id":"42","login":"capybaraharmony","display_name":"CapybaraHarmony",
         "access_token":"tok","expires_at":1700000000000,"scopes":["chat:read","chat:edit","clips:edit"],"can_chat":true,"reconnect":false}
        """
        let s = try CobaltJSON.decoder().decode(TwitchSession.self, from: Data(json.utf8))
        let creds = try #require(s.credentials)
        #expect(creds == TwitchCredentials(login: "capybaraharmony", userID: "42", clientID: "cid", token: "tok", canChat: true))
        #expect(s.canClip)
        #expect(s.expiresAt == Date(timeIntervalSince1970: 1_700_000_000))
        let off = try CobaltJSON.decoder().decode(TwitchSession.self, from: Data(#"{"status":"success","connected":false}"#.utf8))
        #expect(off.credentials == nil)
        let again = try CobaltJSON.decoder().decode(TwitchSession.self, from: Data("""
            {"connected":true,"client_id":"c","user_id":"1","login":"a","access_token":null,"reconnect":true,"can_chat":false}
            """.utf8))
        #expect(again.credentials == nil)
    }

    @Test func channelNamesFromWhatPeopleType() {
        #expect(TwitchStore.login(from: "CapybaraHarmony") == "capybaraharmony")
        #expect(TwitchStore.login(from: "@kiko_") == "kiko_")
        #expect(TwitchStore.login(from: "https://www.twitch.tv/mothmoth?sr=a") == "mothmoth")
        #expect(TwitchStore.login(from: "twitch.tv/ren123") == "ren123")
        #expect(TwitchStore.login(from: "no spaces allowed") == nil)
        #expect(TwitchStore.login(from: "ab") == nil)
    }
}

/// Counts `GET /stage/twitch/session` and answers whatever the test set last.
private actor TwitchSessionScript {
    var calls = 0
    var next: TwitchSession
    init(_ first: TwitchSession) { next = first }
    func answer() -> TwitchSession { calls += 1; return next }
    func set(_ s: TwitchSession) { next = s }
}

@MainActor
struct TwitchStoreSessionRecheckTests {
    /// A cached session that cannot chat (read-only, or connected before the chat scopes) is asked for again once the last
    /// answer is older than `recheckAfter`, so a reconnect in studio shows up without a relaunch; one that can chat is kept.
    @Test func aReadOnlySessionIsAskedForAgain() async throws {
        let far = Date().addingTimeInterval(3600)
        let readOnly = TwitchSession(connected: true, login: "capy", accessToken: "t", expiresAt: far, canChat: false)
        let canChat = TwitchSession(connected: true, login: "capy", accessToken: "t", expiresAt: far, canChat: true)
        let script = TwitchSessionScript(readOnly)
        let h = Harness(.shortClip)
        h.ctx.client = ScriptedClient(base: h.ctx.client, twitchSessionHook: { await script.answer() })
        let store = h.app.twitch

        await store.load()
        #expect(await script.calls == 1)
        #expect(store.session?.canChat == false)
        #expect(store.needsChatScopes)

        // a second appearance right away does not ask again
        await store.load()
        #expect(await script.calls == 1)

        // the owner reconnects in studio; once the last answer is old, the read-only session is asked for again
        await script.set(canChat)
        store.sessionFetchedAt = Date().addingTimeInterval(-(TwitchStore.recheckAfter + 1))
        await store.load()
        #expect(await script.calls == 2)
        #expect(store.session?.canChat == true)
        #expect(!store.needsChatScopes)

        // a session that can chat and is far from its end is kept, however old the last answer
        store.sessionFetchedAt = Date().addingTimeInterval(-(TwitchStore.recheckAfter + 1))
        await store.load()
        #expect(await script.calls == 2)

        // pull to refresh asks anyway
        await store.load(force: true)
        #expect(await script.calls == 3)
    }
}

// The emote picker's sections (APP-API-CONTRACT 70.6).
struct TwitchEmotePickerTests {
    private func seven(_ name: String, global: Bool = false) -> ChatEmote {
        ChatEmote(id: "7-\(name)", name: name, url: URL(string: "https://cdn.7tv.app/emote/\(name)/2x.webp")!, animated: false,
                  source: global ? .sevenTvGlobal : .sevenTv)
    }

    private func user(_ id: String, _ name: String, type: String, owner: String) -> TwitchUserEmote {
        TwitchUserEmote(emote: .twitch(id: id, name: name), type: type, ownerID: owner)
    }

    private var sections: [TwitchEmoteSection] {
        TwitchEmoteList.pickerSections(
            sevenTvChannel: [seven("liaBox"), seven("Clap")],
            channelTwitch: [.twitch(id: "c1", name: "capyHi"), .twitch(id: "c2", name: "capyLove")],
            user: [
                user("25", "Kappa", type: "globals", owner: "0"),
                user("c2", "capyLove", type: "subscriptions", owner: "room"),
                user("f1", "capyWave", type: "follower", owner: "room"),
                user("o1", "otherHype", type: "subscriptions", owner: "someone"),
            ],
            roomID: "room",
            sevenTvGlobal: [seven("Clap", global: true), seven("EZ", global: true)])
    }

    @Test func groupsBySource() {
        let s = sections
        #expect(s.map(\.kind) == [.channelSevenTv, .channelTwitch, .yourTwitch, .twitchGlobal, .sevenTvGlobal])
        #expect(s[0].emotes.map(\.name) == ["Clap", "liaBox"])
        // sendable first (c2, then the follower emote), the sub emote without the sub last and locked
        #expect(s[1].emotes.map(\.name) == ["capyLove", "capyWave", "capyHi"])
        #expect(s[1].locked == ["c1"])
        #expect(s[2].emotes.map(\.name) == ["otherHype"])
        #expect(s[3].emotes.map(\.name) == ["Kappa"])
        // the channel's 7TV "Clap" wins: the global one is not offered twice
        #expect(s[4].emotes.map(\.name) == ["EZ"])
    }

    @Test func searchKeepsSectionsAndPutsPrefixFirst() {
        let list = TwitchEmoteList(sections: sections)
        let hits = list.sections(matching: "  CAP ")
        #expect(hits.map(\.kind) == [.channelTwitch])
        #expect(hits[0].emotes.map(\.name) == ["capyLove", "capyWave", "capyHi"])
        #expect(list.sections(matching: "box").map { $0.emotes.map(\.name) } == [["liaBox"]])
        #expect(list.sections(matching: "zzz").isEmpty)
        #expect(list.sections(matching: "").count == 5)
    }

    @Test func helixUserEmotesDecodeTypeAndOwner() throws {
        let json = #"{"data":[{"id":"25","name":"Kappa","format":["static"],"emote_type":"globals","owner_id":"0"}],"pagination":{}}"#
        let page = try HelixWire.decoder().decode(HelixWire.CursorPage<HelixWire.UserEmote>.self, from: Data(json.utf8))
        #expect(page.data?.first?.emoteType == "globals")
        #expect(page.data?.first?.ownerId == "0")
    }
}

private final class ChatStubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest, Data?) -> (Int, Data))?

    static func setHandler(_ block: (@Sendable (URLRequest, Data?) -> (Int, Data))?) {
        lock.lock()
        handler = block
        lock.unlock()
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChatStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let block = Self.handler
        Self.lock.unlock()

        let body = request.httpBody ?? Self.readBodyStream(request.httpBodyStream)
        let (status, data) = block?(request, body) ?? (404, Data())
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        return out
    }
}

@Suite(.serialized)
struct TwitchChatEngineBadgesAndCosmeticsTests {
    @Test func backfillsTwitchBadgesAndOverridesWithChannelBadges() async throws {
        defer { ChatStubURLProtocol.setHandler(nil) }
        ChatStubURLProtocol.setHandler { req, _ in
            guard let url = req.url?.absoluteString else { return (404, Data()) }
            if url.contains("/chat/badges/global") {
                return (200, Data("""
                {"data":[
                  {"set_id":"broadcaster","versions":[{"id":"1","image_url_2x":"https://static-cdn.jtvnw.net/badges/v1/broadcaster/2","title":"Broadcaster"}]},
                  {"set_id":"subscriber","versions":[{"id":"12","image_url_2x":"https://static-cdn.jtvnw.net/badges/v1/global-sub/2","title":"Global Sub"}]},
                  {"set_id":"vip","versions":[{"id":"1","image_url_2x":"https://static-cdn.jtvnw.net/badges/v1/vip/2","title":"VIP"}]}
                ]}
                """.utf8))
            }
            if url.contains("/chat/badges?broadcaster_id=999") {
                return (200, Data("""
                {"data":[
                  {"set_id":"subscriber","versions":[{"id":"12","image_url_2x":"https://static-cdn.jtvnw.net/badges/v1/channel-sub12/2","title":"Channel 1-Year Sub"}]}
                ]}
                """.utf8))
            }
            return (404, Data())
        }

        let creds = TwitchCredentials(login: "me", userID: "1", clientID: "cid", token: "tok", canChat: true)
        let engine = TwitchChatEngine(channel: "capy", credentials: creds, session: ChatStubURLProtocol.makeSession())
        defer { Task { await engine.stop() } }

        // Message arrives before badge maps finish loading
        await engine.ingestIRCForTesting(
            "@badges=broadcaster/1,subscriber/12,vip/1;display-name=Capy;id=m1 :capy!capy@capy.tmi.twitch.tv PRIVMSG #capy :hello")
        #expect(await engine.currentSnapshot().lines.first?.badges.isEmpty == true)

        await engine.loadBadgesForTesting(roomID: "999")
        let badges = try #require(await engine.currentSnapshot().lines.first?.badges)
        #expect(badges.map(\.id) == ["broadcaster/1", "subscriber/12", "vip/1"])
        #expect(badges[1].url.absoluteString == "https://static-cdn.jtvnw.net/badges/v1/channel-sub12/2")
        #expect(badges[1].title == "Channel 1-Year Sub")
    }

    @Test func anonymousChatFallsBackToGQLBadges() async throws {
        defer { ChatStubURLProtocol.setHandler(nil) }
        ChatStubURLProtocol.setHandler { req, body in
            guard req.url?.host() == "gql.twitch.tv" else { return (404, Data()) }
            let query = body.map { String(decoding: $0, as: UTF8.self) } ?? ""
            if query.contains("broadcastBadges") {
                return (200, Data("""
                {"data":{"user":{"id":"999","broadcastBadges":[
                  {"setID":"subscriber","version":"6","title":"6-Month Sub","imageURL":"https://static-cdn.jtvnw.net/badges/v1/sub6/2"}
                ]}}}
                """.utf8))
            }
            return (200, Data("""
            {"data":{"badges":[
              {"setID":"moderator","version":"1","title":"Moderator","imageURL":"https://static-cdn.jtvnw.net/badges/v1/mod/2"}
            ]}}
            """.utf8))
        }

        let engine = TwitchChatEngine(channel: "capy", credentials: nil, session: ChatStubURLProtocol.makeSession())
        defer { Task { await engine.stop() } }

        await engine.ingestIRCForTesting(
            "@badges=moderator/1,subscriber/6;display-name=Mod;id=m2 :mod!mod@mod.tmi.twitch.tv PRIVMSG #capy :hi")
        await engine.loadBadgesForTesting(roomID: "999")
        let badges = try #require(await engine.currentSnapshot().lines.first?.badges)
        #expect(badges.map(\.id) == ["moderator/1", "subscriber/6"])
        #expect(badges[0].title == "Moderator")
        #expect(badges[1].title == "6-Month Sub")
    }

    @Test func batchesSevenTvCosmeticsAndRespectsLiveEvents() async throws {
        defer { ChatStubURLProtocol.setHandler(nil) }
        ChatStubURLProtocol.setHandler { req, body in
            guard req.url?.host() == "7tv.io" else { return (404, Data()) }
            let text = body.map { String(decoding: $0, as: UTF8.self) } ?? ""
            // Popped LIFO from tail: bob (202) is u0, alice (101) is u1
            let bobFirst = text.contains("u0: userByConnection(platform: TWITCH, id: \\\"202\\\")")
            let bobAlias = bobFirst ? "u0" : "u1"
            let aliceAlias = bobFirst ? "u1" : "u0"
            return (200, Data("""
            {"data":{
              "\(aliceAlias)":{"style":{
                "paint":{"id":"p-alice","name":"Bismuth","function":"LINEAR_GRADIENT","angle":90,"repeat":true,"color":null,
                  "stops":[{"at":0,"color":-16776961},{"at":0.5,"color":16711935}],
                  "shadows":[{"x_offset":0,"y_offset":0,"radius":1,"color":-16776961}]},
                "badge":{"id":"b-alice","name":"7TV Sub","tooltip":"7TV Sub","host":{"url":"//cdn.7tv.app/badge/b-alice","files":[{"name":"2x.webp","format":"WEBP","frame_count":90}]}}
              }},
              "\(bobAlias)":{"style":{
                "paint":{"id":"p-bob","name":"Galaxy","function":"URL","image_url":"https://cdn.7tv.app/paint/p-bob/1x.webp","stops":[],"shadows":[]},
                "badge":null
              }}
            }}
            """.utf8))
        }

        let engine = TwitchChatEngine(channel: "capy", credentials: nil, session: ChatStubURLProtocol.makeSession())
        defer { Task { await engine.stop() } }

        await engine.ingestIRCForTesting(
            "@user-id=101;display-name=Alice;id=a1 :alice!alice@alice.tmi.twitch.tv PRIVMSG #capy :hi")
        await engine.ingestIRCForTesting(
            "@user-id=202;display-name=Bob;id=b1 :bob!bob@bob.tmi.twitch.tv PRIVMSG #capy :yo")
        await engine.flushCosmeticsForTesting()

        let snap = await engine.currentSnapshot()
        let alicePaint = try #require(snap.paints["alice"])
        #expect(alicePaint.id == "p-alice" && alicePaint.repeats && alicePaint.shadows.count == 1)
        let aliceBadge = try #require(snap.sevenTvBadges["alice"])
        #expect(aliceBadge.id == "7tv:b-alice" && aliceBadge.animated)
        let bobPaint = try #require(snap.paints["bob"])
        #expect(bobPaint.kind == .image && bobPaint.imageURL?.absoluteString == "https://cdn.7tv.app/paint/p-bob/1x.webp")

        // Live EventAPI entitlement.delete removes alice's paint without touching bob
        let deleteJSON = """
        {"op":0,"d":{"type":"entitlement.delete","body":{"object":{"id":"e1","kind":"PAINT","ref_id":"p-alice",
          "user":{"id":"u1","username":"alice","connections":[{"platform":"TWITCH","id":"101","username":"Alice"}]}}}}}
        """
        let delEnv = try SevenTvChatWire.decoder().decode(SevenTvChatWire.Envelope.self, from: Data(deleteJSON.utf8))
        await engine.dispatchEventForTesting(type: "entitlement.delete", body: try #require(delEnv.d?.body))
        let afterDelete = await engine.currentSnapshot()
        #expect(afterDelete.paints["alice"] == nil)
        #expect(afterDelete.sevenTvBadges["alice"]?.id == "7tv:b-alice")
        #expect(afterDelete.paints["bob"]?.id == "p-bob")

        // Live EventAPI entitlement.reset clears bob's cosmetics
        let resetJSON = """
        {"op":0,"d":{"type":"entitlement.reset","body":{"object":{"id":"e2","kind":"PAINT",
          "user":{"id":"u2","username":"bob","connections":[{"platform":"TWITCH","id":"202","username":"Bob"}]}}}}}
        """
        let resetEnv = try SevenTvChatWire.decoder().decode(SevenTvChatWire.Envelope.self, from: Data(resetJSON.utf8))
        await engine.dispatchEventForTesting(type: "entitlement.reset", body: try #require(resetEnv.d?.body))
        #expect(await engine.currentSnapshot().paints["bob"] == nil)
    }
}

