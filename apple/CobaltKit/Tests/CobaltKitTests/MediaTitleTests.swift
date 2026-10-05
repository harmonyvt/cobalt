import Foundation
import Testing
@testable import CobaltKit

// CONTRACT-LIBRARY2.md section 9 K: the title resolver and its validator, the wire fields, and the
// `PATCH /library/items/<id>/post` client.

private let titleKey = "7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21"

/// True once `Capabilities.titles` is the stored flag of `Server.swift` (`k1-requests.md`); until then it is
/// the K1 shim, which ignores writes, and the tests that need a server with titles are skipped.
let titlesFlagIsStored: Bool = {
    var caps = Capabilities.unknown
    caps.titles = true
    return caps.titles
}()

/// True once `HTTPCobaltClient.titleCredentials` returns the client's own key and session
/// (`k1-requests.md` 2); until then `setTitle` cannot sign a request and the loopback tests are skipped.
let titleClientIsWired: Bool = {
    HTTPCobaltClient(baseURL: URL(string: "https://wired.example")!, apiKey: { "k" }).titleCredentials.key == "k"
}()

// MARK: - resolve, clean, stripExtension, text

struct MediaTitleTests {
    @Test func aCustomTitleWinsOverALinkSaveAndAFile() {
        #expect(MediaTitle.resolve(custom: "my clip", service: "instagram", ref: "Dd7P496wolG", fileName: "instagram_Dd7P496wolG")
                == .custom("my clip"))
        #expect(MediaTitle.resolve(custom: "  my clip \n", service: "upload", ref: nil, fileName: "IMG_0412.mov") == .custom("my clip"))
        // a blank custom title is no custom title
        #expect(MediaTitle.resolve(custom: "   ", service: "instagram", ref: "Dd7P496wolG", fileName: nil)
                == .post(service: "instagram", ref: "Dd7P496wolG"))
    }

    @Test func uploadIsNotAServiceSoAFileShowsItsNameWithoutTheExtension() {
        #expect(MediaTitle.resolve(custom: nil, service: "upload", ref: nil, fileName: "IMG_0412.mov") == .file("IMG_0412"))
        #expect(MediaTitle.resolve(custom: nil, service: nil, ref: nil, fileName: "crop-gestures.MOV") == .file("crop-gestures"))
        #expect(MediaTitle.resolve(custom: nil, service: "", ref: nil, fileName: "from photos · 4 oct.mp4") == .file("from photos · 4 oct"))
        // an upload that happens to have a ref is still a file
        #expect(MediaTitle.resolve(custom: nil, service: "upload", ref: "x", fileName: "a.png") == .file("a"))
    }

    @Test func aLinkSaveIsServiceDotRef() {
        let r = MediaTitle.resolve(custom: nil, service: "instagram", ref: "Dd7P496wolG", fileName: "instagram_Dd7P496wolG")
        #expect(r == .post(service: "instagram", ref: "Dd7P496wolG"))
        #expect(MediaTitle.text(r) == "instagram · Dd7P496wolG")
        // a service with no ref: the file name when there is one, else the bare service
        #expect(MediaTitle.resolve(custom: nil, service: "x", ref: nil, fileName: "clip.mp4") == .file("clip"))
        #expect(MediaTitle.text(MediaTitle.resolve(custom: nil, service: "x", ref: nil, fileName: nil)) == "x")
    }

    @Test func nothingIsCobalt() {
        #expect(MediaTitle.resolve(custom: nil, service: nil, ref: nil, fileName: nil) == .none)
        #expect(MediaTitle.resolve(custom: nil, service: "upload", ref: nil, fileName: ".mp4") == .file(".mp4"))   // nothing to strip
        #expect(MediaTitle.resolve(custom: nil, service: "upload", ref: nil, fileName: "   ") == .none)
        #expect(MediaTitle.text(.none) == "cobalt")
    }

    @Test func cleanTrimsAndStripsControlCharacters() {
        #expect(MediaTitle.clean("  hello  ") == "hello")
        #expect(MediaTitle.clean("a\nb\u{7}c\u{2028}d\u{2029}e\u{85}f\u{7F}g") == "abcdefg")
        #expect(MediaTitle.clean("\n\t title \r\n") == "title")
        #expect(MediaTitle.clean("   ") == nil)
        #expect(MediaTitle.clean("\u{7}\u{2028}") == nil)
        #expect(MediaTitle.clean("") == nil)
        #expect(MediaTitle.clean("crème brûlée · 4 oct") == "crème brûlée · 4 oct")
    }

    @Test func cleanCutsAtEightyCodePointsNeverSplittingACharacter() {
        let eighty = String(repeating: "a", count: 80)
        #expect(MediaTitle.clean(eighty) == eighty)
        #expect(MediaTitle.clean(eighty + "b")?.unicodeScalars.count == 80)        // 81 -> 80
        #expect(MediaTitle.clean(eighty + "b") == eighty)
        // an emoji sequence straddling the cut is dropped whole: family = 7 scalars, 1 Character
        let family = "👨‍👩‍👧‍👦"
        #expect(family.unicodeScalars.count == 7 && family.count == 1)
        let cut = MediaTitle.clean(String(repeating: "a", count: 76) + family)
        #expect(cut == String(repeating: "a", count: 76))                          // 76 + 7 = 83 > 80: not split
        let fits = MediaTitle.clean(String(repeating: "a", count: 73) + family)
        #expect(fits?.unicodeScalars.count == 80 && fits?.hasSuffix(family) == true)
        // trailing space left by the cut is trimmed
        #expect(MediaTitle.clean(String(repeating: "a", count: 79) + " bcd") == String(repeating: "a", count: 79))
    }

    @Test func stripExtensionStripsOnlyMediaExtensions() {
        #expect(MediaTitle.stripExtension("IMG_0412.mov") == "IMG_0412")
        #expect(MediaTitle.stripExtension("clip.MOV") == "clip")
        #expect(MediaTitle.stripExtension("clip.v2") == "clip.v2")
        #expect(MediaTitle.stripExtension("notes.txt") == "notes.txt")
        #expect(MediaTitle.stripExtension("a.b.webp") == "a.b")
        #expect(MediaTitle.stripExtension("from photos · 4 oct.mp4") == "from photos · 4 oct")
        #expect(MediaTitle.stripExtension("noext") == "noext")
        #expect(MediaTitle.stripExtension(".mp4") == ".mp4")                         // nothing left: keep it
        for ext in ["mp4", "mov", "m4v", "gif", "webp", "png", "jpg", "jpeg", "heic", "JPG", "HeIc"] {
            #expect(MediaTitle.stripExtension("x.\(ext)") == "x")
        }
    }

    @Test func textTruncatesWithAnEllipsisWithinTheLimit() {
        let long = String(repeating: "x", count: 100)
        let sixty = MediaTitle.text(.custom(long), limit: MediaTitle.notifyLength)
        #expect(sixty.unicodeScalars.count == 60 && sixty.hasSuffix("…") && sixty.hasPrefix("xxx"))
        #expect(MediaTitle.text(.custom(long)).unicodeScalars.count == 80)
        #expect(MediaTitle.text(.custom("short"), limit: 60) == "short")
        let exact = String(repeating: "y", count: 60)
        #expect(MediaTitle.text(.file(exact), limit: 60) == exact)
        #expect(MediaTitle.text(.post(service: "instagram", ref: nil)) == "instagram")
        let family = "👨‍👩‍👧‍👦"
        #expect(MediaTitle.text(.custom(String(repeating: "z", count: 55) + family), limit: 60) == String(repeating: "z", count: 55) + "…")
    }
}

