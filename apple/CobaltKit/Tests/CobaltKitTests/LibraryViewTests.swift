import Foundation
import Testing
@testable import CobaltKit

// CONTRACT-LIBRARY2.md section 9 K: `LibraryRow`, sort, show, search, `needsWholeLibrary`, `loadAll`, `locate`
// and the remembered view state.

private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
private let viewKey = "7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21"

// MARK: - synthetic posts

private func file(
    _ id: String, _ kind: LibraryFile.Kind, bytes: Int64, w: Int = 100, h: Int = 100, d: Double = 1, at: Date,
    type: String = "video/mp4", name: String? = nil
) -> LibraryFile {
    let isWebp = type == "image/webp"
    return LibraryFile(
        id: id, kind: kind, source: isWebp ? .studio : .saved, name: name ?? id,
        url: kind == .public ? URL(string: "https://media.capybaraharmony.com/\(id).\(isWebp ? "webp" : "mp4")") : nil,
        contentType: type, bytes: bytes, width: w, height: h, duration: d, createdAt: at,
        mediaName: kind == .public ? "\(id).\(isWebp ? "webp" : "mp4")" : nil, deletable: isWebp)
}

/// A link post (`ref` -> an instagram reel) with an original of `privateBytes` and `webps` public webps of 10
/// bytes each: size = `privateBytes + 10 × webps`. The original is private unless `publicVideo` (CONTRACT-VISIBILITY
/// decision 13: a row's badge is the video's switch, not whether some webp is public).
private func post(
    _ id: String, service: String? = "instagram", ref: String? = nil, custom: String? = nil, title: String? = nil,
    dur: Double = 1, w: Int = 100, h: Int = 100, at: Date = t0, privateBytes: Int64 = 100, webps: Int = 0,
    publicVideo: Bool = false
) -> LibraryPost {
    var original = file("\(id)-src", .private, bytes: privateBytes, w: w, h: h, d: dur, at: at, name: "\(id)-src")
    if publicVideo {
        original.wireVisibility = .public
        original.url = URL(string: "https://media.capybaraharmony.com/\(id)-src.mp4")
    }
    var files = [original]
    for n in 0..<webps {
        files.append(file("\(id)-w\(n)", .public, bytes: 10, w: 480, h: 480, d: 1, at: at, type: "image/webp"))
    }
    let link = ref.flatMap { URL(string: "https://www.instagram.com/reel/\($0)/") }
    return LibraryPost(
        id: id, service: service, link: link, title: title, duration: dur, width: w, height: h, createdAt: at,
        session: nil, files: files, customTitle: custom)
}

/// Four posts with a distinct value on every sort key (see the tables in each test).
private func four() -> [LibraryPost] {
    [
        post("a", custom: "Banana", dur: 10, w: 300, h: 100, at: t0.addingTimeInterval(100), privateBytes: 390, webps: 1, publicVideo: true),
        post("b", custom: "apple", dur: 40, w: 100, h: 100, at: t0.addingTimeInterval(300), privateBytes: 100, webps: 0),
        post("c", custom: "Cherry", dur: 20, w: 400, h: 100, at: t0.addingTimeInterval(200), privateBytes: 270, webps: 3, publicVideo: true),
        post("d", custom: "date", dur: 30, w: 200, h: 100, at: t0.addingTimeInterval(400), privateBytes: 180, webps: 2, publicVideo: true),
    ]
}

@MainActor
private func emptyApp(posts: [LibraryPost]) -> AppModel {
    let app = AppModel.makePreview(.emptyOrbit, timeScale: 1, clock: SystemClock())
    app.library.posts = posts
    return app
}

@MainActor
private func ids(_ app: AppModel) -> [String] { app.libraryRows.map(\.id) }

// MARK: - rows

