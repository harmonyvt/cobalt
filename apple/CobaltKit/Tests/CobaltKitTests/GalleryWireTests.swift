import Foundation
import Synchronization
import Testing
@testable import CobaltKit

// APP-API-CONTRACT 18.2-18.13 on the wire, over real loopback sockets: what `HTTPCobaltClient` sends (the exact bodies the
// server's validators read) and how it reads the answers.

private let key = "7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21"

private func client(_ server: LoopbackServer, key: String? = key) -> HTTPCobaltClient {
    HTTPCobaltClient(baseURL: server.base, apiKey: { key })
}

private func body(_ request: LoopbackServer.Request) -> [String: Any] {
    ((try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]) ?? [:]
}

private func photos(_ n: Int) -> [GalleryItem] { (0..<n).map { GalleryItem(id: $0, type: .photo, width: 1080, height: 1350) } }

@Suite(.serialized)
struct GalleryWireTests {
    // MARK: capabilities

    @Test func theGalleryFeaturesAreRead() async throws {
        let server = try await LoopbackServer.start { _ in
            .json(#"{"status":"success","server":"cobalt-cloudflare","cobalt":{"version":"11.7.1"},"features":{"studio":true,"line":true,"gallery":true,"gallery_make":true},"key":"valid","key_name":"iphone"}"#)
        }
        defer { server.stop() }
        let caps = await client(server).capabilities()
        #expect(caps.gallery && caps.galleryMake)
    }

    @Test func gallery_makeNeedsGalleryAndAbsenceIsFalse() async throws {
        let server = try await LoopbackServer.start { request in
            request.path == "/capabilities"
                ? .json(#"{"server":"cobalt-cloudflare","features":{"studio":true,"gallery_make":true},"key":"valid"}"#)
                : .init(status: 404)
        }
        defer { server.stop() }
        let half = await client(server).capabilities()
        #expect(!half.gallery && !half.galleryMake)
        let old = try await LoopbackServer.start { _ in .json(#"{"server":"cobalt-cloudflare","features":{"studio":true},"key":"valid"}"#) }
        defer { old.stop() }
        let caps = await client(old).capabilities()
        #expect(!caps.gallery && !caps.galleryMake)
    }

    // MARK: the create

    @Test func aGalleryCreateAsksForEveryItemWithTheCountItSaw() async throws {
        let server = try await LoopbackServer.start { _ in .json(#"{"status":"success","id":"sid1","url":null,"queued":true,"queue_ahead":2}"#, status: 201) }
        defer { server.stop() }
        let created = try await client(server).createStudio(
            url: URL(string: "https://www.instagram.com/p/Ddy0-gpGg5U/")!,
            options: StudioCreateOptions(makePublic: true, queue: true, title: "t", items: .all, itemCount: 10))
        #expect(created.id == "sid1" && created.queued && created.queueAhead == 2 && created.make == nil)
        let req = try #require(server.requests.first)
        #expect(req.method == "POST" && req.path == "/studio" && req.headers["authorization"] == "Api-Key \(key)")
        let sent = body(req)
        #expect(sent["items"] as? String == "all" && sent["item_count"] as? Int == 10 && sent["queue"] as? Bool == true)
        #expect(sent["url"] as? String == "https://www.instagram.com/p/Ddy0-gpGg5U/" && sent["public"] as? Bool == true && sent["title"] as? String == "t")
        #expect(sent["slideshow"] == nil && sent["gallery_image"] == nil)
    }

    @Test func theShareSheetsOneRequestCarriesTheMakeAndReadsItsJob() async throws {
        let server = try await LoopbackServer.start { _ in .json(#"{"status":"success","id":"sid2","make":{"job":"job9","kind":"slideshow"}}"#, status: 201) }
        defer { server.stop() }
        let options = StudioCreateOptions(
            makePublic: true, queue: true, origin: "share", notify: NotifyOptIn(on: [.rendered, .failed], label: "x · @a"),
            items: .all, itemCount: 4, slideshow: SlideshowPlan(format: .webp, items: [0, 1, 2, 3], quality: .med, width: 480),
            itemInfo: photos(4))
        let created = try await client(server).createStudio(url: URL(string: "https://x.com/a/status/1")!, options: options)
        #expect(created.make == StudioMake(job: "job9", kind: "slideshow"))
        let sent = body(try #require(server.requests.first))
        #expect(sent["origin"] as? String == "share")
        #expect((sent["notify"] as? [String: Any])?["on"] as? [String] == ["rendered", "failed"] && (sent["notify"] as? [String: Any])?["label"] as? String == "x · @a")
        let plan = try #require(sent["slideshow"] as? [String: Any])
        #expect(plan["format"] as? String == "webp" && plan["quality"] as? String == "med" && plan["width"] as? Int == 480)
        #expect(plan["items"] as? [Int] == [0, 1, 2, 3] && plan["seconds"] as? [Double] == [2, 2, 2, 2] && plan["fade"] as? Bool == true)
        #expect(plan["frame"] as? String == "keep" && plan["sound"] as? String == "none")
    }

    @Test func theShareSheetsThreeRequestsAreThe18_12Bodies() throws {
        let c = HTTPCobaltClient(baseURL: URL(string: "https://api.capybaraharmony.com")!, apiKey: { key })
        let link = URL(string: "https://www.instagram.com/p/Ddy0-gpGg5U/")!
        let items = photos(10)
        func request(_ extra: (inout StudioCreateOptions) -> Void, on: [NotifyEvent]) throws -> [String: Any] {
            var options = StudioCreateOptions(
                makePublic: true, queue: true, origin: "share", notify: NotifyOptIn(on: on, label: "instagram · Ddy0-gpGg5U"),
                items: .all, itemCount: 10, itemInfo: items)
            extra(&options)
            let (req, data) = try c.shareSaveRequest(link: link, options: options)
            #expect(req.httpMethod == "POST" && req.url?.path == "/studio" && req.value(forHTTPHeaderField: "Authorization") == "Api-Key \(key)")
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
        let all = try request({ _ in }, on: [.saved, .failed])
        #expect(all["items"] as? String == "all" && all["item_count"] as? Int == 10 && all["public"] as? Bool == true && all["origin"] as? String == "share")
        #expect(all["queue"] as? Bool == true && (all["notify"] as? [String: Any])?["on"] as? [String] == ["saved", "failed"])
        #expect(all["slideshow"] == nil && all["gallery_image"] == nil)
        let webp = try request({ $0.slideshow = SlideshowPlan(format: .webp, items: Array(0..<10), quality: .med, width: 480) }, on: [.rendered, .failed])
        #expect((webp["slideshow"] as? [String: Any])?["format"] as? String == "webp" && webp["gallery_image"] == nil)
        #expect((webp["notify"] as? [String: Any])?["on"] as? [String] == ["rendered", "failed"])
        let image = try request({ $0.galleryImage = GalleryImagePlan(items: Array(0..<10), layout: .grid3) }, on: [.rendered, .failed])
        #expect((image["gallery_image"] as? [String: Any])?["layout"] as? String == "grid3" && image["slideshow"] == nil)
        let noKey = HTTPCobaltClient(baseURL: URL(string: "https://api.capybaraharmony.com")!, apiKey: { nil })
        #expect(throws: CobaltError.noAPIKey) { try noKey.shareSaveRequest(link: link, options: StudioCreateOptions(items: .all)) }
    }

    @Test func aPlainCreateStillSendsExactlyWhatItSent() async throws {
        let server = try await LoopbackServer.start { _ in .json(#"{"status":"success","id":"sid3"}"#, status: 201) }
        defer { server.stop() }
        _ = try await client(server).createStudio(link: URL(string: "https://x.com/i/status/1")!, public: nil, queue: false, title: nil)
        #expect(body(try #require(server.requests.first)).keys.sorted() == ["url"])
    }

    // MARK: the makes

    @Test func aSlideshowRequestIsKeyedFocusedAndCarriesNullForVideos() async throws {
        let server = try await LoopbackServer.start { _ in .json(#"{"status":"pending","job":"j1","queued":true,"queue_ahead":3}"#, status: 202) }
        defer { server.stop() }
        let items = [GalleryItem(id: 0, type: .photo), GalleryItem(id: 1, type: .video, duration: 6), GalleryItem(id: 2, type: .photo)]
        let plan = SlideshowPlan(format: .mp4, items: [2, 0, 1], photoSeconds: 1.5, fade: false, frame: .square, sound: .own)
        let accepted = try await client(server).makeSlideshow(session: "sidA", plan: plan, items: items, focused: true, notify: true)
        #expect(accepted == RenderAccepted(job: "j1", queued: true, queueAhead: 3))
        let req = try #require(server.requests.first)
        #expect(req.method == "POST" && req.path == "/studio/sidA/slideshow" && req.headers["authorization"] != nil)
        let sent = body(req)
        #expect(sent["items"] as? [Int] == [2, 0, 1] && sent["format"] as? String == "mp4" && sent["queue"] as? Bool == true)
        #expect(sent["priority"] as? String == "focused" && sent["notify"] as? Bool == true && sent["fade"] as? Bool == false)
        #expect(sent["frame"] as? String == "1:1" && sent["sound"] as? String == "own")
        let seconds = try #require(sent["seconds"] as? [Any])
        // play order is [2, 0, 1]: two photos, then the video
        #expect(seconds.count == 3 && seconds[0] as? Double == 1.5 && seconds[1] as? Double == 1.5 && seconds[2] is NSNull)
        #expect(sent["quality"] == nil && sent["width"] == nil, "an mp4 carries neither")
        // a webp carries both, and an unfocused request carries no priority
        _ = try await client(server).makeSlideshow(
            session: "sidA", plan: SlideshowPlan(format: .webp, items: [0, 2], quality: .low, width: 320), items: items, focused: false)
        let webp = body(server.requests[1])
        #expect(webp["quality"] as? String == "low" && webp["width"] as? Int == 320 && webp["priority"] == nil && webp["notify"] == nil)
    }

    @Test func aGalleryImageRequestNamesItsLayout() async throws {
        let server = try await LoopbackServer.start { _ in .json(#"{"status":"pending","job":"j2"}"#, status: 202) }
        defer { server.stop() }
        let accepted = try await client(server).makeGalleryImage(
            session: "sidB", plan: GalleryImagePlan(items: [3, 1, 2], layout: .row), focused: true)
        #expect(accepted == RenderAccepted(job: "j2", queued: false, queueAhead: nil))
        let req = try #require(server.requests.first)
        #expect(req.path == "/studio/sidB/gallery-image")
        let sent = body(req)
        #expect(sent["items"] as? [Int] == [3, 1, 2] && sent["layout"] as? String == "row" && sent["queue"] as? Bool == true && sent["priority"] as? String == "focused")
    }

    @Test func makesNeedAKey() async throws {
        let server = try await LoopbackServer.start { _ in .json("{}") }
        defer { server.stop() }
        await #expect(throws: CobaltError.noAPIKey) {
            _ = try await client(server, key: nil).makeGalleryImage(session: "s", plan: GalleryImagePlan(items: [0, 1], layout: .strip), focused: false)
        }
        #expect(server.requests.isEmpty)
    }

    @Test func aMakesProgressAndResultAreRead() async throws {
        let answers = Mutex(0)
        let server = try await LoopbackServer.start { _ in
            switch answers.withLock({ n -> Int in n += 1; return n }) {
            case 1: return .json(#"{"status":"pending","phase":"queued","queue_ahead":2}"#)
            case 2: return .json(#"{"status":"pending","phase":"composing","frames_done":3,"frames_total":10}"#)
            case 3: return .json(#"{"status":"pending","phase":"encoding","frames_done":8,"frames_total":20}"#)
            case 4: return .json(#"{"status":"pending","phase":"some_new_phase"}"#)
            case 5:
                return .json(#"{"status":"success","job":"j1","url":"https://media.capybaraharmony.com/abc.webp","item_id":"it9","bytes":1800000,"width":480,"height":600,"seconds":20.0,"format":"webp","replaced":["old1"]}"#)
            case 6:
                return .json(#"{"status":"success","job":"j2","item_id":"it10","bytes":2900000,"width":2160,"height":4500,"cropped":[1,2],"upscaled":[2]}"#)
            default: return .json(#"{"status":"error","error":{"code":"error.webp.encode_failed"}}"#)
            }
        }
        defer { server.stop() }
        let c = client(server)
        func status() async throws -> MakeStatus { try await c.makeStatus(session: "sid", job: "j1", wait: 1) }
        #expect(try await status() == .pending(phase: .queued, done: nil, total: nil, queueAhead: 2))
        #expect(try await status() == .pending(phase: .composing, done: 3, total: 10, queueAhead: nil))
        #expect(try await status() == .pending(phase: .encoding, done: 8, total: 20, queueAhead: nil))
        #expect(try await status() == .pending(phase: nil, done: nil, total: nil, queueAhead: nil))
        let webp = try await status()
        #expect(webp == .success(MadeResult(
            job: "j1", itemID: "it9", url: URL(string: "https://media.capybaraharmony.com/abc.webp"), bytes: 1_800_000, width: 480,
            height: 600, seconds: 20, format: .webp, replaced: ["old1"])))
        // a gallery image has no url when the post is private, no seconds, and says what it cropped and drew larger
        let image = try await status()
        guard case .success(let made) = image else { Issue.record("\(image)"); return }
        #expect(made.url == nil && made.seconds == nil && made.cropped == [1, 2] && made.upscaled == [2] && made.itemID == "it10")
        #expect(try await status() == .failed(code: "error.webp.encode_failed"))
        #expect(server.requests.allSatisfy { $0.path == "/studio/sid/render/j1" && $0.query == "wait=1" })
    }

    // MARK: renders of one item, retries, deletes, visibility

    @Test func aRenderOfAnItemSendsItAndALeadRenderSendsNothing() async throws {
        let server = try await LoopbackServer.start { _ in .json(#"{"status":"pending","job":"r1"}"#, status: 202) }
        defer { server.stop() }
        let c = client(server)
        _ = try await c.render(session: "sid", RenderRequest(start: 0, length: 5, width: 480, quality: .med, item: 3))
        _ = try await c.render(session: "sid", RenderRequest(start: 0, length: 5, width: 480, quality: .med))
        #expect(body(server.requests[0])["item"] as? Int == 3)
        #expect(body(server.requests[1])["item"] == nil, "absent = the lead, as before")
    }

    @Test func aRetryNamesTheIndicesAndJoinsTheLine() async throws {
        let server = try await LoopbackServer.start { _ in .json(#"{"status":"pending","id":"sidR","queued":true,"queue_ahead":1}"#, status: 202) }
        defer { server.stop() }
        let created = try await client(server).retryItems(session: "sidR", items: [6, 8])
        #expect(created.id == "sidR" && created.queued && created.queueAhead == 1)
        let req = try #require(server.requests.first)
        #expect(req.method == "POST" && req.path == "/studio/sidR/items/retry")
        #expect(body(req)["items"] as? [Int] == [6, 8] && body(req)["queue"] as? Bool == true)
    }

    @Test func deletingOneItemIsADeleteOfItsRow() async throws {
        let server = try await LoopbackServer.start { request in
            request.path.hasSuffix("last")
                ? .json(#"{"status":"error","error":{"code":"error.library.last_item"}}"#, status: 409)
                : .json(#"{"status":"success","deleted":{"files":1,"bytes":10}}"#)
        }
        defer { server.stop() }
        try await client(server).deleteItem("rowid1")
        #expect(server.requests[0].method == "DELETE" && server.requests[0].path == "/library/items/rowid1")
        await #expect(throws: CobaltError.api(code: "error.library.last_item", httpStatus: 409)) { try await client(server).deleteItem("last") }
    }

    @Test func aPostWideSwitchSendsTheScopeAndReadsAPartialAnswer() async throws {
        let answers = Mutex(0)
        let server = try await LoopbackServer.start { _ in
            if answers.withLock({ n -> Int in n += 1; return n }) == 1 {
                return .json(#"{"status":"success","items":[{"id":"a","kind":"private","source":"saved","name":"01.jpg","url":"https://media.capybaraharmony.com/a.jpg","content_type":"image/jpeg","created_at":1790000000000,"deletable":false,"visibility":"public","role":"item","item_index":0}],"cache_cleared":null}"#)
            }
            return .json(#"{"status":"error","error":{"code":"error.library.partial"},"items":[{"id":"a","kind":"private","source":"saved","name":"01.jpg","content_type":"image/jpeg","created_at":1790000000000,"deletable":false,"visibility":"private"}],"remaining":["b","c"]}"#, status: 502)
        }
        defer { server.stop() }
        let c = client(server)
        let done = try await c.setPostVisibility(anchor: "a", public: true)
        #expect(done.files.map(\.id) == ["a"] && done.remaining.isEmpty && done.files[0].galleryRole == .item && done.files[0].itemIndex == 0)
        let sent = body(server.requests[0])
        #expect(server.requests[0].method == "PATCH" && server.requests[0].path == "/library/items/a/visibility")
        #expect(sent["public"] as? Bool == true && sent["scope"] as? String == "post")
        let partial = try await c.setPostVisibility(anchor: "a", public: false)
        #expect(partial.remaining == ["b", "c"] && partial.files.count == 1, "a partial answer is returned, not thrown")
    }

    // MARK: reading a gallery

    @Test func aSessionOfAGalleryListsItsItems() throws {
        let json = #"""
        {"status":"ready","id":"sid","link":"https://x.com/a/status/1","service":"twitter","created_at":1790000000000,"expires_at":1790600000000,"renders":[],
         "item_count":4,"items":[{"i":0,"type":"photo","status":"ready","code":null},{"i":1,"type":"photo","status":"error","code":"error.api.fetch.expired"},{"i":2,"type":"weird","status":"ready"},"junk"]}
        """#
        let s = try CobaltJSON.decoder().decode(StudioSession.self, from: Data(json.utf8))
        #expect(s.itemCount == 4 && s.items.count == 3)
        #expect(s.items[0] == SessionItem(i: 0, type: .photo, status: .ready))
        #expect(s.items[1].status == .error && s.items[1].code == "error.api.fetch.expired")
        #expect(s.items[2].type == nil, "a type this build does not know reads as unsaid")
        // a single-file session has neither
        let single = try CobaltJSON.decoder().decode(StudioSession.self, from: Data(#"{"status":"saving","id":"s","created_at":1,"expires_at":2}"#.utf8))
        #expect(single.itemCount == nil && single.items.isEmpty)
    }

    @Test func libraryV3AsksForV3AndReadsTheGalleryRows() async throws {
        let server = try await LoopbackServer.start { _ in
            .json(#"""
            {"status":"success","counts":{"posts":1,"files":3},"usage":{"public_bytes":0,"private_bytes":9},"next":null,"posts":[
             {"id":"sid","service":"instagram","link":"https://www.instagram.com/p/Ddy0-gpGg5U/","created_at":1790000000000,"kind":"gallery","item_count":2,"items_failed":[2],
              "files":[
               {"id":"i0","kind":"private","source":"saved","name":"01.jpg","content_type":"image/jpeg","width":1080,"height":1350,"created_at":1790000000000,"deletable":false,"visibility":"private","visibility_toggle":true,"role":"item","item_index":0,"poster_url":"https://media.capybaraharmony.com/p0.jpg"},
               {"id":"i1","kind":"private","source":"saved","name":"02.jpg","content_type":"image/jpeg","created_at":1790000000001,"deletable":false,"role":"item","item_index":1},
               {"id":"m1","kind":"private","source":"studio","name":"slideshow","content_type":"image/webp","created_at":1790000001000,"deletable":false,"role":"slideshow","made_from":["i0","i1"],"made_spec":{"format":"webp","items":[0,1],"fade":true,"width":480}},
               {"id":"m2","kind":"private","source":"studio","name":"gi","content_type":"image/jpeg","created_at":1790000002000,"deletable":false,"role":"export","made_from":["i0","i1"],"made_spec":{"kind":"gallery","layout":"grid3","items":[0,1]}},
               {"id":"x1","kind":"private","source":"studio","name":"old pdf","content_type":"application/pdf","created_at":1790000003000,"deletable":false,"role":"export","made_spec":{"kind":"pdf"}}]}]}
            """#)
        }
        defer { server.stop() }
        let page = try await client(server).library(cursor: nil, limit: 20, v3: true)
        #expect(server.requests[0].query.contains("v=3") && server.requests[0].query.contains("limit=20"))
        let post = try #require(page.posts.first)
        #expect(post.kind == .gallery && post.itemCount == 2 && post.itemsFailed == [2])
        let files = Dictionary(uniqueKeysWithValues: post.files.map { ($0.id, $0) })
        #expect(files["i0"]?.galleryRole == .item && files["i0"]?.itemIndex == 0 && files["i0"]?.canToggleVisibility == true)
        #expect(files["m1"]?.madeFrom == ["i0", "i1"] && files["m1"]?.madeKind == .slideshow(.webp) && files["m1"]?.madeSpec?.items == [0, 1])
        #expect(files["m2"]?.madeKind == .galleryImage(.grid3))
        #expect(files["x1"]?.madeKind == nil, "an export that is not a gallery image is no tab")
        // the same page without v3 asks for neither
        _ = try await client(server).library(cursor: nil, limit: 20, v3: false)
        #expect(!server.requests[1].query.contains("v="))
        _ = try await client(server).library(cursor: nil, limit: 20, v2: true)
        #expect(server.requests[2].query.contains("v=2"))
    }

    @Test func aFileWithoutV3FieldsHasNoRoleAndAnOldPostNoKind() throws {
        let json = #"{"id":"p","files":[{"id":"f","kind":"private","source":"saved","name":"n","created_at":1,"deletable":false}],"created_at":1}"#
        let post = try CobaltJSON.decoder().decode(LibraryPost.self, from: Data(json.utf8))
        #expect(post.kind == nil && post.itemCount == nil && post.itemsFailed.isEmpty)
        #expect(post.files[0].galleryRole == nil && post.files[0].itemIndex == nil && post.files[0].madeFrom.isEmpty && post.files[0].madeSpec == nil)
        // and a role this build does not know never loses the file
        let odd = #"{"id":"f","kind":"private","source":"saved","name":"n","created_at":1,"role":"hologram","item_index":"x","made_from":3}"#
        let file = try CobaltJSON.decoder().decode(LibraryFile.self, from: Data(odd.utf8))
        #expect(file.galleryRole == nil && file.itemIndex == nil && file.madeFrom.isEmpty)
    }

    @Test func aV3FileSurvivesAnEncodeAndDecode() throws {
        var file = LibraryFile(
            id: "m", kind: .private, source: .studio, name: "n", url: nil, contentType: "image/jpeg", bytes: 5, width: 2, height: 3,
            duration: nil, createdAt: Date(timeIntervalSince1970: 1_790_000_000), mediaName: nil, deletable: false)
        file.galleryRole = .export
        file.madeFrom = ["a", "b"]
        file.madeSpec = MadeSpec(data: Data(#"{"kind":"gallery","layout":"strip","items":[0,1]}"#.utf8))
        let data = try CobaltJSON.encoder().encode(file)
        let back = try CobaltJSON.decoder().decode(LibraryFile.self, from: data)
        #expect(back.galleryRole == .export && back.madeFrom == ["a", "b"] && back.madeKind == .galleryImage(.strip))
    }
}
