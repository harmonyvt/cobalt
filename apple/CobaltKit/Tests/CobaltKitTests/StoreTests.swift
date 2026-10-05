import AVFoundation
import Foundation
import Testing
@testable import CobaltKit

// MARK: - OfflineStore on disk, with the real media tools

@MainActor
struct OfflineStoreOnDiskTests {
    private func store(_ root: URL) -> OfflineStore { OfflineStore(root: root) }          // SystemMediaTools

    @Test func addingARealVideoFillsInWhatTheFileSaysAndMakesAPoster() async throws {
        let root = try makeTempDirectory()
        let s = store(root)
        let source = try makeTempDirectory().appendingPathComponent("clip.mp4")
        try FileManager.default.copyItem(at: try await TestVideo.clip(), to: source)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int64)

        // the session only knew a name: duration and size come from the file
        let stored = try await s.add(
            file: source, kind: .original, media: MediaInfo(name: "clip", duration: nil, width: nil, height: nil, bytes: nil, isImage: false),
            sessionID: "sid", link: URL(string: "https://x.com/i/status/1"), remoteURL: nil, move: true)
        #expect(abs((stored.duration ?? 0) - 6) < 0.2 && stored.width == 96 && stored.height == 160)
        #expect(stored.bytes == size)
        let poster = try #require(stored.posterURL)
        #expect(FileManager.default.fileExists(atPath: poster.path))
        #expect(!FileManager.default.fileExists(atPath: source.path))                 // moved
        // the file and its poster (CONTRACT-LIVE.md 4.2: both count against the limit)
        let posterSize = try #require(try FileManager.default.attributesOfItem(atPath: poster.path)[.size] as? Int64)
        let flipbook = stored.previewFrameURLs.reduce(Int64(0)) {
            $0 + ((try? FileManager.default.attributesOfItem(atPath: $1.path)[.size]) as? NSNumber)!.int64Value
        }
        #expect(stored.previewFrameURLs.count == 12 && flipbook > 0)
        #expect(s.usage == StorageUsage(count: 1, bytes: size + posterSize + flipbook))
        #expect(stored.fileURL?.pathExtension == "mp4")
    }

    @Test func addingAnAnimatedWebpKeepsItsLengthAndASizeAndPoster() async throws {
        let s = store(try makeTempDirectory())
        let webp = try makeTempDirectory().appendingPathComponent("made.webp")
        try TestImages.animatedWebP.write(to: webp)
        let stored = try await s.add(
            file: webp, kind: .webp, media: MediaInfo(name: "made.webp", duration: nil, width: nil, height: nil, bytes: nil, isImage: false),
            sessionID: "sid", link: nil, remoteURL: URL(string: "https://media.capybaraharmony.com/AbCdEfGhIj.webp"), move: false)
        #expect(stored.kind == .webp && stored.width == 24 && stored.height == 16)
        #expect(abs((stored.duration ?? 0) - 0.6) < 0.001)
        #expect(stored.bytes == Int64(TestImages.animatedWebP.count))
        #expect(stored.posterURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
        #expect(FileManager.default.fileExists(atPath: webp.path))                    // copied, not moved
    }

    @Test func twoStoresWritingTheSameIndexLoseNothing() async throws {
        let root = try makeTempDirectory()
        let app = OfflineStore(root: root, tools: PreviewMediaTools(clock: VirtualClock(), clip: PreviewData.long))
        let extensionSide = OfflineStore(root: root, tools: PreviewMediaTools(clock: VirtualClock(), clip: PreviewData.long))
        let media = MediaInfo(name: "n", duration: 1, width: 1, height: 1, bytes: 1, isImage: false)
        func file(_ n: Int) throws -> URL { try makeTempFile("f\(n).mp4", bytes: 10 + n) }

        // interleaved: each add re-reads the index under a file coordination before it writes
        async let a: [StoredVideo] = {
            var out: [StoredVideo] = []
            for i in 0..<6 { out.append(try await app.add(file: try file(i), kind: .original, media: media, sessionID: nil, link: nil, remoteURL: nil, move: true)) }
            return out
        }()
        async let b: [StoredVideo] = {
            var out: [StoredVideo] = []
            for i in 10..<16 { out.append(try await extensionSide.add(file: try file(i), kind: .original, media: media, sessionID: nil, link: nil, remoteURL: nil, move: true)) }
            return out
        }()
        let (fromApp, fromExtension) = try await (a, b)
        let everything = Set((fromApp + fromExtension).map(\.id))
        #expect(everything.count == 12)

        await app.reload()
        await extensionSide.reload()
        #expect(Set(app.videos.map(\.id)) == everything)
        #expect(Set(extensionSide.videos.map(\.id)) == everything)
        #expect(OfflineStore(root: root, tools: PreviewMediaTools(clock: VirtualClock(), clip: PreviewData.long)).videos.count == 12)
    }

    @Test func addingAFileThatIsNotThereThrowsAndChangesNothing() async throws {
        let root = try makeTempDirectory()
        let s = store(root)
        let media = MediaInfo(name: "n", duration: 1, width: 1, height: 1, bytes: 1, isImage: false)
        await #expect(throws: (any Error).self) {
            _ = try await s.add(file: root.appendingPathComponent("nope.mp4"), kind: .original, media: media, sessionID: nil, link: nil, remoteURL: nil, move: true)
        }
        #expect(s.videos.isEmpty && s.usage == StorageUsage(count: 0, bytes: 0))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("files").path))?.isEmpty ?? true)
    }

    @Test func filesAndPostersThatVanishedAreForgottenNotPointedAt() async throws {
        let root = try makeTempDirectory()
        let s = OfflineStore(root: root, tools: PreviewMediaTools(clock: VirtualClock(), clip: PreviewData.long))
        let media = MediaInfo(name: "n", duration: 1, width: 1, height: 1, bytes: 1, isImage: false)
        let a = try await s.add(file: try makeTempFile("a.mp4", bytes: 20), kind: .original, media: media, sessionID: nil, link: nil, remoteURL: nil, move: true)
        #expect(a.posterURL == nil)                                                      // the preview tools make none
        try FileManager.default.removeItem(at: try #require(a.fileURL))
        let reopened = OfflineStore(root: root, tools: PreviewMediaTools(clock: VirtualClock(), clip: PreviewData.long))
        #expect(reopened.videos.count == 1 && reopened.videos[0].fileURL == nil && reopened.videos[0].name == "n")
        #expect(reopened.usage == StorageUsage(count: 0, bytes: 0))

        // and a poster that went missing while the real tools made it
        let real = OfflineStore(root: try makeTempDirectory())
        let webp = try makeTempDirectory().appendingPathComponent("w.webp")
        try TestImages.animatedWebP.write(to: webp)
        let w = try await real.add(file: webp, kind: .webp, media: media, sessionID: nil, link: nil, remoteURL: nil, move: true)
        try FileManager.default.removeItem(at: try #require(w.posterURL))
        await real.reload()
        #expect(real.videos[0].posterURL == nil && real.videos[0].fileURL != nil)
    }

    @Test func removeAndDropDeleteTheFilesAndPostersOnDisk() async throws {
        let root = try makeTempDirectory()
        let s = store(root)
        let webp = try makeTempDirectory().appendingPathComponent("w.webp")
        try TestImages.animatedWebP.write(to: webp)
        let media = MediaInfo(name: "w", duration: nil, width: nil, height: nil, bytes: nil, isImage: false)
        let one = try await s.add(file: webp, kind: .webp, media: media, sessionID: nil, link: nil, remoteURL: nil, move: false)
        let two = try await s.add(file: webp, kind: .webp, media: media, sessionID: nil, link: nil, remoteURL: nil, move: false)
        let fm = FileManager.default

        await s.dropFilesKeepingPosters()
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("files/\(one.fileURL!.lastPathComponent)").path))
        #expect(s.videos.allSatisfy { $0.fileURL == nil && $0.posterURL.map { fm.fileExists(atPath: $0.path) } == true })
        // no files left; only the posters and their flipbooks still count
        let posterBytes = try (s.videos.compactMap(\.posterURL) + s.videos.flatMap(\.previewFrameURLs)).reduce(Int64(0)) { sum, url in
            sum + (try #require(try fm.attributesOfItem(atPath: url.path)[.size] as? Int64))
        }
        #expect(s.usage == StorageUsage(count: 0, bytes: posterBytes) && posterBytes > 0)

        let poster = try #require(s.videos.first { $0.id == two.id }?.posterURL)
        let frames = try #require(s.videos.first { $0.id == two.id }?.previewFrameURLs)
        #expect(frames.count == 3 && frames.allSatisfy { fm.fileExists(atPath: $0.path) })
        await s.remove(two.id)
        #expect(!fm.fileExists(atPath: poster.path) && s.videos.count == 1)
        #expect(frames.allSatisfy { !fm.fileExists(atPath: $0.path) })
        await s.remove("not-there")                                                         // harmless
        #expect(s.videos.count == 1)
    }

    @Test func staleInboxFoldersGoAndFreshOnesStay() async throws {
        let root = try makeTempDirectory()
        let s = store(root)
        let old = s.inboxURL(for: "old.mov").deletingLastPathComponent()
        let fresh = s.inboxURL(for: "fresh.mov").deletingLastPathComponent()
        try Data("x".utf8).write(to: old.appendingPathComponent("old.mov"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 86_400)], ofItemAtPath: old.path)
        await s.reload()
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        // the same sweep runs when a store opens
        let old2 = s.inboxURL(for: "old2.mov").deletingLastPathComponent()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 86_400)], ofItemAtPath: old2.path)
        _ = store(root)
        #expect(!FileManager.default.fileExists(atPath: old2.path))
    }

    @Test func appGroupFallsBackToApplicationSupportWithoutAContainer() throws {
        // no app-group entitlement under `swift test` (and none on macOS at all): the process's own folder
        #expect(AppGroup.containerURL() == nil)
        let name = "CobaltKitTests-\(UUID().uuidString.prefix(8))"
        let dir = AppGroup.directory(name)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(FileManager.default.fileExists(atPath: dir.path))
        #expect(dir.deletingLastPathComponent().path == FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path)
        #expect(AppGroup.defaults() === UserDefaults.standard)             // macOS never opens the group suite
    }
}