@MainActor
struct LibraryRowTests {
    @Test func theRenditionsFixtureBecomesRows() throws {
        let app = AppModel.makePreview(.renditions, timeScale: 1, clock: SystemClock())
        app.library.sort = .newest
        let rows = app.libraryRows
        #expect(rows.count == app.library.posts.count && rows.count == 6)
        let dd7p = try #require(rows.first { $0.id == "Dd7P496wolG" })
        #expect(dd7p.title == "instagram · Dd7P496wolG" && dd7p.service == "instagram" && !dd7p.isUpload)
        #expect(dd7p.bytes == 4_500_000 + 4_331_778 + 2_371_210 + 1_600_000)          // all of the post's files
        #expect(dd7p.webps == 3 && dd7p.fileCount == 4 && dd7p.hasVideo && !dd7p.originalIsImage)
        // its video is private (its webps are public): the badge is the video's switch (CONTRACT-VISIBILITY 13)
        #expect(!dd7p.isPublic && dd7p.visibilityRank == 0)
        let hosted = try #require(rows.first { $0.id == "Dd55fEyN1Yy" })                 // the video has its hosted link
        #expect(hosted.isPublic && hosted.visibilityRank == 1)
        #expect(dd7p.length == 14.77 && dd7p.width == 720 && dd7p.height == 1280 && dd7p.pixels == 720 * 1280)
        #expect(dd7p.faceAspect == 600.0 / 480.0)                                      // the newest webp, 480×600
        #expect(dd7p.id == dd7p.item.post?.id && dd7p.item.local != nil)               // joined with the device's media

        let tiny = try #require(rows.first { $0.id == "2105432512428445875" })
        #expect(!tiny.isPublic && tiny.visibilityRank == 0 && tiny.webps == 0 && tiny.fileCount == 1)
        #expect(tiny.bytes == 1_000_000 && tiny.title == "x · 2105432512428445875")

        let custom = try #require(rows.first { $0.id == "2105435404002562056" })
        #expect(custom.title == "kitchen timer loop" && custom.service == "x")        // custom_title wins, the service stays
    }

    @Test func anUploadIsAFileWithItsNameOrItsCustomTitle() throws {
        let app = AppModel.makePreview(.renditions, timeScale: 1, clock: SystemClock())
        app.library.posts += PreviewData.uploadPosts(now: SystemClock().now())
        let up = try #require(app.libraryRows.first { $0.id == "PrEvIeWupost0001" })
        #expect(up.isUpload && up.service == "file" && up.title == "crop editor, pinch and drag")
        #expect(up.bytes == 8_979_061 * 2 && up.isPublic && up.fileCount == 1 && up.hasVideo)
        #expect(up.width == 1206 && up.height == 2622 && up.faceAspect == 2622.0 / 1206.0)
        let photos = try #require(app.libraryRows.first { $0.id == "PrEvIeWupost0002" })
        #expect(photos.isUpload && photos.title == "from photos · 4 oct")               // "upload" is no service; extension stripped
    }

    @Test func anImageUploadIsMarkedAndAnUnknownFaceIsSixteenByNine() throws {
        let when = t0
        let png = LibraryPost(
            id: "img", service: "upload", link: nil, title: "shot.png", duration: nil, width: 1170, height: 2532,
            createdAt: when, session: nil,
            files: [file("img-src", .private, bytes: 500, w: 1170, h: 2532, d: 0, at: when, type: "image/png", name: "shot.png")])
        let bare = LibraryPost(id: "bare", service: nil, link: nil, title: nil, duration: nil, width: nil, height: nil,
                               createdAt: when, session: nil, files: [])
        let app = emptyApp(posts: [png, bare])
        let rows = Dictionary(uniqueKeysWithValues: app.libraryRows.map { ($0.id, $0) })
        let image = try #require(rows["img"])
        #expect(image.originalIsImage && image.hasVideo && image.length == -1 && image.title == "shot")
        let unknown = try #require(rows["bare"])
        #expect(unknown.faceAspect == 9.0 / 16.0 && unknown.length == -1 && unknown.pixels == 0 && unknown.title == "cobalt")
        #expect(unknown.service == "file" && unknown.bytes == 0 && !unknown.isPublic)
    }

    @Test func everySortKeyOrdersBothWays() {
        let app = emptyApp(posts: four())
        let expected: [(LibrarySortKey, [String])] = [
            (.date, ["a", "c", "b", "d"]),             // 100, 200, 300, 400
            (.title, ["b", "a", "c", "d"]),            // apple, Banana, Cherry, date: case-insensitive
            (.length, ["a", "c", "d", "b"]),           // 10, 20, 30, 40
            (.size, ["b", "d", "c", "a"]),             // 100, 200, 300, 400
            (.resolution, ["b", "d", "a", "c"]),       // 10000, 20000, 30000, 40000
            (.files, ["b", "a", "d", "c"]),            // 1, 2, 3, 4 renditions
            (.visibility, ["b", "d", "c", "a"]),       // private first; the public three newest first
        ]
        for (key, ascending) in expected {
            app.library.sort = LibrarySort(key: key, ascending: true)
            #expect(ids(app) == ascending, "\(key) ascending")
            app.library.sort = LibrarySort(key: key, ascending: false)
            let descending = key == .visibility ? ["d", "c", "a", "b"] : ascending.reversed()
            #expect(ids(app) == Array(descending), "\(key) descending")
        }
    }

