import Foundation
import Testing
@testable import CobaltKit

// MARK: - Link extraction (the worker's cases)

struct LinkTests {
    @Test func firstLinkMatchesTheWorkersRule() {
        #expect(LinkInfo.firstLink(in: "\nhttps://x.com/maria_rcks/status/2105237035271258436?s=20")?.absoluteString
            == "https://x.com/maria_rcks/status/2105237035271258436?s=20")
        #expect(LinkInfo.firstLink(in: "look (https://vimeo.com/288386543). ok")?.absoluteString == "https://vimeo.com/288386543")
        #expect(LinkInfo.firstLink(in: "no link here") == nil)
        #expect(LinkInfo.firstLink(in: "") == nil)
        #expect(LinkInfo.firstLink(in: "wow! HTTPS://Example.com/Path, then more")?.absoluteString == "HTTPS://Example.com/Path")
        #expect(LinkInfo.firstLink(in: "<https://a.com/x> and https://b.com/y")?.absoluteString == "https://a.com/x")
        #expect(LinkInfo.firstLink(in: "\"https://a.com/x\"")?.absoluteString == "https://a.com/x")
        #expect(LinkInfo.firstLink(in: "ftp://example.com/x") == nil)
    }

    @Test func serviceAndRef() throws {
        let ig = try #require(LinkInfo(URL(string: "https://www.instagram.com/reel/Dd7P496wolG/")!))
        #expect(ig.service == "instagram" && ig.ref == "Dd7P496wolG")
        let tw = try #require(LinkInfo(URL(string: "https://twitter.com/i/status/2105435404002562056")!))
        #expect(tw.service == "x" && tw.ref == "2105435404002562056")
        let x = try #require(LinkInfo(URL(string: "https://x.com/i/status/2105435404002562056")!))
        #expect(x.service == "x")
        let bare = try #require(LinkInfo(URL(string: "https://vimeo.com")!))
        #expect(bare.service == "vimeo" && bare.ref == "vimeo.com")
        #expect(LinkInfo(URL(string: "mailto:a@b.c")!) == nil)
        #expect(LinkInfo(URL(string: "file:///tmp/a.mp4")!) == nil)
    }
}

// MARK: - Format

struct FormatTests {
    @Test func bytes() {
        #expect(Format.bytes(4_331_778) == "4.3 MB")
        #expect(Format.bytes(4_500_000) == "4.5 MB")
        #expect(Format.bytes(1_000_000) == "1.0 MB")
        #expect(Format.bytes(841_000) == "841 KB")
        #expect(Format.bytes(256_000) == "256 KB")
        #expect(Format.bytes(0) == "1 KB")
        #expect(Format.bytes(400) == "1 KB")
        #expect(Format.bytes(54_000_000) == "54.0 MB")
    }

    @Test func secondsTimecodeSize() {
        #expect(Format.seconds(10) == "10.0 s")
        #expect(Format.seconds(14.77) == "14.8 s")
        #expect(Format.timecode(4.1) == "00:04.1")
        #expect(Format.timecode(0) == "00:00.0")
        #expect(Format.timecode(14.77) == "00:14.8")
        #expect(Format.timecode(75.25) == "01:15.2" || Format.timecode(75.25) == "01:15.3")
        #expect(Format.size(720, 1280) == "720×1280")
    }

    @Test func when() throws {
        let cal = Calendar.current
        func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) throws -> Date {
            try #require(cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min)))
        }
        let now = try date(2026, 10, 2, 15, 0)
        #expect(Format.when(try date(2026, 10, 2, 12, 46), now: now) == "today 12:46")
        #expect(Format.when(try date(2026, 10, 1, 13, 59), now: now) == "yesterday 13:59")
        #expect(Format.when(try date(2026, 10, 1, 9, 31), now: now) == "yesterday 09:31")
        #expect(Format.when(try date(2026, 10, 3, 9, 31), now: try date(2026, 10, 6, 8, 0)) == "3 oct 09:31")
        #expect(Format.when(try date(2026, 1, 9, 0, 5), now: now) == "9 jan 00:05")
    }
}

