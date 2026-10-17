import Foundation
import Testing
@testable import CobaltKit

// Rich link pages (APP-API-CONTRACT 22): a copied public link is the server's share page, which unfurls as a
// playable video or a full-size image in Discord, iMessage, X and the rest. Absent `share_base_url`: the file's own URL.

struct ShareLinkTests {
    private func caps(_ extra: String) throws -> Capabilities {
        let json = #"{"server":"cobalt-cloudflare","features":{"studio":true},"media_base_url":"https://media.capybaraharmony.com/"\#(extra),"key":"valid"}"#
        return try #require(HTTPCobaltClient.parseForkCapabilities(Data(json.utf8)))
    }

    @Test func theShareBaseIsReadAndOnlyHttps() throws {
        #expect(try caps(#","share_base_url":"https://share.capybaraharmony.com/""#).shareBaseURL == URL(string: "https://share.capybaraharmony.com/"))
        #expect(try caps(#","share_base_url":null"#).shareBaseURL == nil)
        #expect(try caps("").shareBaseURL == nil)
        #expect(try caps(#","share_base_url":"http://share.capybaraharmony.com/""#).shareBaseURL == nil)
        #expect(Capabilities.unknown.shareBaseURL == nil)
    }

    @Test func aPublicFileBecomesItsPage() throws {
        let c = try caps(#","share_base_url":"https://share.capybaraharmony.com/""#)
        let file = try #require(URL(string: "https://media.capybaraharmony.com/AbCdEfGh12.mp4"))
        #expect(c.shareLink(for: file) == URL(string: "https://share.capybaraharmony.com/AbCdEfGh12"))
        let webp = try #require(URL(string: "https://media.capybaraharmony.com/WeBpWeBp01.webp"))
        #expect(c.shareLink(for: webp) == URL(string: "https://share.capybaraharmony.com/WeBpWeBp01"))
    }

    @Test(arguments: [
        "https://elsewhere.example/AbCdEfGh12.mp4",
        "https://media.capybaraharmony.com/a/b.mp4",
        "https://media.capybaraharmony.com/AbCdEfGh12",
        "https://media.capybaraharmony.com/AbCdEfGh12.mp4?x=1",
        "https://media.capybaraharmony.com/Ab.mp4",
    ])
    func anythingElseIsUnchanged(_ s: String) throws {
        let c = try caps(#","share_base_url":"https://share.capybaraharmony.com/""#)
        let url = try #require(URL(string: s))
        #expect(c.shareLink(for: url) == url)
    }

    @Test func withoutTheCapabilityTheFileItselfIsCopied() throws {
        let c = try caps("")
        let file = try #require(URL(string: "https://media.capybaraharmony.com/AbCdEfGh12.mp4"))
        #expect(c.shareLink(for: file) == file)
    }
}
