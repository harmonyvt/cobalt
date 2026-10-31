import Foundation
import Testing
@testable import CobaltKit

/// The select panel's trash on a video with webps: the webps can be picked one by one, the video only goes with everything.
struct DeletePickTests {
    private func video(webps: [String?]) -> MediaItem {
        let now = Date()
        var renditions = [Rendition(id: "video", kind: .video, publicURL: URL(string: "https://media.example/v.mp4"), createdAt: now)]
        for (n, name) in webps.enumerated() {
            renditions.append(Rendition(
                id: "w\(n + 1)", kind: .webp(number: n + 1), publicURL: URL(string: "https://media.example/w\(n + 1).webp"),
                createdAt: now, deletableName: name))
        }
        return MediaItem(id: "m", local: nil, post: nil, service: nil, ref: nil, link: nil, renditions: renditions)
    }

    @Test func aVideosWebpsArePickedOneByOne() {
        var pick = DeletePick(item: video(webps: ["a.webp", "b.webp", "c.webp"]))
        #expect(pick.canChoose && pick.choosable.map(\.id) == ["w1", "w2", "w3"])
        pick.toggle("w2")
        #expect(pick.plan == .files(items: [], made: [], webps: ["w1", "w3"]))
        #expect(pick.isChosen("w1") && !pick.isChosen("w2"))
        // ticking all three webps again still keeps the video: the video only goes with everything
        pick.toggle("w2")
        #expect(pick.plan == .files(items: [], made: [], webps: ["w1", "w2", "w3"]))
        #expect(!pick.isChosen("video"))
        pick.toggleEverything()
        #expect(pick.plan == .everything && pick.isChosen("video"))
    }

    @Test func aWebpTheServerCannotDeleteAloneIsNotOffered() {
        let pick = DeletePick(item: video(webps: [nil, "b.webp"]))
        #expect(pick.choosable.map(\.id) == ["w2"])
        #expect(DeletePick(item: video(webps: [])).canChoose == false)
    }

    @Test func untickingTheWholePostKeepsIt() {
        var pick = DeletePick(item: video(webps: ["a.webp"]))
        pick.toggleEverything()
        #expect(pick.plan == .nothing && pick.fileCount == 0)
    }
}