// MARK: - Error code map (section 4.5)

struct ErrorMapTests {
    @Test func codeMap() {
        func map(_ code: String, _ phase: ErrorPhase = .saving) -> PipelineFailure { mapFailure(code: code, during: phase) }
        #expect(map("error.api.fetch.fail") == .fetchFailed(code: "error.api.fetch.fail"))
        #expect(map("error.api.fetch.empty") == .fetchFailed(code: "error.api.fetch.empty"))
        #expect(map("error.api.content.video.private") == .fetchFailed(code: "error.api.content.video.private"))
        #expect(map("error.api.link.invalid") == .linkUnreadable(code: "error.api.link.invalid"))
        #expect(map("error.api.link.unsupported") == .linkUnreadable(code: "error.api.link.unsupported"))
        #expect(map("error.webp.no_video") == .fetchFailed(code: "error.webp.no_video"))
        #expect(map("error.webp.bad_source") == .fetchFailed(code: "error.webp.bad_source"))
        #expect(map("error.webp.download_failed") == .fetchFailed(code: "error.webp.download_failed"))
        #expect(map("error.api.auth.key.missing") == .keyMissing)
        #expect(map("error.api.auth.key.invalid") == .keyInvalid)
        #expect(map("error.api.auth.key.not_api_key") == .keyInvalid)
        #expect(map("error.api.auth.key.not_found") == .keyInvalid)
        #expect(map("error.studio.busy") == .serverBusy)
        #expect(map("error.webp.busy") == .renderBusy)
        #expect(map("error.webp.job_lost", .rendering) == .renderLost)
        #expect(map("error.studio.save_lost", .rendering) == .renderLost)
        #expect(map("error.studio.save_lost", .saving) == .server(code: "error.studio.save_lost"))
        #expect(map("error.studio.expired") == .expired)
        #expect(map("error.library.too_large") == .tooLarge(limit: 100_000_000))
        #expect(map("error.studio.too_large") == .tooLarge(limit: 209_715_200))
        #expect(map("error.webp.too_large") == .tooLarge(limit: 209_715_200))
        #expect(map("error.webp.unsupported") == .unsupported)
        #expect(map("error.library.unsupported") == .unsupported)
        #expect(map("error.studio.not_video") == .unsupported)
        #expect(map("error.something.new") == .server(code: "error.something.new"))
    }

    @Test func thrownErrors() {
        #expect(pipelineFailure(from: URLError(.notConnectedToInternet), during: .saving) == .unreachable)
        #expect(pipelineFailure(from: CobaltError.network(.timedOut), during: .saving) == .unreachable)
        #expect(pipelineFailure(from: CobaltError.network(.cancelled), during: .saving) == nil)
        #expect(pipelineFailure(from: CancellationError(), during: .saving) == nil)
        #expect(pipelineFailure(from: CobaltError.noAPIKey, during: .saving) == .keyMissing)
        #expect(pipelineFailure(from: CobaltError.invalidResponse(httpStatus: 502), during: .saving) == .server(code: "http.502"))
        #expect(pipelineFailure(from: CobaltError.api(code: "error.webp.busy", httpStatus: 429), during: .rendering) == .renderBusy)
        #expect(pipelineFailure(from: CobaltError.tooLarge(limit: 5), during: .saving) == .tooLarge(limit: 5))
        #expect(!PipelineFailure.server(code: "x").keepsTrim)                       // no phase: saving, nothing to keep
        #expect(PipelineFailure.server(code: "render.x").keepsTrim)                  // came up while rendering
        #expect(!PipelineFailure.unreachable.keepsTrim && !PipelineFailure.expired.keepsTrim && !PipelineFailure.serverBusy.keepsTrim)
    }
}

// MARK: - Wire decoding, with and without the API contract's new fields

