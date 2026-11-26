import Foundation
import Testing
@testable import CobaltKit

@Suite struct CapybaraUploadNamesTests {
    private struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    @Test func everyCandidateIsCleanAndFitsNotifications() {
        let all = CapybaraUploadNames.allCandidates
        #expect(all.count >= 800, "pool should stay large and varied")
        for name in all {
            #expect(MediaTitle.clean(name) == name, "candidate must pass MediaTitle.clean unchanged: \(name)")
            #expect(name.unicodeScalars.count <= MediaTitle.notifyLength, "candidate too long for notifications: \(name)")
            #expect(name == name.lowercased(), "candidate should match cobalt lowercase copy: \(name)")
        }
    }

    @Test func generatorProducesVariedValidNames() {
        var rng = SeededRNG(state: 42)
        var seen = Set<String>()
        for _ in 0..<200 {
            let name = CapybaraUploadNames.random(using: &rng)
            #expect(MediaTitle.clean(name) == name)
            #expect(name.unicodeScalars.count <= MediaTitle.notifyLength)
            seen.insert(name)
        }
        #expect(seen.count > 100, "expected high variety across 200 draws, got \(seen.count)")
    }

    @Test func shareUploadRequestIncludesTitleWhenProvided() throws {
        let client = HTTPCobaltClient(baseURL: URL(string: "https://api.capybaraharmony.com")!, apiKey: { "test-key" })
        let req = try client.shareUploadRequest(
            name: "IMG_0412.heic", contentType: "image/heic", public: true, title: "tax-evading capybara")
        #expect(req.url?.absoluteString == "https://api.capybaraharmony.com/studio/upload?name=IMG_0412.heic&public=1&queue=1&title=tax-evading%20capybara")
    }

    @Test func instantUploadSummaryPrefersCustomTitleWhenSet() {
        let file = URL(fileURLWithPath: "/tmp/upload-a-0.heic")
        let named = SharedUpload(file: file, name: "IMG_0412.heic", contentType: "image/heic", bytes: 10, title: "sleepy yuzu capy")
        let plain = SharedUpload(file: file, name: "IMG_0412.heic", contentType: "image/heic", bytes: 10)
        #expect(InstantShare.uploadSummary([named]) == "sleepy yuzu capy")
        #expect(InstantShare.uploadSummary([plain]) == "IMG_0412.heic")
        #expect(InstantShare.uploadSummary([named, plain]) == "2 files")
    }
}
