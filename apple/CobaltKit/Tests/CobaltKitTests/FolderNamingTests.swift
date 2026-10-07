import Foundation
import Testing
@testable import CobaltKit

// What survives of the Mac's old "save to a folder" (wave M retired FolderSync): how a file is named and a clash
// settled, the folder ledger's destination records, and the bookmark round trip. Real files in temp directories.

private let hostedWebp1 = URL(string: "https://media.capybaraharmony.com/aBcD000001.webp")!
private let hostedWebp2 = URL(string: "https://media.capybaraharmony.com/aBcD000002.webp")!
private let igLink = URL(string: "https://www.instagram.com/reel/DeHC9jcpfQW/")!

// MARK: - Naming

struct FolderNamingTests {
    private func video(
        kind: StoredVideo.Kind = .original, id: String = "v1", name: String = "clip", file: String? = "x.mp4",
        link: URL? = igLink, title: String? = nil, remote: URL? = nil
    ) -> StoredVideo {
        StoredVideo(
            id: id, kind: kind, fileURL: file.map { URL(fileURLWithPath: "/store/\($0)") }, posterURL: nil, name: name,
            duration: 5, width: 1, height: 1, bytes: 10, sessionID: "S1", link: link, remoteURL: remote,
            createdAt: Date(timeIntervalSince1970: 1_000), title: title)
    }

    @Test func aLinkSaveIsServiceDotRef() {
        let v = video()
        #expect(FolderNaming.fileName(for: v, in: nil) == "instagram · DeHC9jcpfQW.mp4")
    }

    @Test func aCustomTitleWinsAndAFileKeepsItsName() {
        #expect(FolderNaming.fileName(for: video(title: "cat on a keyboard"), in: nil) == "cat on a keyboard.mp4")
        let picked = video(name: "IMG_0412.MOV", file: "y.mov", link: nil)
        #expect(FolderNaming.fileName(for: picked, in: nil) == "IMG_0412.mov", "the file's name without its media extension, the file's own extension")
        let bare = video(name: "", link: nil)
        #expect(FolderNaming.fileName(for: bare, in: nil) == "cobalt.mp4")
    }

    @Test func aWebpIsTitleDotWebpAndItsNumber() throws {
        let original = video()
        let w1 = video(kind: .webp, id: "w1", name: "a.webp", file: "w1.webp", remote: hostedWebp1)
        let w2 = video(kind: .webp, id: "w2", name: "b.webp", file: "w2.webp", remote: hostedWebp2)
        let media = try #require(StoredMedia(id: "m", original: original, webps: [w1, w2]))
        #expect(FolderNaming.fileName(for: w1, in: media) == "instagram · DeHC9jcpfQW · webp 1.webp")
        #expect(FolderNaming.fileName(for: w2, in: media) == "instagram · DeHC9jcpfQW · webp 2.webp")
        #expect(FolderNaming.fileName(for: original, in: media) == "instagram · DeHC9jcpfQW.mp4")
        var titled = w2
        titled.title = "party"
        let renamed = try #require(StoredMedia(id: "m", original: nil, webps: [titled]))
        #expect(FolderNaming.fileName(for: titled, in: renamed) == "party · webp 1.webp", "the webp's own place among the media's webps")
    }

    @Test func theNameIsOnePathComponent() {
        let evil = video(link: nil, title: "a/b:c\\d\u{0}e\n..")
        let name = FolderNaming.fileName(for: evil, in: nil)
        #expect(!name.contains("/") && !name.contains(":") && !name.contains("\\") && !name.contains("\n") && !name.contains("\u{0}"))
        #expect(!name.hasPrefix("."))
        #expect(FolderNaming.assemble(stem: "...", ext: "mp4") == "cobalt.mp4")
        #expect(FolderNaming.assemble(stem: ".hidden", ext: "mp4").hasPrefix("_hidden"), "never a hidden file")
        #expect(FolderNaming.assemble(stem: "fin. ", ext: "mp4") == "fin.mp4", "no trailing dot or space before the extension")
    }

    @Test func aLongTitleKeepsItsExtensionAndFitsAName() {
        let emoji = String(repeating: "🎬", count: 80)                       // 4 bytes each: 320 bytes
        let name = FolderNaming.fileName(for: video(title: emoji), in: nil)
        #expect(name.hasSuffix(".mp4"))
        #expect(name.utf8.count <= 255 - 5, "room is left for ' (99)'")
    }

    @Test func aClashGetsACounterBeforeTheExtension() {
        var taken: Set<String> = ["a.mp4", "a (2).mp4"]
        #expect(FolderNaming.unique("b.mp4") { taken.contains($0) } == "b.mp4")
        #expect(FolderNaming.unique("a.mp4") { taken.contains($0) } == "a (3).mp4")
        taken.insert("a (3).mp4")
        #expect(FolderNaming.unique("a.mp4") { taken.contains($0) } == "a (4).mp4")
        #expect(FolderNaming.unique("noext") { $0 == "noext" } == "noext (2)")
    }

    @Test func theExtensionIsTheFilesOwn() {
        #expect(FolderNaming.fileExtension(of: video(file: "z.MOV")) == "mov")
        #expect(FolderNaming.fileExtension(of: video(file: nil)) == "mp4")
        #expect(FolderNaming.fileExtension(of: video(kind: .webp, file: nil)) == "webp")
        #expect(FolderNaming.fileExtension(of: video(file: "weird")) == "mp4", "no extension: the kind's")
    }
}