struct DecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try CobaltJSON.decoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func sessionWithoutNewFields() throws {
        let s = try decode(StudioSession.self, """
        {"status":"saving","id":"abc","link":"https://x.com/i/status/1","service":"twitter","title":null,
         "duration":null,"width":null,"height":null,"bytes":null,"created_at":1790000000000,
         "expires_at":1790604800000,"error":null,"renders":[]}
        """)
        #expect(s.status == .saving && s.id == "abc" && s.service == "twitter")
        #expect(s.step == nil && s.stepBytes == nil && s.stepTotal == nil && s.waking == nil)
        #expect(s.errorCode == nil && s.renders.isEmpty && s.title == nil)
        #expect(s.createdAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(s.expiresAt == Date(timeIntervalSince1970: 1_790_604_800))
    }

    @Test func sessionWithNewFields() throws {
        let s = try decode(StudioSession.self, """
        {"status":"saving","id":"abc","link":"https://x.com/i/status/1","service":"twitter","title":null,
         "duration":null,"width":null,"height":null,"bytes":null,"created_at":1790000000000,
         "expires_at":1790604800000,"error":null,"renders":[],
         "step":"storing","step_bytes":1048576,"step_total":4331778,"waking":false}
        """)
        #expect(s.step == .storing && s.stepBytes == 1_048_576 && s.stepTotal == 4_331_778 && s.waking == false)
        let fetching = try decode(StudioSession.self, """
        {"status":"saving","id":"abc","created_at":1,"expires_at":2,"step":"fetching","step_bytes":null,
         "step_total":null,"waking":true}
        """)
        #expect(fetching.step == .fetching && fetching.stepBytes == nil && fetching.waking == true)
        // a step this build does not know is "not said"
        let future = try decode(StudioSession.self, """
        {"status":"saving","id":"abc","created_at":1,"expires_at":2,"step":"teleporting"}
        """)
        #expect(future.step == nil)
    }

    @Test func readyAndErroredSessions() throws {
        let ready = try decode(StudioSession.self, """
        {"status":"ready","id":"abc","link":"https://x.com/i/status/1","service":"twitter","title":"twitter_1",
         "duration":5.46,"width":480,"height":568,"bytes":256000,"created_at":1790000000000,"expires_at":1790604800000,
         "error":null,"renders":[{"id":"job1","url":"https://media.capybaraharmony.com/PrEvIeW002.webp","start":0,
         "length":5.4,"width":480,"quality":"med","bytes":841000,"created_at":1790000100000}],
         "step":null,"step_bytes":null,"step_total":null,"waking":false}
        """)
        #expect(ready.status == .ready && ready.duration == 5.46 && ready.bytes == 256_000)
        #expect(ready.renders.count == 1 && ready.renders[0].bytes == 841_000 && ready.renders[0].quality == "med")
        let failed = try decode(StudioSession.self, """
        {"status":"error","id":"abc","created_at":1,"expires_at":2,"error":{"code":"error.api.fetch.fail"},"renders":[]}
        """)
        #expect(failed.status == .error && failed.errorCode == "error.api.fetch.fail")
        // round trip through our own encoder
        let data = try CobaltJSON.encoder().encode(ready)
        #expect(try decode(StudioSession.self, String(decoding: data, as: UTF8.self)) == ready)
    }

    @Test func libraryPostsWithAndWithoutNewFields() throws {
        let post = try decode(LibraryPost.self, """
        {"id":"p","service":"instagram","link":"https://www.instagram.com/reel/Dd7P496wolG/","title":"instagram_Dd7P496wolG",
         "duration":14.77,"width":720,"height":1280,"created_at":1790000000000,
         "session":{"id":"s","status":"ready","expires_at":1790600000000,"source_url":"https://api.capybaraharmony.com/studio/s/source"},
         "files":[
          {"id":"a","kind":"public","source":"studio","name":"x.webp","url":"https://media.capybaraharmony.com/AbCdEfGhIj.webp",
           "content_type":"image/webp","bytes":4500000,"width":480,"height":854,"duration":10.1,"created_at":1790000000000,
           "media_name":"AbCdEfGhIj.webp","deletable":true},
          {"id":"b","kind":"private","source":"saved","name":"x","url":null,"content_type":"video/mp4","bytes":4331778,
           "width":720,"height":1280,"duration":14.77,"created_at":1789999990000,"media_name":null,"deletable":false},
          {"id":"c","kind":"public","source":"host","name":"x.mp4","url":"https://media.capybaraharmony.com/AbCdEfGhIk.mp4",
           "content_type":"video/mp4","bytes":8300000,"created_at":1789999980000}]}
        """)
        #expect(post.ref == "Dd7P496wolG")
        #expect(post.session?.sourceURL.absoluteString == "https://api.capybaraharmony.com/studio/s/source")
        #expect(post.files.map(\.role) == [.webp, .privateCopy, .hostedLink])
        #expect(post.pills == [.webp, .mp4Link, .privateCopy])
        #expect(post.files[0].deletable && !post.files[1].deletable && !post.files[2].deletable)
        #expect(post.files[2].mediaName == nil && post.files[2].width == nil)

        let bare = try decode(LibraryPost.self, """
        {"id":"q","created_at":1,"files":[{"id":"z","kind":"private","source":"upload","name":"n","created_at":1}]}
        """)
        #expect(bare.link == nil && bare.ref == nil && bare.session == nil && bare.pills == [.privateCopy])
    }

    @Test func webpResultAndPickerItem() throws {
        let r = try decode(WebpResult.self, """
        {"job":"j","url":"https://media.capybaraharmony.com/PrEvIeW001.webp","bytes":4500000,"width":480,"height":854,"seconds":10.1}
        """)
        #expect(r.width == 480 && r.seconds == 10.1)
        let item = PickerItem(id: 0, type: .gif, url: URL(string: "https://a.b/c")!, thumb: nil)
        #expect(item.canWebp)
        #expect(!PickerItem(id: 1, type: .photo, url: URL(string: "https://a.b/c")!, thumb: nil).canWebp)
    }
}