// MARK: - SharedJobStore across processes

struct SharedJobStoreTests {
    private func job(_ i: Int, origin: SharedJob.Origin = .shareExtension, stage: SharedJob.Stage = .ready, at t: Double = 2_000_000_000, pickedUp: Bool = false) -> SharedJob {
        SharedJob(
            id: UUID(), origin: origin, link: nil, sessionID: "s\(i)", media: nil, trim: nil, stage: stage,
            wantsTrim: false, pickedUp: pickedUp, updatedAt: Date(timeIntervalSince1970: t))
    }

    @Test func manyWritersOnTwoInstancesLoseNothing() throws {
        let dir = try makeTempDirectory()
        let a = SharedJobStore(directory: dir)
        let b = SharedJobStore(directory: dir)
        let jobs = (0..<40).map { job($0) }
        DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
            (i % 2 == 0 ? a : b).upsert(jobs[i])
        }
        #expect(Set(a.all().map(\.id)) == Set(jobs.map(\.id)))
        #expect(b.all().count == 40)
        // updating one of them in place keeps the count
        var changed = jobs[3]
        changed.stage = .rendering(job: "j")
        b.upsert(changed)
        #expect(a.all().count == 40 && a.all().first { $0.id == changed.id }?.stage == .rendering(job: "j"))
    }

    @Test func aDamagedFileReadsAsEmptyAndTheNextWriteRepairsIt() throws {
        let dir = try makeTempDirectory()
        let store = SharedJobStore(directory: dir)
        store.upsert(job(1))
        try Data("{ not json".utf8).write(to: dir.appendingPathComponent("jobs.json"))
        #expect(store.all().isEmpty && store.nextHandoff() == nil)
        store.upsert(job(2))
        #expect(store.all().count == 1)
    }

    @Test func oldRecordsAreDroppedWhenTheNextOneIsWritten() throws {
        let store = SharedJobStore(directory: try makeTempDirectory())
        let now = 2_000_000_000.0
        let stale = job(1, at: now - 8 * 86_400)                       // a week old, never finished
        let tookOver = job(2, at: now - 2 * 86_400, pickedUp: true)    // the app took it over days ago
        let recentTookOver = job(3, at: now - 3_600, pickedUp: true)
        let recent = job(4, at: now - 60)
        for j in [stale, tookOver, recentTookOver, recent] { store.upsert(j) }
        // writing a record stamped `now` measures everyone's age against it
        let fresh = job(5, at: now)
        store.upsert(fresh)
        #expect(Set(store.all().map(\.id)) == Set([recentTookOver.id, recent.id, fresh.id]))
    }

    @Test func anAppJobIsFollowedOnlyWhileItIsRecentAndInFlight() throws {
        let store = SharedJobStore(directory: try makeTempDirectory())
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let rendering = job(1, origin: .app, stage: .rendering(job: "j"), at: now.timeIntervalSince1970 - 120)
        let saving = job(2, origin: .app, stage: .saving, at: now.timeIntervalSince1970 - 30)
        let old = job(3, origin: .app, stage: .rendering(job: "x"), at: now.timeIntervalSince1970 - 3_600)
        let ready = job(4, origin: .app, stage: .ready, at: now.timeIntervalSince1970 - 5)
        let fromExtension = job(5, origin: .shareExtension, stage: .rendering(job: "y"), at: now.timeIntervalSince1970 - 5)
        let taken = job(6, origin: .app, stage: .saving, at: now.timeIntervalSince1970 - 5, pickedUp: true)
        for j in [rendering, saving, old, ready, fromExtension, taken] { store.upsert(j) }
        #expect(store.nextInFlightAppJob(now: now)?.id == saving.id)                  // the newest in flight
        store.remove(saving.id)
        #expect(store.nextInFlightAppJob(now: now)?.id == rendering.id)
        store.remove(rendering.id)
        #expect(store.nextInFlightAppJob(now: now) == nil)                           // old, ready, extension's, taken: none
    }
}

