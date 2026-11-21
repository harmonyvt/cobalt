import Foundation
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import CobaltKit

// Photos and videos shared with no link (CONTRACT-SHARE-QUICK.md 9.10): copied into the app group and sent as
// `PUT /studio/upload?queue=1` on a background session; the app's wake deletes the copy and tells only of a refusal.

private let key = "7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21"
private let base = URL(string: "https://api.capybaraharmony.com")!
private func client(key: String? = key) -> HTTPCobaltClient { HTTPCobaltClient(baseURL: base, apiKey: { key }) }

private func item(_ providers: [NSItemProvider]) -> NSExtensionItem {
    let item = NSExtensionItem()
    item.attachments = providers
    return item
}

/// A provider that hands out a real file for `type`.
private func provider(_ file: URL, type: UTType, name: String? = nil) -> NSItemProvider {
    let p = NSItemProvider()
    p.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { done in
        done(file, false, nil)
        return nil
    }
    p.suggestedName = name
    return p
}

private func tempFile(_ name: String, bytes: Int = 64) throws -> URL {
    let dir = try makeTempDirectory()
    let url = dir.appendingPathComponent(name)
    try Data(repeating: 7, count: bytes).write(to: url)
    return url
}

@Suite struct ShareUploadsTests {
    @Test func thePickedTypeIsTheFirstTheServerTakes() {
        #expect(ShareUploads.uploadType([UTType.heic.identifier, UTType.jpeg.identifier]) == .heic)
        #expect(ShareUploads.uploadType(["com.apple.live-photo-bundle", UTType.jpeg.identifier]) == .jpeg)
        #expect(ShareUploads.uploadType([UTType.quickTimeMovie.identifier]) == .quickTimeMovie)
        #expect(ShareUploads.uploadType([UTType.tiff.identifier, UTType.pdf.identifier]) == nil, "nothing the server takes")
        #expect(ShareUploads.uploadType([UTType.plainText.identifier]) == nil)
    }

    @Test func theNameIsTheSendersWithAnExtensionTheServerCanType() {
        let copy = URL(fileURLWithPath: "/tmp/x/QuickTime movie.mov")
        #expect(ShareUploads.name(for: copy, suggested: "IMG_0412", type: .quickTimeMovie) == "IMG_0412.mov")
        #expect(ShareUploads.name(for: URL(fileURLWithPath: "/tmp/x/blob"), suggested: nil, type: .jpeg) == "blob.jpeg")
    }

    @Test func theLabelFindsItsFolderAndNothingElse() {
        let saves = URL(fileURLWithPath: "/tmp/saves")
        let folder = UUID().uuidString.lowercased()
        let file = ShareUploadFile(
            url: ShareUploads.directory(saves: saves).appendingPathComponent(folder).appendingPathComponent("IMG_1.heic"),
            name: "IMG_1.heic", contentType: "image/heic", bytes: 1)
        #expect(file.label == "upload:\(folder)/IMG_1.heic")
        #expect(ShareUploads.folder(forLabel: file.label, saves: saves)?.lastPathComponent == folder)
        #expect(ShareUploads.folder(forLabel: "upload:../IMG_1.heic", saves: saves) == nil)
        #expect(ShareUploads.folder(forLabel: "upload:\(folder)", saves: saves) == nil)
        #expect(ShareUploads.folder(forLabel: "https://x.com/i/status/1", saves: saves) == nil)
    }

    @Test func theNotificationLineCountsPhotosAndVideos() {
        func f(_ type: String, _ name: String = "a") -> ShareUploadFile {
            ShareUploadFile(url: URL(fileURLWithPath: "/tmp/\(name)"), name: name, contentType: type, bytes: 1)
        }
        #expect(ShareUploads.summary([f("image/heic", "IMG_1.heic")]) == "IMG_1.heic")
        #expect(ShareUploads.summary([f("image/jpeg"), f("image/png")]) == "2 photos")
        #expect(ShareUploads.summary([f("video/mp4"), f("video/quicktime")]) == "2 videos")
        #expect(ShareUploads.summary([f("image/jpeg"), f("image/jpeg"), f("video/mp4")]) == "2 photos and 1 video")
    }

