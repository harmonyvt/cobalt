import Foundation

// The real wiring of `ShareGalleryFlow` (the extension's key, the instant share's two transports) and the previews that
// replay it without a network (`ShareGalleryFlow.preview`).

extension InstantShareEngine {
    /// `POST /studio` with the gallery fields (APP-API-CONTRACT 18.12) through the same transports as the instant
    /// share: a background session when the build has the app group, else the foreground wait. One request, never
    /// retried here.
    func enqueue(link: LinkInfo, options: StudioCreateOptions, client: HTTPCobaltClient, job: UUID) async -> InstantShare.Result {
        let built: (request: URLRequest, body: Data)
        do {
            built = try client.shareSaveRequest(link: link.url, options: options)
        } catch CobaltError.noAPIKey {
            return .failed(.noKey)
        } catch {
            return .failed(.couldNotStart)
        }
        let file = directory.appendingPathComponent("\(job.uuidString.lowercased()).json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try built.body.write(to: file, options: [.atomic])
        } catch {
            return .failed(.couldNotStart)
        }
        let sink = SaveSink()
        let session = transport.session(identifier: BackgroundSessionID.save(job: job), events: sink)
        _ = session.upload(built.request, from: file, label: link.url.absoluteString)

        if transport.background {
            await Self.race(registerWait) { await session.registered() }
            return .saved
        }
        await Self.race(foregroundWait) { await sink.signal.wait() }
        try? FileManager.default.removeItem(at: file)
        switch sink.answer {
        case .none: return .saved
        case .responded(let status, _): return (200..<300).contains(status) ? .saved : .failed(.rejected(status: status))
        case .failed(let code): return code == NSURLErrorCancelled ? .failed(.couldNotStart) : .failed(.unreachable)
        }
    }
}

/// The real sender: the instant share's engine and the extension's client.
struct EngineShareSender: ShareGallerySender {
    var engine: InstantShareEngine
    var client: HTTPCobaltClient

    func send(_ request: ShareSend, job: UUID) async -> InstantShare.Result {
        switch request {
        case .plain(let link):
            return await engine.enqueue(link: link, client: client, job: job)
        case .options(let link, let options):
            return await engine.enqueue(link: link, options: options, client: client, job: job)
        }
    }
}

extension ShareGalleryFlow {
    /// The flow the extension runs: the stored key (`client`), the instant share's transport, the owner's settings.
    static func live(link: LinkInfo, client: HTTPCobaltClient, settings: Settings) -> ShareGalleryFlow {
        var engine = InstantShareEngine(transport: URLSessionSaveTransport.current, directory: AppGroup.directory("Saves"))
        engine.makePublic = settings.newSavesPublic
        var env = ShareGalleryEnvironment(server: client, sender: EngineShareSender(engine: engine, client: client))
        env.notify = { job, head, body in await Notifications.postInstantSaving(job: job, title: head, body: body) }
        env.unnotify = { Notifications.removeInstantSaving(job: $0) }
        env.makePublic = settings.newSavesPublic
        env.webpQuality = settings.webpQuality
        env.webpWidth = settings.webpWidth
        return ShareGalleryFlow(link: link, env: env)
    }
}

// MARK: - Previews

/// What a preview of the compact sheet replays. Each one is a post and a server (the posts' item kinds are the board's:
/// the Instagram carousel and the X post are real, the mixed ones synthetic).
public enum ShareGalleryPreview: String, CaseIterable, Sendable {
    /// `instagram.com/p/Ddy0-gpGg5U`: 10 photos, a warm server (the sheet appears complete).
    case instagram
    /// The same post with the server asleep: the checking state, then the rows fill in.
    case instagramCold
    /// `x.com/ilokineedsleep/status/2106850389551374806`: 4 photos.
    case x
    /// 2 photos, a video and a gif.
    case mixed
    /// 1 photo and 1 video: the gallery image row says `needs 2 photos`.
    case photoAndVideo
    /// 6 photos and 2 videos with no sizes known: the webp row says `videos play in full`.
    case manyAndVideos
    /// A server with galleries but no makes, known before the sheet shows: the one-row sheet.
    case noMake
    /// The same server, found out while the sheet is already showing: rows 2-3 stay, disabled.
    case noMakeLate
    /// A server without `features.gallery`: the same-height card.
    case oldServer
    /// No answer from the server at all: the 8 s fallback.
    case noAnswer
    /// A reel: one item, no sheet.
    case reel
    /// A single photo post: one item, no sheet.
    case photo
    /// A reel on a server that takes 5 s to answer: the sheet checks, then closes with `sent to cobalt`.
    case reelSlow
    /// A gallery whose request is refused (the key): the failure inside the same frame.
    case requestRefused

