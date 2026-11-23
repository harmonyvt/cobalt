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

    @MainActor @Test func storeSearchesAndNeverAsksAboveGeneralInSafeMode() async {
        let model = AppModel.preview(.happy)
        let store = model.booru
        await store.load()
        #expect(store.phase == .loaded)
        #expect(!store.posts.isEmpty)
        #expect(store.posts.allSatisfy { $0.rating <= .sensitive })
        // safeMode's didSet starts the reload itself; a second reload here would be dropped by the generation check
        store.safeMode = true
        for _ in 0..<200 where store.pageLevel != .general || store.phase != .loaded {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.pageLevel == .general)
        #expect(store.posts.allSatisfy { $0.rating == .general })
    }

    @Test func levelShowsNoHigherThanAsked() {
        #expect(BooruLevel.shows(.general, at: .general))
        #expect(!BooruLevel.shows(.sensitive, at: .general))
        #expect(BooruLevel.shows(.sensitive, at: .sensitive))
        #expect(BooruLevel.shows(.general, at: .sensitive))
        #expect(BooruLevel.shows(.sensitive, at: nil))
    }

    /// A post open in the pane is judged by the store, not the booru screen: safe mode lowers the level at once.
    @MainActor @Test func storeStopsAllowingASensitivePostInSafeMode() async throws {
        let model = AppModel.preview(.happy)
        let store = model.booru
        await store.load()
        #expect(store.settings?.level == .sensitive)
        let sensitive = try #require(store.posts.first { $0.rating == .sensitive })
        let general = try #require(store.posts.first { $0.rating == .general })
        #expect(store.allows(sensitive) && store.allows(general))
        store.safeMode = true
        #expect(!store.allows(sensitive))
        #expect(store.allows(general))
        store.safeMode = false
        #expect(store.allows(sensitive))
    }
}
