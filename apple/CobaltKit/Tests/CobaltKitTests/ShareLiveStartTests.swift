import Foundation
import Testing
@testable import CobaltKit

// The instant share asks the server to push-start its Live Activity (APP-API-CONTRACT 8.10): `live` on `POST /studio`.
@Suite struct ShareLiveStartTests {
    private let key = "8e1a4c2f-3b5d-4e6f-9a7b-0c1d2e3f4a5b"
    private let link = LinkInfo(URL(string: "https://www.instagram.com/reel/Dd7P496wolG/")!)!
    private let job = UUID(uuidString: "0B5F2C3E-6C1A-4F5E-9A57-1D0E6C9F2A11")!

    private func client() -> HTTPCobaltClient {
        HTTPCobaltClient(baseURL: URL(string: "https://api.capybaraharmony.com")!, apiKey: { [key] in key })
    }

    private func json(_ body: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test func theInstantSaveCarriesLiveWithTheJobAsTheRun() throws {
        let live = ShareLiveStart(job: job, link: link, environment: .production)
        let (_, body) = try client().shareSaveRequest(link: link.url, label: "instagram · Dd7P496wolG", live: live)
        let fields = try json(body)
        #expect(fields["live"] as? [String: String] == [
            "run": "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11", "environment": "production", "service": "instagram", "ref": "Dd7P496wolG",
        ])
    }

    @Test func noPushEnvironmentNoLive() throws {
        #expect(ShareLiveStart(job: job, link: link, environment: nil) == nil)
        let (_, body) = try client().shareSaveRequest(link: link.url, label: "x", live: nil)
        #expect(try json(body)["live"] == nil)
    }

    @Test func theGalleryCreateCarriesItToo() throws {
        var options = StudioCreateOptions(queue: true, origin: "share")
        options.live = ShareLiveStart(job: job, link: link, environment: .sandbox)
        let (_, body) = try client().shareSaveRequest(link: link.url, options: options)
        let live = try #require(try json(body)["live"] as? [String: String])
        #expect(live["environment"] == "sandbox" && live["run"] == "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11")
    }
}
