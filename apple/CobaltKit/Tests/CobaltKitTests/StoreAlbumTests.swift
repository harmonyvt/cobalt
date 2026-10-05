import Foundation
import Testing
@testable import CobaltKit

// 2026-10-05: nothing the owner's iPhone saved or uploaded ever reached the offline store or the album.
// Root causes pinned here: (1) an upload was never stored (`runUpload` had no keep step); (2) the album
// was off until turned on, and left out everything without a web link; (3) where the store lives was
// decided silently, with no fallback proof and no telemetry. A re-signed (sideloaded) build has no app group.

// MARK: - Where the store lives

@MainActor
struct StoreLocationTests {
    private func scratch() throws -> URL { try makeTempDirectory() }

    @Test func noAppGroupFallsBackToTheAppsOwnFolder() throws {
        let support = try scratch()
        let location = AppGroup.resolve(container: nil, applicationSupport: support, usesGroup: true)
        #expect(location.kind == .fallback && location.base == support && location.writable)
        #expect(location.groupSkipped == "no-container", "the entitlement is missing or renamed")
    }

    @Test func aContainerThatRefusesWritesFallsBackToo() throws {
        let support = try scratch()
        // a container path that is a regular file can never take a directory or a file
        let blocked = try makeTempFile("not-a-folder")
        let location = AppGroup.resolve(container: blocked, applicationSupport: support, usesGroup: true)
        #expect(location.kind == .fallback && location.groupSkipped == "unwritable")
        #expect(location.telemetry["kind"] == .string("fallback") && location.telemetry["groupSkipped"] == .string("unwritable"))
    }

    @Test func aWritableContainerIsUsed() throws {
        let support = try scratch()
        let container = try scratch()
        let location = AppGroup.resolve(container: container, applicationSupport: support, usesGroup: true)
        #expect(location.kind == .appGroup && location.base == container && location.groupSkipped == nil)
    }

    @Test func nothingWritableIsNoneAndSaysSo() throws {
        let blocked = try makeTempFile("not-a-folder")
        let location = AppGroup.resolve(container: blocked, applicationSupport: blocked, usesGroup: true)
        #expect(location.kind == .none && location.base == FileManager.default.temporaryDirectory)
    }

    @Test func theMacNeverOpensTheGroup() throws {
        let support = try scratch()
        let container = try scratch()
        let location = AppGroup.resolve(container: container, applicationSupport: support, usesGroup: false)
        #expect(location.kind == .fallback && location.groupSkipped == "macos")
    }

    @Test func foldersTheFallbackKeptMoveIntoTheGroupOnceItIsThere() throws {
        let support = try scratch()
        let container = try scratch()
        let old = support.appendingPathComponent("Videos", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: old.appendingPathComponent("index.json"))
        // the group already has its own Sync folder: never merged or overwritten
        try FileManager.default.createDirectory(at: support.appendingPathComponent("Sync"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: container.appendingPathComponent("Sync"), withIntermediateDirectories: true)

        let location = AppGroup.resolve(container: container, applicationSupport: support, usesGroup: true)
        #expect(location.kind == .appGroup && location.migrated == ["Videos"])
        #expect(FileManager.default.fileExists(atPath: container.appendingPathComponent("Videos/index.json").path))
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: support.appendingPathComponent("Sync").path), "left alone")
    }

    @Test func theProcessDecidesOnceAndEveryFolderHangsOffThatAnswer() {
        let first = AppGroup.location
        let dir = AppGroup.directory("StoreLocationTests-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(AppGroup.location == first)
        #expect(dir.deletingLastPathComponent().standardizedFileURL == first.base.standardizedFileURL)
        #expect(first.writable)
    }

    @Test func aStoreOnTheFallbackRootAddsAndReadsBack() async throws {
        // the same code path the device takes without an app group: root = <Application Support>/Videos
        let support = try scratch()
        let location = AppGroup.resolve(container: nil, applicationSupport: support, usesGroup: true)
        let root = location.base.appendingPathComponent("Videos", isDirectory: true)
        let clock = VirtualClock()
        let store = OfflineStore(root: root, tools: PreviewMediaTools(clock: clock, clip: PreviewData.long))
        let file = try makeTempFile("clip.mp4", bytes: 4_000)
        let media = MediaInfo(name: "clip", duration: 5, width: 720, height: 1280, bytes: nil, isImage: false)
        _ = try await store.add(file: file, kind: .original, media: media, sessionID: "S1", link: nil, remoteURL: nil, move: true)
        #expect(store.videos.count == 1)
        // a new process (a relaunch) opens the same root and sees it
        let again = OfflineStore(root: root, tools: PreviewMediaTools(clock: clock, clip: PreviewData.long))
        #expect(again.videos.count == 1 && again.videos.first?.fileURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
    }
}

