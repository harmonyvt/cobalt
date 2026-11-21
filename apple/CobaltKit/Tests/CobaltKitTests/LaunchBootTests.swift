import Foundation
import Testing
@testable import CobaltKit

// The two-step launch (the lifecycle audit, phase 3): the stores the app opens before its first frame do nothing costly in
// their initializers. The offline index, the job ledger, the keychain check and the sync database load off the main thread
// afterwards (`boot()` / `open()`), and nothing may be lost or decided from a state that only looks empty meanwhile.

private let bootInfo = MediaInfo(name: "clip", duration: 6, width: 96, height: 160, bytes: nil, isImage: false)

private func freshBootDefaults() -> UserDefaults {
    let suite = "cobalt.boot.test.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite) ?? .standard
    d.removePersistentDomain(forName: suite)
    return d
}

@MainActor
struct LaunchBootTests {
    /// An index with two cached files, written by a store that loaded the usual way (the last launch).
    private func lastLaunch() async throws -> (root: URL, defaults: UserDefaults, videos: [StoredVideo]) {
        let root = try makeTempDirectory()
        let defaults = freshBootDefaults()
        let before = OfflineStore(root: root, tools: MediaTestTools(), defaults: defaults)
        for session in ["S1", "S2"] {
            try await before.add(
                file: try makeTempFile("o.mp4", bytes: 1_000), kind: .original, media: bootInfo, sessionID: session,
                link: nil, remoteURL: nil, move: true, keep: false)
        }
        #expect(before.isLoaded)
        #expect(before.videos.count == 2)
        return (root, defaults, before.videos)
    }

    private func filesExist(_ videos: [StoredVideo]) -> Bool {
        videos.allSatisfy { v in v.fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    }

    @Test func theIndexLoadsAfterTheInitializerAndNothingIsDeletedMeanwhile() async throws {
        let (root, defaults, videos) = try await lastLaunch()
        // a leftover of a run that never finished, two days old
        let leftover = root.appendingPathComponent("inbox/old", isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 24 * 60 * 60)], ofItemAtPath: leftover.path)

        let store = OfflineStore(root: root, tools: MediaTestTools(), defaults: defaults, loadsLater: true)
        // Nothing has run yet: the test holds the main actor, where the first load lands.
        #expect(!store.isLoaded)
        #expect(store.videos.isEmpty && store.media.isEmpty)
        #expect(OfflineStore.readRecords(root: root).count == 2, "the index on disk is untouched")
        #expect(filesExist(videos), "an index that only looks empty deletes nothing")
        #expect(FileManager.default.fileExists(atPath: leftover.path), "the inbox purge waits for the engine too")

        await store.boot()
        #expect(store.isLoaded)
        #expect(Set(store.videos.map(\.id)) == Set(videos.map(\.id)))
        #expect(store.media.count == 2)
        #expect(filesExist(videos))
        #expect(!FileManager.default.fileExists(atPath: leftover.path), "the boot purged the old inbox folder")

