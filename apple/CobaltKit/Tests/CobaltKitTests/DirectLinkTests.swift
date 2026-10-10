import Foundation
import Synchronization
import Testing
@testable import CobaltKit

// A link straight at a media file (a Discord CDN attachment, a bare .mp4): recognised by its path, saved by the server
// when it has `features.direct_links`, downloaded on the device and uploaded when it has not, and told apart from a
// post that is private or removed when cobalt cannot read a link at all.

private let discordPNG = "https://cdn.discordapp.com/attachments/1234567890/9876543210/LiaPoor.png?ex=68f0aa00&is=68ef5880&hm=0f3c9e&"

// MARK: - Which links are files

struct DirectLinkRecognitionTests {
    private func info(_ s: String) throws -> LinkInfo {
        let url = try #require(URL(string: s))
        return try #require(LinkInfo(url))
    }

    @Test(arguments: [
        discordPNG,
        "https://media.discordapp.net/attachments/1/2/clip.mp4?ex=1",
        "https://example.com/LiaPoor.PNG",
        "https://example.com/IMG_0412.JPG?w=100",
        "https://example.com/a/b/c.JPEG",
        "https://example.com/pic.webp",
        "https://example.com/pic.heic",
        "https://example.com/loop.GIF",
        "https://example.com/clip.mp4",
        "https://example.com/clip.MOV",
        "https://example.com/clip.webm",
        "https://example.com/clip.m4v#t=3",
        "http://192.0.2.7:8080/files/x.png",
    ])
    func mediaFiles(_ link: String) throws {
        #expect(try info(link).isMediaFile, "\(link)")
    }

    @Test(arguments: [
        "https://example.com/page.html",
        "https://example.com/clip.mp4.html",
        "https://example.com/watch?file=clip.mp4",
        "https://example.com/watch?v=abc#clip.png",
        "https://www.instagram.com/reel/Dd7P496wolG/",
        "https://x.com/ilokineedsleep/status/2105435404002562056",
        "https://example.com/",
        "https://example.com/pngs/readme",
        "https://example.com/song.mp3",
        "https://example.com/clip.mkv",
        "https://example.com/photo.avif",
        "https://example.com/archive.zip",
        "https://example.com/png",
    ])
    func notMediaFiles(_ link: String) throws {
        let value = try info(link)
        #expect(!value.isMediaFile && value.fileName == nil, "\(link)")
    }

    @Test func aDiscordAttachmentIsNamedByItsFile() throws {
        let link = try info(discordPNG)
        #expect(link.service == "discord" && link.ref == "LiaPoor")
        #expect(link.fileName == "LiaPoor.png" && link.isPhotoFile)
        #expect(MediaTitle.text(MediaTitle.resolve(custom: nil, service: link.service, ref: link.ref, fileName: nil)) == "discord · LiaPoor")
        #expect(InstantShareEngine.label(for: link) == "discord · LiaPoor")
    }

    @Test func theStemKeepsDotsAndDecodesTheName() throws {
        let link = try info("https://cdn.discordapp.com/attachments/1/2/My%20Photo.v2.JPG?ex=1")
        #expect(link.fileName == "My Photo.v2.JPG" && link.ref == "My Photo.v2")
    }

    @Test func photosAreTheStillsAndTheRestIsVideo() throws {
        for ext in ["jpg", "jpeg", "png", "webp", "heic", "PNG"] {
            #expect(try info("https://example.com/a.\(ext)").isPhotoFile, "\(ext)")
        }
        for ext in ["gif", "mp4", "mov", "webm", "m4v"] {
            #expect(try !info("https://example.com/a.\(ext)").isPhotoFile, "\(ext)")
        }
    }

    @Test func otherSitesKeepTheirRef() throws {
        let ig = try info("https://www.instagram.com/p/Ddy0-gpGg5U/")
        #expect(ig.service == "instagram" && ig.ref == "Ddy0-gpGg5U")
        let page = try info("https://example.com/files/readme.html")
        #expect(page.service == "example" && page.ref == "readme.html")
        let twimg = try info("https://pbs.twimg.com/media/G3abc.jpg?format=jpg&name=large")
        #expect(twimg.service == "x" && twimg.ref == "G3abc")
        #expect(try info("https://twitter.com/someone/status/1").service == "x")
    }