    var kinds: [MediaType] {
        switch self {
        case .instagram, .instagramCold, .noMake, .noMakeLate, .oldServer, .noAnswer, .requestRefused:
            return Array(repeating: .photo, count: 10)
        case .x: return Array(repeating: .photo, count: 4)
        case .mixed: return [.photo, .video, .photo, .gif]
        case .photoAndVideo: return [.photo, .video]
        case .manyAndVideos: return [.photo, .video, .photo, .photo, .video, .photo, .photo, .photo]
        case .reel, .reelSlow: return [.video]
        case .photo: return [.photo]
        }
    }

    var linkText: String {
        switch self {
        case .x: return "https://x.com/ilokineedsleep/status/2106850389551374806"
        case .reel, .reelSlow: return "https://www.instagram.com/reel/Dd7P496wolG/"
        case .photo: return "https://www.instagram.com/p/DbS1ngLePh0/"
        default: return "https://www.instagram.com/p/Ddy0-gpGg5U/"
        }
    }

    /// How long `POST /` takes to answer.
    var resolveDelay: Duration {
        switch self {
        case .instagramCold: return .milliseconds(5200)
        case .reelSlow: return .milliseconds(5000)
        case .noAnswer: return .seconds(3600)
        case .noMakeLate: return .milliseconds(1200)
        default: return .milliseconds(420)
        }
    }
}

extension ShareGalleryFlow {
    /// The flow over a stand-in server, for previews and the debug harness. `holding` keeps the sheet where it is
    /// (the 8 s fallback never fires and a request never completes), so a screenshot can look at one state.
    public static func preview(_ scenario: ShareGalleryPreview, holding: Bool = false) -> ShareGalleryFlow {
        let link = LinkInfo(URL(string: scenario.linkText)!)!
        let items = scenario.kinds.enumerated().map {
            PickerItem(id: $0.offset, type: $0.element, url: URL(string: "https://example.com/\($0.offset)")!)
        }
        let result: CobaltResult = items.count == 1
            ? .file(url: items[0].url, filename: nil) : .picker(items: items, audio: nil)
        var caps = Capabilities.unknown
        caps.kind = .fork
        caps.studio = true
        caps.createNotify = true
        caps.gallery = scenario != .oldServer
        caps.galleryMake = caps.gallery && scenario != .noMake && scenario != .noMakeLate
        let server = PreviewShareServer(result: result, delay: scenario.resolveDelay, capabilities: caps)
        let sender = PreviewShareSender(
            behavior: holding ? .hang : (scenario == .requestRefused ? .fail(.rejected(status: 401)) : .accept))
        var env = ShareGalleryEnvironment(server: server, sender: sender)
        if holding { env.timing.giveUpAfter = .seconds(3600) }
        let flow = ShareGalleryFlow(link: link, env: env)
        flow.begin()
        return flow
    }
}

private struct PreviewShareServer: ShareGalleryServer {
    var result: CobaltResult
    var delay: Duration
    var capabilities: Capabilities

    func resolve(_ link: URL) async throws -> CobaltResult {
        try await Task.sleep(for: delay)
        return result
    }

    func capabilities() async -> Capabilities { capabilities }
}

private struct PreviewShareSender: ShareGallerySender {
    enum Behavior: Sendable { case accept, hang, fail(InstantShare.Failure) }
    var behavior: Behavior

    func send(_ request: ShareSend, job: UUID) async -> InstantShare.Result {
        switch behavior {
        case .accept:
            try? await Task.sleep(for: .milliseconds(400))
            return .saved
        case .hang:
            try? await Task.sleep(for: .seconds(3600))
            return .failed(.couldNotStart)
        case .fail(let failure):
            try? await Task.sleep(for: .milliseconds(400))
            return .failed(failure)
        }
    }
}
