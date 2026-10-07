import Foundation
import Testing
@testable import CobaltKit

// A remake replaces the file made before (R8), and never an owner's own (CONTRACT-OFFLINE.md 13.7): the old kept file goes
// only while its name is still the one cobalt gave it; on the Mac it goes to the Trash.

private let post = URL(string: "https://www.instagram.com/p/DeKlsGCGZmx/")!

@MainActor
private func makeSlideshow(_ store: OfflineStore, library: String, bytes: Int = 900, keep: Bool = true) async throws -> StoredVideo {
    let file = try makeTempFile("slideshow-\(library).webp", bytes: bytes)
    let info = MediaInfo(name: "slideshow", duration: 3, width: 100, height: 100, bytes: nil, isImage: true)
    return try await store.add(
        file: file, kind: .webp, media: info, sessionID: "G1", link: post, remoteURL: nil, move: true, mediaID: nil, keep: keep,
        role: .slideshow, madeFrom: [0, 1], madeSpec: Data(#"{"format":"webp"}"#.utf8), libraryID: library)
}

/// The post's first photo: the media a made file joins, so the media (and its folder, found by tag) outlives a replaced file.
@MainActor
private func anchor(_ store: OfflineStore) async throws {
    let file = try makeTempFile("01.jpg", bytes: 400)
    let info = MediaInfo(name: "01", duration: nil, width: 10, height: 10, bytes: nil, isImage: true)
    _ = try await store.add(
        file: file, kind: .original, media: info, sessionID: "G1", link: post, remoteURL: nil, move: true, mediaID: nil, keep: true,
        role: .item, itemIndex: 0, libraryID: "i0", postItems: 2)
}

@MainActor
struct ReplaceMadeTests {
    @Test func anUntouchedMadeFileGoesToTheTrashAndTheNewOneTakesItsName() async throws {
        let rig = try MacRig()
        try rig.commit()
        let store = rig.store()
        try await anchor(store)
        let first = try await makeSlideshow(store, library: "m1")
        let path = try #require(rig.record(first.id)?.visiblePath)
        #expect((path as NSString).lastPathComponent == "slideshow.webp")

        #expect(await store.replaceMade(first.id))
        #expect(rig.trash.items.map(\.lastPathComponent) == ["slideshow.webp"], "the Mac sends it to the Trash")
        #expect(!rig.exists(path) && rig.record(first.id) == nil)
        #expect(OfflineTombstones.ids(root: rig.hidden).contains(first.id))

        let second = try await makeSlideshow(store, library: "m2", bytes: 1_400)
        #expect(rig.record(second.id)?.visiblePath == path, "the free name: never `slideshow (2).webp`")
        #expect(rig.files().count == 2, "the first photo and the slideshow")
    }

    @Test func aFileTheOwnerRenamedIsLeftInPlaceUntaggedAndOnlyTheRecordGoes() async throws {
        let rig = try MacRig()
        try rig.commit()
        let store = rig.store()
        try await anchor(store)
        let first = try await makeSlideshow(store, library: "m1")
        let path = try #require(rig.record(first.id)?.visiblePath)
        let folder = (path as NSString).deletingLastPathComponent
        let mine = "\(folder)/my cover.webp"
        try FileManager.default.moveItem(at: rig.folder.appendingPathComponent(path), to: rig.folder.appendingPathComponent(mine))

        #expect(await store.replaceMade(first.id))
        #expect(rig.exists(mine), "the owner's file stays")
        #expect(rig.tag(mine) == nil && !FileAttributes.names(rig.folder.appendingPathComponent(mine)).contains(OfflineTag.attribute), "and is theirs: untagged")
        #expect(rig.trash.items.isEmpty && rig.record(first.id) == nil)
        await store.reload()
        #expect(rig.exists(mine) && rig.index().count == 1, "a scan does not take it for cobalt's again")

        let second = try await makeSlideshow(store, library: "m2")
        #expect(rig.record(second.id)?.visiblePath == path, "the new file takes the free name beside it")
        #expect(rig.exists(mine))
    }

    @Test func aFileCrashRecoveryAdoptedHasNoGivenNameSoItIsLeftToo() async throws {
        let rig = try MacRig()
        try rig.commit()
        let store = rig.store()
        try await anchor(store)
        let first = try await makeSlideshow(store, library: "m1")
        let path = try #require(rig.record(first.id)?.visiblePath)
        _ = try OfflineStore.mutate(root: rig.hidden) { records in
            for i in records.indices where records[i].id == first.id { records[i].givenName = nil }
        }
        await store.reload()
        #expect(await store.replaceMade(first.id))
        #expect(rig.exists(path) && rig.tag(path) == nil && rig.trash.items.isEmpty)
    }

    @Test func aFileAnotherMediaOwnsAtThePathIsNeverDeleted() async throws {
        let rig = try MacRig()
        try rig.commit()
        let store = rig.store()
        try await anchor(store)
        let first = try await makeSlideshow(store, library: "m1")
        let path = try #require(rig.record(first.id)?.visiblePath)
        // the owner swapped the file for one of their own under the same name
        let url = rig.folder.appendingPathComponent(path)
        try FileManager.default.removeItem(at: url)
        try Data(repeating: 4, count: 20).write(to: url)
        #expect(await store.replaceMade(first.id), "the record goes")
        let size = try Data(contentsOf: url).count
        #expect(rig.exists(path) && size == 20 && rig.trash.items.isEmpty)
    }

    @Test func aCacheRecordJustLosesItsRecordAndAnUnknownIdChangesNothing() async throws {
        let rig = try MacRig()
        try rig.commit()
        let store = rig.store()
        let cached = try await makeSlideshow(store, library: "m1", keep: false)
        #expect(rig.record(cached.id)?.fileName != nil)
        #expect(await store.replaceMade(cached.id))
        #expect(rig.record(cached.id) == nil && rig.cacheFiles().isEmpty)
        #expect(!(await store.replaceMade("nope")))
    }

    @Test func onIOSTheFileIsDeletedOutrightNotTrashed() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        try await anchor(store)
        let first = try await makeSlideshow(store, library: "m1")
        let path = try #require(rig.record(first.id)?.visiblePath)
        #expect(FileManager.default.fileExists(atPath: rig.url(path).path))
        #expect(await store.replaceMade(first.id))
        #expect(!FileManager.default.fileExists(atPath: rig.url(path).path) && rig.record(first.id) == nil)
        let second = try await makeSlideshow(store, library: "m2")
        #expect(rig.record(second.id)?.visiblePath == path)
    }
}