    @Test func pastedTextFindsTheFileLinkWithItsQuery() {
        let text = "look at this \(discordPNG) lol"
        #expect(LinkInfo.firstLink(in: text) == URL(string: discordPNG))
        #expect(LinkInfo.allLinks(in: text) == [URL(string: discordPNG)!])
    }

    @Test func theShareSheetSendsAFileAtOnceNeverAsAGallery() throws {
        for link in [discordPNG, "https://example.com/a.mp4", "https://example.com/a.JPG?x=1", "https://example.com/a.webm"] {
            #expect(!InstantShare.mayBeGallery(URL(string: link)!), "\(link)")
        }
        #expect(InstantShare.mayBeGallery(URL(string: "https://example.com/page.html")!))
    }

    @Test func theCapabilityIsReadAndAbsentMeansOff() throws {
        func caps(_ features: String) throws -> Capabilities {
            let json = #"{"server":"cobalt-cloudflare","features":\#(features),"key":"valid"}"#
            return try #require(HTTPCobaltClient.parseForkCapabilities(Data(json.utf8)))
        }
        #expect(try caps(#"{"studio":true,"direct_links":true}"#).directLinks)
        #expect(try !caps(#"{"studio":true,"direct_links":false}"#).directLinks)
        #expect(try !caps(#"{"studio":true}"#).directLinks)
        #expect(!Capabilities.unknown.directLinks)
    }
}

// MARK: - The share sheet

@MainActor
@Suite(.serialized)
struct DirectLinkShareTests {
    @Test func aFileLinkIsSavedByTheServerWithNoCheckFirst() async throws {
        let rig = GSRig(link: LinkInfo(URL(string: discordPNG)!)!)
        rig.begin()
        await gsSettle()
        #expect(rig.server.resolves == 0 && rig.server.capabilityReads == 0, "nothing is asked of the server before the save")
        #expect(rig.sender.sent == [.plain(LinkInfo(URL(string: discordPNG)!)!)])
        #expect(rig.notices.posted.first?.body == "discord · LiaPoor")
        #expect(rig.flow.finish == .sent)
    }
}

// MARK: - The error words

struct DirectLinkErrorTests {
    @Test func onlyTheTwoLinkCodesAreUnreadable() {
        func map(_ code: String) -> PipelineFailure { mapFailure(code: code, during: .saving) }
        #expect(map("error.api.link.invalid") == .linkUnreadable(code: "error.api.link.invalid"))
        #expect(map("error.api.link.unsupported") == .linkUnreadable(code: "error.api.link.unsupported"))
        // the sites' own answers keep the private / removed wording
        for code in [
            "error.api.content.post.private", "error.api.content.post.unavailable", "error.api.content.video.private",
            "error.api.content.video.unavailable", "error.api.fetch.empty", "error.api.fetch.fail", "error.api.fetch.rate",
            "error.api.link.missing",
        ] {
            #expect(map(code) == .fetchFailed(code: code), "\(code)")
        }
        #expect(pipelineFailure(from: CobaltError.api(code: "error.api.link.invalid", httpStatus: 400), during: .saving)
            == .linkUnreadable(code: "error.api.link.invalid"))
    }

    @Test func theCodeTravelsToTelemetryAndTheLiveActivity() {
        let failure = PipelineFailure.linkUnreadable(code: "error.api.link.unsupported")
        #expect(failure.telemetryCode == "error.api.link.unsupported")
        #expect(failure.liveName == "linkUnreadable" && failure.liveCode == "error.api.link.unsupported")
        #expect(!failure.keepsTrim)
    }
}

// MARK: - Through the pipeline

private func readySession(_ id: String, duration: Double?) -> StudioSession {
    StudioSession(
        id: id, status: .ready, link: nil, service: nil, title: "LiaPoor", duration: duration, width: 1024, height: 768,
        bytes: 90_000, createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        expiresAt: Date(timeIntervalSince1970: 1_800_600_000), errorCode: nil, renders: [], step: nil, stepBytes: nil,
        stepTotal: nil, waking: nil)
}

@MainActor
@Suite(.serialized)
struct DirectLinkPipelineTests {
    private let file = URL(string: discordPNG)!