// MARK: - Stores and settings

@MainActor
struct StoreTests {
    @Test func offlineStoreAddsCountsAndDropsFiles() async throws {
        let root = try makeTempDirectory()
        let clock = VirtualClock()
        let tools = PreviewMediaTools(clock: clock, clip: PreviewData.long)
        let store = OfflineStore(root: root, tools: tools)
        #expect(store.videos.isEmpty && store.usage == StorageUsage(count: 0, bytes: 0))

        let a = try makeTempFile("a.mp4", bytes: 2_000)
        let b = try makeTempFile("b.webp", bytes: 3_000)
        let media = MediaInfo(name: "a", duration: 5, width: 480, height: 270, bytes: 2_000, isImage: false)
        let first = try await store.add(file: a, kind: .original, media: media, sessionID: "s1", link: nil, remoteURL: nil, move: true)
        let second = try await store.add(file: b, kind: .webp, media: media, sessionID: "s1", link: URL(string: "https://x.com/i/status/1"), remoteURL: URL(string: "https://media.capybaraharmony.com/x.webp"), move: false)

        #expect(store.videos.map(\.id) == [second.id, first.id])         // newest first
        #expect(store.latest(1).map(\.id) == [second.id])
        #expect(store.usage == StorageUsage(count: 2, bytes: 5_000, mediaCount: 1))     // one session: one media
        #expect(first.bytes == 2_000 && first.duration == 5 && first.sessionID == "s1")
        #expect(!FileManager.default.fileExists(atPath: a.path))          // moved
        #expect(FileManager.default.fileExists(atPath: b.path))           // copied
        #expect(first.fileURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)

        // another instance over the same folder (the share extension) sees it after reload
        let other = OfflineStore(root: root, tools: tools)
        #expect(other.videos.map(\.id) == [second.id, first.id])
        let c = try makeTempFile("c.mp4", bytes: 10)
        let third = try await other.add(file: c, kind: .original, media: media, sessionID: nil, link: nil, remoteURL: nil, move: true)
        await store.reload()
        #expect(store.videos.first?.id == third.id && store.videos.count == 3)

        await store.dropFilesKeepingPosters()
        #expect(store.videos.count == 3 && store.videos.allSatisfy { $0.fileURL == nil })
        #expect(store.usage == StorageUsage(count: 0, bytes: 0))

        await store.remove(first.id)
        #expect(store.videos.count == 2 && !store.videos.contains { $0.id == first.id })
        #expect(OfflineStore(root: root, tools: tools).videos.count == 2)
    }

