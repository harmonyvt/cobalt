import Foundation
import Synchronization
import Testing
@testable import CobaltKit

// The Finder sidebar's pure half: which files become originals, how folders and files are named,
// the sync anchor, and the diff. No File Provider and no network.

private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
private let poster = URL(string: "https://media.capybaraharmony.com/poster0001.jpg")!
private let cdn = URL(string: "https://media.capybaraharmony.com/clip000001.mp4")!

private func file(
    _ id: String, name: String, source: LibraryFile.Source = .saved, kind: LibraryFile.Kind = .private,
    type: String = "video/mp4", bytes: Int64 = 100, at: Date = t0, url: URL? = nil,
    role: GalleryRole? = nil, index: Int? = nil, posterURL: URL? = nil
) -> LibraryFile {
    LibraryFile(
        id: id, kind: kind, source: source, name: name, url: url, contentType: type, bytes: bytes,
        width: 10, height: 10, duration: 1, createdAt: at, mediaName: nil, deletable: false,
        posterURL: posterURL, galleryRole: role, itemIndex: index)
}

private func post(
    _ id: String, title: String? = nil, custom: String? = nil, service: String? = nil, ref: String? = nil,
    files: [LibraryFile], hidden: Bool = false, at: Date = t0, posterURL: URL? = nil
) -> LibraryPost {
    let link = ref.flatMap { URL(string: "https://www.instagram.com/reel/\($0)/") }
    return LibraryPost(
        id: id, service: service, link: link, title: title, duration: nil, width: nil, height: nil,
        createdAt: at, session: nil, files: files, customTitle: custom, posterURL: posterURL, hidden: hidden)
}

private func page(_ posts: [LibraryPost], next: String? = nil) -> LibraryPage {
    LibraryPage(
        posts: posts, postCount: posts.count, fileCount: posts.reduce(0) { $0 + $1.files.count },
        publicBytes: 0, privateBytes: 0, next: next)
}

private func node(_ snapshot: FinderLibrary.Snapshot, _ raw: String) -> FinderLibrary.Node {
    snapshot.node(raw)!
}

struct FinderLibraryTests {
    @Test func aHiddenPostIsLeftOut() {
        let posts = [
            post("hide", custom: "secret", files: [file("h1", name: "a.mp4")], hidden: true),
            post("show", custom: "visible", files: [file("s1", name: "b.mp4")]),
        ]
        let snapshot = FinderLibrary.make(posts: posts)
        #expect(snapshot.rootChildren == ["post:show"])
        #expect(snapshot.node("post:hide") == nil)
        #expect(snapshot.node("file:h1") == nil)
    }

    @Test func webpPreviewsCropsAndMadeFilesStayOut() {
        let video = file("vid", name: "clip.mp4", posterURL: poster)
        let webp = file("w", name: "clip.webp", source: .webp, kind: .public, type: "image/webp", url: URL(string: "https://media.capybaraharmony.com/w.webp"))
        let studioWebp = file("sw", name: "made.webp", source: .studio, type: "image/webp")
        let crop = file("c", name: "crop.jpg", source: .made, type: "image/jpeg", role: .crop)
        let snapshot = FinderLibrary.make(posts: [post("p", custom: "Cat", files: [video, webp, studioWebp, crop], posterURL: poster)])
        #expect(snapshot.children["post:p"] == ["file:vid"])
        let item = node(snapshot, "file:vid")
        #expect(item.name == "clip.mp4")
        #expect(item.typeIdentifier == "public.mpeg-4")
        #expect(item.privateFileID == "vid")
        #expect(item.contentURL == nil)
        #expect(item.thumbnailURL == poster)
        #expect(node(snapshot, "post:p").thumbnailURL == poster)
        #expect(node(snapshot, "post:p").name == "Cat")
    }

    @Test func aGalleryShowsItsItemsAndNotTheDerivatives() {
        let first = file("a", name: "01.jpg", type: "image/jpeg", role: .item, index: 0, posterURL: poster)
        let second = file("b", name: "02.mp4", role: .item, index: 1)
        let slide = file("s", name: "slideshow.webp", source: .made, type: "image/webp", role: .slideshow)
        let snapshot = FinderLibrary.make(posts: [post("g", custom: "trip", files: [second, slide, first])])
        #expect(snapshot.children["post:g"] == ["file:a", "file:b"])
        #expect(node(snapshot, "file:a").name == "01.jpg")
        #expect(node(snapshot, "file:a").typeIdentifier == "public.jpeg")
        #expect(node(snapshot, "file:b").typeIdentifier == "public.mpeg-4")
    }