// MARK: - The album is on by default and asks at the first save

@MainActor
struct DefaultAlbumTests {
    @Test func aFreshInstallIsOnAndExplicitAnswersSurvive() throws {
        let env = try PhotosEnv(defaultsOn: true)
        #expect(env.settings.photosAlbumSync && env.settings.photosSyncWebps)
        #expect(env.sync.status.enabled)
        env.sync.disable()
        #expect(!env.settings.photosAlbumSync && !env.sync.status.enabled, "an owner who turned it off stays off")
    }

    @Test func theFirstSaveAsksOnceThenFillsTheAlbumWithVideosAndWebps() async throws {
        let env = try PhotosEnv(rw: .notDetermined, addOnly: .notDetermined, defaultsOn: true)
        env.library.rwAnswer = .authorized
        // nothing to save yet: nothing is asked
        await env.reconcile()
        #expect(env.library.count("requestReadWrite") == 0)
        try await env.add(session: "S1")
        try await env.add(session: "S1", remote: hostedWebpURL, kind: .webp)
        try await env.add(session: "S2", link: nil)                      // an upload
        await env.reconcile()
        #expect(env.library.count("requestReadWrite") == 1)
        #expect(env.sync.status.access == .album && env.library.addCalls == 3)
        let album = try #require(env.library.albums.first { $0.value == "cobalt" }?.key)
        #expect(env.library.members(of: album).count == 3, "originals, the webp and the upload all went into the album")
        #expect(env.library.assets.values.filter(\.isImage).count == 1, "the webp as a still picture")
        try await env.add(session: "S3")
        await env.reconcile()
        #expect(env.library.count("requestReadWrite") == 1, "asked once")
    }

    @Test func aRefusalIsRememberedForTheLaunchAndTheStatusSaysSo() async throws {
        let env = try PhotosEnv(rw: .notDetermined, addOnly: .notDetermined, defaultsOn: true)
        env.library.rwAnswer = .denied
        try await env.add(session: "S1")
        await env.reconcile()
        #expect(env.sync.status.access == .denied && env.library.addCalls == 0)
        #expect(env.sync.status.enabled, "still on: it starts working the moment access is allowed in settings")
        await env.reconcile()
        #expect(env.library.count("requestReadWrite") == 1)
        // allowed later in Settings: the next foreground adds it
        env.library.setAccess(rw: .authorized, addOnly: .authorized)
        await env.sync.refresh()
        await env.reconcile()
        #expect(env.sync.status.access == .album && env.library.addCalls == 1)
    }

    @Test func limitedAccessFallsBackToTheLibraryOnly() async throws {
        let env = try PhotosEnv(rw: .notDetermined, addOnly: .notDetermined, defaultsOn: true)
        env.library.rwAnswer = .limited
        try await env.add(session: "S1")
        await env.reconcile()
        #expect(env.sync.status.access == .libraryLimited && env.library.addCalls == 1)
        #expect(env.library.albums.isEmpty, "limited access cannot make an album")
    }

    @Test func aBackgroundWakeNeverAsks() async throws {
        let env = try PhotosEnv(rw: .notDetermined, addOnly: .notDetermined, defaultsOn: true, isForeground: { false })
        try await env.add(session: "S1")
        await env.reconcile()
        #expect(env.library.count("requestReadWrite") == 0 && env.library.addCalls == 0)
        #expect(env.sync.status.access == .notAsked)
    }

    @Test func keepOffMeansNoPromptEither() async throws {
        let env = try PhotosEnv(rw: .notDetermined, addOnly: .notDetermined, defaultsOn: true)
        env.settings.keepVideosOnDevice = false
        try await env.add(session: "S1")
        await env.reconcile()
        #expect(env.library.count("requestReadWrite") == 0)
    }
}

private let hostedWebpURL = URL(string: "https://media.capybaraharmony.com/uPlOaD.webp")!

// MARK: - A video that is already in Photos is adopted, never copied

@MainActor
struct AdoptExistingAssetTests {
    @Test func theExistingAssetGoesIntoTheAlbumAndTheStoreAddsNoSecondCopy() async throws {
        let env = try PhotosEnv(defaultsOn: true)
        env.library.seedAsset("PICKED-1")
        await env.sync.adoptExistingAsset(localIdentifier: "PICKED-1", forSession: "SU1")
        let album = try #require(env.library.albums.first { $0.value == "cobalt" }?.key)
        #expect(env.library.members(of: album) == ["PICKED-1"], "the existing asset, in the album")
        #expect(env.library.addCalls == 0)
        let entry = try #require(env.ledger.entry("s:SU1"))
        #expect(entry.state == .done && entry.asset == "PICKED-1" && entry.inAlbum == .yes && entry.origin == .sync)

        // the upload's original is stored afterwards: the sync finds it settled
        try await env.add(session: "SU1", link: nil)
        await env.reconcile()
        #expect(env.library.addCalls == 0 && env.library.assets.count == 1, "no duplicate asset")
        #expect(env.sync.status.added == 1)
    }