    @Test func inboxURLsAreFreshAndSafe() throws {
        let store = OfflineStore(root: try makeTempDirectory(), tools: PreviewMediaTools(clock: VirtualClock(), clip: PreviewData.long))
        let a = store.inboxURL(for: "IMG/0412.mov")
        let b = store.inboxURL(for: "IMG/0412.mov")
        #expect(a != b && a.lastPathComponent == "IMG_0412.mov")
        #expect(FileManager.default.fileExists(atPath: a.deletingLastPathComponent().path))
    }

    @Test func sharedJobsRoundTripAcrossTwoInstances() throws {
        let dir = try makeTempDirectory()
        let writer = SharedJobStore(directory: dir)
        let reader = SharedJobStore(directory: dir)
        let now = Date(timeIntervalSince1970: 2_100)                 // the fixtures' own "now" (their jobs are 1000-3000 s old)
        #expect(reader.all().isEmpty && reader.nextHandoff(now: now) == nil)

        let result = WebpResult(job: "j", url: URL(string: "https://media.capybaraharmony.com/PrEvIeW002.webp")!, bytes: 841_000, width: 480, height: 568, seconds: 5.4)
        let old = SharedJob(
            id: UUID(), origin: .shareExtension, link: URL(string: "https://x.com/i/status/1"), sessionID: "s",
            media: MediaInfo(name: "n", duration: 14.77, width: 720, height: 1280, bytes: 1, isImage: false),
            trim: TrimRange(start: 0, end: 10), stage: .uploadInterrupted(localFile: URL(fileURLWithPath: "/tmp/a.mov")),
            wantsTrim: false, pickedUp: false, updatedAt: Date(timeIntervalSince1970: 1_000))
        var newer = old
        newer.id = UUID(); newer.stage = .rendering(job: "job9"); newer.updatedAt = Date(timeIntervalSince1970: 2_000)
        var fromApp = old
        fromApp.id = UUID(); fromApp.origin = .app; fromApp.stage = .done(result); fromApp.updatedAt = Date(timeIntervalSince1970: 3_000)
        for j in [old, newer, fromApp] { writer.upsert(j) }

        #expect(reader.all().count == 3)
        #expect(reader.all().first { $0.id == newer.id }?.stage == .rendering(job: "job9"))
        #expect(reader.all().first { $0.id == fromApp.id }?.stage == .done(result))
        #expect(reader.all().first { $0.id == old.id } == old)
        #expect(reader.nextHandoff(now: now)?.id == newer.id)            // newest from the extension; the app's own job is skipped

        var taken = newer
        taken.pickedUp = true
        reader.upsert(taken)
        #expect(writer.all().count == 3 && writer.nextHandoff(now: now)?.id == old.id)
        writer.remove(old.id)
        #expect(reader.nextHandoff(now: now) == nil && reader.all().count == 2)
    }

