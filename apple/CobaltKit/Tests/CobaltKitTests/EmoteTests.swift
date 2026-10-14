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
}

private struct EmoteListProbe: Decodable { var items: [EmoteHit] }
