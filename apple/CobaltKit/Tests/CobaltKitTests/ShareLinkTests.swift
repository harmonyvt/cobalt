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

    @Test func shortcutSavesHandOutShareLinksNotFiles() throws {
        let c = try caps(#","share_base_url":"https://share.capybaraharmony.com/""#)
        let media = { (n: String) in URL(string: "https://media.capybaraharmony.com/\(n)")! }
        let save = ShortcutSave(
            id: "p", title: "t", link: nil, service: nil, state: .saved, publicLink: media("ViDeO00001.mp4"),
            webpLinks: [media("WeBpWeBp01.webp")], created: .now, itemLinks: [media("PhOtO00001.jpg")],
            madeLinks: [media("MaDeMaDe01.webp"), URL(string: "https://elsewhere.example/x.mp4")!])
        let shared = save.sharing(c)
        #expect(shared.publicLink == URL(string: "https://share.capybaraharmony.com/ViDeO00001"))
        #expect(shared.webpLinks == [URL(string: "https://share.capybaraharmony.com/WeBpWeBp01")!])
        #expect(shared.itemLinks == [URL(string: "https://share.capybaraharmony.com/PhOtO00001")!])
        #expect(shared.madeLinks == [URL(string: "https://share.capybaraharmony.com/MaDeMaDe01")!, URL(string: "https://elsewhere.example/x.mp4")!])
        #expect(save.sharing(try caps("")) == save)   // no share pages: the files themselves
    }

    @Test func withoutTheCapabilityTheFileItselfIsCopied() throws {
        let c = try caps("")
        let file = try #require(URL(string: "https://media.capybaraharmony.com/AbCdEfGh12.mp4"))
        #expect(c.shareLink(for: file) == file)
    }
}