// MARK: - Settings and Keychain

@MainActor
struct SettingsPersistenceTests {
    @Test func preferencesServerAndKeySurviveANewInstance() throws {
        let defaults = UserDefaults(suiteName: "cobaltkit.tests.\(UUID().uuidString)")!
        let keychain = Keychain.memory()
        let first = Settings(defaults: defaults, keychain: keychain)
        try first.setServer(pasted: "https://cobalt.example.org:8443/x")
        try first.setAPIKey(pasted: "7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21")
        first.webpQuality = .low
        first.webpWidth = 320
        first.keepVideosOnDevice = false
        first.haptics = false

        let second = Settings(defaults: defaults, keychain: keychain)
        #expect(second.serverURL.absoluteString == "https://cobalt.example.org:8443")
        #expect(second.hasAPIKey && second.apiKey() == "7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21")
        #expect(second.webpQuality == .low && second.webpWidth == 320 && !second.keepVideosOnDevice && !second.haptics)

        second.resetServer()
        second.clearAPIKey()
        let third = Settings(defaults: defaults, keychain: keychain)
        #expect(third.serverURL == Settings.defaultServer && !third.hasAPIKey)
    }

    @Test func defaultsAreTheOwnersChoices() {
        let s = Settings(defaults: UserDefaults(suiteName: "cobaltkit.tests.\(UUID().uuidString)")!, keychain: .memory())
        #expect(s.keepVideosOnDevice && s.haptics && s.webpQuality == .med && s.webpWidth == 480)
        #expect(Settings.defaultServer.absoluteString == "https://api.capybaraharmony.com")
    }