// MARK: - decoding

struct TitleDecodingTests {
    private func post(_ extra: String) throws -> LibraryPost {
        let json = #"{"id":"a","service":"instagram","link":"https://www.instagram.com/reel/Dd7P496wolG/","title":"instagram_Dd7P496wolG","created_at":1790000000000,"files":[]\#(extra)}"#
        return try CobaltJSON.decoder().decode(LibraryPost.self, from: Data(json.utf8))
    }

    @Test func aPostWithAndWithoutCustomTitleAndPoster() throws {
        let plain = try post("")
        #expect(plain.customTitle == nil && plain.posterURL == nil)
        let full = try post(#","custom_title":"my clip","poster_url":"https://media.capybaraharmony.com/AbCdEfGhIj.jpg""#)
        #expect(full.customTitle == "my clip")
        #expect(full.posterURL?.absoluteString == "https://media.capybaraharmony.com/AbCdEfGhIj.jpg")
        let nulls = try post(#","custom_title":null,"poster_url":null"#)
        #expect(nulls.customTitle == nil && nulls.posterURL == nil)
        // a wrong type never loses the post
        let odd = try post(#","custom_title":5,"poster_url":7"#)
        #expect(odd.id == "a" && odd.customTitle == nil && odd.posterURL == nil)
    }

    @Test func aFileWithAPosterAndOneWithout() throws {
        func file(_ extra: String) throws -> LibraryFile {
            let json = #"{"id":"f1","kind":"public","source":"host","name":"x.mp4","url":"https://media.example/AbCdEfGhIj.mp4","content_type":"video/mp4","bytes":10,"created_at":1790000000000\#(extra)}"#
            return try CobaltJSON.decoder().decode(LibraryFile.self, from: Data(json.utf8))
        }
        #expect(try file("").posterURL == nil)
        #expect(try file(#","poster_url":"https://media.example/AbCdEfGhIj.jpg""#).posterURL?.absoluteString == "https://media.example/AbCdEfGhIj.jpg")
    }

    @Test func theNewFieldsRoundTrip() throws {
        let p = try post(#","custom_title":"my clip","poster_url":"https://media.example/AbCdEfGhIj.jpg""#)
        let data = try CobaltJSON.encoder().encode(p)
        let back = try CobaltJSON.decoder().decode(LibraryPost.self, from: data)
        #expect(back == p && back.customTitle == "my clip")
    }

    @Test func oldFixturesStillDecode() throws {
        // the page the client tests have always used: no custom_title, no poster_url anywhere
        let json = #"{"status":"success","posts":[{"id":"a","service":"instagram","link":"https://www.instagram.com/reel/Dd7P496wolG/","title":"instagram_Dd7P496wolG","duration":14.77,"width":720,"height":1280,"created_at":1790000000000,"session":{"id":"sid","status":"ready","expires_at":1790600000000,"source_url":"https://api.example/studio/sid/source"},"files":[{"id":"f1","kind":"public","source":"studio","name":"x.webp","url":"https://media.example/AbCdEfGhIj.webp","content_type":"image/webp","bytes":4500000,"width":480,"height":854,"duration":10.1,"created_at":1790000000000,"media_name":"AbCdEfGhIj.webp","deletable":true}]}],"counts":{"posts":2,"files":3},"next":null}"#
        struct Wire: Decodable { var posts: [LibraryPost] }
        let wire = try CobaltJSON.decoder().decode(Wire.self, from: Data(json.utf8))
        #expect(wire.posts.count == 1 && wire.posts[0].files[0].posterURL == nil && wire.posts[0].customTitle == nil)
    }

    @Test func theMergedRenditionCarriesTheServersPoster() throws {
        let poster = try #require(URL(string: "https://media.example/AbCdEfGhIj.jpg"))
        let when = Date(timeIntervalSince1970: 1_790_000_000)
        func file(_ id: String, _ kind: LibraryFile.Kind, _ type: String, poster: URL?) -> LibraryFile {
            LibraryFile(
                id: id, kind: kind, source: .saved, name: id, url: kind == .public ? URL(string: "https://media.example/\(id)") : nil,
                contentType: type, bytes: 1, width: 10, height: 10, duration: 1, createdAt: when, mediaName: nil, deletable: false,
                posterURL: poster)
        }
        let post = LibraryPost(
            id: "p", service: "x", link: nil, title: "t", duration: 1, width: 10, height: 10, createdAt: when, session: nil,
            files: [file("w", .public, "image/webp", poster: nil), file("h", .public, "video/mp4", poster: poster),
                    file("v", .private, "video/mp4", poster: nil)],
            posterURL: poster)
        let item = try #require(MediaItem.merge(local: nil, post: post))
        #expect(item.video?.posterURL == poster)                               // hosted first
        #expect(item.webps.first?.posterURL == nil)                            // the server makes no webp posters
    }

    @Test(.enabled(if: titlesFlagIsStored)) func theTitlesCapabilityComesFromFeaturesTitlesAndIsFalseWhenAbsent() {
        func caps(_ features: String) -> Capabilities? {
            HTTPCobaltClient.parseForkCapabilities(Data(#"{"server":"cobalt-cloudflare","features":{\#(features)}}"#.utf8))
        }
        #expect(caps(#""titles":true"#)?.titles == true)
        #expect(caps(#""titles":false"#)?.titles == false)
        #expect(caps(#""studio":true"#)?.titles == false)
        #expect(Capabilities.unknown.titles == false)
    }
}

// MARK: - the client

@Suite(.serialized)
struct SetTitleClientTests {
    private func client(_ server: LoopbackServer, key: String? = titleKey) -> HTTPCobaltClient {
        HTTPCobaltClient(baseURL: server.base, apiKey: { key })
    }

    private func body(_ request: LoopbackServer.Request) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    }

    @Test(.enabled(if: titleClientIsWired)) func twoHundredSetsTheTitleAndTheCallIsAKeyedPatch() async throws {
        let server = try await LoopbackServer.start { _ in .json(#"{"status":"success","post":"Dd7P496wolG","title":"my clip"}"#) }
        defer { server.stop() }
        let result = try await client(server).setTitle(anchor: "AbCdEfGhIjKlMnOp", "my clip")
        #expect(result == PostTitleResult(post: "Dd7P496wolG", title: "my clip"))
        let sent = try #require(server.requests.first)
        #expect(sent.method == "PATCH" && sent.path == "/library/items/AbCdEfGhIjKlMnOp/post")
        #expect(sent.headers["authorization"] == "Api-Key \(titleKey)" && sent.headers["accept"] == "application/json")
        #expect(sent.headers["content-type"] == "application/json")
        #expect(try body(sent)["title"] as? String == "my clip")
    }

    @Test(.enabled(if: titleClientIsWired)) func twoHundredClearsWithANullTitle() async throws {
        let server = try await LoopbackServer.start { _ in .json(#"{"status":"success","post":"Dd7P496wolG","title":null}"#) }
        defer { server.stop() }
        let result = try await client(server).setTitle(anchor: "AbCdEfGhIjKlMnOp", nil)
        #expect(result == PostTitleResult(post: "Dd7P496wolG", title: nil))
        let sent = try #require(server.requests.first)
        #expect(String(decoding: sent.body, as: UTF8.self) == #"{"title":null}"#)
    }

    @Test(.enabled(if: titleClientIsWired)) func aBadTitleIsAServerFailureWithItsCode() async throws {
        let server = try await LoopbackServer.start { _ in .json(#"{"status":"error","error":{"code":"error.library.bad_title"}}"#, status: 400) }
        defer { server.stop() }
        await #expect(throws: PipelineFailure.server(code: "error.library.bad_title")) {
            try await client(server).setTitle(anchor: "AbCdEfGhIjKlMnOp", "x")
        }
    }

    @Test(.enabled(if: titleClientIsWired)) func notFoundIsAServerFailureWithTheNotFoundCode() async throws {
        let server = try await LoopbackServer.start { _ in .json(#"{"status":"error","error":{"code":"error.library.not_found"}}"#, status: 404) }
        defer { server.stop() }
        await #expect(throws: PipelineFailure.server(code: "error.library.not_found")) {
            try await client(server).setTitle(anchor: "AbCdEfGhIjKlMnOp", "x")
        }
        // a 404 with no body is the same answer
        let bare = try await LoopbackServer.start { _ in LoopbackServer.Response(status: 404) }
        defer { bare.stop() }
        await #expect(throws: PipelineFailure.server(code: "error.library.not_found")) {
            try await client(bare).setTitle(anchor: "AbCdEfGhIjKlMnOp", nil)
        }
    }

    @Test(.enabled(if: titleClientIsWired)) func aRevokedKeyIsKeyInvalidAndAMissingKeyNeverLeavesTheDevice() async throws {
        let server = try await LoopbackServer.start { _ in .json(#"{"status":"error","error":{"code":"error.api.auth.key.invalid"}}"#, status: 401) }
        defer { server.stop() }
        let error = await #expect(throws: CobaltError.api(code: "error.api.auth.key.invalid", httpStatus: 401)) {
            try await client(server).setTitle(anchor: "AbCdEfGhIjKlMnOp", "x")
        }
        #expect(error.flatMap { pipelineFailure(from: $0, during: .saving) } == .keyInvalid)

        let quiet = try await LoopbackServer.start { _ in .json("{}") }
        defer { quiet.stop() }
        await #expect(throws: CobaltError.noAPIKey) { try await client(quiet, key: nil).setTitle(anchor: "AbCdEfGhIjKlMnOp", "x") }
        #expect(quiet.requests.isEmpty)
    }

    @Test(.enabled(if: titleClientIsWired)) func otherAnswersAreOrdinaryServerErrors() async throws {
        let down = try await LoopbackServer.start { _ in .json(#"{"status":"error","error":{"code":"error.api.generic"}}"#, status: 503) }
        defer { down.stop() }
        await #expect(throws: CobaltError.api(code: "error.api.generic", httpStatus: 503)) {
            try await client(down).setTitle(anchor: "AbCdEfGhIjKlMnOp", "x")
        }
        let odd = try await LoopbackServer.start { _ in .json("not json", status: 200) }
        defer { odd.stop() }
        await #expect(throws: CobaltError.invalidResponse(httpStatus: 200)) {
            try await client(odd).setTitle(anchor: "AbCdEfGhIjKlMnOp", "x")
        }
    }

    @Test func aClientThatPredatesTheRouteSaysItIsUnsupported() async {
        struct Old: CobaltClient {
            let base: any CobaltClient
            var baseURL: URL { base.baseURL }
            func capabilities() async -> Capabilities { await base.capabilities() }
            func resolve(_ link: URL) async throws -> CobaltResult { try await base.resolve(link) }
            func createStudio(link: URL) async throws -> StudioCreated { try await base.createStudio(link: link) }
            func upload(file: URL, name: String, contentType: String, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> UploadResult {
                try await base.upload(file: file, name: name, contentType: contentType, progress: progress)
            }
            func session(_ id: String, wait: Int) async throws -> StudioSession { try await base.session(id, wait: wait) }
            func sourceURL(session id: String) -> URL { base.sourceURL(session: id) }
            func render(session id: String, _ request: RenderRequest) async throws -> String { try await base.render(session: id, request) }
            func renderStatus(session id: String, job: String, wait: Int) async throws -> RenderStatus { try await base.renderStatus(session: id, job: job, wait: wait) }
            func publish(session id: String) async throws -> HostedFile { try await base.publish(session: id) }
            func publish(item id: String) async throws -> HostedFile { try await base.publish(item: id) }
            func openStudio(item id: String) async throws -> StudioCreated { try await base.openStudio(item: id) }
            func library(cursor: String?, limit: Int) async throws -> LibraryPage { try await base.library(cursor: cursor, limit: limit) }
            func deleteMedia(name: String) async throws { try await base.deleteMedia(name: name) }
            func registerLiveStartToken(_ token: String, environment: LiveEnvironment) async throws {}
            func registerLiveRun(_ r: LiveRunRegistration) async throws -> LiveRunReply { LiveRunReply(pushing: false, started: false) }
            func relayLiveState(run: UUID, _ state: LiveContentState) async throws {}
            func endLiveRun(_ run: UUID) async throws {}
            func liveSelftest() async throws -> LiveSelftest { LiveSelftest(configured: false) }
            func download(_ file: RemoteFile, to destination: URL, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> URL {
                try await base.download(file, to: destination, progress: progress)
            }
        }
        await #expect(throws: PipelineFailure.unsupported) { try await Old(base: PreviewClient()).setTitle(anchor: "x", "y") }
    }

    @Test func thePreviewClientAnswersFromItsOwnLibraryAndRemembersTheTitle() async throws {
        let client = PreviewClient(scenario: .renditions, timeScale: 1, clock: SystemClock())
        let set = try await client.setTitle(anchor: "PrEvIeWitem000008", "  a   title \n")
        #expect(set == PostTitleResult(post: "Dd5JFkMDt4N", title: "a   title"))
        let page = try await client.library(cursor: nil, limit: 20)
        #expect(page.posts.first { $0.id == "Dd5JFkMDt4N" }?.customTitle == "a   title")
        #expect(page.posts.first { $0.id == "Dd7P496wolG" }?.customTitle == nil)
        let cleared = try await client.setTitle(anchor: "PrEvIeWitem000009", nil)
        #expect(cleared.title == nil)
        #expect(try await client.library(cursor: nil, limit: 20).posts.first { $0.id == "Dd5JFkMDt4N" }?.customTitle == nil)
        await #expect(throws: PipelineFailure.server(code: "error.library.not_found")) {
            try await client.setTitle(anchor: "nope", "x")
        }
    }
}
