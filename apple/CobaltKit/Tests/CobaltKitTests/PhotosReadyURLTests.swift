import Foundation
import Testing
@testable import CobaltKit

// "save to photos" on a library file named without an extension: Photos refuses it, so it goes over as a named twin.
struct PhotosReadyURLTests {
    @Test func aNameWithAnExtensionIsKept() {
        let url = URL(fileURLWithPath: "/tmp/a.jpg")
        #expect(AppModel.photosReadyURL(url, ext: "jpg") == url)
    }

    @Test func aBareNameGetsATwinWithTheSniffedExtension() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bare-\(UUID().uuidString)")
        try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let twin = AppModel.photosReadyURL(file, ext: "jpg")
        defer { try? FileManager.default.removeItem(at: twin.deletingLastPathComponent()) }
        #expect(twin != file)
        #expect(twin.pathExtension == "jpg")
        #expect(try Data(contentsOf: twin) == Data([0xFF, 0xD8, 0xFF, 0xE0]))
    }

    @Test func noKnownTypeKeepsTheFile() {
        let url = URL(fileURLWithPath: "/tmp/bare")
        #expect(AppModel.photosReadyURL(url, ext: nil) == url)
    }
}
