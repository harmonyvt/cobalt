import Foundation
import Synchronization
import Testing
@testable import CobaltKit

// CONTRACT-MEDIA 1.15: a detail's "save to photos" records the same ledger key the album sync and the focus use
// (`AppModel.saveToPhotos(_:)`), so the sync never adds the file again and the button reads where it went.

private let hostedWebp = URL(string: "https://media.capybaraharmony.com/PrEvIeW009.webp")!

@MainActor
private struct DetailPhotosRig {
    let h = Harness(.renditions)
    let ledger: PhotosLedger
    let library = FakePhotoLibrary()
    let sync: PhotosSync
    var app: AppModel { h.app }
    let wantsSync: Bool
    func turnOn() { h.ctx.settings.photosAlbumSync = wantsSync }

    init(rw: PhotosReadWrite = .authorized, addOnly: PhotosAccess = .authorized, syncOn: Bool = true) throws {
        wantsSync = syncOn
        library.setAccess(rw: rw, addOnly: addOnly)
        ledger = PhotosLedger(directory: try makeTempDirectory())
        h.ctx.settings.photosAlbumSync = false          // a record added now must not race the test: `turnOn()` after adding
        sync = PhotosSync(
            settings: h.ctx.settings, store: h.ctx.store, ledger: ledger, library: library, clock: h.clock, available: true)
        h.ctx.photosLedger = ledger
        h.ctx.photosSync = sync
    }

    /// `saveToPhotos` with virtual time driven (the preview saver and download take virtual seconds).
    func save(_ r: Rendition) async throws {
        let outcome = Mutex<Result<Void, any Error>?>(nil)
        let app = self.app
        let task = Task { @MainActor in
            do { try await app.saveToPhotos(r); outcome.withLock { $0 = .success(()) } } catch { outcome.withLock { $0 = .failure(error) } }
        }
        await h.drive { outcome.withLock { $0 != nil } }
        await task.value
        try outcome.withLock { $0 }!.get()
    }

    /// A record with a real file in the store, as a finished save or a made webp leaves it.
    func add(kind: StoredVideo.Kind, session: String?, remote: URL? = nil) async throws -> StoredVideo {
        h.ctx.store.onAdd = nil                    // the sync's own "added" pass would race the test: nothing adds this on its own
        let name = kind == .webp ? "w.webp" : "v.mp4"
        let file = try makeTempFile(name, bytes: 2_000)
        let media = MediaInfo(name: "clip", duration: 5, width: 720, height: 1280, bytes: nil, isImage: kind == .webp)
        return try await h.ctx.store.add(
            file: file, kind: kind, media: media, sessionID: session, link: URL(string: shortLink), remoteURL: remote, move: true)
    }

    func rendition(_ stored: StoredVideo?, kind: Rendition.Kind = .video, file: LibraryFile? = nil, url: URL? = nil) -> Rendition {
        Rendition(
            id: stored?.id ?? "x", kind: kind, local: stored, file: file, publicURL: url, width: 720, height: 1280,
            createdAt: Date())
    }
}

@MainActor
struct DetailSaveToPhotosTests {
    @Test func theVideoGoesIntoTheAlbumWithItsSessionKeyAndReadsBackAsInAlbum() async throws {
        let rig = try DetailPhotosRig()
        let stored = try await rig.add(kind: .original, session: "S1")
        rig.turnOn()
        let r = rig.rendition(stored)
        #expect(rig.app.photosPlacement(of: r) == .none)

        try await rig.save(r)

        let entry = try #require(rig.ledger.entry("s:S1"), "the ledger key of the local record is recorded")
        #expect(entry.state == .done && entry.origin == .manual && entry.inAlbum == .yes)
        let album = try #require(rig.ledger.album)
        #expect(rig.library.members(of: album.id).count == 1)
        #expect(rig.app.photosPlacement(of: r) == .inAlbum)
        #expect(rig.sync.placement(of: stored) == .inAlbum)
    }