    @Test func settingsKeyAndServerPasting() throws {
        let defaults = UserDefaults(suiteName: "cobaltkit.tests.\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults, keychain: .memory())
        #expect(settings.serverURL == Settings.defaultServer && settings.serverURL.absoluteString == "https://api.capybaraharmony.com")
        #expect(!settings.hasAPIKey && settings.apiKey() == nil)
        #expect(settings.webpQuality == .med && settings.webpWidth == 480 && settings.keepVideosOnDevice && settings.haptics)

        #expect(throws: KeyInputError.self) { try settings.setAPIKey(pasted: "hello") }
        #expect(throws: KeyInputError.self) { try settings.setAPIKey(pasted: "") }
        #expect(!settings.hasAPIKey)
        try settings.setAPIKey(pasted: "  7C1F2A60-4B0E-4D2F-9A53-3F1D8E9B6A21\n")
        #expect(settings.hasAPIKey && settings.apiKey() == "7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21")
        settings.clearAPIKey()
        #expect(!settings.hasAPIKey && settings.apiKey() == nil)

        try settings.setServer(pasted: "try this: https://cobalt.example.org:8443/some/path?x=1#y please")
        #expect(settings.serverURL.absoluteString == "https://cobalt.example.org:8443")
        #expect(throws: ServerInputError.self) { try settings.setServer(pasted: "not a url") }
        #expect(settings.serverURL.absoluteString == "https://cobalt.example.org:8443")
        settings.resetServer()
        #expect(settings.serverURL == Settings.defaultServer)

        settings.webpQuality = .high
        settings.webpWidth = 320
        settings.keepVideosOnDevice = false
        settings.haptics = false
        let again = Settings(defaults: defaults, keychain: .memory())
        #expect(again.webpQuality == .high && again.webpWidth == 320 && !again.keepVideosOnDevice && !again.haptics)
    }
}

// MARK: - App and library models over the preview data

@MainActor
@Suite(.serialized)
struct AppAndLibraryTests {
    @Test func previewAppModelShowsTheBoardsData() async throws {
        let app = AppModel.preview(.happy)
        #expect(app.capabilities.kind == .fork && app.capabilities.key == .valid && app.capabilities.keyName == "iphone")
        // the orbit's seven plain saves (`.happy` also seeds the media with three webps and a webp-only media)
        let orbit = app.store.videos.filter { $0.id.hasPrefix("preview-orbit-") }
        #expect(orbit.count == 7 && app.store.videos.count == 12)
        #expect(app.store.usage == StorageUsage(count: 13, bytes: 54_000_000))
        #expect(orbit.map(\.duration) == [37.43, 5.46, 1.9, 10.77, nil, 5.06, 28])
        #expect(orbit.map(\.width) == [720, 480, 498, 720, 640, 1920, 1280])
        #expect(app.settings.hasAPIKey)
        #expect(app.selectedTab == .save)
        #expect(app.serverSummary == ServerSummary(host: "api.capybaraharmony.com", kind: .fork, version: "11.7.1", features: ["studio", "library"], key: .valid, keyName: "iphone"))
        #expect(app.library.postCount == 15 && app.library.fileCount == 24 && app.library.posts.count == 6)
        #expect(app.pipeline.state == .idle)

        #expect(AppModel.preview(.emptyOrbit).store.videos.isEmpty)
        #expect(AppModel.preview(.emptyOrbit).store.usage == StorageUsage(count: 0, bytes: 0))
        #expect(AppModel.preview(.plainCobalt).serverSummary.features.isEmpty)
        #expect(AppModel.preview(.legacyFork).serverSummary.features == ["studio"])
        #expect(AppModel.preview(.revokedKey).serverSummary.key == .invalid)
    }

