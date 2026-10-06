import Foundation
import Testing
@testable import CobaltKit

struct LinkInfoAllLinksTests {
    private func strings(_ text: String, limit: Int = 20) -> [String] { LinkInfo.allLinks(in: text, limit: limit).map(\.absoluteString) }

    @Test func oneLinkIsTheFirstLink() {
        let text = "look https://www.instagram.com/reel/Dd7P496wolG/ wow"
        #expect(strings(text) == ["https://www.instagram.com/reel/Dd7P496wolG/"])
        #expect(LinkInfo.firstLink(in: text)?.absoluteString == "https://www.instagram.com/reel/Dd7P496wolG/")
    }

    @Test func everyLinkInOrderWithRepeatsFolded() {
        let text = """
        https://x.com/i/status/1 and https://x.com/i/status/2
        https://x.com/i/status/1
        https://www.tiktok.com/@a/video/3
        """
        #expect(strings(text) == ["https://x.com/i/status/1", "https://x.com/i/status/2", "https://www.tiktok.com/@a/video/3"])
    }

    @Test func trailingPunctuationIsTrimmedLikeTheApi() {
        #expect(strings("(see https://x.com/i/status/1), then https://x.com/i/status/2.") == ["https://x.com/i/status/1", "https://x.com/i/status/2"])
        #expect(strings("\"https://x.com/i/status/1\"! <https://x.com/i/status/2>?") == ["https://x.com/i/status/1", "https://x.com/i/status/2"])
        // no whitespace between two links: the API reads one run up to whitespace, so it is one link
        #expect(strings("https://x.com/i/status/1;https://x.com/i/status/2").count == 1)
    }

    @Test func linksGluedToTextByANewline() {
        #expect(strings("nice clip\nhttps://x.com/i/status/1\nlook at this\nhttps://x.com/i/status/2") == ["https://x.com/i/status/1", "https://x.com/i/status/2"])
        #expect(strings("cobalt:https://x.com/i/status/1") == ["https://x.com/i/status/1"])
    }

    @Test func capAtTwentyAndAtTheLimitGiven() {
        let many = (1...34).map { "https://x.com/i/status/\($0)" }.joined(separator: "\n")
        #expect(strings(many).count == 20)
        #expect(strings(many).first == "https://x.com/i/status/1" && strings(many).last == "https://x.com/i/status/20")
        #expect(strings(many, limit: 3).count == 3)
        #expect(strings(many, limit: 0).isEmpty)
    }

    @Test func noLinkAndNonWebSchemes() {
        #expect(strings("nothing here").isEmpty)
        #expect(strings("ftp://example.com/file mailto:a@b.c").isEmpty)
        #expect(strings("").isEmpty)
    }

    @Test func serviceNamesFollowLinkInfo() {
        let links = LinkInfo.allLinks(in: "https://twitter.com/a/status/9 https://x.com/i/status/9")
        #expect(links.compactMap { LinkInfo($0)?.service } == ["x", "x"])
    }

    @Test func schemeIsCaseInsensitive() {
        #expect(strings("HTTPS://X.COM/i/status/1").count == 1)
    }
}