        await store.boot()                                                 // a second wait returns at once
        #expect(store.videos.count == 2)
    }

    @Test func aRemoveAskedBeforeTheLoadWaitsForItAndRemovesOnlyItsOwn() async throws {
        let (root, defaults, videos) = try await lastLaunch()
        let store = OfflineStore(root: root, tools: MediaTestTools(), defaults: defaults, loadsLater: true)
        let gone = try #require(videos.first)
        await store.remove(gone.id)                                        // asked while `videos` is still empty
        #expect(store.isLoaded)
        #expect(store.videos.map(\.id) == videos.dropFirst().map(\.id))
        #expect(OfflineStore.readRecords(root: root).map(\.id) == videos.dropFirst().map(\.id))
        #expect(filesExist(Array(videos.dropFirst())))
    }

    @Test func theLimitAtLaunchRunsAfterTheLoadAndOnTheIndexOnDisk() async throws {
        let (root, defaults, videos) = try await lastLaunch()
        let store = OfflineStore(root: root, tools: MediaTestTools(), defaults: defaults, loadsLater: true)
        await store.enforceLimit()                                         // AppModel.live's launch task, no limit set
        await store.boot()
        #expect(Set(store.videos.map(\.id)) == Set(videos.map(\.id)))
        #expect(filesExist(videos))
    }

    @Test func aReloadAtLaunchWaitsForTheFirstLoad() async throws {
        let (root, defaults, videos) = try await lastLaunch()
        let store = OfflineStore(root: root, tools: MediaTestTools(), defaults: defaults, loadsLater: true)
        await store.reload()
        #expect(store.isLoaded)
        #expect(Set(store.videos.map(\.id)) == Set(videos.map(\.id)))
    }

    // MARK: the job ledger

    private func ledgerFile() throws -> URL {
        try makeTempDirectory().appendingPathComponent("cobalt", isDirectory: true).appendingPathComponent("job-ledger.json")
    }

    private func entry(_ link: String) -> JobLedger.Entry {
        // a whole second: the file keeps milliseconds, and the entries are compared after a round trip
        JobLedger.Entry(
            id: UUID(), input: .link(URL(string: link)!), options: JobOptions(), via: .shortcut,
            addedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func theLedgerReadsNothingUntilItIsBootedOrAsked() async throws {
        let file = try ledgerFile()
        let first = JobLedger(fileURL: file)
        let (a, b) = (entry("https://example.com/a"), entry("https://example.com/b"))
        first.add(a)
        first.add(b)

        let lazy = JobLedger(fileURL: file)
        #expect(!lazy.isLoaded, "the initializer reads nothing")
        await lazy.boot()
        #expect(lazy.isLoaded)
        #expect(lazy.all == [a, b])

        // asked before any boot: read then, on the spot
        let asked = JobLedger(fileURL: file)
        #expect(asked.all == [a, b])
        #expect(asked.isLoaded)
    }

    @Test func anAddBeforeTheBootKeepsWhatTheFileHeld() async throws {
        let file = try ledgerFile()
        let a = entry("https://example.com/a")
        JobLedger(fileURL: file).add(a)

        let ledger = JobLedger(fileURL: file)
        let b = entry("https://example.com/b")
        ledger.add(b)                                                      // a job added in the first moments
        await ledger.boot()                                                // the background read lands later: dropped
        #expect(ledger.all == [a, b])
        #expect(JobLedger(fileURL: file).all == [a, b], "the file was never written without the old entry")
    }

    // MARK: the key check

    @Test func theKeyStartsFromTheLastAnswerAndTheKeychainHasTheLastWord() async throws {
        let keychain = Keychain.memory()
        let defaults = freshBootDefaults()
        // the first launch of this build: no last answer, so the keychain is read in the initializer, as before
        let first = Settings(defaults: defaults, keychain: keychain, checksKeyLater: true)
        #expect(!first.hasAPIKey)
        try first.setAPIKey(pasted: UUID().uuidString)
        #expect(first.hasAPIKey)

        let next = Settings(defaults: defaults, keychain: keychain, checksKeyLater: true)
        #expect(next.hasAPIKey, "the first frame shows the last answer")
        await next.boot()
        #expect(next.hasAPIKey)

        // the key went while the app was closed: the last answer shows, then the keychain's
        try keychain.set(nil, for: Settings.keyAccount)
        let after = Settings(defaults: defaults, keychain: keychain, checksKeyLater: true)
        #expect(after.hasAPIKey)
        await after.boot()
        #expect(!after.hasAPIKey)
        #expect(!Settings(defaults: defaults, keychain: keychain, checksKeyLater: true).hasAPIKey, "and is remembered")
    }

    @Test func anAnswerGivenDuringTheCheckIsNotUndoneByIt() async throws {
        let keychain = Keychain.memory()
        let defaults = freshBootDefaults()
        let first = Settings(defaults: defaults, keychain: keychain)
        try first.setAPIKey(pasted: UUID().uuidString)                    // remembered: true

        let settings = Settings(defaults: defaults, keychain: keychain, checksKeyLater: true)
        settings.clearAPIKey()                                             // signed out before the check landed
        await settings.boot()
        #expect(!settings.hasAPIKey)
    }

    // MARK: the sync database

    @Test func theSyncDatabaseOpensOnFirstUse() async throws {
        let dir = try makeTempDirectory().appendingPathComponent("sync", isDirectory: true)
        let file = dir.appendingPathComponent("library.sqlite")
        let store = try SyncStore(fileURL: file)
        #expect(!FileManager.default.fileExists(atPath: file.path), "the initializer opens nothing")
        try await store.open()
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try await store.pendingOps().isEmpty)
    }

    @Test func aDatabaseThatCannotOpenSaysSoEveryTime() async throws {
        let blocker = try makeTempFile("not-a-folder", bytes: 10)          // a file where the folder should be
        let store = try SyncStore(fileURL: blocker.appendingPathComponent("library.sqlite"))
        await #expect(throws: (any Error).self) { try await store.open() }
        await #expect(throws: (any Error).self) { try await store.open() }
        await #expect(throws: (any Error).self) { try await store.pendingOps() }
    }
}