    @Test func everyScenarioReachesItsEndState() async throws {
        for scenario in PreviewScenario.allCases {
            let h = Harness(scenario)
            let p = h.pipeline
            switch scenario {
            case .noLink:
                p.start(pastedText: "nothing")
                #expect(p.state == .failed(.noLink), "\(scenario)")
            case .tooBig:
                p.start(file: try makeTempFile("big.mov"))
                #expect(p.state == .failed(.tooLarge(limit: 100_000_000)), "\(scenario)")
            case .image:
                p.start(file: try makeTempFile("photo.png"))
                await h.driveToSettled()
                if case .image = p.state {} else { Issue.record("\(scenario): \(p.state)") }
            case .picker:
                p.start(link: URL(string: pastedLink)!)
                await h.driveToSettled()
                if case .picker = p.state {} else { Issue.record("\(scenario): \(p.state)") }
            case .privatePost:
                p.start(link: URL(string: pastedLink)!)
                await h.driveToSettled()
                if case .failed(.fetchFailed) = p.state {} else { Issue.record("\(scenario): \(p.state)") }
            case .revokedKey:
                p.start(link: URL(string: pastedLink)!)
                await h.driveToSettled()
                #expect(p.state == .failed(.keyInvalid), "\(scenario)")
            case .plainCobalt:
                p.start(link: URL(string: pastedLink)!)
                await h.driveToSettled()
                if case .savedLocally = p.state {} else { Issue.record("\(scenario): \(p.state)") }
            case .renderBusy, .renderLost:
                p.start(link: URL(string: pastedLink)!)
                await h.driveToSettled()
                p.makeWebp()
                await h.driveToSettled()
                #expect(p.state == .failed(scenario == .renderBusy ? .renderBusy : .renderLost), "\(scenario)")
            case .galleryInstagram, .galleryX, .galleryMixed, .galleryOne, .galleryPartial, .galleryNoMake, .galleryMakeFails:
                p.start(link: URL(string: pastedLink)!)
                await h.driveToSettled()
                if case .gallery = p.state {} else { Issue.record("\(scenario): \(p.state)") }
                #expect(p.galleryRun?.isSaved == true, "\(scenario)")
            case .happy, .coldStart, .shortClip, .legacyFork, .emptyOrbit, .renditions, .renditionsLegacy, .renameFails, .offline:
                p.start(link: URL(string: pastedLink)!)
                await h.driveToSettled()
                #expect(p.state == .ready, "\(scenario)")
                p.makeWebp()
                await h.driveToSettled()
                if case .done = p.state {} else { Issue.record("\(scenario): \(p.state)") }
            }
        }
    }