    @Test func theKindKeyGroupsGalleriesPhotosVideosWebpsNewestFirstInEachGroup() {
        func ofKind(_ id: String, _ kind: MediaKind, _ age: TimeInterval) -> LibraryPost {
            var p = post(id, at: t0.addingTimeInterval(age))
            p.kind = kind
            return p
        }
        let app = emptyApp(posts: [
            ofKind("v-old", .video, 10), ofKind("w", .webp, 20), ofKind("g-old", .gallery, 30), ofKind("p", .photo, 40),
            ofKind("v-new", .video, 50), ofKind("g-new", .gallery, 60),
        ])
        app.library.sort = LibrarySort(key: .kind, ascending: true)
        #expect(ids(app) == ["g-new", "g-old", "p", "v-new", "v-old", "w"])
        app.library.sort = LibrarySort(key: .kind, ascending: false)
        #expect(ids(app) == ["w", "v-new", "v-old", "p", "g-new", "g-old"])
        #expect(LibrarySort(stored: "kind.asc") == LibrarySort(key: .kind, ascending: true))
    }

    @Test func tiesBreakByDateNewestFirstThenIdWhicheverWayTheKeyRuns() {
        let same = [
            post("x1", custom: "t", at: t0.addingTimeInterval(1), privateBytes: 100),
            post("x3", custom: "t", at: t0.addingTimeInterval(2), privateBytes: 100),
            post("x2", custom: "t", at: t0.addingTimeInterval(2), privateBytes: 100),
        ]
        let app = emptyApp(posts: same)
        for key in LibrarySortKey.allCases where key != .date {
            for ascending in [true, false] {
                app.library.sort = LibrarySort(key: key, ascending: ascending)
                #expect(ids(app) == ["x2", "x3", "x1"], "\(key) \(ascending)")
            }
        }
        app.library.sort = LibrarySort(key: .date, ascending: false)
        #expect(ids(app) == ["x2", "x3", "x1"])
        app.library.sort = LibrarySort(key: .date, ascending: true)
        #expect(ids(app) == ["x1", "x2", "x3"])
    }

    @Test func showFiltersByVisibilityAndUploads() {
        let up = LibraryPost(
            id: "u", service: "upload", link: nil, title: "IMG_0412.mov", duration: 2, width: 100, height: 100, createdAt: t0,
            session: nil, files: [file("u-src", .private, bytes: 50, at: t0, name: "IMG_0412.mov")])
        let app = emptyApp(posts: four() + [up])
        app.library.sort = LibrarySort(key: .title, ascending: true)
        app.library.show = .everything
        #expect(ids(app) == ["b", "a", "c", "d", "u"])
        app.library.show = .publicOnly
        #expect(ids(app) == ["a", "c", "d"])
        app.library.show = .privateOnly
        #expect(ids(app) == ["b", "u"])
        app.library.show = .uploads
        #expect(ids(app) == ["u"])
    }

    @Test func aPrivateVideoWithPublicWebpsIsPrivate() {
        let app = emptyApp(posts: [post("p", webps: 2), post("q", webps: 2, publicVideo: true)])
        app.library.show = .publicOnly
        #expect(ids(app) == ["q"])
        app.library.show = .privateOnly
        #expect(ids(app) == ["p"])
    }

    @Test func searchFoldsCaseAndDiacriticsAndMatchesRefServiceAndFileNames() {
        let up = LibraryPost(
            id: "u", service: "upload", link: nil, title: "IMG_0412.mov", duration: 2, width: 100, height: 100, createdAt: t0,
            session: nil, files: [file("u-src", .private, bytes: 50, at: t0, name: "IMG_0412.mov")])
        let ref = post("e", ref: "Dd7P496wolG", custom: "Crème brûlée", title: "instagram_Dd7P496wolG")
        let app = emptyApp(posts: four() + [up, ref])
        app.library.sort = LibrarySort(key: .title, ascending: true)

        app.library.query = "creme brulee"
        #expect(ids(app) == ["e"])
        app.library.query = "  CRÈME  "
        #expect(ids(app) == ["e"])
        app.library.query = "dd7p496"                      // the ref, though the title is custom
        #expect(ids(app) == ["e"])
        app.library.query = "img_0412"                     // a file name
        #expect(ids(app) == ["u"])
        app.library.query = "FILE"                         // the service cell of an upload
        #expect(ids(app) == ["u"])
        app.library.query = "banana"                       // a custom title
        #expect(ids(app) == ["a"])
        app.library.query = "instagram"                    // the service
        #expect(Set(ids(app)) == ["a", "b", "c", "d", "e"])
        app.library.query = "zzz"
        #expect(ids(app).isEmpty)
        app.library.query = "   "                          // blank is no search
        #expect(ids(app).count == 6)
        app.library.query = "a-src"                        // a post's file name
        #expect(ids(app) == ["a"])
    }