    @Test func adoptingTwiceIsOneEntry() async throws {
        let env = try PhotosEnv(defaultsOn: true)
        env.library.seedAsset("PICKED-1")
        await env.sync.adoptExistingAsset(localIdentifier: "PICKED-1", forSession: "SU1")
        await env.sync.adoptExistingAsset(localIdentifier: "PICKED-2", forSession: "SU1")
        #expect(env.ledger.entry("s:SU1")?.asset == "PICKED-1")
        #expect(env.library.count("addToAlbum") == 1)
    }

    @Test func withTheAlbumOffTheAssetIsOnlyRecordedSoItIsNeverAddedLater() async throws {
        let env = try PhotosEnv()                                        // explicit off
        env.library.seedAsset("PICKED-1")
        await env.sync.adoptExistingAsset(localIdentifier: "PICKED-1", forSession: "SU1")
        #expect(env.library.count("addToAlbum") == 0 && env.library.albums.isEmpty)
        let entry = try #require(env.ledger.entry("s:SU1"))
        #expect(entry.state == .done && entry.asset == "PICKED-1" && entry.inAlbum == .no)
        env.turnOn()
        try await env.add(session: "SU1", link: nil)
        await env.reconcile()
        #expect(env.library.addCalls == 0, "turning the album on later still adds no second copy")
    }

    @Test func limitedAccessRecordsItAndFullAccessLaterMovesItIntoTheAlbum() async throws {
        let env = try PhotosEnv(rw: .limited, addOnly: .authorized, defaultsOn: true)
        env.library.seedAsset("PICKED-1")
        await env.sync.adoptExistingAsset(localIdentifier: "PICKED-1", forSession: "SU1")
        #expect(env.ledger.entry("s:SU1")?.inAlbum == PhotosEntry.InAlbum.no && env.library.albums.isEmpty)
        env.library.setAccess(rw: .authorized, addOnly: .authorized)
        await env.sync.refresh()
        await env.reconcile()
        let album = try #require(env.library.albums.first { $0.value == "cobalt" }?.key)
        #expect(env.library.members(of: album) == ["PICKED-1"] && env.ledger.entry("s:SU1")?.inAlbum == .yes)
    }

    @Test func theFirstPickedVideoAsksForAccessWhenNothingWasAsked() async throws {
        let env = try PhotosEnv(rw: .notDetermined, addOnly: .notDetermined, defaultsOn: true)
        env.library.rwAnswer = .authorized
        env.library.seedAsset("PICKED-1")
        await env.sync.adoptExistingAsset(localIdentifier: "PICKED-1", forSession: "SU1")
        #expect(env.library.count("requestReadWrite") == 1 && env.ledger.entry("s:SU1")?.inAlbum == .yes)
    }

    @Test func aVideoThatIsAlreadyStoredCanBeAdoptedByItsRecord() async throws {
        let env = try PhotosEnv(defaultsOn: true)
        env.library.seedAsset("PICKED-1")
        let video = try await env.add(session: nil, link: nil)           // a plain save with no session
        await env.sync.adoptExistingAsset(localIdentifier: "PICKED-1", for: video)
        #expect(env.ledger.entry(PhotosKey.of(video))?.asset == "PICKED-1")
        await env.reconcile()
        #expect(env.library.addCalls == 0)
    }
}

// MARK: - An upload stays on the phone

@MainActor
struct UploadKeepTests {
    private func rig(keep: Bool = true) throws -> HandoffRig { try HandoffRig(keep: keep) }

    @Test func anUploadedVideoLandsInTheStoreAsAnOriginal() async throws {
        let rig = try rig()
        rig.pipeline.start(file: try makeTempFile("holiday.mov", bytes: 5_000))
        await rig.h.drive { rig.pipeline.state == .ready }
        await rig.h.drive { rig.pipeline.keepRequest == nil && rig.pipeline.stored != nil }
        let sid = try #require(rig.pipeline.sessionID)
        let kept = try #require(rig.ctx.store.videos.first { $0.sessionID == sid })
        #expect(rig.ctx.store.videos.filter { $0.sessionID == sid }.count == 1)
        #expect(kept.kind == .original && kept.sessionID == sid && kept.link == nil)
        #expect(kept.name == "holiday", "named like a saved link, without the extension")
        #expect(kept.fileURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
        #expect(rig.pipeline.stored?.id == kept.id, "the run plays and saves its stored copy")
        #expect(kept.fileURL?.pathExtension == "mov")
    }

