import AVFoundation
import Foundation
import Testing
@testable import CobaltKit

/// A private library video plays without being kept offline: AVFoundation reads it through the keyed
/// `GET /library/items/<id>/file` in ranges, every request carrying the key.
@Suite(.serialized) @MainActor
struct KeyedStreamTests {
    @Test func streamURLsNameTheFile() throws {
        let url = try #require(KeyedStream.url(itemID: "AbCd1234EfGh5678", ext: "mov"))
        #expect(url.absoluteString == "cobalt-stream://item/AbCd1234EfGh5678.mov")
        #expect(KeyedStream.itemID(of: url) == "AbCd1234EfGh5678")
        #expect(KeyedStream.itemID(of: URL(string: "https://media.capybaraharmony.com/AbCd.mp4")!) == nil)
        #expect(KeyedStream.url(itemID: "x", ext: "")?.pathExtension == "mp4")
    }

    @Test func rangeAndLengthParsing() {
        let partial = HTTPURLResponse(
            url: URL(string: "https://x")!, statusCode: 206, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Range": "bytes 0-1/12345", "Content-Type": "video/mp4"])!
        #expect(KeyedStreamLoader.totalLength(of: partial) == 12345)
        #expect(KeyedStreamLoader.contentType(of: partial, url: nil) == "public.mpeg-4")
    }

    @Test func aPrivateVideoPlaysFromTheKeyedRoute() async throws {
        let data = try Data(contentsOf: try await TestVideo.clip())
        let server = try await LoopbackServer.start { request in
            guard request.headers["authorization"] == "Api-Key test-key" else {
                return .json(#"{"status":"error","error":{"code":"error.api.auth.key.missing"}}"#, status: 401)
            }
            guard request.path == "/library/items/AbCd1234EfGh5678/file" else { return .json("{}", status: 404) }
            return LoopbackServer.serve(data, contentType: "video/mp4", for: request)
        }
        defer { server.stop() }
        let client = HTTPCobaltClient(baseURL: server.base, apiKey: { "test-key" })
        KeyedStream.requests = { client }
        defer { KeyedStream.requests = nil }

        let url = try #require(KeyedStream.url(itemID: "AbCd1234EfGh5678"))
        let asset = KeyedStream.asset(url)
        let duration = try await asset.load(.duration)
        #expect(abs(duration.seconds - 6) < 0.2)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await video.load(.naturalSize)
        #expect(size.width == 96 && size.height == 160)

        // a frame comes out of it, as the player would show
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let frame = try await generator.image(at: CMTime(seconds: 3, preferredTimescale: 600)).image
        #expect(frame.width > 0)

        // every request was keyed and ranged, never one whole download
        #expect(!server.requests.isEmpty)
        #expect(server.requests.allSatisfy { $0.headers["authorization"] == "Api-Key test-key" })
        #expect(server.requests.allSatisfy { $0.headers["range"] != nil })
    }

    @Test func aRefusedKeyFailsTheLoad() async throws {
        let server = try await LoopbackServer.start { _ in
            .json(#"{"status":"error","error":{"code":"error.api.auth.key.invalid"}}"#, status: 401)
        }
        defer { server.stop() }
        let client = HTTPCobaltClient(baseURL: server.base, apiKey: { "wrong" })
        KeyedStream.requests = { client }
        defer { KeyedStream.requests = nil }
        let asset = KeyedStream.asset(try #require(KeyedStream.url(itemID: "AbCd1234EfGh5678")))
        await #expect(throws: (any Error).self) { _ = try await asset.load(.duration) }
    }

    @Test func otherURLsPlayAsTheyAre() throws {
        let plain = URL(fileURLWithPath: "/tmp/clip.mp4")
        #expect(KeyedStream.asset(plain).url == plain)
        // with no client wired (previews), a stream URL still makes an asset; it just never loads
        KeyedStream.requests = nil
        let url = try #require(KeyedStream.url(itemID: "AbCd"))
        #expect(KeyedStream.asset(url).url == url)
    }
}
