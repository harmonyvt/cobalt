import Foundation
import Testing
@testable import CobaltKit

// The booru tab (APP-API-CONTRACT 72): the wire shapes, the tag count and the store against the preview client.
@Suite struct BooruTests {
    @Test func levelsHaveNoExplicit() {
        #expect(BooruLevel.allCases.map(\.rawValue) == ["g", "s"])
        #expect(BooruLevel(rawValue: "e") == nil)
        #expect(BooruLevel.general < .sensitive)
    }

    @Test func countsOnlyRealTags() {
        let q = BooruQuery(tags: "Hatsune_Miku  umbrella rating:e status:any")
        #expect(q.tagList == ["hatsune_miku", "umbrella"])
        #expect(!q.tooManyTags)
        #expect(BooruQuery(tags: "a b c").tooManyTags)
        let items = BooruQuery(tags: "a", order: .popular, minScore: 10, media: .image, shape: .tall).items(page: 2, level: .general)
        #expect(items.map(\.0) == ["tags", "page", "order", "level", "min_score", "media", "shape"])
        #expect(items.map(\.1) == ["a", "2", "popular", "g", "10", "image", "tall"])
    }

    @Test func decodesThePage() throws {
        let json = """
        {"status":"success","level":"s","posts":[{"id":7,"rating":"s","blur":true,"media":"image","ext":"png","width":800,
        "height":1200,"size":1000,"score":10,"favs":5,"created_at":"2026-11-18T10:00:00.000+09:00","source":null,
        "page_url":"https://danbooru.donmai.us/posts/7","thumb_url":"https://cdn.donmai.us/360x360/a.webp",
        "sample_url":"https://cdn.donmai.us/sample/a.jpg","file_url":"https://cdn.donmai.us/original/a.png",
        "tags":{"artist":["x"],"character":[],"copyright":[],"general":["rain"],"meta":[]}}],
        "hidden":{"level":2,"theme":1,"blacklist":0,"refine":0,"blocked":1},"next_page":2,"dropped":["order"]}
        """
        let page = try CobaltJSON.decoder().decode(BooruPage.self, from: Data(json.utf8))
        #expect(page.level == .sensitive && page.nextPage == 2 && page.dropped == ["order"])
        #expect(page.posts.first?.blur == true && page.posts.first?.pageUrl.absoluteString == "https://danbooru.donmai.us/posts/7")
        #expect(page.hidden.byFilters == 1)
    }

    @Test func decodesTheSettings() throws {
        let json = """
        {"status":"success","level":"q","levels":["g","s","q"],"themes":{"partial":"blur","violence":"hide"},
        "theme_list":[{"id":"partial","label":"partial nudity","detail":"d","default":"blur","min_level":"q","tags":["topless"]}],
        "blacklist":"rain","updated_at":5}
        """
        let s = try CobaltJSON.decoder().decode(BooruSettings.self, from: Data(json.utf8))
        // an old server's "q" reads as sensitive, the highest level now
        #expect(s.level == .sensitive && s.blacklist == "rain" && s.updatedAt == 5)
        #expect(s.themes["partial"] == .blur)
        #expect(s.themeList.first?.minLevel == .sensitive)
        #expect(BooruSettingsPatch(level: .general, themes: ["partial": .hide]).json["level"] as? String == "g")
    }

    @MainActor @Test func storeAsksForGeneralOnly() async {
        let model = AppModel.preview(.happy)
        let store = model.booru
        await store.load()
        #expect(store.phase == .loaded)
        #expect(!store.posts.isEmpty)
        #expect(store.askedLevel == .general)
        #expect(store.pageLevel == .general)
        #expect(store.posts.allSatisfy { $0.rating == .general })
    }