    @Test func aPublicFileIsFetchedFromItsURLAndAPrivateOneFromTheLibraryRoute() {
        let hosted = file("pub", name: "clip", type: "video/mp4", url: cdn, posterURL: poster)
        let snapshot = FinderLibrary.make(posts: [post("p", custom: "hosted", files: [hosted])])
        let item = node(snapshot, "file:pub")
        #expect(item.name == "clip.mp4")
        #expect(item.contentURL == cdn)
        #expect(item.privateFileID == nil)
        #expect(item.thumbnailURL == poster)
        #expect(item.typeIdentifier == "public.mpeg-4")
    }

    @Test func anImageWithoutAPosterUsesItselfAsTheThumbnail() {
        let url = URL(string: "https://media.capybaraharmony.com/photo.jpg")!
        let photo = file("img", name: "photo.jpg", source: .upload, type: "image/jpeg", url: url)
        let item = node(FinderLibrary.make(posts: [post("p", custom: "shot", files: [photo])]), "file:img")
        #expect(item.thumbnailURL == url)
        #expect(item.contentURL == url)
        #expect(item.typeIdentifier == "public.jpeg")
    }

    @Test func anEmoteIsTheFileAndAHostCopyIsTheFallback() {
        let emote = file("e", name: "wave.webp", source: .emote, kind: .public, type: "image/webp", url: URL(string: "https://media.capybaraharmony.com/e.webp"))
        let onlyHost = file("h", name: "old.mp4", source: .host, kind: .public, url: cdn)
        let madeOnly = file("m", name: "crop.jpg", source: .made, type: "image/jpeg", role: .crop)
        let snapshot = FinderLibrary.make(posts: [
            post("em", custom: "wave", files: [emote]),
            post("host", custom: "legacy", files: [onlyHost]),
            post("gone", custom: "empty", files: [madeOnly]),
        ])
        #expect(snapshot.rootChildren == ["post:em", "post:host"])
        #expect(node(snapshot, "file:e").typeIdentifier == "org.webmproject.webp")
        #expect(node(snapshot, "file:h").contentURL == cdn)
        #expect(snapshot.node("post:gone") == nil)
    }

    @Test func matchingFolderNamesAreNumberedAndUnsafeCharactersAreStripped() {
        let one = post("a", custom: "Cat", files: [file("1", name: "a.mp4")])
        let two = post("b", custom: "cat", files: [file("2", name: "a/b:c.mov", type: "video/quicktime")])
        let snapshot = FinderLibrary.make(posts: [one, two])
        #expect(node(snapshot, "post:a").name == "Cat")
        #expect(node(snapshot, "post:b").name == "cat (2)")
        #expect(node(snapshot, "file:2").name == "a_b_c.mov")
        #expect(node(snapshot, "file:2").typeIdentifier == "com.apple.quicktime-movie")
    }

    @Test func theSameLibraryKeepsItsAnchorAndAByteChangeMovesIt() throws {
        let posts = [post("p", custom: "Cat", files: [file("1", name: "a.mp4", bytes: 10)])]
        let first = FinderLibrary.make(posts: posts)
        let again = FinderLibrary.make(posts: posts)
        #expect(first.anchor == again.anchor)
        let bigger = FinderLibrary.make(posts: [post("p", custom: "Cat", files: [file("1", name: "a.mp4", bytes: 11)])])
        #expect(bigger.anchor != first.anchor)
        let round = try FinderLibrary.Snapshot.decoded(try FinderLibrary.Snapshot.encoded(first))
        #expect(round == first)
    }

    @Test func aDiffReportsANewFileARenameAndADelete() {
        let before = FinderLibrary.make(posts: [
            post("a", custom: "Cat", files: [file("1", name: "a.mp4")]),
            post("b", custom: "Dog", files: [file("2", name: "b.mp4")]),
        ])
        let after = FinderLibrary.make(posts: [
            post("a", custom: "Kitten", files: [file("1", name: "a.mp4"), file("3", name: "c.jpg", type: "image/jpeg")]),
        ])
        let delta = FinderLibrary.delta(from: before, to: after)
        #expect(delta.deleted == ["file:2", "post:b"])
        #expect(Set(delta.updated) == Set(["post:a", "file:3"]))
        #expect(!delta.updated.contains("file:1"))
    }

    @Test func syncIsCurrentExpiredOrADiff() {
        let before = FinderLibrary.make(posts: [post("a", custom: "Cat", files: [file("1", name: "a.mp4")])])
        let after = FinderLibrary.make(posts: [post("a", custom: "Kitten", files: [file("1", name: "a.mp4")])])
        guard case .current = FinderLibrary.sync(anchor: after.anchor, previous: before, current: after) else {
            Issue.record("a matching anchor should not report changes")
            return
        }
        guard case .rescan = FinderLibrary.sync(anchor: nil, previous: before, current: after) else {
            Issue.record("a missing anchor should rescan")
            return
        }
        guard case .rescan = FinderLibrary.sync(anchor: Data([1, 2, 3]), previous: before, current: after) else {
            Issue.record("an unknown anchor should rescan")
            return
        }
        guard case .apply(let delta, _) = FinderLibrary.sync(anchor: before.anchor, previous: before, current: after) else {
            Issue.record("the previous anchor should apply a diff")
            return
        }
        #expect(delta.updated == ["post:a"])
        #expect(delta.deleted.isEmpty)
    }