    @Test func theRequestIsTheUploadWithTheQueueAndPublicFlags() throws {
        let request = try client().shareUploadRequest(name: "IMG 1.heic", contentType: "image/heic", public: true)
        #expect(request.httpMethod == "PUT")
        let url = try #require(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        #expect(url.path == "/studio/upload")
        #expect(Set(url.queryItems ?? []) == [
            URLQueryItem(name: "name", value: "IMG 1.heic"), URLQueryItem(name: "queue", value: "1"), URLQueryItem(name: "public", value: "1"),
        ])
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "image/heic")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Api-Key \(key)")
        let quiet = try client().shareUploadRequest(name: "a.mp4", contentType: "video/mp4", public: false)
        #expect(quiet.url?.query?.contains("public") == false)
        #expect(throws: CobaltError.noAPIKey) { try client(key: nil).shareUploadRequest(name: "a.mp4", contentType: "video/mp4", public: false) }
    }

    @MainActor
    @Test func photosAndVideosAreCopiedOneFolderEachAndTheRestCounted() async throws {
        let into = try makeTempDirectory()
        let photo = provider(try tempFile("IMG_1.heic"), type: .heic, name: "IMG_1")
        let video = provider(try tempFile("clip.mov"), type: .quickTimeMovie, name: "holiday")
        let tiff = provider(try tempFile("scan.tiff"), type: .tiff)
        let loaded = await ShareUploads.load([item([photo, video, tiff])], into: into)
        #expect(loaded.files.map(\.name) == ["IMG_1.heic", "holiday.mov"])
        #expect(loaded.files.map(\.contentType) == ["image/heic", "video/quicktime"])
        #expect(loaded.files.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) && $0.bytes == 64 })
        #expect(Set(loaded.files.map { $0.url.deletingLastPathComponent() }).count == 2, "one folder each")
        #expect(loaded.unsupported == 1 && loaded.tooLarge == 0 && loaded.overLimit == 0)
    }

    @Test func thePhotosAreSentOnOneBackgroundSessionAndNotWaitedFor() async throws {
        let transport = FakeSaveTransport(background: true)
        let saves = try makeTempDirectory()
        let a = ShareUploadFile(url: try tempFile("a.jpg"), name: "a.jpg", contentType: "image/jpeg", bytes: 64)
        let b = ShareUploadFile(url: try tempFile("b.mp4"), name: "b.mp4", contentType: "video/mp4", bytes: 64)
        let job = UUID()
        let result = await InstantShareEngine(transport: transport, directory: saves).enqueue(files: [a, b], client: client(), job: job)
        #expect(result == .saved)
        #expect(transport.sessions.map(\.identifier) == [BackgroundSessionID.save(job: job)], "the app is woken for it")
        #expect(transport.uploads.map(\.label) == [a.label, b.label])
        #expect(transport.uploads.allSatisfy { $0.request.httpMethod == "PUT" && $0.body.count == 64 })
    }

    @Test func withoutTheAppGroupTheFullSheetDoesIt() async throws {
        let transport = FakeSaveTransport(background: false)
        let a = ShareUploadFile(url: try tempFile("a.jpg"), name: "a.jpg", contentType: "image/jpeg", bytes: 64)
        let result = await InstantShareEngine(transport: transport, directory: try makeTempDirectory())
            .enqueue(files: [a], client: client(), job: UUID())
        #expect(result == .needsSheet && transport.uploads.isEmpty)
    }

    @Test func noKeySendsNothing() async throws {
        let transport = FakeSaveTransport(background: true)
        let a = ShareUploadFile(url: try tempFile("a.jpg"), name: "a.jpg", contentType: "image/jpeg", bytes: 64)
        let result = await InstantShareEngine(transport: transport, directory: try makeTempDirectory())
            .enqueue(files: [a], client: client(key: nil), job: UUID())
        #expect(result == .failed(.noKey) && transport.uploads.isEmpty)
    }

    @Test func aPhotoAloneIsAFileAndALinkStillWins() async {
        let photo = NSItemProvider(item: URL(fileURLWithPath: "/tmp/a.jpg") as NSURL, typeIdentifier: UTType.jpeg.identifier)
        let url = NSItemProvider(item: URL(string: "https://x.com/i/status/1")! as NSURL, typeIdentifier: UTType.url.identifier)
        #expect(await ShareInbox.loadLinkOnly([item([photo])]) == .file)
        #expect(await ShareInbox.loadLinkOnly([item([photo, url])]) == .link(URL(string: "https://x.com/i/status/1")!))
    }
}

@MainActor
@Suite(.serialized)
struct ShareUploadsAppTests {
    @Test func theWakeDeletesEachCopyAndTellsOnlyOfARefusal() async throws {
        let rig = try FetcherRig()
        let fetcher = rig.fetcher
        fetcher.saveTransport = FakeSaveTransport(background: true)
        let saves = try makeTempDirectory()
        fetcher.savesDirectory = { saves }
        let failed = Mutex<[(String, Int?)]>([])
        fetcher.uploadFailed = { name, status in failed.withLock { $0.append((name, status)) } }
        fetcher.instantFailed = { _, _ in Issue.record("an upload is not a link save") }

        func copy(_ name: String) throws -> ShareUploadFile {
            let folder = ShareUploads.directory(saves: saves).appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(name)
            try Data([1]).write(to: url)
            return ShareUploadFile(url: url, name: name, contentType: "image/jpeg", bytes: 1)
        }
        let ok = try copy("ok.jpg"), refused = try copy("big.mp4"), lost = try copy("lost.jpg")
        fetcher.saveAnswers.saveResponded(identifier: "x", task: 1, label: ok.label, status: 201, body: Data("{}".utf8))
        fetcher.saveAnswers.saveResponded(identifier: "x", task: 2, label: refused.label, status: 413, body: Data())
        fetcher.saveAnswers.saveFailed(identifier: "x", task: 3, label: lost.label, code: NSURLErrorNetworkConnectionLost)
        await fetcher.handleWake(identifier: BackgroundSessionID.save(job: UUID()))

        let told = failed.withLock { $0 }
        #expect(told.map(\.0) == ["big.mp4", "lost.jpg"] && told.map(\.1) == [413, nil])
        for file in [ok, refused, lost] {
            #expect(!FileManager.default.fileExists(atPath: file.url.deletingLastPathComponent().path))
        }
        #expect(rig.pending.all().isEmpty)
    }
}