    @Test func needsWholeLibraryFollowsQueryShowAndSort() {
        let app = emptyApp(posts: [])
        let lib = app.library
        #expect(!lib.needsWholeLibrary)
        lib.query = "  "
        #expect(!lib.needsWholeLibrary)
        lib.query = "x"
        #expect(lib.needsWholeLibrary)
        lib.query = ""
        for show in LibraryShow.allCases where show != .everything {
            lib.show = show
            #expect(lib.needsWholeLibrary)
        }
        lib.show = .everything
        #expect(!lib.needsWholeLibrary)
        lib.sort = LibrarySort(key: .date, ascending: true)          // oldest first is not the server's order
        #expect(lib.needsWholeLibrary)
        lib.sort = LibrarySort(key: .title, ascending: false)
        #expect(lib.needsWholeLibrary)
        lib.sort = .newest
        #expect(!lib.needsWholeLibrary)
    }
}

// MARK: - remembered view state

@MainActor
struct LibraryPrefsTests {
    private func suite() -> UserDefaults {
        let name = "cobalt.library.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name) ?? .standard
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func prefsRoundTripThroughAnInjectedUserDefaults() {
        let defaults = suite()
        let ctx = AppModel.makePreview(.emptyOrbit, timeScale: 1, clock: SystemClock()).ctxForTests
        let first = LibraryModel(context: ctx, defaults: defaults)
        #expect(first.viewMode == .mosaic && first.sort == .newest && first.show == .everything && first.query.isEmpty)
        first.viewMode = .table
        first.sort = LibrarySort(key: .size, ascending: true)
        first.show = .uploads
        first.query = "not remembered"
        #expect(defaults.string(forKey: "library.view") == "table")
        #expect(defaults.string(forKey: "library.sort") == "size.asc")
        #expect(defaults.string(forKey: "library.show") == "uploads")

        let second = LibraryModel(context: ctx, defaults: defaults)
        #expect(second.viewMode == .table && second.sort == LibrarySort(key: .size, ascending: true) && second.show == .uploads)
        #expect(second.query.isEmpty)

        second.sort = .newest
        #expect(defaults.string(forKey: "library.sort") == "date.desc")
        #expect(LibraryModel(context: ctx, defaults: defaults).sort == .newest)
    }

    @Test func aBrokenValueFallsBackToTheDefault() {
        let defaults = suite()
        defaults.set("kaleidoscope", forKey: "library.view")
        defaults.set("size.sideways", forKey: "library.sort")
        defaults.set("nobody", forKey: "library.show")
        let ctx = AppModel.makePreview(.emptyOrbit, timeScale: 1, clock: SystemClock()).ctxForTests
        let lib = LibraryModel(context: ctx, defaults: defaults)
        #expect(lib.viewMode == .mosaic && lib.sort == .newest && lib.show == .everything)
    }

    @Test func everySortKeyHasAStoredForm() {
        for key in LibrarySortKey.allCases {
            for ascending in [true, false] {
                let sort = LibrarySort(key: key, ascending: ascending)
                #expect(LibrarySort(stored: sort.stored) == sort)
            }
        }
    }

    @Test func previewModelsDoNotShareTheirViewState() {
        let a = AppModel.makePreview(.emptyOrbit, timeScale: 1, clock: SystemClock())
        a.library.viewMode = .table
        #expect(AppModel.makePreview(.emptyOrbit, timeScale: 1, clock: SystemClock()).library.viewMode == .mosaic)
    }
}

// MARK: - paging: loadAll and locate

@MainActor
@Suite(.serialized)
struct LibraryPagingTests {
    private func server(total: Int) async throws -> LoopbackServer {
        try await LoopbackServer.start { req in
            guard req.path == "/library" else { return .init(status: 404) }
            var query: [String: String] = [:]
            for pair in req.query.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 { query[kv[0]] = kv[1] }
            }
            let limit = Int(query["limit"] ?? "20") ?? 20
            let offset = Int(query["cursor"] ?? "0") ?? 0
            let end = min(total, offset + limit)
            let posts = (offset..<max(offset, end)).map { i in
                #"{"id":"p\#(i)","created_at":\#(1_790_000_000_000 - i * 1000),"files":[]}"#
            }.joined(separator: ",")
            let next = end < total ? "\"\(end)\"" : "null"
            return .json(#"{"status":"success","posts":[\#(posts)],"counts":{"posts":\#(total),"files":0},"usage":{"public_bytes":0,"private_bytes":0},"next":\#(next)}"#)
        }
    }