// MARK: - The ledger
// MARK: - The ledger (what is left of it: the destination record and the sections FolderSync wrote)

struct FolderLedgerTests {
    private func ledger() throws -> FolderLedger { FolderLedger(directory: try makeTempDirectory()) }

    @Test func eachFolderHasItsOwnSectionAndAKnownFolderComesBack() throws {
        let l = try ledger()
        let a = l.choose(path: "/Volumes/A/cobalt", bookmark: Data([1]), isDefault: false)
        let back = l.choose(path: "/somewhere", bookmark: nil, isDefault: true)
        #expect(back == FolderLedger.defaultID && l.destination == nil)
        #expect(l.hasSection(a) && l.hasSection(back))
        let again = l.choose(path: "/Volumes/A/cobalt", bookmark: Data([2]), isDefault: false)
        #expect(again == a, "choosing a folder the ledger knows brings its section back")
        #expect(l.destination?.bookmark == Data([2]))
    }

    @Test func aRecordFromFolderSyncDecodesAndTheIdentityIsRecordedOnce() throws {
        let dir = try makeTempDirectory()
        // a folder.json as 1.14.x wrote it: a destination with no volume or file id, and a done entry
        let old = """
        {"destination":{"id":"X","path":"/Volumes/A/cobalt","bookmark":"AQID"},        "sections":{"X":{"path":"/Volumes/A/cobalt","items":{"s:1":{"state":"done","at":1000,"file":"a.mp4","bytes":10,"tries":0}}}}}
        """
        try Data(old.utf8).write(to: dir.appendingPathComponent("folder.json"))
        let l = FolderLedger(directory: dir)
        #expect(l.destination?.volume == nil && l.entry("X", "s:1")?.state == .done && l.entry("X", "s:1")?.bytes == 10)
        l.recordIdentity(volume: "VOL", fileID: 42)
        #expect(l.destination?.volume == "VOL" && l.destination?.fileID == 42)
        l.recordIdentity(volume: "OTHER", fileID: 7)
        #expect(l.destination?.volume == "VOL", "recorded once: a different disk is never taken for the folder")
        #expect(l.entry("X", "s:1")?.state == .done, "the sections are untouched")
    }

    @Test func theFileSurvivesARelaunch() throws {
        let dir = try makeTempDirectory()
        let a = FolderLedger(directory: dir)
        a.choose(path: "/Volumes/A/cobalt", bookmark: nil, isDefault: false, volume: "V", fileID: 9)
        let b = FolderLedger(directory: dir)
        #expect(b.destination?.path == "/Volumes/A/cobalt" && b.destination?.volume == "V" && b.destination?.fileID == 9)
    }
}

// MARK: - The bookmark

struct FolderBookmarkTests {
    @Test func aBookmarkResolvesToTheSameFolder() throws {
        let dir = try makeTempDirectory().appendingPathComponent("chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try FolderDestination.makeBookmark(for: dir)
        let resolved = try #require(FolderDestination.resolve(bookmark: data))
        defer { resolved.access.stop() }
        #expect(FolderDestination.canonical(resolved.access.url) == FolderDestination.canonical(dir))
        #expect(!resolved.stale)
        // and it is a folder cobalt can write into
        let probe = resolved.access.url.appendingPathComponent("probe.txt")
        try Data("x".utf8).write(to: probe)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("probe.txt").path))
    }

    @Test func aBookmarkFollowsAFolderTheOwnerRenamed() throws {
        let root = try makeTempDirectory()
        let before = root.appendingPathComponent("before", isDirectory: true)
        let after = root.appendingPathComponent("after", isDirectory: true)
        try FileManager.default.createDirectory(at: before, withIntermediateDirectories: true)
        let data = try FolderDestination.makeBookmark(for: before)
        try FileManager.default.moveItem(at: before, to: after)
        let resolved = try #require(FolderDestination.resolve(bookmark: data))
        defer { resolved.access.stop() }
        #expect(FolderDestination.canonical(resolved.access.url) == FolderDestination.canonical(after))
    }

    @Test func openingTheDestinationFollowsTheLedgerAndNeverRecreatesAChosenFolder() throws {
        let root = try makeTempDirectory()
        let l = FolderLedger(directory: root.appendingPathComponent("Sync"))
        let fallback = root.appendingPathComponent("Movies/cobalt", isDirectory: true)

        // default: made on demand
        guard case .ready(let a, let id, _) = FolderDestination.open(ledger: l, defaultFolder: fallback) else { Issue.record("default not ready"); return }
        #expect(id == FolderLedger.defaultID && FileManager.default.fileExists(atPath: fallback.path))
        a.stop()

        // chosen: through its bookmark
        let chosen = root.appendingPathComponent("chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        l.choose(path: chosen.path, bookmark: try FolderDestination.makeBookmark(for: chosen), isDefault: false)
        guard case .ready(let b, let chosenID, _) = FolderDestination.open(ledger: l, defaultFolder: fallback) else { Issue.record("chosen not ready"); return }
        #expect(chosenID == l.destinationID && FolderDestination.canonical(b.url) == FolderDestination.canonical(chosen))
        b.stop()

        // chosen, then deleted: reported missing, not re-made
        try FileManager.default.removeItem(at: chosen)
        guard case .missing = FolderDestination.open(ledger: l, defaultFolder: fallback) else { Issue.record("a deleted folder must read as missing"); return }
        #expect(!FileManager.default.fileExists(atPath: chosen.path))
    }
}
