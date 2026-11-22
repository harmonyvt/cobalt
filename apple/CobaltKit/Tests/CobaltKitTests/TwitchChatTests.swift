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