    /// Everything else runs on the virtual clock; this one runs the preview on the real one (at a
    /// tenth of the lab's timings) so a clock-only bug cannot hide behind the harness.
    @Test func previewRunsOnTheRealClock() async throws {
        let app = AppModel.makePreview(.shortClip, timeScale: 0.1, clock: SystemClock())
        let p = app.pipeline
        p.start(link: URL(string: shortLink)!)
        func wait(_ done: @MainActor () -> Bool) async {
            let deadline = Date().addingTimeInterval(20)
            while !done(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        }
        await wait { p.state == .ready }
        #expect(p.state == .ready)
        p.makeWebp()
        await wait { if case .done = p.state { return true } else { return false } }
        guard case .done(let r) = p.state else { Issue.record("expected .done, got \(p.state)"); return }
        #expect(r.seconds == 5.4)
        #expect(app.store.videos.first?.kind == .webp)
    }

    @Test func libraryRefreshExpandAndDelete() async throws {
        let app = AppModel.makePreview(.happy, timeScale: 1, clock: SystemClock())
        let library = app.library
        await library.refresh()
        #expect(library.failure == nil && !library.isLoading && !library.hasMore)
        #expect(library.posts.count == 6 && library.postCount == 15 && library.fileCount == 24)
        #expect(library.posts[0].pills == [.mp4Link, .privateCopy])
        #expect(library.posts[1].pills == [.webp, .privateCopy])
        #expect(library.posts[3].pills == [.privateCopy])

        library.expandedPostID = library.posts[1].id
        library.expandedPostID = library.posts[2].id        // one card open at a time
        #expect(library.expandedPostID == library.posts[2].id)

        // only .webp files delete
        let hostedMp4 = library.posts[0].files[0]
        let privateCopy = library.posts[1].files[1]
        await #expect(throws: PipelineFailure.self) { try await library.delete(hostedMp4) }
        await #expect(throws: PipelineFailure.self) { try await library.delete(privateCopy) }
        #expect(library.fileCount == 24)

        let webp = library.posts[1].files[0]
        #expect(webp.deletable && webp.mediaName == "PrEvIeW001.webp")
        try await library.delete(webp)
        // the post keeps its private copy and the two newer renders of the `.renditions` fixture
        #expect(library.posts[1].files.count == 3 && library.posts[1].pills == [.webp, .privateCopy])
        #expect(library.fileCount == 23)
        // a post with nothing left disappears
        let only = library.posts[3]
        #expect(only.files.count == 1)

        // copy / host
        app.library.copyLink(library.posts[2].files[0])
        let clip = (app.ctx.clipboard as! MemoryClipboard)
        #expect(clip.last == "https://media.capybaraharmony.com/PrEvIeW002.webp")
        let url = try await library.host(library.posts[2].files[1])
        #expect(url.absoluteString.hasPrefix("https://media.capybaraharmony.com/"))
        #expect(clip.last == url.absoluteString)

        // the deleted file stays gone after a refresh
        await library.refresh()
        #expect(!library.posts.flatMap(\.files).contains { $0.mediaName == "PrEvIeW001.webp" })
    }

    @Test func libraryLocalCopyDownloadsPrivateAndPublicFiles() async throws {
        let app = AppModel.makePreview(.happy, timeScale: 1, clock: SystemClock())
        let library = app.library
        let priv = try await library.localCopy(library.posts[1].files[1])
        #expect(FileManager.default.fileExists(atPath: priv.path) && priv.pathExtension == "mp4")
        let pub = try await library.localCopy(library.posts[1].files[0])
        #expect(FileManager.default.fileExists(atPath: pub.path))
        try await library.save(library.posts[1].files[1])        // the preview photos saver accepts it
    }

    @Test func trimNewWebpFromALibraryPost() async throws {
        let h = Harness(.happy)
        let post = h.app.library.posts[1]                       // Dd7P496wolG, open session
        await h.app.trimNewWebp(from: post)
        #expect(h.app.selectedTab == .save)
        await h.driveToSettled()
        #expect(h.pipeline.state == .ready)
        #expect(h.pipeline.media?.duration == 14.77)
        #expect(h.pipeline.trim == TrimRange(start: 0, end: 10))
        #expect(h.pipeline.sessionID != nil)

        // a post whose session ended reopens the studio from its private copy
        var expired = h.app.library.posts[3]
        expired.session = nil
        await h.app.trimNewWebp(from: expired)
        await h.driveToSettled()
        #expect(h.pipeline.state == .ready)
    }

    @Test func openingLinksAndHandoffs() async throws {
        let h = Harness(.happy)
        h.app.selectedTab = .settings
        h.app.open(URL(string: "cobalt-apple://open")!)
        #expect(h.app.selectedTab == .save)
        h.app.selectedTab = .library
        h.app.open(URL(string: "https://example.com")!)         // not ours
        #expect(h.app.selectedTab == .library)

        let job = SharedJob(
            id: UUID(), origin: .shareExtension, link: URL(string: pastedLink), sessionID: nil, media: nil, trim: nil,
            stage: .failed(code: "error.api.fetch.fail"), wantsTrim: false, pickedUp: false, updatedAt: h.clock.now())
        h.app.jobs.upsert(job)
        h.app.open(URL(string: "cobalt-apple://job/\(job.id.uuidString)")!)
        #expect(h.app.selectedTab == .save)
        #expect(h.pipeline.state == .failed(.fetchFailed(code: "error.api.fetch.fail")))
    }

    @Test func serverAndKeyChangesRefreshCapabilities() async throws {
        let app = AppModel.preview(.plainCobalt)
        #expect(app.capabilities.kind == .plainCobalt)
        await app.refreshServer()
        #expect(app.capabilities.kind == .plainCobalt && !app.isCheckingServer)
        try await app.setServer(pasted: "https://cobalt.example.org/ignored/path")
        #expect(app.settings.serverURL.absoluteString == "https://cobalt.example.org")
        #expect(app.capabilities.kind == .plainCobalt)           // re-read from the (preview) server
        await #expect(throws: KeyInputError.self) { try await app.setAPIKey(pasted: "nope") }
        await #expect(throws: ServerInputError.self) { try await app.setServer(pasted: "nope") }
    }
}