    private func app(on server: LoopbackServer) -> AppModel {
        let app = AppModel.makePreview(.emptyOrbit, timeScale: 1, clock: SystemClock())
        app.ctxForTests.client = HTTPCobaltClient(baseURL: server.base, apiKey: { viewKey })
        app.library.reset()                                   // the preview seed is not on this server
        return app
    }

    @Test func loadAllStopsWhenTheServerHasNoMore() async throws {
        let server = try await server(total: 120)
        defer { server.stop() }
        let app = app(on: server)
        await app.library.loadAll()
        #expect(server.requests.map(\.query) == ["limit=50", "limit=50&cursor=50", "limit=50&cursor=100"])
        #expect(app.library.posts.count == 120 && !app.library.hasMore && app.library.postCount == 120)
        #expect(app.library.loadingAll == nil && !app.library.isLoading && app.library.failure == nil)
        await app.library.loadAll()                           // everything is in: nothing more is asked
        #expect(server.requests.count == 3)
    }

    @Test func loadAllStopsAtTheCapExactly() async throws {
        let server = try await server(total: 400)
        defer { server.stop() }
        let app = app(on: server)
        await app.library.loadAll(cap: 120)
        #expect(server.requests.map(\.query) == ["limit=50", "limit=50&cursor=50", "limit=20&cursor=100"])
        #expect(app.library.posts.count == 120 && app.library.hasMore && app.library.postCount == 400)
        #expect(app.library.posts.map(\.id).prefix(3) == ["p0", "p1", "p2"])
    }

    @Test func loadAllContinuesFromTheFirstPage() async throws {
        let server = try await server(total: 120)
        defer { server.stop() }
        let app = app(on: server)
        await app.library.refresh()
        #expect(app.library.posts.count == 20 && app.library.hasMore)
        await app.library.loadAll()
        #expect(server.requests.map(\.query) == ["limit=20", "limit=50&cursor=20", "limit=50&cursor=70"])
        #expect(app.library.posts.count == 120 && Set(app.library.posts.map(\.id)).count == 120)
    }

    @Test func locateLoadsPagesUntilThePostIsThere() async throws {
        let server = try await server(total: 120)
        defer { server.stop() }
        let app = app(on: server)
        #expect(await app.library.locate(postID: "p75"))
        #expect(server.requests.map(\.query) == ["limit=50", "limit=50&cursor=50"])      // found on page two: no third
        #expect(app.library.posts.count == 100 && app.library.hasMore)
        #expect(await app.library.locate(postID: "p3"))                                  // already loaded
        #expect(server.requests.count == 2)
    }

    @Test func locateGivesUpWhenTheServerHasNoSuchPost() async throws {
        let server = try await server(total: 120)
        defer { server.stop() }
        let app = app(on: server)
        #expect(await app.library.locate(postID: "nope") == false)
        #expect(app.library.posts.count == 120 && !app.library.hasMore)
        #expect(await app.library.locate(postID: "nope") == false)
        #expect(server.requests.count == 3)                                              // nothing left to ask
    }

    @Test func locateStopsAtThousandPosts() async throws {
        let server = try await server(total: 1_300)
        defer { server.stop() }
        let app = app(on: server)
        #expect(await app.library.locate(postID: "p1200") == false)
        #expect(app.library.posts.count == 1_000 && app.library.hasMore)
        #expect(server.requests.count == 20)
    }

    @Test func aFailedPageStopsTheLoopAndLeavesAFailure() async throws {
        let calls = Counter()
        let flaky = try await LoopbackServer.start { req in
            if calls.next() == 2 { return .json(#"{"status":"error","error":{"code":"error.api.generic"}}"#, status: 503) }
            let end = req.query.contains("cursor=50") ? 100 : 50
            let first = end - 50
            let posts = (first..<end).map { #"{"id":"p\#($0)","created_at":1790000000000,"files":[]}"# }.joined(separator: ",")
            return .json(#"{"status":"success","posts":[\#(posts)],"counts":{"posts":500,"files":0},"next":"\#(end)"}"#)
        }
        defer { flaky.stop() }
        let app = app(on: flaky)
        await app.library.loadAll()
        #expect(app.library.posts.count == 50 && app.library.failure != nil && app.library.loadingAll == nil && !app.library.isLoading)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}

extension AppModel {
    /// The package-internal context, for tests that point the client at a loopback server.
    var ctxForTests: PipelineContext { ctx }
}