    @Test func keepOffStoresNothing() async throws {
        let rig = try rig(keep: false)
        let before = rig.ctx.store.videos.count
        rig.pipeline.start(file: try makeTempFile("holiday.mov", bytes: 5_000))
        await rig.h.drive { rig.pipeline.state == .ready }
        await rig.h.settle()
        #expect(rig.ctx.store.videos.count == before && rig.pipeline.keepRequest == nil)
    }

    @Test func aWebpMadeLaterJoinsTheUploadsMedia() async throws {
        let rig = try rig()
        rig.pipeline.start(file: try makeTempFile("holiday.mov", bytes: 5_000))
        await rig.h.drive { rig.pipeline.state == .ready }
        await rig.h.drive { rig.pipeline.keepRequest == nil && rig.pipeline.stored != nil }
        let original = try #require(rig.pipeline.stored)
        rig.pipeline.makeWebp()
        await rig.h.drive { if case .done = rig.pipeline.state { return true } else { return false } }
        let media = try #require(rig.ctx.store.media(containing: original.id))
        #expect(media.renditions.contains { $0.kind == .webp } && media.renditions.contains { $0.id == original.id },
                "the webp attached to the uploaded original's media (same session)")
    }

    @Test func aPickedPhotosVideoIsAdoptedBeforeItIsStoredSoItIsNeverCopiedToPhotos() async throws {
        let rig = try rig()
        let library = FakePhotoLibrary()
        library.seedAsset("PICKED-9")
        let ledger = PhotosLedger(directory: try makeTempDirectory())
        let sync = PhotosSync(
            settings: rig.ctx.settings, store: rig.ctx.store, ledger: ledger, library: library, clock: rig.h.clock,
            available: true)
        rig.ctx.photosSync = sync
        rig.ctx.settings.photosAlbumSync = true
        let file = try makeTempFile("IMG_0042.MOV", bytes: 5_000)
        rig.pipeline.adoptPhotosAsset("PICKED-9", forFile: file)
        rig.pipeline.start(file: file)
        await rig.h.drive { rig.pipeline.state == .ready }
        await rig.h.drive { rig.pipeline.keepRequest == nil && rig.pipeline.stored != nil }
        let sid = try #require(rig.pipeline.sessionID)
        await sync.reconcile()
        #expect(library.addCalls == 0, "the asset was already in Photos")
        let entry = try #require(ledger.entry("s:\(sid)"))
        #expect(entry.asset == "PICKED-9" && entry.state == .done && entry.inAlbum == .yes)
        #expect(rig.pipeline.photosPlacement == .inAlbum, "the button says so")
    }

    @Test func aFileFromFilesIsAddedToTheAlbumAsANewAsset() async throws {
        let rig = try rig()
        let library = FakePhotoLibrary()
        let ledger = PhotosLedger(directory: try makeTempDirectory())
        let sync = PhotosSync(
            settings: rig.ctx.settings, store: rig.ctx.store, ledger: ledger, library: library, clock: rig.h.clock,
            available: true)
        rig.ctx.photosSync = sync
        rig.ctx.settings.photosAlbumSync = true
        rig.pipeline.start(file: try makeTempFile("clip.mp4", bytes: 5_000))
        await rig.h.drive { rig.pipeline.state == .ready }
        await rig.h.drive { rig.pipeline.keepRequest == nil && rig.pipeline.stored != nil }
        await sync.reconcile()
        #expect(library.addCalls == 1)
        let album = try #require(library.albums.first { $0.value == "cobalt" }?.key)
        #expect(library.members(of: album).count == 1)
    }

    @Test func theAssetIdentifierOnlyBelongsToTheNextStartOfThatFile() async throws {
        let rig = try rig()
        let library = FakePhotoLibrary()
        library.seedAsset("PICKED-9")
        let ledger = PhotosLedger(directory: try makeTempDirectory())
        rig.ctx.photosSync = PhotosSync(
            settings: rig.ctx.settings, store: rig.ctx.store, ledger: ledger, library: library, clock: rig.h.clock, available: true)
        rig.pipeline.adoptPhotosAsset("PICKED-9", forFile: URL(fileURLWithPath: "/somewhere/else.mov"))
        rig.pipeline.start(file: try makeTempFile("other.mov", bytes: 5_000))
        await rig.h.drive { rig.pipeline.state == .ready }
        await rig.h.drive { rig.pipeline.keepRequest == nil && rig.pipeline.stored != nil }
        #expect(ledger.snapshot().items.isEmpty || ledger.snapshot().items.values.allSatisfy { $0.asset != "PICKED-9" })
    }
}