    private func rig(directLinks: Bool, gallery: Bool = false) -> (h: Harness, resolves: Log<URL>, downloads: Log<URL>) {
        let h = Harness(.happy)
        h.ctx.capabilities.directLinks = directLinks
        h.ctx.capabilities.gallery = gallery
        let resolves = Log<URL>(), downloads = Log<URL>()
        var stub = ScriptedClient(base: h.ctx.client)
        stub.resolveHook = { url in
            resolves.add(url)
            throw CobaltError.api(code: "error.api.link.invalid", httpStatus: 400)
        }
        stub.downloadHook = { remote, dest in
            if case .open(let url) = remote { downloads.add(url) }
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 9, count: 150_000).write(to: dest)
            return dest
        }
        h.ctx.client = stub
        return (h, resolves, downloads)
    }

    private func calls(_ h: Harness) -> [String] { (h.ctx.client as? ScriptedClient).flatMap { ($0.base as? PreviewClient)?.server.lineCalls } ?? [] }

    // direct_links on

    @Test func serverSavesAFileLinkWithNoResolve() async throws {
        let (h, resolves, _) = rig(directLinks: true)
        h.pipeline.start(link: file)
        await h.driveToSettled()
        #expect(resolves.count == 0, "POST / is never called for a link at a file")
        let sid = try #require(h.pipeline.sessionID)
        let preview = try #require((h.ctx.client as? ScriptedClient)?.base as? PreviewClient)
        #expect(preview.server.session(sid)?.link == file, "the create carried the link as it was pasted")
        #expect(calls(h).contains { $0.hasPrefix("POST /studio") })
        #expect(!calls(h).contains { $0.hasPrefix("PUT /studio/upload") })
        #expect(h.pipeline.state == .ready)
        guard case .link(let info) = h.pipeline.input else { Issue.record("no link input"); return }
        #expect(info.ref == "LiaPoor" && info.service == "discord")
    }

    @Test func aSavedPhotoIsAGalleryOfOneAndAVideoIsAClipToTrim() async throws {
        let photo = Harness(.happy)
        photo.ctx.capabilities.directLinks = true
        photo.ctx.capabilities.gallery = true
        var stub = ScriptedClient(base: photo.ctx.client)
        stub.sessionHook = { id, _ in readySession(id, duration: nil) }
        photo.ctx.client = stub
        photo.pipeline.start(link: file)
        await photo.driveToSettled()
        guard case .gallery(let items) = photo.pipeline.state else { Issue.record("expected a gallery of one: \(photo.pipeline.state)"); return }
        #expect(items.count == 1 && items[0].isPhoto && items[0].width == 1024)
        #expect(photo.pipeline.galleryRun?.phase == .saved && photo.pipeline.galleryRun?.total == 1)

        let clip = Harness(.happy)
        clip.ctx.capabilities.directLinks = true
        clip.ctx.capabilities.gallery = true
        var clipStub = ScriptedClient(base: clip.ctx.client)
        clipStub.sessionHook = { id, _ in readySession(id, duration: 12) }
        clip.ctx.client = clipStub
        clip.pipeline.start(link: URL(string: "https://example.com/holiday.mp4")!)
        await clip.driveToSettled()
        #expect(clip.pipeline.state == .ready, "a video is the clip card, as always")
    }

    @Test func aSecondFileHostIsTreatedTheSame() async throws {
        let (h, resolves, _) = rig(directLinks: true)
        h.pipeline.start(link: URL(string: "https://files.example.org/videos/holiday.MP4")!)
        await h.driveToSettled()
        #expect(resolves.count == 0 && h.pipeline.sessionID != nil)
    }

    @Test func aPageLinkStillGoesThroughTheCheck() async throws {
        let (h, resolves, _) = rig(directLinks: true)
        h.pipeline.start(link: URL(string: "https://example.com/page.html")!)
        await h.driveToSettled()
        #expect(resolves.count == 1)
    }

    // the fallback

    @Test func linkInvalidTriesTheServerOnceAndItsSaveStands() async throws {
        let (h, resolves, _) = rig(directLinks: true)
        let link = URL(string: "https://cdn.example.com/image?id=42")!
        h.pipeline.start(link: link)
        await h.driveToSettled()
        #expect(resolves.count == 1)
        let preview = try #require((h.ctx.client as? ScriptedClient)?.base as? PreviewClient)
        #expect(calls(h).filter { $0.hasPrefix("POST /studio") }.count == 1, "the server was tried exactly once")
        let sid = try #require(h.pipeline.sessionID)
        #expect(preview.server.session(sid)?.link == link)
        #expect(h.pipeline.state == .ready)
    }

    @Test func linkUnsupportedTriesTheServerToo() async throws {
        let h = Harness(.happy)
        h.ctx.capabilities.directLinks = true
        var stub = ScriptedClient(base: h.ctx.client)
        stub.resolveHook = { _ in throw CobaltError.api(code: "error.api.link.unsupported", httpStatus: 400) }
        h.ctx.client = stub
        h.pipeline.start(link: URL(string: "https://example.com/some/path")!)
        await h.driveToSettled()
        #expect(h.pipeline.sessionID != nil && h.pipeline.state == .ready)
    }

    @Test func whenTheServerCannotReadItEitherTheOwnerReadsCantReadThisLink() async throws {
        let h = Harness(.happy)
        h.ctx.capabilities.directLinks = true
        var stub = ScriptedClient(base: h.ctx.client)
        stub.resolveHook = { _ in throw CobaltError.api(code: "error.api.link.invalid", httpStatus: 400) }
        stub.sessionHook = { id, _ in
            StudioSession(
                id: id, status: .error, link: nil, service: nil, title: nil, duration: nil, width: nil, height: nil, bytes: nil,
                createdAt: Date(timeIntervalSince1970: 1_800_000_000), expiresAt: Date(timeIntervalSince1970: 1_800_600_000),
                errorCode: "error.api.fetch.empty", renders: [], step: nil, stepBytes: nil, stepTotal: nil, waking: nil)
        }
        h.ctx.client = stub
        h.pipeline.start(link: URL(string: "https://example.com/some/path")!)
        await h.driveToSettled()
        #expect(h.pipeline.state == .failed(.linkUnreadable(code: "error.api.link.invalid")))
    }

    @Test func aServerRefusalAboutSomethingElseStandsAsItIs() async throws {
        let h = Harness(.happy)
        h.ctx.capabilities.directLinks = true
        var stub = ScriptedClient(base: h.ctx.client)
        stub.resolveHook = { _ in throw CobaltError.api(code: "error.api.link.invalid", httpStatus: 400) }
        stub.sessionHook = { _, _ in throw CobaltError.api(code: "error.studio.line_full", httpStatus: 429) }
        h.ctx.client = stub
        h.pipeline.start(link: URL(string: "https://example.com/some/path")!)
        await h.driveToSettled()
        #expect(h.pipeline.state == .failed(.lineFull))
    }

    @Test func privateAndBlockedCodesNeverTryTheServer() async throws {
        for code in ["error.api.content.post.private", "error.api.fetch.empty", "error.api.content.video.unavailable"] {
            let h = Harness(.happy)
            h.ctx.capabilities.directLinks = true
            var stub = ScriptedClient(base: h.ctx.client)
            stub.resolveHook = { _ in throw CobaltError.api(code: code, httpStatus: 400) }
            h.ctx.client = stub
            h.pipeline.start(link: URL(string: "https://www.instagram.com/p/Ddy0-gpGg5U/")!)
            await h.driveToSettled()
            #expect(h.pipeline.state == .failed(.fetchFailed(code: code)), "\(code)")
            #expect(!calls(h).contains { $0.hasPrefix("POST /studio") }, "\(code)")
            #expect(h.pipeline.sessionID == nil)
        }
    }

    @Test func withoutDirectLinksTheUnreadableLinkFailsInItsOwnWords() async throws {
        let (h, resolves, _) = rig(directLinks: false)
        h.pipeline.start(link: URL(string: "https://cdn.example.com/image?id=42")!)
        await h.driveToSettled()
        #expect(resolves.count == 1)
        #expect(h.pipeline.state == .failed(.linkUnreadable(code: "error.api.link.invalid")))
        #expect(!calls(h).contains { $0.hasPrefix("POST /studio") })
    }

    // direct_links off

    @Test func anOlderServerGetsTheFileFromTheDeviceThroughTheUpload() async throws {
        let (h, resolves, downloads) = rig(directLinks: false)
        h.pipeline.start(link: file)
        await h.driveToSettled()
        #expect(resolves.count == 0, "no check for a link at a file")
        #expect(downloads.all == [file], "the device fetched the link itself")
        #expect(calls(h).contains { $0.hasPrefix("PUT /studio/upload") })
        #expect(!calls(h).contains { $0.hasPrefix("POST /studio") || $0 == "POST /" })
        guard case .image(let media) = h.pipeline.state else { Issue.record("expected the saved image, got \(h.pipeline.state)"); return }
        #expect(media.name == "LiaPoor.png", "titled from the file name")
        #expect(MediaTitle.text(h.pipeline.resolvedTitle) == "discord · LiaPoor")
    }

    @Test func aVideoFileOnAnOlderServerUploadsAsAVideo() async throws {
        let (h, resolves, downloads) = rig(directLinks: false)
        let link = URL(string: "https://files.example.org/holiday.mp4?sig=abc")!
        h.pipeline.start(link: link)
        await h.driveToSettled()
        #expect(resolves.count == 0 && downloads.all == [link])
        #expect(calls(h).contains { $0.hasPrefix("PUT /studio/upload") })
        #expect(h.pipeline.state == .ready)
    }

    @Test func theDeviceDownloadNeverStartsForATypeTheUploadRefuses() async throws {
        let (h, _, downloads) = rig(directLinks: false)
        h.pipeline.start(link: URL(string: "https://example.com/clip.webm")!)
        await h.driveToSettled()
        #expect(h.pipeline.state == .failed(.unsupported))
        #expect(downloads.count == 0)
    }

    @Test func theDeviceDownloadStopsAtTheUploadLimit() async throws {
        let h = Harness(.happy)
        let limit = h.ctx.capabilities.limits.maxUploadBytes
        let cancelled = Log<Bool>()
        var stub = ScriptedClient(base: h.ctx.client)
        stub.downloadProgressHook = { _, _, progress in
            progress(TransferProgress(bytes: 4_096, total: limit * 3))          // the host announces a huge file
            do { try await Task.sleep(for: .seconds(30)) } catch { cancelled.add(true); throw error }
            return URL(fileURLWithPath: "/dev/null")
        }
        h.ctx.client = stub
        h.pipeline.start(link: file)
        await h.driveToSettled()
        #expect(h.pipeline.state == .failed(.tooLarge(limit: limit)))
        #expect(cancelled.count == 1, "the download was cancelled, not run to the end")
    }

    @Test func theDeviceDownloadStopsWhenTheBytesPassTheLimitWithNoAnnouncedLength() async throws {
        let h = Harness(.happy)
        let limit = h.ctx.capabilities.limits.maxUploadBytes
        var stub = ScriptedClient(base: h.ctx.client)
        stub.downloadProgressHook = { _, _, progress in
            progress(TransferProgress(bytes: limit + 1, total: nil))
            try await Task.sleep(for: .seconds(30))
            return URL(fileURLWithPath: "/dev/null")
        }
        h.ctx.client = stub
        h.pipeline.start(link: file)
        await h.driveToSettled()
        #expect(h.pipeline.state == .failed(.tooLarge(limit: limit)))
    }

    @Test func aHostThatSaysNoReadsAsALinkThatCannotBeFetched() async throws {
        let h = Harness(.happy)
        var stub = ScriptedClient(base: h.ctx.client)
        stub.downloadHook = { _, _ in throw CobaltError.invalidResponse(httpStatus: 404) }
        h.ctx.client = stub
        h.pipeline.start(link: file)
        await h.driveToSettled()
        #expect(h.pipeline.state == .failed(.fetchFailed(code: "error.app.link_download_failed")))
    }

    @Test func plainCobaltKeepsItsOwnFlowForAFileLink() async throws {
        let h = Harness(.plainCobalt)
        var stub = ScriptedClient(base: h.ctx.client)
        let resolves = Log<URL>()
        stub.resolveHook = { url in resolves.add(url); throw CobaltError.api(code: "error.api.link.invalid", httpStatus: 400) }
        h.ctx.client = stub
        h.pipeline.start(link: file)
        await h.driveToSettled()
        #expect(resolves.count == 1, "plain cobalt has neither a direct save nor an upload: it asks, as before")
        #expect(h.pipeline.state == .failed(.linkUnreadable(code: "error.api.link.invalid")))
    }
}
