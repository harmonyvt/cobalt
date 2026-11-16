import Foundation
import Testing
@testable import CobaltKit

/// "variants" (APP-API-CONTRACT 20.2): emotes with the held emote's own 7TV name, never its alias in the set.
@MainActor
struct EmoteVariantsTests {
    private static func hit(_ id: String, _ name: String) -> EmoteHit {
        EmoteHit(
            id: id, name: name, animated: false,
            previewURL: URL(string: "https://cdn.7tv.app/emote/\(id)/2x.webp")!,
            fileURL: URL(string: "https://cdn.7tv.app/emote/\(id)/4x.webp")!,
            libraryID: nil, libraryURL: nil)
    }

    /// Renamed in the set: alias "vibe", own name "catJAM".
    private static let held = SevenTvSetItem(
        emoteID: "01F6MQ33FG000FFJ97ZB8MWV52", alias: "vibe", name: "catJAM", animated: true, previewURL: nil, fileURL: nil)

    @Test func theSameNameIgnoresCaseButNotExtraLetters() {
        #expect(EmoteVariants.sameName("catJAM", "CATJAM"))
        #expect(EmoteVariants.sameName(" catJAM", "catjam "))
        #expect(!EmoteVariants.sameName("catJAM", "catJAM2"))
        let kept = EmoteVariants.keep([Self.hit("a", "catJAM"), Self.hit("b", "catJAMming"), Self.hit("c", "CatJam")], name: "catJAM")
        #expect(kept.map(\.id) == ["a", "c"])
    }

    @Test func itLooksUpTheOwnNameNotTheAlias() async {
        let asked = Asked<String>()
        let model = SevenTvVariantsModel(emote: Self.held) { name, page in
            asked.items.append("\(name)#\(page)")
            return EmotePage(items: [Self.hit("01F6MQ33FG000FFJ97ZB8MWV52", "catJAM"), Self.hit("x", "CATJAM")], page: page, hasMore: false)
        }
        #expect(model.state == .loading)
        await model.load()
        #expect(asked.items == ["catJAM#1"])
        #expect(model.state == .loaded)
        #expect(model.items.map(\.id) == ["01F6MQ33FG000FFJ97ZB8MWV52", "x"])
        #expect(model.othersCount == 1)
        #expect(!model.hasMore)
    }

    @Test func emptyFilteredPagesReadOnAndRepeatsAreKeptOnce() async {
        let asked = Asked<Int>()
        // An old server: fuzzy pages, the name only on page 3; page 4 repeats an emote.
        let pages: [Int: [EmoteHit]] = [
            1: [Self.hit("n1", "catJAM2")],
            2: [Self.hit("n2", "catJAMs")],
            3: [Self.hit("a", "catJAM")],
            4: [Self.hit("a", "catJAM"), Self.hit("b", "catjam")],
        ]
        let model = SevenTvVariantsModel(emote: Self.held) { _, page in
            asked.items.append(page)
            return EmotePage(items: pages[page] ?? [], page: page, hasMore: page < 6)
        }
        await model.load()
        #expect(asked.items == [1, 2, 3])
        #expect(model.items.map(\.id) == ["a"])
        #expect(model.hasMore)
        await model.loadMore()
        #expect(asked.items == [1, 2, 3, 4])
        #expect(model.items.map(\.id) == ["a", "b"])
        // nothing more of the name: a step stops after pagesPerStep pages
        await model.loadMore()
        #expect(asked.items == [1, 2, 3, 4, 5, 6])
        #expect(!model.hasMore)
    }

    @Test func aFailedFirstPageSaysSo() async {
        let model = SevenTvVariantsModel(emote: Self.held) { _, _ in throw CobaltError.api(code: "error.emote.unavailable", httpStatus: 502) }
        await model.load()
        #expect(model.state == .failed)
        #expect(model.items.isEmpty)
    }

    @Test func thePreviewHasVariantsOfCatJam() async throws {
        let page = try await PreviewClient().emoteVariants(name: "catjam", page: 1)
        #expect(page.items.count == 4)
        #expect(page.items.allSatisfy { EmoteVariants.sameName($0.name, "catJAM") })
    }
}

@MainActor private final class Asked<T> {
    var items: [T] = []
}
