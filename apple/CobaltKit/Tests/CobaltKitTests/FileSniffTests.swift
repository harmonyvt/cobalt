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

    /// The owner's second "couldn't save to photos" (8.32, 2026-11-21): a library jpg downloaded with no extension
    /// reached Photos as a bare name, which PhotoKit refuses. Photos now gets it under the extension of its bytes.
    @Test func photosGetsANameThatMatchesTheBytes() async throws {
        let bare = try file([0xFF, 0xD8, 0xFF, 0xE0], named: "noext")
        let ready = try await FileSniff.photosReady(bare, isImage: false)
        #expect(ready.temporary && ready.isImage && ready.url.pathExtension == "jpg")
        #expect(try Data(contentsOf: ready.url) == Data(contentsOf: bare))
        await FileSniff.discardPhotosCopy(ready)
        #expect(!FileManager.default.fileExists(atPath: ready.url.path))
        #expect(FileManager.default.fileExists(atPath: bare.path), "the original stays")

        let misnamed = try file([0x89] + Array("PNG".utf8), named: "x.mp4")
        let fixed = try await FileSniff.photosReady(misnamed, isImage: false)
        #expect(fixed.temporary && fixed.isImage && fixed.url.pathExtension == "png")

        let fine = try file([0, 0, 0, 0x18] + Array("ftypmp42".utf8), named: "x.mp4")
        let same = try await FileSniff.photosReady(fine, isImage: false)
        #expect(!same.temporary && same.url == fine && !same.isImage)

        let unknown = try file([1, 2, 3], named: "bare")
        let guessed = try await FileSniff.photosReady(unknown, isImage: true)
        #expect(guessed.temporary && guessed.url.pathExtension == "jpg" && guessed.isImage)
    }
}

struct MediaExtensionTests {
    @Test func theAppsExtensionsAreAnsweredFromTheTable() {
        #expect(MediaExtension.isImage("JPG") && MediaExtension.isImage("webp") && MediaExtension.isImage("heic"))
        #expect(MediaExtension.isMovie("mp4") && MediaExtension.isMovie("MOV") && !MediaExtension.isMovie("png"))
        #expect(MediaExtension.isMedia("m4a") && !MediaExtension.isMedia("") && !MediaExtension.isMedia("txt"))
    }
}
