import Foundation
import Testing
@testable import CobaltKit

// Post frames (APP-API-CONTRACT 52): the style from a link, `PostDetails` off the wire, the bodies of the frame and PATCH
// routes, the refusals, the capability, a post render in the queue's renders, the save hook's target, and the preview server.

private let frameKey = "9b1e7c2a-4d3f-4e8a-b6c5-2f0a1d9e8c71"

private let wireDetails = """
{"link":"https://x.com/i/status/2105435404002562056","site":"x","found":true,"name":"mochi","handle":"@mochibytes",\
"text":"the cat learned to open the fridge","title":null,"channel":null,"game":null,"site_name":null,\
"posted_at":1790000000000,"counts":{"likes":18000,"reposts":2100,"replies":312,"views":402000},"verified":true,\
"avatar_url":"https://api.example.com/library/items/PrEvIeWitem000006/post-details/avatar","edited":false}
"""

private let wirePostRender = """
{"id":"Rq7sTu0vWx3yZa6bCd9p","kind":"post","project_id":"post:PrEvIeWitem000006","revision":0,\
"title":"kitchen timer loop (post)","status":"queued","queue_ahead":0,"progress":null,"seconds_total":5.46,\
"created_at":1790000000000}
"""

private func decodeDetails(_ json: String) throws -> PostDetails {
    try CobaltJSON.decoder().decode(PostDetails.self, from: Data(json.utf8))
}

struct PostFrameStyleTests {
    private func style(_ s: String?) -> PostFrameStyle { PostFrameStyle(link: s.flatMap { URL(string: $0) }) }

    @Test func theHostPicksTheStyle() {
        #expect(style("https://x.com/i/status/1") == .x)
        #expect(style("https://twitter.com/a/status/1") == .x)
        #expect(style("https://mobile.twitter.com/a/status/1") == .x)
        #expect(style("https://www.instagram.com/reel/AbC/") == .instagram)
        #expect(style("https://clips.twitch.tv/SomeClip") == .twitch)
        #expect(style("https://www.twitch.tv/somebody/clip/Abc") == .twitch)
        #expect(style("https://youtu.be/abc") == .youtube)
        #expect(style("https://m.youtube.com/watch?v=abc") == .youtube)
        #expect(style("https://www.youtube.com/shorts/abc") == .youtube)
    }

    @Test func caseAndWwwAreIgnored() {
        #expect(style("https://WWW.X.COM/i/status/1") == .x)
        #expect(style("https://Www.Instagram.Com/p/AbC/") == .instagram)
    }

    @Test func anythingElseIsGeneric() {
        #expect(style("https://vimeo.com/123") == .generic)
        #expect(style("https://notx.com/i/status/1") == .generic)
        #expect(style("https://x.com.example.org/a") == .generic)
        #expect(style(nil) == .generic)
        #expect(PostFrameStyle(linkString: nil) == .generic)
        #expect(PostFrameStyle(linkString: "not a link") == .generic)
        #expect(PostFrameStyle(linkString: "https://www.tiktok.com/@a/video/1") == .generic)
    }