    @Test func theLibraryPageSizeIsTheAPIMaximum() {
        // GET /library answers 400 above 50 (`MAX_LIBRARY_LIMIT` in app-routes.ts).
        #expect(FinderLibrary.pageLimit == 50)
    }

    @Test func aRootPageMapsTheAPICursorAndTheNextPageDisambiguatesTheName() {
        var taken = Set<String>()
        let first = FinderLibrary.listingPage(
            page([post("a", custom: "Cat", files: [file("1", name: "a.mp4")])], next: "cursor-1"),
            takenNames: &taken)
        #expect(first.nextCursor == "cursor-1")
        #expect(first.folders.map(\.name) == ["Cat"])
        #expect(first.files.map(\.raw) == ["file:1"])
        #expect(first.files.first?.parent == .post("a"))
        let token = FinderLibrary.RootPageToken(cursor: first.nextCursor)
        #expect(token.cursor == "cursor-1")
        #expect(FinderLibrary.RootPageToken(pageData: token.data).cursor == "cursor-1")
        #expect(FinderLibrary.RootPageToken(pageData: Data()).cursor == nil)

        let second = FinderLibrary.listingPage(
            page([
                post("h", custom: "Hidden", files: [file("9", name: "h.mp4")], hidden: true),
                post("b", custom: "Cat", files: [file("2", name: "b.mp4")]),
            ], next: nil),
            takenNames: &taken)
        #expect(second.folders.map(\.name) == ["Cat (2)"])
        #expect(second.nextCursor == nil)
        #expect(second.files.map(\.parent) == [.post("b")])
    }

    @Test func pagingDropsHiddenPostsAndStopsOnARepeatedCursor() async throws {
        let calls = Mutex<[String?]>([])
        let posts = try await FinderLibrary.collect { cursor in
            calls.withLock { $0.append(cursor) }
            if cursor == nil { return page([post("a", custom: "A", files: [file("1", name: "a.mp4")], hidden: true), post("b", custom: "B", files: [file("2", name: "b.mp4")])], next: "c1") }
            return page([post("b", custom: "B", files: [file("2", name: "b.mp4")])], next: "c1")
        }
        #expect(posts.map(\.id) == ["b"])
        #expect(calls.withLock { $0 } == [nil, "c1"])
    }

    @Test func refusalsMapToUnauthorizedUnreachableAndNotFound() {
        #expect(FinderLibrary.failure(from: CobaltError.noAPIKey) == .unauthorized)
        #expect(FinderLibrary.failure(from: CobaltError.api(code: "error.api.auth.key.invalid", httpStatus: 401)) == .unauthorized)
        #expect(FinderLibrary.failure(from: CobaltError.api(code: "error.library.not_found", httpStatus: 404)) == .notFound)
        #expect(FinderLibrary.failure(from: CobaltError.network(.timedOut)) == .unreachable)
        #expect(FinderLibrary.failure(from: URLError(.notConnectedToInternet)) == .unreachable)
        #expect(FinderLibrary.failure(from: FinderLibrary.Failure.unauthorized) == .unauthorized)
    }

    @Test func knownTypesAndAnUnknownMime() {
        #expect(FinderLibrary.typeIdentifier(mime: "image/png", filename: "a.bin") == "public.png")
        #expect(FinderLibrary.typeIdentifier(mime: "image/heic", filename: "a") == "public.heic")
        #expect(FinderLibrary.typeIdentifier(mime: "image/gif", filename: "a") == "com.compuserve.gif")
        #expect(FinderLibrary.typeIdentifier(mime: nil, filename: "a.WEBP") == "org.webmproject.webp")
        #expect(FinderLibrary.typeIdentifier(mime: "application/octet-stream", filename: "a.bin") == "public.data")
        #expect(FinderLibrary.preferredExtension(mime: "video/quicktime") == "mov")
        #expect(FinderLibrary.thumbnailURL(URL(string: "http://example.com/a.jpg")) == nil)
        #expect(FinderLibrary.Ref(raw: "post:abc") == .post("abc"))
        #expect(FinderLibrary.Ref(raw: "nope") == nil)
    }

    @Test func theBridgeRoundTripsWithoutTheKey() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("finder-bridge-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = FinderBridge.Record(serverURL: "https://api.capybaraharmony.com", enabled: true)
        try FinderBridge.write(record, in: directory)
        let back = try #require(FinderBridge.read(in: directory))
        #expect(back == record)
        #expect(back.url == URL(string: "https://api.capybaraharmony.com"))
        let text = try String(contentsOf: FinderBridge.fileURL(in: directory), encoding: .utf8)
        #expect(!text.contains("api-key"))
    }
}