    @Test func observersHearPreferenceChanges() async {
        let s = Settings(defaults: UserDefaults(suiteName: "cobaltkit.tests.\(UUID().uuidString)")!, keychain: .memory())
        final class Flag: @unchecked Sendable { var fired = false }
        let flag = Flag()
        withObservationTracking { _ = s.keepVideosOnDevice } onChange: { flag.fired = true }
        s.keepVideosOnDevice = false
        #expect(flag.fired)
    }
}

/// The real macOS keychain, on an item of its own. Skipped (not passed) where there is no usable keychain.
struct RealKeychainTests {
    static let usable: Bool = {
        let service = "com.capybaraharmony.cobalt.tests.probe-\(UUID().uuidString)"
        let k = Keychain(service: service, accessGroup: nil, backend: SystemKeychainBackend(), files: nil)
        defer { try? k.set(nil, for: "p") }
        do { try k.set("x", for: "p") } catch { return false }
        return k.string(for: "p") == "x"
    }()

    @Test(.enabled(if: RealKeychainTests.usable)) func storesUpdatesAndDeletes() throws {
        let k = Keychain(service: "com.capybaraharmony.cobalt.tests.\(UUID().uuidString)", accessGroup: nil, backend: SystemKeychainBackend(), files: nil)
        defer { try? k.set(nil, for: "api-key") }
        #expect(k.string(for: "api-key") == nil)
        try k.set("first", for: "api-key")
        #expect(k.string(for: "api-key") == "first")
        try k.set("second", for: "api-key")
        #expect(k.string(for: "api-key") == "second")
        try k.set(nil, for: "api-key")
        #expect(k.string(for: "api-key") == nil)
        try k.set(nil, for: "api-key")                                                // deleting nothing is fine
    }

    @Test(.enabled(if: RealKeychainTests.usable)) func aGroupThisBuildIsNotEntitledToFallsBackToTheDefaultKeychain() throws {
        // what an unsigned build sees: a configured group it cannot use
        let k = Keychain(service: "com.capybaraharmony.cobalt.tests.\(UUID().uuidString)", accessGroup: "ABCDE12345.com.capybaraharmony.cobalt", backend: SystemKeychainBackend(), files: nil)
        defer { try? k.set(nil, for: "api-key") }
        try k.set("v1", for: "api-key")
        #expect(k.string(for: "api-key") == "v1")
        try k.set("v2", for: "api-key")
        #expect(k.string(for: "api-key") == "v2")
        try k.set(nil, for: "api-key")
        #expect(k.string(for: "api-key") == nil)
    }

    @Test func theSharedKeychainWorksWithOrWithoutAGroup() {
        // `Keychain.shared` probes for an entitled group: under `swift test` there is none
        #expect(Keychain.entitledGroup() == nil)
    }

    @Test func theInMemoryKeychainBehavesLikeTheRealOne() throws {
        let k = Keychain.memory()
        try k.set("a", for: "x")
        #expect(k.string(for: "x") == "a")
        try k.set(nil, for: "x")
        #expect(k.string(for: "x") == nil)
        let other = Keychain.memory()
        #expect(other.string(for: "x") == nil)                                           // each one is its own
    }
}
