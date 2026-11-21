import Foundation
import Testing
@testable import CobaltKit

struct FileSniffTests {
    private func file(_ bytes: [UInt8], named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sniff-\(UUID().uuidString)-\(name)", isDirectory: false)
        try Data(bytes + [UInt8](repeating: 0, count: 24)).write(to: url)
        return url
    }

    @Test func readsTheBytesNotTheName() {
        #expect(FileSniff.kind(of: Data([0xFF, 0xD8, 0xFF, 0xE0])) == .image(ext: "jpg"))
        #expect(FileSniff.kind(of: Data([0x89] + Array("PNG".utf8))) == .image(ext: "png"))
        #expect(FileSniff.kind(of: Data(Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WEBP".utf8))) == .image(ext: "webp"))
        #expect(FileSniff.kind(of: Data([0, 0, 0, 0x18] + Array("ftypheic".utf8))) == .image(ext: "heic"))
        #expect(FileSniff.kind(of: Data([0, 0, 0, 0x18] + Array("ftypisom".utf8))) == .video(ext: "mp4"))
        #expect(FileSniff.kind(of: Data([0, 0, 0, 0x14] + Array("ftypqt  ".utf8))) == .video(ext: "mov"))
        #expect(FileSniff.kind(of: Data([1, 2, 3])) == nil)
    }

    /// The owner's "couldn't save to photos": a jpg that came without an extension was stored as `.mp4`.
    @Test func aPictureIsNeverStoredAsMp4() throws {
        let bare = try file([0xFF, 0xD8, 0xFF, 0xE0], named: "noext")
        #expect(FileSniff.storedExtension(for: bare, fallback: "mp4") == "jpg")
        let misnamed = try file([0xFF, 0xD8, 0xFF, 0xE0], named: "x.mp4")
        #expect(FileSniff.storedExtension(for: misnamed, fallback: "mp4") == "jpg")
        let video = try file([0, 0, 0, 0x18] + Array("ftypmp42".utf8), named: "x.mov")
        #expect(FileSniff.storedExtension(for: video, fallback: "mp4") == "mov")
        let unknown = try file([1, 2, 3], named: "x.gif")
        #expect(FileSniff.storedExtension(for: unknown, fallback: "mp4") == "gif")
    }
}
