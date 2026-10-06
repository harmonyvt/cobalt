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

    // MARK: a huge clipboard

    private func clock(_ body: () -> Void) -> Double {
        let start = ContinuousClock.now
        body()
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    @Test func aMultiMegabyteClipboardWithManyLinksIsReadInOnePassWithinBounds() {
        // 6 MB of prose, a link every ~100 characters: a loop that re-copied the rest of the text per link would take
        // minutes; one pass over the first 200 000 characters takes milliseconds. The bound is loose on purpose.
        let line = "some words on the clipboard that are not a link at all, then https://x.com/i/status/%d and on\n"
        var big = ""
        var n = 0
        while big.utf8.count < 6_000_000 { n += 1; big += String(format: line, n) }
        var all: [URL] = []
        let seconds = clock { all = LinkInfo.allLinks(in: big, limit: 1000) }
        #expect(all.count == 1000, "the cap still fills from the part that is read")
        #expect(all.first?.absoluteString == "https://x.com/i/status/1")
        #expect(seconds < 3, "took \(seconds) s")
    }

    @Test func aMultiMegabyteClipboardWithNoLinkAndOneWithOnlyBrokenOnesAreFast() {
        let prose = String(repeating: "no links here, just words and http:// halves. ", count: 150_000)       // ~7 MB
        var found = [URL]()
        let none = clock { found = LinkInfo.allLinks(in: prose, limit: 1000) }
        #expect(found.isEmpty && none < 3, "took \(none) s")
        let broken = String(repeating: "https://%% https://%%%% ", count: 400_000)                                   // ~7 MB of matches that are not links
        let slow = clock { found = LinkInfo.allLinks(in: broken, limit: 1000) }
        #expect(found.isEmpty && slow < 5, "took \(slow) s")
    }

    @Test func onlyTheFirstScanLimitCharactersAreReadAndALinkCutByTheEdgeIsDropped() {
        let head = "https://x.com/i/status/1 "
        let filler = String(repeating: "a ", count: (LinkInfo.scanLimit - head.count) / 2)
        let edge = head + filler                                            // ends right at the limit
        let link = "https://x.com/i/status/2"
        // a link wholly beyond the limit is not read
        #expect(strings(edge + " " + link, limit: 1000) == ["https://x.com/i/status/1"])
        // a link straddling the limit is dropped rather than read half
        let straddling = String(edge.dropLast(10)) + link + " tail"
        #expect(!strings(straddling, limit: 1000).contains(link))
        #expect(strings(straddling, limit: 1000).first == "https://x.com/i/status/1")
        // inside the limit nothing changes
        #expect(strings(head + link) == ["https://x.com/i/status/1", link])
    }
}
