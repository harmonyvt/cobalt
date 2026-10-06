import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import CobaltKit

// The repost tools (apple/CONTRACT-GALLERY.md 1.23-1.24, wave A7): `PUT /library/items/<id>/made` on the wire, `crop` through
// the model on the gallery preview scenarios (render on the device, upload, store, tab), and `repost frame` that makes files
// and keeps nothing.

private let igLink = URL(string: "https://www.instagram.com/p/Ddy0-gpGg5U/")!
private let mixLink = URL(string: "https://www.instagram.com/p/DdMix1xedPo/")!
private let key = "7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21"

private func client(_ server: LoopbackServer) -> HTTPCobaltClient {
    HTTPCobaltClient(baseURL: server.base, apiKey: { key })
}

/// A real photo (a JPEG, top half red and bottom half blue) of the size an Instagram carousel photo has.
private func writePhoto(to url: URL, width: Int = 1080, height: Int = 1350) throws {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(srgbRed: 0.92, green: 0.2, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))
    context.setFillColor(CGColor(srgbRed: 0.2, green: 0.3, blue: 0.92, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
    let sink = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(sink, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(sink) else { throw FrameRenderer.Failure.failed }
}

private func jpegBytes() throws -> URL {
    let url = try makeTempDirectory().appendingPathComponent("crop.jpg")
    try writePhoto(to: url, width: 90, height: 160)
    return url
}

@MainActor private final class Finished { var value = false }

@MainActor @discardableResult
private func driven<T: Sendable>(_ h: Harness, _ op: @escaping @MainActor () async throws -> T) async throws -> T {
    let flag = Finished()
    let task = Task { @MainActor () throws -> T in
        defer { flag.value = true }
        return try await op()
    }
    await h.drive(until: { flag.value })
    return try await task.value
}

@MainActor
private func calls(_ h: Harness, _ name: String) -> [String] {
    (h.ctx.client as! PreviewClient).galleries.calls.filter { $0.name == name }.map(\.detail)
}

/// The temporary frame folders that hold a file of this name (other tests run beside this one: names keep them apart).
private func frameFolders(holding name: String) -> [String] {
    let tmp = FileManager.default.temporaryDirectory
    return ((try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []).filter {
        $0.hasPrefix("cobalt-frames-") && FileManager.default.fileExists(atPath: tmp.appendingPathComponent($0).appendingPathComponent(name).path)
    }
}

/// Pastes the scenario's link, runs to the end of the save, and puts a real photo behind every kept item (the preview
/// server's files are placeholders), so the renderer has pixels to draw.
@MainActor
private func savedGallery(_ scenario: PreviewScenario, link: URL = igLink) async throws -> (Harness, MediaItem) {
    let h = Harness(scenario)
    h.pipeline.start(link: link)
    await h.driveToSettled()
    let sid = try #require(h.pipeline.sessionID)
    try await refreshed(h)
    for record in try #require(h.app.store.media(session: sid)).items {
        if let url = record.fileURL { try writePhoto(to: url) }
    }
    return (h, try fresh(h))
}

/// Reads the library again until it lists the post (a refresh that finds one already running does nothing, and a loaded
/// machine makes that likely).
@MainActor
private func refreshed(_ h: Harness) async throws {
    let sid = try #require(h.pipeline.sessionID)
    for _ in 0..<20 {
        await h.app.library.refresh()
        if h.app.library.posts.contains(where: { $0.id == sid }) { return }
        try? await Task.sleep(for: .milliseconds(50))
    }
}

@MainActor
private func fresh(_ h: Harness) throws -> MediaItem {
    let sid = try #require(h.pipeline.sessionID)
    return h.app.mediaItem(for: try #require(h.app.library.posts.first { $0.id == sid }))
}

private let story = FrameSpec(aspect: .story, fill: .blur)

// MARK: - the wire

@Suite(.serialized)
struct MadeUploadWireTests {
    @Test func theCropGoesUpAsOneKeyedPutWithItsSpecInTheQuery() async throws {
        let server = try await LoopbackServer.start { _ in
            .json(#"{"status":"success","item":{"id":"crop1","kind":"private","source":"made","name":"photo 3 · crop 9:16.jpg","content_type":"image/jpeg","created_at":1790000000000,"deletable":false,"visibility":"public","url":"https://media.capybaraharmony.com/crop1.jpg","width":1080,"height":1920,"role":"crop","made_from":["rowid3"],"made_spec":{"aspect":"9:16","fill":"blur"}},"replaced":[]}"#, status: 201)
        }
        defer { server.stop() }
        let file = try jpegBytes()
        let progress = Mutex<[TransferProgress]>([])
        let made = try await client(server).uploadMade(
            item: "rowid3", role: .crop, file: file, contentType: "image/jpeg", name: "photo 3 · crop 9:16.jpg",
            spec: story.wireData, progress: { p in progress.withLock { $0.append(p) } })
        let r = try #require(server.requests.first)
        #expect(r.method == "PUT" && r.path == "/library/items/rowid3/made")
        #expect(r.headers["content-type"] == "image/jpeg" && r.headers["authorization"] == "Api-Key \(key)")
        let sent = try Data(contentsOf: file)
        #expect(r.headers["content-length"] == String(sent.count) && r.body == sent)
        // the query: role, a name and a spec (JSON, under 512 bytes), each percent-encoded
        var parts = URLComponents()
        parts.percentEncodedQuery = r.query
        let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["role"] == "crop" && query["name"] == "photo 3 · crop 9:16.jpg")
        #expect(query["spec"] == #"{"aspect":"9:16","fill":"blur"}"# && (query["spec"]?.utf8.count ?? 999) <= 512)
        // the answer is the new row
        #expect(made.file.id == "crop1" && made.file.galleryRole == .crop && made.file.madeSpec?.frame?.aspect == .story && made.replaced.isEmpty)
        #expect(made.file.madeKind == .crop && made.file.isPublic)
    }

    @Test func aMadeRowOfTheLibraryListingIsNotDropped() async throws {
        // the server's `source` for a crop is "made" (18.6): a library that cannot read the word would lose every crop
        let server = try await LoopbackServer.start { _ in
            .json(#"""
            {"status":"success","counts":{"posts":1,"files":2},"usage":{"public_bytes":0,"private_bytes":9},"next":null,"posts":[
             {"id":"sid","service":"instagram","link":"https://www.instagram.com/p/Ddy0-gpGg5U/","created_at":1790000000000,"kind":"gallery","item_count":2,"items_failed":[],
              "files":[{"id":"i0","kind":"private","source":"saved","name":"01.jpg","content_type":"image/jpeg","created_at":1790000000000,"deletable":false,"visibility":"private","role":"item","item_index":0},
                       {"id":"c1","kind":"private","source":"made","name":"photo 1 · crop 4:5.jpg","content_type":"image/jpeg","created_at":1790000001000,"deletable":false,"visibility":"private","role":"crop","made_from":["i0"],"made_spec":{"aspect":"4:5","fill":"cut","rect":[0.1,0,0.8,1]}}]}]}
            """#)
        }
        defer { server.stop() }
        let page = try await client(server).library(cursor: nil, limit: 25, v3: true)
        let files = try #require(page.posts.first).files
        #expect(files.map(\.id) == ["i0", "c1"], "the crop's row is listed")
        #expect(files[1].source == .made && files[1].madeKind == .crop && files[1].madeSpec?.frame?.rect == CGRect(x: 0.1, y: 0, width: 0.8, height: 1))
    }

    @Test func theServersRefusalsKeepTheirCodes() async throws {
        let server = try await LoopbackServer.start { request in
            switch request.path {
            case "/library/items/video/made": return .json(#"{"status":"error","error":{"code":"error.library.not_photo"}}"#, status: 409)
            case "/library/items/big/made": return .json(#"{"status":"error","error":{"code":"error.studio.too_large"}}"#, status: 413)
            case "/library/items/bad/made": return .json(#"{"status":"error","error":{"code":"error.library.bad_request"}}"#, status: 400)
            default: return .json(#"{"status":"success"}"#, status: 201)
            }
        }
        defer { server.stop() }
        let file = try jpegBytes()
        func put(_ id: String) async throws -> MadeUpload {
            try await client(server).uploadMade(
                item: id, role: .crop, file: file, contentType: "image/jpeg", name: "c.jpg", spec: story.wireData, progress: { _ in })
        }
        await #expect(throws: CobaltError.api(code: "error.library.not_photo", httpStatus: 409)) { try await put("video") }
        await #expect(throws: CobaltError.api(code: "error.studio.too_large", httpStatus: 413)) { try await put("big") }
        await #expect(throws: CobaltError.api(code: "error.library.bad_request", httpStatus: 400)) { try await put("bad") }
        await #expect(throws: CobaltError.self, "a 201 with no row is not a success") { try await put("odd") }
    }

    @Test func aClientWithNoKeyThrowsBeforeAnyRequest() async throws {
        let server = try await LoopbackServer.start { _ in .json("{}", status: 201) }
        defer { server.stop() }
        let keyless = HTTPCobaltClient(baseURL: server.base, apiKey: { nil })
        await #expect(throws: CobaltError.noAPIKey) {
            try await keyless.uploadMade(
                item: "a", role: .crop, file: try jpegBytes(), contentType: "image/jpeg", name: "c.jpg", spec: story.wireData, progress: { _ in })
        }
        #expect(server.requests.isEmpty)
    }
}

// MARK: - crop

@Suite(.serialized) @MainActor
struct PhotoCropTests {
    @Test func aCropIsDrawnOnTheDeviceUploadedStoredAndShownAsATab() async throws {
        let (h, item) = try await savedGallery(.galleryInstagram)
        let app = h.app
        let sid = try #require(h.pipeline.sessionID)
        let photo3 = try #require(item.items.first { $0.itemIndex == 2 })
        #expect(app.canStoreCrop(of: photo3))
        let progress = Mutex<[TransferProgress]>([])
        let upload = try await driven(h) { try await app.saveCrop(of: photo3, in: item, spec: story, progress: { p in progress.withLock { $0.append(p) } }) }
        // the server saw one PUT for photo 3's row, with the spec
        #expect(calls(h, "made") == [#"crop \#(sid)-i02 {"aspect":"9:16","fill":"blur"}"#])
        #expect(upload.file.galleryRole == .crop && upload.replaced.isEmpty && !progress.withLock { $0 }.isEmpty)
        // it is a made file of the media on this device: kept, with its spec, from photo 3, and named for the folder
        let media = try #require(app.store.media(session: sid))
        let kept = try #require(media.made.first { $0.role == .crop })
        #expect(kept.madeFrom == [2] && kept.libraryID == upload.file.id && kept.fileURL != nil && media.items.count == 10)
        let keptSpec = try #require(kept.madeSpec)
        #expect(MadeSpec(data: keptSpec)?.frame == story)
        let keptFile = try #require(kept.fileURL)
        let size = try #require(FrameRenderer.sourceSize(of: keptFile))
        #expect(size == CGSize(width: 1080, height: 1920), "the file is the frame, made from the photo's real pixels")
        // after the library lists it, the media has a `crop 9:16` tab that joins the device's file and the server's row
        try await refreshed(h)
        let after = try fresh(h)
        let tab = try #require(after.made.first { $0.madeKind == .crop })
        #expect(tab.tabName == "crop 9:16" && tab.local != nil && tab.file?.id == upload.file.id && after.made.count == 1)
        if case .crop(let of, let spec) = tab.kind { #expect(of == 2 && spec?.frame == story) } else { Issue.record("\(tab.kind)") }
        // the photo is untouched
        #expect(after.items.count == 10 && after.items[2].local?.fileURL == photo3.local?.fileURL)
        // the render left nothing in the temporary folder
        #expect(frameFolders(holding: "photo 3 · crop 9:16.jpg").isEmpty, "the frame that was drawn is removed")
    }

    @Test func cropsAccumulateAndEachIsDeletableOnItsOwn() async throws {
        let (h, item) = try await savedGallery(.galleryInstagram)
        let app = h.app
        let photo = try #require(item.items.first { $0.itemIndex == 0 })
        let cut = FrameSpec(aspect: .square, fill: .cut, rect: CGRect(x: 0, y: 0.1, width: 1, height: 0.8))
        try await driven(h) { try await app.saveCrop(of: photo, in: item, spec: story) }
        try await driven(h) { try await app.saveCrop(of: photo, in: item, spec: cut) }
        try await driven(h) { try await app.saveCrop(of: photo, in: item, spec: story) }
        try await refreshed(h)
        var after = try fresh(h)
        #expect(after.made.count == 3 && after.made.allSatisfy { $0.madeKind == .crop }, "a crop is never replaced")
        #expect(Set(after.made.map(\.tabName)) == ["crop 9:16", "crop 1:1"])
        // delete the 1:1 one: the other two stay, here and on the server
        let square = try #require(after.made.first { $0.tabName == "crop 1:1" })
        try await driven(h) { try await app.deleteMade(square, of: after) }
        try await refreshed(h)
        after = try fresh(h)
        #expect(after.made.count == 2 && after.made.allSatisfy { $0.tabName == "crop 9:16" } && after.items.count == 10)
        let sid = try #require(h.pipeline.sessionID)
        #expect(app.store.media(session: sid)?.made.count == 2)
    }

    @Test func aCropOfAnOtherFilledPhotoFollowsThePostsVisibility() async throws {
        let (h, item) = try await savedGallery(.galleryInstagram)
        let app = h.app
        let photo = try #require(item.items.first { $0.itemIndex == 4 })
        try await driven(h) { try await app.saveCrop(of: photo, in: item, spec: story) }
        try await refreshed(h)
        var after = try fresh(h)
        let initial = try #require(after.made.first).isPublic
        // the media's one switch moves the crop with the photos
        try await driven(h) { try await app.setPublic(!initial, for: after) }
        try await refreshed(h)
        after = try fresh(h)
        let crop = try #require(after.made.first)
        #expect(crop.isPublic == !initial && after.items.allSatisfy { $0.isPublic == !initial })
    }

    @Test func aFailedUploadChangesNothingAndTheNextTryWorks() async throws {
        let (h, item) = try await savedGallery(.galleryMakeFails)
        let app = h.app
        let sid = try #require(h.pipeline.sessionID)
        let photo = try #require(item.items.first { $0.itemIndex == 6 })
        await #expect(throws: PipelineFailure.self) { try await driven(h) { try await app.saveCrop(of: photo, in: item, spec: story) } }
        try await refreshed(h)
        let unchanged = try fresh(h)
        #expect(unchanged.made.isEmpty && app.store.media(session: sid)?.made.isEmpty == true, "the photo is unchanged: no row, no file")
        #expect(frameFolders(holding: "photo 7 · crop 9:16.jpg").isEmpty, "the frame that was drawn is removed")
        // `save crop` again
        try await driven(h) { try await app.saveCrop(of: photo, in: item, spec: story) }
        try await refreshed(h)
        let again = try fresh(h)
        #expect(again.made.count == 1)
    }

    @Test func aVideoOrAPhotoThePhotoHasNoRowForCannotBeStored() async throws {
        let (h, item) = try await savedGallery(.galleryMixed, link: mixLink)
        let app = h.app
        let video = try #require(item.items.first { $0.itemType == .video })
        let photo = try #require(item.items.first { $0.itemType == .photo })
        // a video item: the route answers `not_photo`
        await #expect(throws: PipelineFailure.self) { try await driven(h) { try await app.saveCrop(of: video, in: item, spec: story) } }
        // a photo the library does not list (no row): nothing to anchor the crop to, so the tool saves to Photos instead
        var rowless = photo
        rowless.file = nil
        #expect(!app.canStoreCrop(of: rowless))
        await #expect(throws: PipelineFailure.unsupported) { try await app.saveCrop(of: rowless, in: item, spec: story) }
        // and a server without galleries stores none
        let plain = Harness(.plainCobalt)
        #expect(!plain.app.canStoreCrop(of: photo))
    }

    @Test func aPhotoThatIsNotKeptHereIsDownloadedForTheRenderAndTheDownloadRemoved() async throws {
        let (h, item) = try await savedGallery(.galleryInstagram)
        let app = h.app
        var photo = try #require(item.items.first { $0.itemIndex == 1 })
        photo.local = nil                                              // evicted: only the server has it
        let source = try await driven(h) { try await app.frameSource(of: photo) }
        #expect(source.isTemporary && FileManager.default.fileExists(atPath: source.url.path))
        source.discard()
        #expect(!FileManager.default.fileExists(atPath: source.url.deletingLastPathComponent().path))
        let here = try #require(item.items.first { $0.itemIndex == 1 })
        let kept = try await app.frameSource(of: here)
        #expect(!kept.isTemporary, "a copy the device keeps is read in place")
        kept.discard()
        #expect(FileManager.default.fileExists(atPath: kept.url.path), "and discard never touches it")
    }
}

// MARK: - repost frame

@Suite(.serialized) @MainActor
struct RepostFrameTests {
    @Test func everyPhotoMakesOneFrameAndVideosAreSkippedAndCounted() async throws {
        let (h, item) = try await savedGallery(.galleryMixed, link: mixLink)
        let app = h.app
        let all = item.items
        #expect(all.count == 4)
        let result = try await driven(h) { try await app.repostFrames(all, spec: FrameSpec(aspect: .square, fill: .blur), to: .files) }
        #expect(result.skipped == 2 && result.files.count == 2)
        #expect(result.files.map(\.lastPathComponent) == ["photo 1 · 1:1.jpg", "photo 2 · 1:1.jpg"])
        for file in result.files {
            #expect(FrameRenderer.sourceSize(of: file) == CGSize(width: 1080, height: 1080))
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        // nothing was uploaded and no rendition was made
        try await refreshed(h)
        let unchanged = try fresh(h)
        #expect(calls(h, "made").isEmpty && unchanged.made.isEmpty)
    }

    @Test func aFolderGetsTheFramesAndKeepsWhatWasThereBefore() async throws {
        let (h, item) = try await savedGallery(.galleryInstagram)
        let folder = try makeTempDirectory()
        try Data("keep me".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        let some = Array(item.items.prefix(3))
        let result = try await driven(h) { try await h.app.repostFrames(some, spec: story, to: .folder(folder)) }
        #expect(result.skipped == 0 && result.files.count == 3)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == ["notes.txt", "photo 1 · 9:16.jpg", "photo 2 · 9:16.jpg", "photo 3 · 9:16.jpg"], "\(names)")
        #expect(FrameRenderer.sourceSize(of: folder.appendingPathComponent("photo 2 · 9:16.jpg")) == CGSize(width: 1080, height: 1920))
    }

    @Test func toPhotosTheFramesAreSavedAndTheTemporaryFilesRemoved() async throws {
        let (h, item) = try await savedGallery(.galleryInstagram)
        let spec = FrameSpec(aspect: .portrait, fill: .blur)
        let result = try await driven(h) { try await h.app.repostFrames(Array(item.items.prefix(2)), spec: spec, to: .photos) }
        #expect(result.files.count == 2 && result.skipped == 0)
        #expect(result.files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }, "saved to Photos, then removed")
        #expect(frameFolders(holding: "photo 1 · 4:5.jpg").isEmpty && frameFolders(holding: "photo 2 · 4:5.jpg").isEmpty)
    }

    @Test func aPhotoThatCannotBeReadFailsWithAFrameFailure() async throws {
        let (h, item) = try await savedGallery(.galleryInstagram)
        let sid = try #require(h.pipeline.sessionID)
        for record in try #require(h.app.store.media(session: sid)).items {
            if let url = record.fileURL { try Data("not a picture".utf8).write(to: url) }
        }
        await #expect(throws: PipelineFailure.server(code: AppModel.frameFailedCode)) {
            try await driven(h) { try await h.app.repostFrames([try #require(item.items.first)], spec: story, to: .files) }
        }
    }

    @Test func theNamesAreThePhotosPlaceInThePost() {
        let photo = Rendition(id: "item:6", kind: .item(index: 6, type: .photo), createdAt: Date())
        #expect(AppModel.frameName(of: photo, spec: story) == "photo 7 · 9:16.jpg")
        #expect(AppModel.cropName(of: photo, spec: story) == "photo 7 · crop 9:16.jpg")
        #expect(AppModel.cropName(of: photo, spec: FrameSpec(aspect: .free)) == "photo 7 · crop.jpg")
        let single = Rendition(id: "video", kind: .video, createdAt: Date())
        #expect(AppModel.frameName(of: single, spec: FrameSpec(aspect: .portrait)) == "photo · 4:5.jpg")
    }
}
