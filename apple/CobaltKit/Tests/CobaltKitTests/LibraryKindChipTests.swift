import Foundation
import Testing
@testable import CobaltKit

/// The webps chip is every media with a webp the owner made; a video with webps stays a video too.
struct LibraryKindChipTests {
    private let original = #"{"id":"o1","kind":"private","source":"saved","name":"clip.mp4","content_type":"video/mp4","bytes":10,"created_at":1790000000000}"#
    private let webp = #"{"id":"w1","kind":"public","source":"studio","name":"x.webp","url":"https://media.capybaraharmony.com/AbCdEfGhIj.webp","content_type":"image/webp","bytes":4,"created_at":1790000001000,"media_name":"AbCdEfGhIj.webp","deletable":true}"#

    private func row(kind: String, files: [String]) throws -> LibraryRow {
        let json = #"{"id":"p","service":"instagram","created_at":1790000000000,"kind":"\#(kind)","files":[\#(files.joined(separator: ","))]}"#
        let post = try CobaltJSON.decoder().decode(LibraryPost.self, from: Data(json.utf8))
        return LibraryRow(item: try #require(MediaItem.merge(local: nil, post: post)))
    }

    private func passes(_ row: LibraryRow, _ filter: LibraryKindFilter) -> Bool {
        filter.passes(kind: row.kind, emote: row.emote, hasWebp: row.hasWebp)
    }

    @Test func aVideoWithAWebpIsOnVideosAndWebps() throws {
        let r = try row(kind: "video", files: [original, webp])
        #expect(r.kind == .video && r.hasWebp)
        #expect(passes(r, .videos) && passes(r, .webps) && passes(r, .all))
        #expect(!passes(r, .photos) && !passes(r, .galleries) && !passes(r, .emotes))
        #expect(LibraryKindFilter.chips(kind: r.kind, hasWebp: r.hasWebp) == [.videos, .webps])
    }

    @Test func aVideoWithNoWebpIsNotOnWebps() throws {
        let r = try row(kind: "video", files: [original])
        #expect(!r.hasWebp && passes(r, .videos) && !passes(r, .webps))
        #expect(LibraryKindFilter.chips(kind: r.kind, hasWebp: r.hasWebp) == [.videos])
    }

    @Test func aWebpOnlyPostIsOnWebpsOnceAndNotOnVideos() throws {
        let r = try row(kind: "webp", files: [webp])
        #expect(r.kind == .webp && passes(r, .webps) && !passes(r, .videos))
        #expect(LibraryKindFilter.chips(kind: r.kind, hasWebp: r.hasWebp) == [.webps])
    }
}
