import Foundation
import Testing
@testable import CobaltKit

struct EmoteTests {
    @Test func anEmoteFileDecodesAndABadLinkDoesNotDropThePost() throws {
        let json = """
        {"id":"post1","created_at":1790000000000,"link":"7tv:01F6MQ33FG000FFJ97ZB8MWV52",
         "files":[{"id":"f1","kind":"public","source":"emote","name":"catJAM","url":"https://media.capybaraharmony.com/AbCdEfGhIj.webp","content_type":"image/webp","bytes":4,"width":128,"height":128,"created_at":1790000000000}]}
        """
        let post = try CobaltJSON.decoder().decode(LibraryPost.self, from: Data(json.utf8))
        #expect(post.link == nil)
        #expect(post.isEmote)
        #expect(post.files.first?.source == .emote)
        let row = LibraryRow(item: try #require(MediaItem.merge(local: nil, post: post)))
        #expect(row.emote)
        #expect(!LibraryKindFilter.all.passes(kind: row.kind, emote: true))
        #expect(!LibraryKindFilter.webps.passes(kind: .webp, emote: true))
        #expect(LibraryKindFilter.emotes.passes(kind: .webp, emote: true))
        #expect(LibraryKindFilter.webps.passes(kind: .webp, emote: false))
    }

    @Test func searchJsonKeepsTheLargestFileAndAMissingSave() throws {
        let json = """
        {"items":[{"id":"01F6MQ33FG000FFJ97ZB8MWV52","name":"catJAM","animated":true,
          "preview_url":"https://cdn.7tv.app/emote/01F6MQ33FG000FFJ97ZB8MWV52/2x.webp",
          "file_url":"https://cdn.7tv.app/emote/01F6MQ33FG000FFJ97ZB8MWV52/4x.webp",
          "library_id":null,"library_url":null}]}
        """
        let hit = try CobaltJSON.decoder().decode(EmoteListProbe.self, from: Data(json.utf8)).items[0]
        #expect(hit.fileURL.absoluteString.hasSuffix("/4x.webp"))
        #expect(hit.previewURL.absoluteString.hasSuffix("/2x.webp"))
        #expect(hit.libraryID == nil)
    }

    @Test func sortsAreTheServersWords() {
        #expect(EmoteSort.allCases.map(\.rawValue) == [
            "trending_daily", "trending_weekly", "trending_monthly", "top_daily", "top_weekly", "top_monthly", "top", "new",
            "global",
        ])
    }

    @Test func aBrowsePageDecodesWithItsPaging() throws {
        let json = """
        {"items":[{"id":"01F6MQ33FG000FFJ97ZB8MWV52","name":"catJAM","animated":true,
          "preview_url":"https://cdn.7tv.app/emote/01F6MQ33FG000FFJ97ZB8MWV52/2x.webp",
          "file_url":"https://cdn.7tv.app/emote/01F6MQ33FG000FFJ97ZB8MWV52/4x.webp",
          "width":128,"height":128,"library_id":"f1","library_url":"https://media.capybaraharmony.com/AbCdEfGhIj.webp"}],
         "sort":"trending_weekly","page":2,"has_more":true}
        """
        let probe = try CobaltJSON.decoder().decode(EmotePageProbe.self, from: Data(json.utf8))
        #expect(probe.items.first?.libraryID == "f1")
        #expect(probe.page == 2)
        #expect(probe.hasMore == true)
        #expect(EmoteSort(rawValue: probe.sort) == .trendingWeekly)
    }

    @Test func thePreviewBrowsesWithoutAName() async throws {
        let page = try await PreviewClient().browseEmotes(query: "", sort: .topWeekly, page: 1)
        #expect(page.items.map(\.name) == ["catJAM"])
        #expect(!page.hasMore)
    }
}

private struct EmoteListProbe: Decodable { var items: [EmoteHit] }
private struct EmotePageProbe: Decodable { var items: [EmoteHit]; var sort: String; var page: Int; var hasMore: Bool }