    @Test func anUnknownStyleWordDecodesAsGeneric() throws {
        let styles = try JSONDecoder().decode([PostFrameStyle].self, from: Data(#"["x","bluesky","youtube"]"#.utf8))
        #expect(styles == [.x, .generic, .youtube])
    }
}

struct PostDetailsWireTests {
    @Test func theContractsExampleDecodes() throws {
        let d = try decodeDetails(wireDetails)
        #expect(d.link == "https://x.com/i/status/2105435404002562056" && d.site == .x && d.found)
        #expect(d.name == "mochi" && d.handle == "@mochibytes" && d.text == "the cat learned to open the fridge")
        #expect(d.title == nil && d.channel == nil && d.game == nil && d.siteName == nil)
        #expect(d.postedAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(d.counts.likes == 18_000 && d.counts.reposts == 2_100 && d.counts.replies == 312 && d.counts.views == 402_000)
        #expect(d.counts.comments == nil && d.counts.subscribers == nil)
        #expect(d.verified && !d.edited)
        #expect(d.avatarURL?.absoluteString == "https://api.example.com/library/items/PrEvIeWitem000006/post-details/avatar")
        #expect(d.host == "x.com" && d.displayName == "mochi")
    }

    @Test func flagsMayBeTheTablesZeroAndOne() throws {
        let d = try decodeDetails(
            #"{"link":"https://www.instagram.com/reel/Dd7P496wolG/","site":"instagram","found":0,"verified":1,"edited":1}"#)
        #expect(!d.found && d.verified && d.edited)
        #expect(d.site == .instagram && d.counts.isEmpty && d.postedAt == nil && d.avatarURL == nil)
        #expect(d.host == "instagram.com")
    }

    @Test func blankWordsAreMissingAndFoundDefaultsToTrue() throws {
        let d = try decodeDetails(#"{"link":"https://x.com/a/status/1","site":"x","name":"  ","handle":"","text":"hi"}"#)
        #expect(d.name == nil && d.handle == nil && d.text == "hi")
        #expect(d.found && !d.verified && !d.edited)
        #expect(d.displayName == nil)
    }

    @Test func anUnknownSiteIsGenericAndAMissingOneComesFromTheLink() throws {
        #expect(try decodeDetails(#"{"link":"https://x.com/a/status/1","site":"bluesky"}"#).site == .generic)
        #expect(try decodeDetails(#"{"link":"https://clips.twitch.tv/Abc"}"#).site == .twitch)
        #expect(try decodeDetails(#"{"link":"https://clips.twitch.tv/Abc","site":null}"#).site == .twitch)
    }

    @Test func brokenCountsReadAsMissing() throws {
        let d = try decodeDetails(
            #"{"link":"https://x.com/a/status/1","site":"x","counts":{"likes":"lots","views":1200.0,"replies":-3,"subscribers":null}}"#)
        #expect(d.counts.likes == nil && d.counts.views == 1200 && d.counts.replies == nil && d.counts.subscribers == nil)
        let junk = try decodeDetails(#"{"link":"https://x.com/a/status/1","site":"x","counts":"none"}"#)
        #expect(junk.counts.isEmpty)
    }

    @Test func theNameFallsBackToChannelThenHandle() {
        var d = PostDetails(link: "https://www.youtube.com/watch?v=a", site: .youtube, found: true, channel: "Little Builds")
        #expect(d.displayName == "Little Builds")
        d.channel = nil
        d.handle = "@littlebuilds"
        #expect(d.displayName == "littlebuilds")
    }

    @Test func overridesAreDrawnInsteadAndNilsChangeNothing() {
        let d = PostDetails(link: "https://x.com/a/status/1", site: .x, found: true, name: "mochi", handle: "@mochibytes", text: "a")
        let out = d.applying(PostDetailsFields(name: "Mochi!", text: "b"))
        #expect(out.name == "Mochi!" && out.text == "b" && out.handle == "@mochibytes")
        #expect(d.applying(PostDetailsFields()) == d)
    }

    @Test func countsAreShortenedLikeTheSites() {
        #expect(PostCounts.compact(0) == "0")
        #expect(PostCounts.compact(999) == "999")
        #expect(PostCounts.compact(1_000) == "1K")
        #expect(PostCounts.compact(1_250) == "1.2K")
        #expect(PostCounts.compact(1_999) == "1.9K")
        #expect(PostCounts.compact(18_000) == "18K")
        #expect(PostCounts.compact(402_000) == "402K")
        #expect(PostCounts.compact(999_999) == "999K")
        #expect(PostCounts.compact(1_200_000) == "1.2M")
        #expect(PostCounts.compact(2_300_000) == "2.3M")
        #expect(PostCounts.compact(-5) == "0")
    }
}

struct PostFrameBodyTests {
    @Test func theDefaultsSendOnlyTheLook() throws {
        let body = HTTPCobaltClient.postFrameBody(PostFrameOptions())
        #expect(Set(body.keys) == ["theme", "canvas", "show"])
        #expect(body["theme"] as? String == "dark" && body["canvas"] as? String == "fit")
        let show = try #require(body["show"] as? [String: Bool])
        #expect(show == ["avatar": true, "text": true, "counts": true, "time": true])
    }

    @Test func everyOptionIsSentByItsWireName() throws {
        let options = PostFrameOptions(
            style: .instagram, theme: .light, canvas: .portrait, show: PostFrameShow(avatar: true, text: false, counts: false, time: true),
            from: 2.0004, to: 9.25, details: PostDetailsFields(name: "tofu", text: "hello"), notify: true)
        let body = HTTPCobaltClient.postFrameBody(options)
        #expect(body["style"] as? String == "instagram" && body["theme"] as? String == "light" && body["canvas"] as? String == "portrait")
        #expect(body["show"] as? [String: Bool] == ["avatar": true, "text": false, "counts": false, "time": true])
        #expect(body["from"] as? Double == 2.0 && body["to"] as? Double == 9.25)
        #expect(body["details"] as? [String: String] == ["name": "tofu", "text": "hello"])
        #expect(body["notify"] as? Bool == true)
        #expect(body.count == 8)
    }

    @Test func aRangeIsSentOnlyWhenItIsOne() {
        func range(_ from: Double?, _ to: Double?) -> [Double?] {
            let body = HTTPCobaltClient.postFrameBody(PostFrameOptions(from: from, to: to))
            return [body["from"] as? Double, body["to"] as? Double]
        }
        #expect(range(0, nil) == [nil, nil], "from 0 is the server's default")
        #expect(range(-3, 4) == [nil, 4])
        #expect(range(5, 5) == [5, nil], "a `to` not after `from` is left out")
        #expect(range(5, 3) == [5, nil])
        #expect(range(.nan, .infinity) == [nil, nil])
        #expect(range(nil, 7.5) == [nil, 7.5])
    }

    @Test func longOverridesAreHeldToTheServersLengths() throws {
        let body = HTTPCobaltClient.postFrameBody(
            PostFrameOptions(details: PostDetailsFields(name: String(repeating: "n", count: 2500), text: String(repeating: "t", count: 5000))))
        let details = try #require(body["details"] as? [String: String])
        #expect(details["name"]?.count == 2000 && details["text"]?.count == 4000)
    }

    @Test func aPatchSendsOnlyWhatChanges() {
        let old = PostDetails(
            link: "https://x.com/a/status/1", site: .x, found: true, name: "mochi", handle: "@mochibytes", text: "the fridge")
        let patch = PostDetailsPatch(from: old, to: PostDetailsFields(name: "mochi ", handle: "  ", text: "the fridge, again", title: nil))
        #expect(patch.name == .keep, "trimmed it is the same")
        #expect(patch.handle == .clear && patch.text == .set("the fridge, again") && patch.title == .keep)
        let wire = patch.wire
        #expect(Set(wire.keys) == ["handle", "text"])
        #expect(wire["handle"] is NSNull && wire["text"] as? String == "the fridge, again")
        #expect(!patch.isEmpty)
        #expect(PostDetailsPatch(from: old, to: PostDetailsFields(name: "mochi")).isEmpty)
        #expect(PostDetailsPatch().isEmpty)
    }

    @Test func aPatchSendsThePostTimeInMilliseconds() {
        var patch = PostDetailsPatch()
        patch.postedAt = .set(Date(timeIntervalSince1970: 1_790_000_000.5))
        #expect(patch.wire["posted_at"] as? Int64 == 1_790_000_000_500)
        patch.postedAt = .clear
        #expect(patch.wire["posted_at"] is NSNull)
    }

    @Test func theRefusalCodesAreKnown() {
        #expect(PostFrameError(code: "error.library.not_found") == .notFound)
        #expect(PostFrameError(code: "error.post.no_link") == .noLink)
        #expect(PostFrameError(code: "error.post.not_video") == .notVideo)
        #expect(PostFrameError(code: "error.post.bad_request") == .badRequest)
        #expect(PostFrameError(code: "error.post.off") == .off)
        #expect(PostFrameError(code: "error.api.generic") == nil)
    }
}

struct PostFrameCapabilityTests {
    private func caps(_ rest: String) throws -> Capabilities {
        let json = #"{"server":"cobalt-cloudflare"\#(rest),"key":"valid"}"#
        return try #require(HTTPCobaltClient.parseForkCapabilities(Data(json.utf8)))
    }

    @Test func postFrameIsReadAndOffWhenAbsent() throws {
        #expect(try caps(#","features":{"editor":true,"post_frame":true}"#).postFrame)
        #expect(try !caps(#","features":{"editor":true,"post_frame":false}"#).postFrame)
        #expect(try !caps(#","features":{"editor":true}"#).postFrame)
        #expect(try !caps("").postFrame)
    }
}

struct PostFrameRenderTests {
    private func decodeRender(_ json: String) throws -> EditRender {
        try CobaltJSON.decoder().decode(EditRender.self, from: Data(json.utf8))
    }

    @Test func aPostRenderDecodesItsKindAndItem() throws {
        let r = try decodeRender(wirePostRender)
        #expect(r.kind == .post && r.isPost && !r.isChat && r.isProjectless)
        #expect(r.postItemID == "PrEvIeWitem000006")
        #expect(r.status == .queued && r.secondsTotal == 5.46)
    }

    @Test func aPostProjectIDWithoutKindIsStillAPost() throws {
        let r = try decodeRender(wirePostRender.replacingOccurrences(of: #""kind":"post","#, with: ""))
        #expect(r.kind == .post && r.isPost && r.postItemID == "PrEvIeWitem000006")
    }

    @Test func otherRendersAreNotPosts() throws {
        let edit = try decodeRender(
            #"{"id":"a","project_id":"ProjectAAAAAAAAA","revision":1,"title":"t","status":"done","created_at":1790000000000}"#)
        #expect(!edit.isPost && edit.postItemID == nil && !edit.isProjectless)
        let chat = try decodeRender(
            #"{"id":"b","kind":"chat","project_id":"chat:T1","revision":0,"title":"t","status":"done","created_at":1790000000000}"#)
        #expect(!chat.isPost && chat.isProjectless)
        #expect(!EditRender.isPostProjectID("ProjectAAAAAAAAA") && EditRender.isPostProjectID("post:x"))
    }
}

struct PostFrameSaveHookTests {
    private let at = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(
        status: SessionStatus = .ready, link: String? = "https://x.com/i/status/1", duration: Double? = 5.46,
        itemID: String? = "PrEvIeWitem000006", items: [SessionItem] = []
    ) -> StudioSession {
        StudioSession(
            id: "PrEvIeWsession00000001", status: status, link: link, service: "x", title: "t", duration: duration, width: 480,
            height: 568, bytes: 1, createdAt: at, expiresAt: at.addingTimeInterval(3600), errorCode: nil, renders: [], step: nil,
            stepBytes: nil, stepTotal: nil, waking: nil, itemID: itemID, items: items)
    }

    @Test func aReadyVideoFromAPageIsFramed() throws {
        let target = try #require(Pipeline.postFrameTarget(session()))
        #expect(target.itemID == "PrEvIeWitem000006" && target.link.absoluteString == "https://x.com/i/status/1")
    }

    @Test func everythingElseIsNot() {
        #expect(Pipeline.postFrameTarget(session(status: .saving)) == nil)
        #expect(Pipeline.postFrameTarget(session(status: .error)) == nil)
        #expect(Pipeline.postFrameTarget(session(itemID: nil)) == nil, "no library row yet")
        #expect(Pipeline.postFrameTarget(session(duration: nil)) == nil, "a picture")
        #expect(Pipeline.postFrameTarget(session(link: "upload:PrEvIeWitem000006")) == nil)
        #expect(Pipeline.postFrameTarget(session(link: nil)) == nil)
        #expect(Pipeline.postFrameTarget(session(items: [SessionItem(i: 0, type: .video, status: .ready)])) == nil,
                "a gallery")
    }
}

struct PostFrameHTTPTests {
    private func client(_ server: LoopbackServer) -> HTTPCobaltClient {
        HTTPCobaltClient(baseURL: server.base, apiKey: { frameKey })
    }

    @Test func theDetailsAreReadAndRefreshed() async throws {
        let server = try await LoopbackServer.start { req in
            req.method == "GET" && req.path == "/library/items/PrEvIeWitem000006/post-details"
                ? .json(#"{"status":"success","details":\#(wireDetails)}"#) : .init(status: 404)
        }
        defer { server.stop() }
        let d = try await client(server).postDetails(item: "PrEvIeWitem000006", refresh: false)
        #expect(d.name == "mochi" && d.site == .x)
        _ = try await client(server).postDetails(item: "PrEvIeWitem000006", refresh: true)
        let reqs = server.requests
        #expect(reqs.count == 2)
        #expect(reqs[0].query == "" && reqs[1].query == "refresh=1")
        #expect(reqs[0].headers["authorization"] == "Api-Key \(frameKey)")
    }

    @Test func aPatchSendsItsFields() async throws {
        let server = try await LoopbackServer.start { req in
            req.method == "PATCH" && req.path == "/library/items/PrEvIeWitem000006/post-details"
                ? .json(#"{"status":"success","details":\#(wireDetails.replacingOccurrences(of: #""edited":false"#, with: #""edited":true"#))}"#)
                : .init(status: 404)
        }
        defer { server.stop() }
        var patch = PostDetailsPatch()
        patch.name = .set("Mochi")
        patch.handle = .clear
        let d = try await client(server).setPostDetails(item: "PrEvIeWitem000006", patch)
        #expect(d.edited)
        let req = try #require(server.requests.first)
        let json = try #require(JSONSerialization.jsonObject(with: req.body) as? [String: Any])
        #expect(json["name"] as? String == "Mochi" && json["handle"] is NSNull && json.count == 2)
    }

    @Test func aFrameIsAskedForAndItsRenderComesBack() async throws {
        let server = try await LoopbackServer.start { req in
            req.method == "POST" && req.path == "/library/items/PrEvIeWitem000006/post-frame"
                ? .json(#"{"status":"success","render":\#(wirePostRender)}"#, status: 202) : .init(status: 404)
        }
        defer { server.stop() }
        let r = try await client(server).postFrame(item: "PrEvIeWitem000006", options: PostFrameOptions(style: .x, theme: .light))
        #expect(r.kind == .post && r.postItemID == "PrEvIeWitem000006")
        let req = try #require(server.requests.first)
        let json = try #require(JSONSerialization.jsonObject(with: req.body) as? [String: Any])
        #expect(req.headers["content-type"] == "application/json")
        #expect(json["style"] as? String == "x" && json["theme"] as? String == "light" && json["canvas"] as? String == "fit")
    }

    @Test func refusalsAreMapped() async throws {
        func refused(_ code: String, _ status: Int, frame: Bool) async throws -> Error? {
            let server = try await LoopbackServer.start { _ in .json(#"{"status":"error","error":{"code":"\#(code)"}}"#, status: status) }
            defer { server.stop() }
            do {
                if frame {
                    _ = try await client(server).postFrame(item: "x", options: PostFrameOptions())
                } else {
                    _ = try await client(server).postDetails(item: "x", refresh: false)
                }
                return nil
            } catch {
                return error
            }
        }
        let cases: [(String, Int, PostFrameError)] = [
            ("error.library.not_found", 404, .notFound), ("error.post.no_link", 400, .noLink), ("error.post.not_video", 400, .notVideo),
            ("error.post.off", 404, .off), ("error.post.something_new", 400, .badRequest),
        ]
        for (code, status, expected) in cases {
            #expect(try await refused(code, status, frame: true) as? PostFrameError == expected, "\(code) frame")
            #expect(try await refused(code, status, frame: false) as? PostFrameError == expected, "\(code) details")
        }
        #expect(try await refused("error.edit.queue_full", 429, frame: true) as? EditError == .queueFull)
        #expect(try await refused("error.edit.off", 404, frame: true) as? EditError == .off)
        let other = try await refused("error.api.generic", 503, frame: true)
        #expect(other != nil && !(other is PostFrameError))
    }
}

struct PostFramePreviewTests {
    private let client = PreviewClient(scenario: .happy, timeScale: 0)

    @Test func thePreviewKnowsItsPosts() async throws {
        let x = try await client.postDetails(item: "PrEvIeWitem000006", refresh: false)
        #expect(x.site == .x && x.found)
        let gone = try await client.postDetails(item: "PrEvIeWitem000004", refresh: false)
        #expect(gone.site == .instagram && !gone.found)
        await #expect(throws: PostFrameError.notFound) { try await client.postDetails(item: "nothing-here", refresh: false) }
    }

    @Test func anEditIsKeptAndMarked() async throws {
        var patch = PostDetailsPatch()
        patch.text = .set("edited words")
        let d = try await client.setPostDetails(item: "PrEvIeWitem000006", patch)
        #expect(d.text == "edited words" && d.edited)
        let again = try await client.postDetails(item: "PrEvIeWitem000006", refresh: false)
        #expect(again.text == "edited words" && again.edited)
    }

    @Test func aFrameStartsAPostRender() async throws {
        let r = try await client.postFrame(item: "PrEvIeWitem000006", options: PostFrameOptions())
        #expect(r.kind == .post && r.isPost && r.postItemID == "PrEvIeWitem000006")
    }
}