    @Test func creditKeepsThePageAndTheArtist() throws {
        let json = #"""
        {"id":7,"rating":"g","blur":false,"media":"image","ext":"png","width":10,"height":10,"size":1,"score":3,"favs":42,
         "created_at":"2024-01-02T03:04:05.678-05:00","source":"https://www.pixiv.net/artworks/99",
         "page_url":"https://danbooru.donmai.us/posts/7","thumb_url":"https://cdn.donmai.us/t.jpg","sample_url":"https://cdn.donmai.us/s.jpg",
         "file_url":"https://cdn.donmai.us/original/f.png",
         "tags":{"artist":["mochi_(artist)"],"character":["hatsune_miku"],"copyright":["vocaloid"],"general":[],"meta":[]}}
        """#
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        let post = try d.decode(BooruPost.self, from: Data(json.utf8))
        let c = BooruCredit(post: post)
        #expect(c.page.absoluteString == "https://danbooru.donmai.us/posts/7")
        #expect(c.artist == "mochi_(artist)" && c.source == "https://www.pixiv.net/artworks/99" && c.title == "hatsune miku")
        #expect(c.postedAt == 1_704_182_645_678 && c.favs == 42)
        var o = StudioCreateOptions()
        o.booru = c
        let body = o.body(link: post.fileUrl)
        #expect(body["url"] as? String == "https://cdn.donmai.us/original/f.png")
        #expect((body["booru"] as? [String: Any])?["page"] as? String == "https://danbooru.donmai.us/posts/7")
    }

    @Test func iqdbPageParses() {
        let html = """
        <div><table><tr><th>Your image</th></tr><tr><td class='image'><img src='/thu/x.jpg'></td></tr><tr><td>850×973 JPEG</td></tr></table>
        <table><tr><th>Best match</th></tr><tr><td class='image'><a href="//danbooru.donmai.us/posts/5001000"><img src='/danbooru/d/8/9/a.jpg' alt="Rating: s Score: 2 Tags: 1girl"></a></td></tr><tr><td>900×1030 [Safe]</td></tr><tr><td>97% similarity</td></tr></table>
        <table><tr><th>Possible match</th></tr><tr><td class='image'><a href="//danbooru.donmai.us/posts/9310510"><img src='b.jpg'></a></td></tr><tr><td>57% similarity</td></tr></table>
        <table><tr><th>Possible match</th></tr><tr><td class='image'><a href="//danbooru.donmai.us/posts/7831511"><img src='c.jpg'></a></td></tr><tr><td>62% similarity</td></tr></table>
        <table><tr><th>Additional match</th></tr><tr><td class='image'><a href="//danbooru.donmai.us/posts/5001000"><img src='d.jpg'></a></td></tr><tr><td>90% similarity</td></tr></table></div>
        """
        let found = Iqdb.parse(html: html)
        #expect(found.map(\.post) == [5001000, 7831511])
        #expect(found.map(\.similarity) == [97, 62])
        #expect(Iqdb.parse(html: "<p>No relevant matches</p>").isEmpty)
        let req = Iqdb.request(jpeg: Data([0xff, 0xd8]), boundary: "B")
        #expect(req.httpMethod == "POST" && req.url == Iqdb.url)
        let body = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("name=\"service[]\"\r\n\r\n1\r\n") && body.contains("name=\"file\"; filename=\"picture.jpg\""))
    }

    @Test func sureMatchIsNinetyOrMore() {
        let p = PreviewBooru.post(1, level: .general)
        #expect(BooruMatch(post: p, similarity: 90).isSure)
        #expect(!BooruMatch(post: p, similarity: 89).isSure)
    }

    @Test func danbooruSearchAnswerParses() {
        let list: [[String: Any]] = [
            ["post_id": 12, "score": 71.4, "post": ["id": 12, "rating": "g"]],
            ["post_id": 34, "score": 96.6],
            ["post_id": 12, "score": 50.0],
            ["post_id": 56, "score": 40.2],
            ["score": 99.0],
        ]
        let found = DanbooruAccount.parse(list)
        #expect(found.map(\.post) == [34, 12])
        #expect(found.map(\.similarity) == [97, 71])
        #expect(found[1].object?["rating"] as? String == "g" && found[0].object == nil)
        let a = DanbooruAccount(login: " mochi ", apiKey: "k3y\n")
        #expect(a.login == "mochi" && a.authorization == "Basic " + Data("mochi:k3y".utf8).base64EncodedString())
    }
}