    @Test func theSyncNeverAddsWhatTheDetailSaved() async throws {
        let rig = try DetailPhotosRig()
        let stored = try await rig.add(kind: .original, session: "S1")
        rig.turnOn()
        try await rig.save(rig.rendition(stored))
        #expect(rig.library.addCalls == 1)
        await rig.sync.reconcile()
        await rig.sync.reconcile()
        #expect(rig.library.addCalls == 1, "recorded by the manual save, so the sync leaves it")
    }

    @Test func withTheSyncOffItGoesToTheLibraryAndReadsBackAsInLibrary() async throws {
        let rig = try DetailPhotosRig(rw: .denied, addOnly: .authorized, syncOn: false)
        let stored = try await rig.add(kind: .original, session: "S2")
        rig.turnOn()
        let r = rig.rendition(stored)
        try await rig.save(r)
        let entry = try #require(rig.ledger.entry("s:S2"))
        #expect(entry.state == .done && entry.inAlbum == .no)
        #expect(rig.library.count("createAlbum") == 0)
        #expect(rig.app.photosPlacement(of: r) == .inLibrary)
    }

    @Test func aWebpRecordsItsWebpKeyAndGoesInAsAPicture() async throws {
        let rig = try DetailPhotosRig()
        let stored = try await rig.add(kind: .webp, session: "S3", remote: hostedWebp)
        rig.turnOn()
        let r = rig.rendition(stored, kind: .webp(number: 1), url: hostedWebp)
        try await rig.save(r)
        let entry = try #require(rig.ledger.entry("w:\(hostedWebp.absoluteString)"))
        #expect(entry.state == .done && entry.inAlbum == .yes)
        #expect(rig.library.assets.values.filter(\.isImage).count == 1)
        #expect(rig.app.photosPlacement(of: r) == .inAlbum)
    }

    @Test func aRenditionWithNoLocalFileFetchesTheLibraryCopyFirstAndKeepsTheRecordsKey() async throws {
        let rig = try DetailPhotosRig(rw: .denied, addOnly: .authorized, syncOn: false)
        rig.turnOn()
        // the device's record is evicted (no file): the private copy comes down from the library, then goes in
        let evicted = StoredVideo(
            id: "evicted-1", kind: .original, fileURL: nil, posterURL: nil, name: "clip", duration: 5, width: 720, height: 1280,
            bytes: 0, sessionID: "S9", link: URL(string: shortLink), remoteURL: nil, createdAt: Date())
        let privateCopy = LibraryFile(
            id: "ITEM0001", kind: .private, source: .saved, name: "clip.mp4", url: nil, contentType: "video/mp4", bytes: 2_000,
            width: 720, height: 1280, duration: 5, createdAt: Date(), mediaName: nil, deletable: false)
        let r = rig.rendition(evicted, file: privateCopy)

        try await rig.save(r)

        let entry = try #require(rig.ledger.entry("s:S9"), "the evicted record's own key, not a new one")
        #expect(entry.state == .done && entry.origin == .manual)
        #expect(rig.app.photosPlacement(of: r) == .inLibrary)
    }

    @Test func aWebpOnlyTheServerHoldsIsFetchedFromItsLinkAndKeyedByIt() async throws {
        let rig = try DetailPhotosRig(rw: .denied, addOnly: .authorized, syncOn: false)
        let r = rig.rendition(nil, kind: .webp(number: 2), url: hostedWebp)
        #expect(rig.app.photosPlacement(of: r) == .none)

        try await rig.save(r)

        let key = "w:\(hostedWebp.absoluteString)"
        #expect(rig.ledger.entry(key)?.state == .done)
        #expect(rig.app.photosPlacement(of: r) == .inLibrary)
    }

    @Test func nothingToSaveIsUnsupportedAndRecordsNothing() async throws {
        let rig = try DetailPhotosRig()
        let r = rig.rendition(nil)                           // a video this device never held and the server has no copy of
        await #expect(throws: PipelineFailure.unsupported) { try await rig.save(r) }
        #expect(rig.ledger.snapshot().items.isEmpty)
    }
}
