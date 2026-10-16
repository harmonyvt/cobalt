import Foundation
import Testing
@testable import CobaltKit

struct EmoteSuggestionTests {
    @Test func aColonAfterSpaceOrAtTheStartIsATrigger() {
        #expect(EmoteTrigger.query(before: ":") == "")
        #expect(EmoteTrigger.query(before: "hi :cat") == "cat")
        #expect(EmoteTrigger.query(before: "hi\n:cat_JAM-2") == "cat_JAM-2")
        #expect(EmoteTrigger.query(before: ":catJAM") == "catJAM")
    }

    @Test func timesLinksAndFinishedWordsAreNot() {
        #expect(EmoteTrigger.query(before: nil) == nil)
        #expect(EmoteTrigger.query(before: "") == nil)
        #expect(EmoteTrigger.query(before: "at 12:30") == nil)
        #expect(EmoteTrigger.query(before: "https:") == nil)
        #expect(EmoteTrigger.query(before: ":cat ") == nil)
        #expect(EmoteTrigger.query(before: "hi ::") == nil)
        #expect(EmoteTrigger.query(before: ":" + String(repeating: "a", count: 65)) == nil)
    }

    @Test func recentsMoveToTheFrontAndStayCapped() {
        let a = hit("a", "catJAM"), b = hit("b", "pepeD")
        var list = EmoteRecents.adding(a, to: [])
        list = EmoteRecents.adding(b, to: list)
        list = EmoteRecents.adding(a, to: list)
        #expect(list.map(\.id) == ["a", "b"])
        let many = (0..<40).reduce([EmoteHit]()) { EmoteRecents.adding(hit("\($1)", "e\($1)"), to: $0) }
        #expect(many.count == EmoteRecents.limit)
        #expect(many.first?.id == "39")
    }

    @Test func prefixMatchesComeBeforeContains() {
        let list = [hit("1", "vibeCat"), hit("2", "catJAM"), hit("3", "dog")]
        #expect(EmoteRecents.matching("CAT", in: list).map(\.id) == ["2", "1"])
        #expect(EmoteRecents.matching("", in: list).map(\.id) == ["1", "2", "3"])
    }

    @Test func suggestionsPutRecentsFirstWithoutRepeats() {
        let saved = URL(string: "https://media.capybaraharmony.com/AbCdEfGhIj.webp")!
        let recent = hit("a", "catJAM")
        var fresh = hit("a", "catJAM")
        fresh.libraryID = "f1"
        fresh.libraryURL = saved
        let out = EmoteRecents.suggestions(query: "cat", recents: [recent, hit("z", "dog")], found: [hit("b", "catKISS"), fresh])
        #expect(out.map(\.id) == ["a", "b"])
        #expect(out.first?.libraryURL == saved)
    }

    @Test func theStoredListRoundTrips() {
        var one = hit("a", "catJAM")
        one.libraryURL = URL(string: "https://media.capybaraharmony.com/AbCdEfGhIj.webp")
        let back = EmoteRecents.decode(EmoteRecents.encode([one]))
        #expect(back == [one])
        #expect(EmoteRecents.decode(Data("junk".utf8)).isEmpty)
    }

    private func hit(_ id: String, _ name: String) -> EmoteHit {
        EmoteHit(
            id: id, name: name, animated: true,
            previewURL: URL(string: "https://cdn.7tv.app/emote/\(id)/2x.webp")!,
            fileURL: URL(string: "https://cdn.7tv.app/emote/\(id)/4x.webp")!,
            libraryID: nil, libraryURL: nil)
    }
}
