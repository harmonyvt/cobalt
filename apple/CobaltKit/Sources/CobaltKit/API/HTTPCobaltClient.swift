import Foundation
import Synchronization

/// A client that can say what request a download makes, so a background `URLSession` can run it
/// (CONTRACT-OFFLINE.md decision 9). A client that does not conform (`PreviewClient`) is fetched in the foreground
/// with `download`.
public protocol RemoteFileRequests: Sendable {
    func urlRequest(for file: RemoteFile) throws -> URLRequest
}

extension HTTPCobaltClient: RemoteFileRequests {}

/// The real client. Rules (section 4.3): the `Authorization` header goes only to keyed routes and
/// only to `baseURL`'s host; `Accept: application/json` everywhere; long polls time out at
/// `wait + 15` s; `POST /` carries `{"url": …}` and nothing else; a missing key on a keyed route
/// throws `.noAPIKey` before any request.
public struct HTTPCobaltClient: CobaltClient {
    public let baseURL: URL
    let apiKey: @Sendable () -> String?
    let urlSession: URLSession

    public init(baseURL: URL, apiKey: @escaping @Sendable () -> String?, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.urlSession = session
    }

    // MARK: - Request plumbing

    func makeRequest(
        _ method: String, _ path: String, query: [(String, String)] = [],
        keyed: Bool, optionalKey: Bool = false, timeout: TimeInterval = 30
    ) throws -> URLRequest {
        guard var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw CobaltError.invalidResponse(httpStatus: 0)
        }
        let basePath = comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path
        comps.percentEncodedPath = basePath + path
        if !query.isEmpty {
            comps.percentEncodedQuery = query
                .map { "\(Self.encode($0.0))=\(Self.encode($0.1))" }
                .joined(separator: "&")
        }
        guard let url = comps.url else { throw CobaltError.invalidResponse(httpStatus: 0) }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if keyed || optionalKey {
            let key = apiKey()
            if let key, url.host?.lowercased() == baseURL.host?.lowercased(), url.port == baseURL.port {
                req.setValue("Api-Key \(key)", forHTTPHeaderField: "Authorization")
            } else if keyed {
                throw CobaltError.noAPIKey
            }
        }
        return req
    }

    static func encode(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=#?/")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    func send(_ req: URLRequest, body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        var req = req
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await urlSession.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw CobaltError.invalidResponse(httpStatus: 0) }
            return (data, http)
        } catch let e as URLError {
            throw CobaltError.network(e.code)
        }
    }

    func apiError(_ data: Data, status: Int) -> CobaltError {
        if let env = try? JSONDecoder().decode(ErrorEnvelope.self, from: data), let code = env.error?.code {
            return .api(code: code, httpStatus: status)
        }
        return .invalidResponse(httpStatus: status)
    }

    private func sendJSON<T: Decodable>(
        _ type: T.Type, _ req: URLRequest, body: Data? = nil, accept: Range<Int> = 200..<300
    ) async throws -> T {
        let (data, http) = try await send(req, body: body)
        guard accept.contains(http.statusCode) else { throw apiError(data, status: http.statusCode) }
        do { return try CobaltJSON.decoder().decode(T.self, from: data) }
        catch {
            // A 2xx that carries an error envelope is still an error.
            if let env = try? JSONDecoder().decode(ErrorEnvelope.self, from: data), let code = env.error?.code {
                throw CobaltError.api(code: code, httpStatus: http.statusCode)
            }
            throw CobaltError.invalidResponse(httpStatus: http.statusCode)
        }
    }

    static func jsonBody(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - Capability detection (APP-API-CONTRACT section 1)

    public func capabilities() async -> Capabilities {
        // Step 1: GET /capabilities, never following redirects.
        do {
            let req = try makeRequest("GET", "/capabilities", keyed: false, optionalKey: true, timeout: 15)
            let (data, response) = try await urlSession.data(for: req, delegate: NoRedirectDelegate())
            if let http = response as? HTTPURLResponse, http.statusCode == 200,
               let caps = Self.parseForkCapabilities(data) {
                return caps
            }
            // A server error is a bad moment, not a different server: the caller keeps what it knew.
            if let http = response as? HTTPURLResponse, http.statusCode >= 500 { return .unknown }
        } catch {
            return .unknown                                       // unreachable (the last known caps are kept by the caller)
        }

        // Step 2: GET / with Accept: application/json. Plain cobalt answers with its version.
        do {
            let req = try makeRequest("GET", "/", keyed: false, timeout: 15)
            let (data, http) = try await send(req)
            if http.statusCode == 200, let version = Self.plainCobaltVersion(data) {
                var caps = Capabilities.unknown
                caps.kind = .plainCobalt
                caps.cobaltVersion = version
                caps.limits.maxUploadBytes = 0
                caps.key = .unknown
                return caps
            }
            if http.statusCode == 200 { return Self.notCobalt() }
            if http.statusCode != 404 { return Self.notCobalt() }
        } catch {
            return .unknown
        }

        // Step 3: the legacy fork answers an unknown 22-char session id with a JSON 404.
        do {
            let req = try makeRequest("GET", "/studio/0000000000000000000000", keyed: false, timeout: 15)
            let (data, http) = try await send(req)
            if http.statusCode == 404,
               let env = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
               env.error?.code == "error.studio.not_found" {
                var caps = Capabilities.unknown
                caps.kind = .legacyFork
                caps.studio = true
                caps.limits.maxUploadBytes = 0
                caps.key = .unknown
                return caps
            }
            return Self.notCobalt()
        } catch {
            return .unknown
        }
    }

    private static func notCobalt() -> Capabilities {
        var caps = Capabilities.unknown
        caps.kind = .notCobalt
        return caps
    }

    static func plainCobaltVersion(_ data: Data) -> String? {
        struct Root: Decodable { struct Cobalt: Decodable { var version: String? }; var cobalt: Cobalt? }
        return (try? JSONDecoder().decode(Root.self, from: data))?.cobalt?.version
    }

    static func parseForkCapabilities(_ data: Data) -> Capabilities? {
        struct Wire: Decodable {
            struct Cobalt: Decodable { var version: String? }
            struct Features: Decodable {
                var studio: Bool?; var upload: Bool?; var library: Bool?
                var saveProgress: Bool?; var renderProgress: Bool?; var finishesUnpolled: Bool?
                var liveActivityPush: Bool?
                var notifyBridge: Bool?
                var crop: Bool?
                var sourceWait: Bool?
                var deletePost: Bool?
                var telemetry: Bool?
                var createNotify: Bool?
                var titles: Bool?
                var publicDefault: Bool?
                var visibility: Bool?
                var line: Bool?
                var gallery: Bool?
                var galleryMake: Bool?
                var directLinks: Bool?
                var queue: Bool?
                var search: Bool?
                var shareSets: Bool?
                var shareCollections: Bool?
                var shareGroups: Bool?
                var chat: Bool?
                var stage: Bool?
                var stageTwitch: Bool?
                var editor: Bool?
                var editLivePush: Bool?
                var stillWebp: Bool?
            }
            struct Limits: Decodable {
                var maxWebpSeconds: Double?; var minWebpSeconds: Double?; var webpWidths: [Int]?
                var renderFps: Int?; var maxUploadBytes: Int64?; var maxSourceBytes: Int64?
                var sessionTtlMs: Double?
                var lineMax: Int?; var lineWaitMs: Double?
                var shareSetMax: Int?
                var editMaxSeconds: Double?; var editMaxClips: Int?; var editMaxProjects: Int?
                var editPitch: Bool?
            }
            var server: String?
            var cobalt: Cobalt?
            var features: Features?
            var limits: Limits?
            var mediaBaseUrl: String?
            var shareBaseUrl: String?
            var key: String?
            var keyName: String?
        }
        guard let w = try? CobaltJSON.decoder().decode(Wire.self, from: data), w.server == "cobalt-cloudflare" else {
            return nil
        }
        var limits = Capabilities.Limits.fork
        if let l = w.limits {
            limits.maxWebpSeconds = l.maxWebpSeconds ?? limits.maxWebpSeconds
            limits.minWebpSeconds = l.minWebpSeconds ?? limits.minWebpSeconds
            limits.webpWidths = l.webpWidths ?? limits.webpWidths
            limits.renderFPS = l.renderFps ?? limits.renderFPS
            limits.maxUploadBytes = l.maxUploadBytes ?? limits.maxUploadBytes
            limits.maxSourceBytes = l.maxSourceBytes ?? limits.maxSourceBytes
            if let ttl = l.sessionTtlMs { limits.sessionTTL = ttl / 1000 }
            limits.lineMax = l.lineMax ?? limits.lineMax
            if let wait = l.lineWaitMs { limits.lineWait = wait / 1000 }
            limits.shareSetMax = max(ShareSetRule.minimum, l.shareSetMax ?? limits.shareSetMax)
            limits.editMaxSeconds = l.editMaxSeconds ?? limits.editMaxSeconds
            limits.editMaxClips = l.editMaxClips ?? limits.editMaxClips
            limits.editMaxProjects = l.editMaxProjects ?? limits.editMaxProjects
            limits.editPitch = l.editPitch ?? limits.editPitch
        }
        let f = w.features
        var caps = Capabilities(
            kind: .fork,
            cobaltVersion: w.cobalt?.version,
            studio: f?.studio ?? false,
            upload: f?.upload ?? false,
            library: f?.library ?? false,
            saveProgress: f?.saveProgress ?? false,
            renderProgress: f?.renderProgress ?? false,
            finishesUnpolled: f?.finishesUnpolled ?? false,
            limits: limits,
            mediaBaseURL: w.mediaBaseUrl.flatMap(URL.init(string:)),
            key: w.key.flatMap(KeyState.init(rawValue:)) ?? .unknown,
            keyName: w.keyName,
            livePush: f?.liveActivityPush ?? false,
            notifyBridge: f?.notifyBridge ?? false,
            crop: f?.crop ?? false,
            sourceWait: f?.sourceWait ?? false,
            deletePost: f?.deletePost ?? false,
            telemetry: f?.telemetry ?? false,
            createNotify: f?.createNotify ?? false,
            titles: f?.titles ?? false,
            publicDefault: f?.publicDefault ?? false,
            visibility: f?.visibility ?? false,
            line: f?.line ?? false,
            gallery: f?.gallery ?? false,
            galleryMake: (f?.gallery ?? false) && (f?.galleryMake ?? false),
            directLinks: f?.directLinks ?? false,
            queue: f?.queue ?? false)
        caps.search = f?.search ?? false
        caps.shareBaseURL = w.shareBaseUrl.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        caps.shareSets = (f?.shareSets ?? false) && caps.shareBaseURL != nil
        caps.shareCollections = (f?.shareCollections ?? false) && caps.shareSets
        caps.shareGroups = (f?.shareGroups ?? false) && caps.shareCollections
        caps.chat = f?.chat ?? false
        caps.stage = f?.stage ?? false
        caps.stageTwitch = (f?.stageTwitch ?? false) && caps.stage
        caps.editor = f?.editor ?? false
        caps.editLivePush = f?.editLivePush ?? false
        caps.stillWebp = (f?.stillWebp ?? false) && caps.galleryMake
        return caps
    }

    // MARK: - Resolve and studio

    public func resolve(_ link: URL) async throws -> CobaltResult {
        // The key is optional here: plain cobalt on an open instance needs none, and the fork
        // answers 401 `error.api.auth.key.missing`, which maps to the same `.keyMissing`.
        let req = try makeRequest("POST", "/", keyed: false, optionalKey: true)
        let body = Self.jsonBody(["url": link.absoluteString])
        let wire = try await sendJSON(ResolveWire.self, req, body: body)
        switch wire.status {
        case "tunnel", "redirect":
            guard let url = wire.url else { throw CobaltError.invalidResponse(httpStatus: 200) }
            return .file(url: url, filename: wire.filename)
        case "picker":
            let items = (wire.picker ?? []).enumerated().map { index, p in
                PickerItem(id: index, type: p.type.flatMap(MediaType.init(rawValue:)) ?? .photo, url: p.url, thumb: p.thumb)
            }
            return .picker(items: items, audio: wire.audio)
        case "local-processing":
            return .localProcessing
        case "error":
            throw CobaltError.api(code: wire.error?.code ?? "error.api.generic", httpStatus: 200)
        default:
            throw CobaltError.invalidResponse(httpStatus: 200)
        }
    }

    public func createStudio(link: URL) async throws -> StudioCreated {
        try await createStudio(link: link, public: nil)
    }

    /// `public` rides next to `url` (APP-API-CONTRACT 13.2); nil leaves it out, which is "private" for the server.
    public func createStudio(link: URL, public makePublic: Bool?) async throws -> StudioCreated {
        try await createStudio(link: link, public: makePublic, queue: false, title: nil)
    }

    /// `queue: true` (17.3) makes the server answer `201` with `queued` and `queue_ahead` instead of `429
    /// error.studio.busy`; `title` is the post's custom title, stored with the create. Both are left out when nil/false.
    public func createStudio(link: URL, public makePublic: Bool?, queue: Bool, title: String?) async throws -> StudioCreated {
        try await createStudio(url: link, options: StudioCreateOptions(makePublic: makePublic, queue: queue, title: title))
    }

    /// Everything the create takes (APP-API-CONTRACT 13.2, 14.1, 17.3, 18.2, 18.12). The answer's `make` is the chained
    /// make's job (18.12).
    public func createStudio(url: URL, options: StudioCreateOptions) async throws -> StudioCreated {
        let req = try makeRequest("POST", "/studio", keyed: true, timeout: options.isPlain ? 30 : 60)
        let wire = try await sendJSON(IDWire.self, req, body: Self.jsonBody(options.body(link: url)))
        return StudioCreated(
            id: wire.id, pageURL: wire.url.flatMap(URL.init(string:)), queued: wire.queued ?? false, queueAhead: wire.queueAhead,
            make: wire.make.map { StudioMake(job: $0.job, kind: $0.kind) })
    }

    // MARK: - Instant share (APP-API-CONTRACT section 14)

    /// `POST /studio` for a share sheet's background save: the link, `public: true`, `origin: "share"`
    /// and the Hark opt-in for `saved` and `failed`, in one call. The body is returned apart from the
    /// request because a background `URLSession` uploads from a file. Throws `.noAPIKey` without a key
    /// for this server (the extension then shows its one-line card instead of queueing anything).
    ///
    /// `public` is sent when `makePublic` (Settings "make new saves public", on by default); off leaves the
    /// field out and the save stays private.
    public func shareSaveRequest(
        link: URL, label: String, public makePublic: Bool = true, live: ShareLiveStart? = nil
    ) throws -> (request: URLRequest, body: Data) {
        var req = try makeRequest("POST", "/studio", keyed: true, timeout: 60)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var fields: [String: Any] = [
            "url": link.absoluteString, "origin": "share",
            "notify": ["on": ["saved", "failed"], "label": label] as [String: Any],
        ]
        if makePublic { fields["public"] = true }
        if let live { fields["live"] = live.wire }
        guard let body = Self.jsonBody(fields) else { throw CobaltError.invalidResponse(httpStatus: 0) }
        return (req, body)
    }

    /// The share sheet's request for a gallery (APP-API-CONTRACT 18.12): `POST /studio` with whatever `options` carry
    /// (`items: "all"`, `item_count`, `origin: "share"`, the Hark opt-in, and the chained `slideshow` or `gallery_image`),
    /// returned apart from the request for a background `URLSession` like `shareSaveRequest(link:label:public:)`. Throws
    /// `.noAPIKey` without a key for this server.
    public func shareSaveRequest(link: URL, options: StudioCreateOptions) throws -> (request: URLRequest, body: Data) {
        var req = try makeRequest("POST", "/studio", keyed: true, timeout: 60)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let body = Self.jsonBody(options.body(link: link)) else { throw CobaltError.invalidResponse(httpStatus: 0) }
        return (req, body)
    }

    /// `GET /studio/recent` (keyed): the sessions this key created from a share sheet in the last 24
    /// hours, newest first. A server without the route answers 404, which throws.
    public func recentShares(since: Date? = nil, limit: Int = 25) async throws -> [StudioSession] {
        var query = [("limit", String(max(1, min(25, limit))))]
        if let since { query.append(("since", String(Int64((since.timeIntervalSince1970 * 1000).rounded())))) }
        let req = try makeRequest("GET", "/studio/recent", query: query, keyed: true, timeout: 20)
        struct Wire: Decodable { var sessions: [Lossy<StudioSession>] }
        let wire = try await sendJSON(Wire.self, req)
        return wire.sessions.compactMap(\.value)
    }

    public func upload(
        file: URL, name: String, contentType: String,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> UploadResult {
        try await upload(file: file, name: name, contentType: contentType, public: nil, progress: progress)
    }

    /// `?public=1` asks for a public link as soon as the file is stored (APP-API-CONTRACT 13.2).
    public func upload(
        file: URL, name: String, contentType: String, public makePublic: Bool?,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> UploadResult {
        try await upload(file: file, name: name, contentType: contentType, public: makePublic, queue: false, title: nil, progress: progress)
    }

    /// `?queue=1` (17.3): an adopt that finds the server busy joins its line (`queued`, `queue_ahead`) instead of
    /// answering `studio_error`. `?title=` is the post's custom title.
    public func upload(
        file: URL, name: String, contentType: String, public makePublic: Bool?, queue: Bool, title: String?,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> UploadResult {
        var query = [("name", name)]
        if makePublic == true { query.append(("public", "1")) }
        if queue { query.append(("queue", "1")) }
        if let title { query.append(("title", title)) }
        var req = try makeRequest("PUT", "/studio/upload", query: query, keyed: true, timeout: 120)
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let delegate = ProgressDelegate(progress)
        defer { delegate.finish() }
        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, r) = try await urlSession.upload(for: req, fromFile: file, delegate: delegate)
            guard let h = r as? HTTPURLResponse else { throw CobaltError.invalidResponse(httpStatus: 0) }
            data = d; http = h
        } catch let e as URLError {
            throw CobaltError.network(e.code)
        }
        guard http.statusCode == 201 || http.statusCode == 200 else { throw apiError(data, status: http.statusCode) }
        guard let wire = try? CobaltJSON.decoder().decode(UploadWire.self, from: data) else {
            throw CobaltError.invalidResponse(httpStatus: http.statusCode)
        }
        // The server may answer without `item` when it stored the file but could not read the row
        // back (APP-API-CONTRACT section 3 shows an object; app-routes.ts can send null). Then the
        // item id is unknown: an empty id says so and the pipeline avoids routes that need it.
        let size = ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.int64Value
        let item = wire.item ?? LibraryFile(
            id: "", kind: .private, source: .upload, name: name, url: nil, contentType: contentType, bytes: size,
            width: nil, height: nil, duration: nil, createdAt: Date(), mediaName: nil, deletable: false)
        return UploadResult(
            sessionID: wire.id, item: item, studioErrorCode: wire.studioError?.code,
            queued: wire.queued ?? false, queueAhead: wire.queueAhead)
    }

    public func session(_ id: String, wait: Int) async throws -> StudioSession {
        let w = max(0, min(25, wait))
        let req = try makeRequest("GET", "/studio/\(id)", query: [("wait", String(w))], keyed: false, timeout: TimeInterval(w + 15))
        return try await sendJSON(StudioSession.self, req)
    }

    public func sourceURL(session id: String) -> URL {
        (try? makeRequest("GET", "/studio/\(id)/source", keyed: false).url)
            ?? baseURL.appendingPathComponent("studio/\(id)/source")
    }

    public func render(session id: String, _ request: RenderRequest) async throws -> String {
        let req = try makeRequest("POST", "/studio/\(id)/render", keyed: false)
        // Whole-frame crops are never sent: absent means no crop, and the server knows nothing else.
        var fields: [String: Any] = [
            "start": request.start, "length": request.length,
            "width": request.width, "quality": request.quality.rawValue,
        ]
        if request.notify { fields["notify"] = true }
        if let item = request.item { fields["item"] = item }                          // 18.13: the lead when absent
        if let crop = request.crop, !crop.isFull { fields["crop"] = crop.wire }
        if request.queue == true {
            fields["queue"] = true
            if let priority = request.priority { fields["priority"] = priority }      // only valid with `queue`
        }
        return try await sendJSON(JobWire.self, req, body: Self.jsonBody(fields)).job
    }

    public func renderStatus(session id: String, job: String, wait: Int) async throws -> RenderStatus {
        let w = max(0, min(25, wait))
        let req = try makeRequest("GET", "/studio/\(id)/render/\(job)", query: [("wait", String(w))], keyed: false, timeout: TimeInterval(w + 15))
        let wire = try await sendJSON(RenderWire.self, req)
        switch wire.status {
        case "pending":
            return .pending(
                phase: wire.phase.flatMap(RenderPhase.init(rawValue:)), framesDone: wire.framesDone,
                framesTotal: wire.framesTotal, queueAhead: wire.queueAhead)
        case "success":
            guard let url = wire.url, let bytes = wire.bytes, let width = wire.width, let height = wire.height, let seconds = wire.seconds
            else { throw CobaltError.invalidResponse(httpStatus: 200) }
            return .success(WebpResult(job: wire.job ?? job, url: url, bytes: bytes, width: width, height: height, seconds: seconds))
        default:
            return .failed(code: wire.error?.code ?? "error.api.generic")
        }
    }

    public func publish(session id: String) async throws -> HostedFile {
        let req = try makeRequest("POST", "/studio/\(id)/publish", keyed: true)
        return try await hosted(req)
    }

    public func publish(item id: String) async throws -> HostedFile {
        let req = try makeRequest("POST", "/library/items/\(id)/publish", keyed: true)
        return try await hosted(req)
    }

    private func hosted(_ req: URLRequest) async throws -> HostedFile {
        let wire = try await sendJSON(PublishWire.self, req)
        return HostedFile(url: wire.url, bytes: wire.bytes, contentType: wire.contentType, itemID: wire.itemId)
    }

    public func openStudio(item id: String) async throws -> StudioCreated {
        try await openStudio(item: id, queue: false)
    }

    /// `?queue=1` (17.3): a busy server queues the reopened session instead of answering `429`.
    public func openStudio(item id: String, queue: Bool) async throws -> StudioCreated {
        let req = try makeRequest("POST", "/library/items/\(id)/studio", query: queue ? [("queue", "1")] : [], keyed: true)
        let wire = try await sendJSON(IDWire.self, req)
        return StudioCreated(
            id: wire.id, pageURL: wire.url.flatMap(URL.init(string:)), queued: wire.queued ?? false, queueAhead: wire.queueAhead)
    }

    public func library(cursor: String?, limit: Int) async throws -> LibraryPage {
        try await library(cursor: cursor, limit: limit, v2: false)
    }

    /// `v=2`: one entry per file, each with its `visibility` (APP-API-CONTRACT 16.5). Without it the server answers
    /// the shape older apps know (an original, and a synthesized hosted copy after a public one).
    public func library(cursor: String?, limit: Int, v2: Bool) async throws -> LibraryPage {
        try await library(cursor: cursor, limit: limit, version: v2 ? 2 : nil)
    }

    /// `v=3` (APP-API-CONTRACT 18.3): `v=2` plus a gallery's items and made files, each post's `kind` and item counts.
    public func library(cursor: String?, limit: Int, v3: Bool) async throws -> LibraryPage {
        try await library(cursor: cursor, limit: limit, version: v3 ? 3 : nil)
    }

    private func library(cursor: String?, limit: Int, version: Int?) async throws -> LibraryPage {
        var query = [("limit", String(max(1, min(50, limit))))]
        if let cursor { query.append(("cursor", cursor)) }
        if let version { query.append(("v", String(version))) }
        let req = try makeRequest("GET", "/library", query: query, keyed: true)
        let wire = try await sendJSON(LibraryWire.self, req)
        let posts = wire.posts.compactMap(\.value)
        return LibraryPage(
            posts: posts, postCount: wire.counts?.posts ?? posts.count,
            fileCount: wire.counts?.files ?? posts.reduce(0) { $0 + $1.files.count },
            publicBytes: wire.usage?.publicBytes ?? 0, privateBytes: wire.usage?.privateBytes ?? 0,
            next: wire.next)
    }

    /// `PATCH /library/items/<id>/visibility` (keyed): 200 → the file as it is now and `cache_cleared`;
    /// `409 error.library.not_toggleable` → `.unsupported`; any other error as the keyed calls throw it.
    public func setVisibility(item id: String, public makePublic: Bool) async throws -> VisibilityChange {
        let req = try makeRequest("PATCH", "/library/items/\(Self.encode(id))/visibility", keyed: true, timeout: 60)
        let wire = try await sendJSON(VisibilityWire.self, req, body: Self.jsonBody(["public": makePublic]))
        return VisibilityChange(file: wire.item, cacheCleared: wire.cacheCleared)
    }

    public func searchEmotes(query: String) async throws -> [EmoteHit] {
        let req = try makeRequest("GET", "/emotes", query: [("q", query)], keyed: true)
        return try await sendJSON(EmoteListWire.self, req).items
    }

    public func saveEmote(id: String) async throws -> SavedEmote {
        let req = try makeRequest("POST", "/emotes", keyed: true)
        return try await sendJSON(SavedEmote.self, req, body: Self.jsonBody(["id": id]))
    }

    // MARK: - Library search (APP-API-CONTRACT 21; `features.search`)

    /// `GET /library/search?q=&limit=&v=` (keyed): the posts best first, each decoded as `GET /library` decodes it,
    /// plus its `score`. Errors as the keyed calls throw them: `503 error.search.waking` / `error.search.off`,
    /// `502 error.search.failed` and `400 error.library.bad_request` are `CobaltError.api(code:httpStatus:)`.
    public func librarySearch(query: String, limit: Int, version: Int?) async throws -> LibrarySearchResult {
        var params = [("q", String(query.prefix(200))), ("limit", String(max(1, min(50, limit))))]
        if let version, version == 2 || version == 3 { params.append(("v", String(version))) }
        let req = try makeRequest("GET", "/library/search", query: params, keyed: true, timeout: 30)
        let (data, http) = try await send(req)
        guard (200..<300).contains(http.statusCode) else { throw apiError(data, status: http.statusCode) }
        do {
            return try LibrarySearchWire.decode(data, asked: query)
        } catch {
            if let env = try? JSONDecoder().decode(ErrorEnvelope.self, from: data), let code = env.error?.code {
                throw CobaltError.api(code: code, httpStatus: http.statusCode)
            }
            throw CobaltError.invalidResponse(httpStatus: http.statusCode)
        }
    }

    /// `GET /library/search/post?key=<post key>` (keyed): how one post sits in the index. `404 error.library.not_found`
    /// is `CobaltError.api`.
    public func librarySearchStatus(postKey: String) async throws -> LibrarySearchStatus {
        let req = try makeRequest("GET", "/library/search/post", query: [("key", postKey)], keyed: true, timeout: 20)
        return try await sendJSON(LibrarySearchStatus.self, req)
    }

    /// `GET /library/map` (keyed): the embedded posts with their vectors, newest first. Errors as the keyed calls throw
    /// them (`503 error.api.generic` is `CobaltError.api(code:httpStatus:)`); a body that is not the map is
    /// `CobaltError.invalidResponse`. Posts with no readable vector are dropped, not an error.
    public func libraryMap() async throws -> LibraryMap {
        let req = try makeRequest("GET", "/library/map", keyed: true, timeout: 30)
        let (data, http) = try await send(req)
        guard (200..<300).contains(http.statusCode) else { throw apiError(data, status: http.statusCode) }
        do {
            return try LibraryMap.decode(data)
        } catch {
            if let env = try? JSONDecoder().decode(ErrorEnvelope.self, from: data), let code = env.error?.code {
                throw CobaltError.api(code: code, httpStatus: http.statusCode)
            }
            throw CobaltError.invalidResponse(httpStatus: http.statusCode)
        }
    }

    // MARK: - Gallery share links (APP-API-CONTRACT 24; `features.share_sets`; keyed)

    /// `POST /share/sets` `{items, title?}` (keyed): one link for 2..`share_set_max` public files, in the order given.
    /// `409 error.share.not_public` is `ShareSetError.notPublic(ids)` (the ids missing or private), `400
    /// error.share.bad_request` is `.badRequest`, `503` is `.unavailable`.
    public func createShareSet(items: [String], title: String?) async throws -> ShareSet {
        let req = try makeRequest("POST", "/share/sets", keyed: true, timeout: 30)
        var body: [String: Any] = ["items": items]
        if let title { body["title"] = title }
        let (data, http) = try await send(req, body: Self.jsonBody(body))
        guard (200..<300).contains(http.statusCode) else { throw shareSetError(data, status: http.statusCode) }
        struct Wire: Decodable { var set: ShareSet }
        guard let wire = try? CobaltJSON.decoder().decode(Wire.self, from: data) else {
            throw CobaltError.invalidResponse(httpStatus: http.statusCode)
        }
        return wire.set
    }

    /// `GET /share/sets` (keyed): the live sets, newest first.
    public func shareSets() async throws -> [ShareSet] {
        let req = try makeRequest("GET", "/share/sets", keyed: true, timeout: 20)
        let (data, http) = try await send(req)
        guard (200..<300).contains(http.statusCode) else { throw shareSetError(data, status: http.statusCode) }
        struct Wire: Decodable { var sets: [Lossy<ShareSet>] }
        guard let wire = try? CobaltJSON.decoder().decode(Wire.self, from: data) else {
            throw CobaltError.invalidResponse(httpStatus: http.statusCode)
        }
        return wire.sets.compactMap(\.value)
    }

    /// `DELETE /share/sets/<id>` (keyed): the link is a 404 at once. A repeat is 200; an unknown id is `.notFound`.
    public func revokeShareSet(id: String) async throws {
        let req = try makeRequest("DELETE", "/share/sets/\(Self.encode(id))", keyed: true, timeout: 20)
        let (data, http) = try await send(req)
        guard (200..<300).contains(http.statusCode) else { throw shareSetError(data, status: http.statusCode) }
    }

    /// The share routes' refusals as `ShareSetError`; any other code stays the generic `CobaltError.api`.
    private func shareSetError(_ data: Data, status: Int) -> Error {
        struct Body: Decodable {
            struct Err: Decodable { var code: String? }
            var error: Err?
            var items: [String]?
        }
        let body = try? JSONDecoder().decode(Body.self, from: data)
        switch body?.error?.code {
        case "error.share.not_public": return ShareSetError.notPublic(body?.items ?? [])
        case "error.share.bad_request": return ShareSetError.badRequest
        case "error.share.not_found": return ShareSetError.notFound
        default:
            if status == 503 { return ShareSetError.unavailable }
            return apiError(data, status: status)
        }
    }

    // MARK: - Share link collections (APP-API-CONTRACT 26; `features.share_collections`; keyed)

    /// `GET /share/collections` (keyed): the collections, most recently changed first.
    public func shareCollections() async throws -> [ShareCollection] {
        let req = try makeRequest("GET", "/share/collections", keyed: true, timeout: 20)
        let (data, http) = try await send(req)
        guard (200..<300).contains(http.statusCode) else { throw shareCollectionError(data, status: http.statusCode) }
        struct Wire: Decodable { var collections: [Lossy<ShareCollection>] }
        guard let wire = try? CobaltJSON.decoder().decode(Wire.self, from: data) else {
            throw CobaltError.invalidResponse(httpStatus: http.statusCode)
        }
        return wire.collections.compactMap(\.value)
    }

    /// `POST /share/collections` `{name, set_ids?}` (keyed): `set_ids` is left out when empty.
    public func createShareCollection(name: String, setIDs: [String]) async throws -> ShareCollection {
        let req = try makeRequest("POST", "/share/collections", keyed: true, timeout: 30)
        var body: [String: Any] = ["name": name]
        if !setIDs.isEmpty { body["set_ids"] = setIDs }
        let (data, http) = try await send(req, body: Self.jsonBody(body))
        return try shareCollectionAnswer(data, http)
    }

    /// `PATCH /share/collections/<id>` `{name?, add?, remove?}` (keyed): only what is given is sent.
    public func updateShareCollection(id: String, name: String?, add: [String], remove: [String]) async throws -> ShareCollection {
        let req = try makeRequest("PATCH", "/share/collections/\(Self.encode(id))", keyed: true, timeout: 30)
        var body: [String: Any] = [:]
        if let name { body["name"] = name }
        if !add.isEmpty { body["add"] = add }
        if !remove.isEmpty { body["remove"] = remove }
        let (data, http) = try await send(req, body: Self.jsonBody(body))
        return try shareCollectionAnswer(data, http)
    }

    /// `DELETE /share/collections/<id>` (keyed): the folder only; its links keep working.
    public func deleteShareCollection(id: String) async throws {
        let req = try makeRequest("DELETE", "/share/collections/\(Self.encode(id))", keyed: true, timeout: 20)
        let (data, http) = try await send(req)
        guard (200..<300).contains(http.statusCode) else { throw shareCollectionError(data, status: http.statusCode) }
    }

    /// `POST /share/collections/<id>/reroll` (keyed, no body): `{collection, replaced}`.
    public func rerollShareCollection(id: String) async throws -> ShareCollectionReroll {
        let req = try makeRequest("POST", "/share/collections/\(Self.encode(id))/reroll", keyed: true, timeout: 60)
        let (data, http) = try await send(req)
        guard (200..<300).contains(http.statusCode) else { throw shareCollectionError(data, status: http.statusCode) }
        guard let answer = try? CobaltJSON.decoder().decode(ShareCollectionReroll.self, from: data) else {
            throw CobaltError.invalidResponse(httpStatus: http.statusCode)
        }
        return answer
    }

    private func shareCollectionAnswer(_ data: Data, _ http: HTTPURLResponse) throws -> ShareCollection {
        guard (200..<300).contains(http.statusCode) else { throw shareCollectionError(data, status: http.statusCode) }
        struct Wire: Decodable { var collection: ShareCollection }
        guard let wire = try? CobaltJSON.decoder().decode(Wire.self, from: data) else {
            throw CobaltError.invalidResponse(httpStatus: http.statusCode)
        }
        return wire.collection
    }

    /// The collection routes' refusals as `ShareCollectionError`; any other code stays the generic `CobaltError.api`.
    /// (`404 error.share.off` is the generic one: the share host is not set up.)
    private func shareCollectionError(_ data: Data, status: Int) -> Error {
        struct Body: Decodable {
            struct Err: Decodable { var code: String? }
            var error: Err?
            var setIds: [String]?
        }
        let body = try? CobaltJSON.decoder().decode(Body.self, from: data)
        switch body?.error?.code {
        case "error.collection.bad_request": return ShareCollectionError.badRequest
        case "error.collection.not_found": return ShareCollectionError.notFound
        case "error.collection.link_not_found": return ShareCollectionError.linkNotFound(body?.setIds ?? [])
        case "error.collection.too_many": return ShareCollectionError.tooMany
        case "error.collection.full": return ShareCollectionError.full
        case "error.collection.empty": return ShareCollectionError.empty
        default:
            if status == 503 { return ShareCollectionError.unavailable }
            return apiError(data, status: status)
        }
    }

    // MARK: - Collection sets (APP-API-CONTRACT 28; `features.share_groups`; keyed)

    /// `GET /share/groups` (keyed): the groups, most recently changed first.
    public func collectionGroups() async throws -> [CollectionGroup] {
        let req = try makeRequest("GET", "/share/groups", keyed: true, timeout: 20)
        let (data, http) = try await send(req)
        guard (200..<300).contains(http.statusCode) else { throw collectionGroupError(data, status: http.statusCode) }
        struct Wire: Decodable { var groups: [Lossy<CollectionGroup>] }
        guard let wire = try? CobaltJSON.decoder().decode(Wire.self, from: data) else {
            throw CobaltError.invalidResponse(httpStatus: http.statusCode)
        }
        return wire.groups.compactMap(\.value)
    }

    /// `POST /share/groups` `{name, collection_ids?}` (keyed): `collection_ids` is left out when empty.
    public func createCollectionGroup(name: String, collectionIDs: [String]) async throws -> CollectionGroup {
        let req = try makeRequest("POST", "/share/groups", keyed: true, timeout: 30)
        var body: [String: Any] = ["name": name]
        if !collectionIDs.isEmpty { body["collection_ids"] = collectionIDs }
        let (data, http) = try await send(req, body: Self.jsonBody(body))
        return try collectionGroupAnswer(data, http)
    }

    /// `PATCH /share/groups/<id>` `{name?, add?, remove?}` (keyed): only what is given is sent.
    public func updateCollectionGroup(id: String, name: String?, add: [String], remove: [String]) async throws -> CollectionGroup {
        let req = try makeRequest("PATCH", "/share/groups/\(Self.encode(id))", keyed: true, timeout: 30)
        var body: [String: Any] = [:]
        if let name { body["name"] = name }
        if !add.isEmpty { body["add"] = add }
        if !remove.isEmpty { body["remove"] = remove }
        let (data, http) = try await send(req, body: Self.jsonBody(body))
        return try collectionGroupAnswer(data, http)
    }

    /// `DELETE /share/groups/<id>` (keyed): the group only; its collections and links stay.
    public func deleteCollectionGroup(id: String) async throws {
        let req = try makeRequest("DELETE", "/share/groups/\(Self.encode(id))", keyed: true, timeout: 20)
        let (data, http) = try await send(req)
        guard (200..<300).contains(http.statusCode) else { throw collectionGroupError(data, status: http.statusCode) }
    }

    private func collectionGroupAnswer(_ data: Data, _ http: HTTPURLResponse) throws -> CollectionGroup {
        guard (200..<300).contains(http.statusCode) else { throw collectionGroupError(data, status: http.statusCode) }
        struct Wire: Decodable { var group: CollectionGroup }
        guard let wire = try? CobaltJSON.decoder().decode(Wire.self, from: data) else {
            throw CobaltError.invalidResponse(httpStatus: http.statusCode)
        }
        return wire.group
    }

    /// The group routes' refusals as `CollectionGroupError`; any other code stays the generic `CobaltError.api`.
    /// (`404 error.share.off` is the generic one: the share host is not set up.)
    private func collectionGroupError(_ data: Data, status: Int) -> Error {
        struct Body: Decodable {
            struct Err: Decodable { var code: String? }
            var error: Err?
            var collectionIds: [String]?
        }
        let body = try? CobaltJSON.decoder().decode(Body.self, from: data)
        switch body?.error?.code {
        case "error.group.bad_request": return CollectionGroupError.badRequest
        case "error.group.not_found": return CollectionGroupError.notFound
        case "error.group.collection_not_found": return CollectionGroupError.collectionNotFound(body?.collectionIds ?? [])
        case "error.group.too_many": return CollectionGroupError.tooMany
        case "error.group.full": return CollectionGroupError.full
        default:
            if status == 503 { return CollectionGroupError.unavailable }
            return apiError(data, status: status)
        }
    }

    // MARK: - Chat (APP-API-CONTRACT 27; `features.chat`; keyed)

    /// `GET /chat/threads` (keyed): most recently updated first (at most 200).
    public func chatThreads() async throws -> [ChatThread] {
        let req = try makeRequest("GET", "/chat/threads", keyed: true, timeout: 20)
        let (data, http) = try await send(req)
        guard (200..<300).contains(http.statusCode) else { throw chatError(data, status: http.statusCode) }
        struct Wire: Decodable { var threads: [Lossy<ChatThread>] }
        guard let wire = try? CobaltJSON.decoder().decode(Wire.self, from: data) else {
            throw CobaltError.invalidResponse(httpStatus: http.statusCode)
        }
        return wire.threads.compactMap(\.value)
    }

    /// `POST /chat/threads` `{title?}` (keyed): `201` with the thread. The field is left out for a nil title.
    public func createChatThread(title: String?) async throws -> ChatThread {
        let req = try makeRequest("POST", "/chat/threads", keyed: true, timeout: 30)
        var body: [String: Any] = [:]
        if let title { body["title"] = title }
        let (data, http) = try await send(req, body: Self.jsonBody(body))
        return try chatThreadAnswer(data, http)
    }

    /// `GET /chat/threads/<id>` (keyed): the thread, its messages (oldest first) and the `posts` map.
    public func chatThread(id: String) async throws -> ChatThreadDetail {
        let req = try makeRequest("GET", "/chat/threads/\(Self.encode(id))", keyed: true, timeout: 30)
        let (data, http) = try await send(req)
        guard (200..<300).contains(http.statusCode) else { throw chatError(data, status: http.statusCode) }
        guard let detail = try? CobaltJSON.decoder().decode(ChatThreadDetail.self, from: data) else {
            throw CobaltError.invalidResponse(httpStatus: http.statusCode)
        }
        return detail
    }

    /// `PATCH /chat/threads/<id>` `{title}` (keyed): the thread as it is now.
    public func renameChatThread(id: String, title: String) async throws -> ChatThread {
        let req = try makeRequest("PATCH", "/chat/threads/\(Self.encode(id))", keyed: true, timeout: 30)
        let (data, http) = try await send(req, body: Self.jsonBody(["title": title]))
        return try chatThreadAnswer(data, http)
    }

    /// `DELETE /chat/threads/<id>` (keyed): the thread and its messages.
    public func deleteChatThread(id: String) async throws {
        let req = try makeRequest("DELETE", "/chat/threads/\(Self.encode(id))", keyed: true, timeout: 20)
        let (data, http) = try await send(req)
        guard (200..<300).contains(http.statusCode) else { throw chatError(data, status: http.statusCode) }
    }

    /// `POST /chat/threads/<id>/messages` `{text, post_ids?}` (keyed), answered as `text/event-stream`. The bytes go through
    /// `ChatSSEParser` as they arrive. A refusal before the stream (the status is not 2xx) finishes the stream with the
    /// `ChatError` and no event; a transport failure at any point finishes it with `CobaltError.network`. Dropping the
    /// consumer cancels the request.
    public func sendChatMessage(threadID: String, text: String, postIDs: [String]) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = try makeRequest("POST", "/chat/threads/\(Self.encode(threadID))/messages", keyed: true, timeout: 90)
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    var body: [String: Any] = ["text": text]
                    if !postIDs.isEmpty { body["post_ids"] = postIDs }
                    req.httpBody = Self.jsonBody(body)
                    let (bytes, response) = try await urlSession.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else { throw CobaltError.invalidResponse(httpStatus: 0) }
                    guard (200..<300).contains(http.statusCode) else {
                        var data = Data()
                        for try await byte in bytes {
                            data.append(byte)
                            if data.count >= 16_384 { break }
                        }
                        throw chatError(data, status: http.statusCode)
                    }
                    var parser = ChatSSEParser()
                    var line: [UInt8] = []
                    for try await byte in bytes {
                        line.append(byte)
                        if byte == 0x0A {                      // a whole line at a time
                            for event in parser.feed(line) { continuation.yield(event) }
                            line.removeAll(keepingCapacity: true)
                        }
                    }
                    for event in parser.feed(line) { continuation.yield(event) }
                    for event in parser.finish() { continuation.yield(event) }
                    continuation.finish()
                } catch let e as URLError {
                    continuation.finish(throwing: e.code == .cancelled ? CancellationError() : CobaltError.network(e.code))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `GET /chat/threads/<id>/messages/<message id>/collage?offset=&limit=` (keyed, 27.5): a page of the collage a reply
    /// attached. The limit is held to 1...60 and the offset to 0 or more before it is sent.
    public func chatCollage(threadID: String, messageID: String, offset: Int, limit: Int) async throws -> ChatCollagePage {
        let query = [("offset", String(max(0, offset))), ("limit", String(max(1, min(60, limit))))]
        let path = "/chat/threads/\(Self.encode(threadID))/messages/\(Self.encode(messageID))/collage"
        let req = try makeRequest("GET", path, query: query, keyed: true, timeout: 30)
        let (data, http) = try await send(req)
        guard (200..<300).contains(http.statusCode) else { throw chatError(data, status: http.statusCode) }
        guard let page = try? CobaltJSON.decoder().decode(ChatCollagePage.self, from: data) else {
            throw CobaltError.invalidResponse(httpStatus: http.statusCode)
        }
        return page
    }

    private func chatThreadAnswer(_ data: Data, _ http: HTTPURLResponse) throws -> ChatThread {
        guard (200..<300).contains(http.statusCode) else { throw chatError(data, status: http.statusCode) }
        struct Wire: Decodable { var thread: ChatThread }
        guard let wire = try? CobaltJSON.decoder().decode(Wire.self, from: data) else {
            throw CobaltError.invalidResponse(httpStatus: http.statusCode)
        }
        return wire.thread
    }

    /// The chat routes' refusals as `ChatError`; any other code stays the generic `CobaltError.api`.
    private func chatError(_ data: Data, status: Int) -> Error {
        if let env = try? JSONDecoder().decode(ErrorEnvelope.self, from: data), let code = env.error?.code,
           let known = ChatError(code: code) {
            return known
        }
        if status == 503 { return ChatError.unavailable }
        return apiError(data, status: status)
    }

    public func deleteMedia(name: String) async throws {
        let req = try makeRequest("DELETE", "/media/\(Self.encode(name))", keyed: true)
        let (data, http) = try await send(req)
        guard (200..<300).contains(http.statusCode) else { throw apiError(data, status: http.statusCode) }
    }

    /// `DELETE /library/items/<id>/post` (CONTRACT-MEDIA 6.1; keyed). 200 → the result; `502
    /// error.library.partial` → the result decoded from the error body (the files that went stay
    /// gone, the call is idempotent); `409 error.library.busy` → `CobaltError.api`, which maps to
    /// `PipelineFailure.serverBusy`; 404 → `PipelineFailure.expired` (the post is already gone).
    public func deletePost(anchor itemID: String) async throws -> PostDeleteResult {
        let req = try makeRequest("DELETE", "/library/items/\(Self.encode(itemID))/post", keyed: true)
        let (data, http) = try await send(req)
        switch http.statusCode {
        case 200..<300:
            guard let result = try? CobaltJSON.decoder().decode(PostDeleteResult.self, from: data) else {
                throw CobaltError.invalidResponse(httpStatus: http.statusCode)
            }
            return result
        case 404:
            throw PipelineFailure.expired
        case 502:
            if let env = try? JSONDecoder().decode(ErrorEnvelope.self, from: data), env.error?.code == "error.library.partial",
               let result = try? CobaltJSON.decoder().decode(PostDeleteResult.self, from: data) {
                return result
            }
            throw apiError(data, status: http.statusCode)
        default:
            throw apiError(data, status: http.statusCode)
        }
    }

    // MARK: - Galleries and made files (APP-API-CONTRACT 18.4, 18.5, 18.10-18.12; keyed)

    public func makeSlideshow(
        session: String, plan: SlideshowPlan, items: [GalleryItem], focused: Bool, notify: Bool
    ) async throws -> RenderAccepted {
        let req = try makeRequest("POST", "/studio/\(Self.encode(session))/slideshow", keyed: true, timeout: 30)
        let body = plan.wireBody(items: items, includesQueue: true, focused: focused, notify: notify)
        let wire = try await sendJSON(JobWire.self, req, body: Self.jsonBody(body))
        return RenderAccepted(job: wire.job, queued: wire.queued ?? false, queueAhead: wire.queueAhead)
    }

    public func makeGalleryImage(
        session: String, plan: GalleryImagePlan, focused: Bool, notify: Bool
    ) async throws -> RenderAccepted {
        let req = try makeRequest("POST", "/studio/\(Self.encode(session))/gallery-image", keyed: true, timeout: 30)
        let body = plan.wireBody(items: [], includesQueue: true, focused: focused, notify: notify)
        let wire = try await sendJSON(JobWire.self, req, body: Self.jsonBody(body))
        return RenderAccepted(job: wire.job, queued: wire.queued ?? false, queueAhead: wire.queueAhead)
    }

    public func makeStatus(session: String, job: String, wait: Int) async throws -> MakeStatus {
        let w = max(0, min(25, wait))
        let req = try makeRequest(
            "GET", "/studio/\(Self.encode(session))/render/\(Self.encode(job))", query: [("wait", String(w))], keyed: false,
            timeout: TimeInterval(w + 15))
        let wire = try await sendJSON(MakeWire.self, req)
        switch wire.status {
        case "pending":
            return .pending(
                phase: wire.phase.flatMap(MakePhase.init(rawValue:)), done: wire.framesDone, total: wire.framesTotal,
                queueAhead: wire.queueAhead)
        case "success":
            return .success(MadeResult(
                job: wire.job ?? job, itemID: wire.itemId, url: wire.url, bytes: wire.bytes, width: wire.width, height: wire.height,
                seconds: wire.seconds, format: wire.format.flatMap(SlideshowPlan.Format.init(rawValue:)),
                cropped: wire.cropped ?? [], upscaled: wire.upscaled ?? [], replaced: wire.replaced ?? []))
        default:
            return .failed(code: wire.error?.code ?? "error.api.generic")
        }
    }

    public func retryItems(session: String, items: [Int]) async throws -> StudioCreated {
        let req = try makeRequest("POST", "/studio/\(Self.encode(session))/items/retry", keyed: true, timeout: 30)
        let wire = try await sendJSON(IDWire.self, req, body: Self.jsonBody(["items": items, "queue": true] as [String: Any]))
        return StudioCreated(
            id: wire.id.isEmpty ? session : wire.id, pageURL: wire.url.flatMap(URL.init(string:)), queued: wire.queued ?? false,
            queueAhead: wire.queueAhead)
    }

    public func deleteItem(_ itemID: String) async throws {
        let req = try makeRequest("DELETE", "/library/items/\(Self.encode(itemID))", keyed: true)
        let (data, http) = try await send(req)
        guard (200..<300).contains(http.statusCode) else { throw apiError(data, status: http.statusCode) }
    }

    /// `PUT /library/items/<id>/made?role=&name=&spec=` (18.6): the body is the file, streamed; `201` answers the new row.
    public func uploadMade(
        item itemID: String, role: GalleryRole, file: URL, contentType: String, name: String, spec: Data,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> MadeUpload {
        let query = [("role", role.rawValue), ("name", name), ("spec", String(decoding: spec, as: UTF8.self))]
        var req = try makeRequest("PUT", "/library/items/\(Self.encode(itemID))/made", query: query, keyed: true, timeout: 120)
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let delegate = ProgressDelegate(progress)
        defer { delegate.finish() }
        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, r) = try await urlSession.upload(for: req, fromFile: file, delegate: delegate)
            guard let h = r as? HTTPURLResponse else { throw CobaltError.invalidResponse(httpStatus: 0) }
            data = d; http = h
        } catch let e as URLError {
            throw CobaltError.network(e.code)
        }
        guard http.statusCode == 201 || http.statusCode == 200 else { throw apiError(data, status: http.statusCode) }
        guard let wire = try? CobaltJSON.decoder().decode(MadeWire.self, from: data), let item = wire.item else {
            throw CobaltError.invalidResponse(httpStatus: http.statusCode)
        }
        return MadeUpload(file: item, replaced: wire.replaced ?? [])
    }

    /// `200` → every file; `502 error.library.partial` → the files that switched and the ids that did not (a retry is
    /// idempotent); any other error as the keyed calls throw it.
    public func setPostVisibility(anchor itemID: String, public makePublic: Bool) async throws -> VisibilityResult {
        let req = try makeRequest("PATCH", "/library/items/\(Self.encode(itemID))/visibility", keyed: true, timeout: 120)
        let body = Self.jsonBody(["public": makePublic, "scope": "post"] as [String: Any])
        let (data, http) = try await send(req, body: body)
        let decode: () -> VisibilityResult? = {
            guard let wire = try? CobaltJSON.decoder().decode(PostVisibilityWire.self, from: data) else { return nil }
            return VisibilityResult(
                files: (wire.items ?? []).compactMap(\.value), cacheCleared: wire.cacheCleared, remaining: wire.remaining ?? [])
        }
        switch http.statusCode {
        case 200..<300:
            guard let result = decode() else { throw CobaltError.invalidResponse(httpStatus: http.statusCode) }
            return result
        case 502:
            if let env = try? JSONDecoder().decode(ErrorEnvelope.self, from: data), env.error?.code == "error.library.partial",
               let result = decode() {
                return result
            }
            throw apiError(data, status: http.statusCode)
        default:
            throw apiError(data, status: http.statusCode)
        }
    }

    // MARK: - Notify bridge (APP-API-CONTRACT section 9; keyed)

    public func setNotify(session id: String, _ optIn: NotifyOptIn) async throws {
        let req = try makeRequest("PUT", "/studio/\(id)/notify", keyed: true, timeout: 15)
        let body = Self.jsonBody(["on": optIn.on.map(\.rawValue), "label": optIn.label])
        try await sendEmpty(req, body: body)
    }

    public func cancelNotify(session id: String) async throws {
        let req = try makeRequest("DELETE", "/studio/\(id)/notify", keyed: true, timeout: 15)
        try await sendEmpty(req)
    }

    // MARK: - The server's line (APP-API-CONTRACT section 17; keyed)

    public func cancelQueued(session id: String) async throws -> QueueCancel {
        try await cancelQueued(try makeRequest("DELETE", "/studio/\(Self.encode(id))/line", keyed: true, timeout: 15))
    }

    public func cancelQueued(session id: String, job: String) async throws -> QueueCancel {
        try await cancelQueued(try makeRequest("DELETE", "/studio/\(Self.encode(id))/render/\(Self.encode(job))", keyed: true, timeout: 15))
    }

    /// `200 {cancelled: true}` → `.cancelled`; `409 error.studio.started` → `.started` (its turn came first: the
    /// server finishes what it started); anything else as the keyed calls throw it.
    private func cancelQueued(_ req: URLRequest) async throws -> QueueCancel {
        let (data, http) = try await send(req)
        if (200..<300).contains(http.statusCode) { return .cancelled }
        if http.statusCode == 409,
           let env = try? JSONDecoder().decode(ErrorEnvelope.self, from: data), env.error?.code == "error.studio.started" {
            return .started
        }
        throw apiError(data, status: http.statusCode)
    }

    public func line() async throws -> ServerLineSnapshot {
        let req = try makeRequest("GET", "/studio/line", keyed: true, timeout: 15)
        return try await sendJSON(ServerLineSnapshot.self, req)
    }

    public func queue() async throws -> QueueSnapshot {
        let req = try makeRequest("GET", "/queue", keyed: true, timeout: 15)
        return try await sendJSON(QueueSnapshot.self, req)
    }

    public func setLineNotify() async throws -> Int {
        let req = try makeRequest("PUT", "/studio/line/notify", keyed: true, timeout: 15)
        struct Wire: Decodable { var watching: Int? }
        let wire = try await sendJSON(Wire.self, req, body: Self.jsonBody([:]))
        return wire.watching ?? 0
    }

    public func cancelLineNotify() async throws {
        let req = try makeRequest("DELETE", "/studio/line/notify", keyed: true, timeout: 15)
        try await sendEmpty(req)
    }

    // MARK: - Live Activities (APP-API-CONTRACT section 8; all keyed)

    public func registerLiveStartToken(_ token: String, environment: LiveEnvironment) async throws {
        let req = try makeRequest("PUT", "/live/start-token", keyed: true)
        let body = Self.jsonBody(["token": token, "environment": environment.rawValue])
        try await sendEmpty(req, body: body)
    }

    public func registerLiveRun(_ r: LiveRunRegistration) async throws -> LiveRunReply {
        let req = try makeRequest("PUT", "/live/runs/\(Self.runPath(r.run))", keyed: true)
        let wire = try await sendJSON(LiveRunWire.self, req, body: try r.requestBody())
        return LiveRunReply(pushing: wire.pushing ?? false, started: wire.started ?? false, reason: wire.reason)
    }

    public func relayLiveState(run: UUID, _ state: LiveContentState) async throws {
        struct Envelope: Encodable { var state: LiveContentState }
        let req = try makeRequest("POST", "/live/runs/\(Self.runPath(run))/state", keyed: true)
        try await sendEmpty(req, body: try JSONEncoder().encode(Envelope(state: state)))
    }

    public func endLiveRun(_ run: UUID) async throws {
        let req = try makeRequest("DELETE", "/live/runs/\(Self.runPath(run))", keyed: true)
        try await sendEmpty(req)
    }

    public func liveSelftest() async throws -> LiveSelftest {
        let req = try makeRequest("GET", "/live/selftest", keyed: true)
        let wire = try await sendJSON(LiveSelftestWire.self, req)
        return LiveSelftest(
            configured: wire.configured ?? false, transport: wire.transport, host: wire.host, jwt: wire.jwt,
            apnsStatus: wire.apnsStatus, apnsReason: wire.apnsReason)
    }

    /// Run ids go into paths lowercased.
    private static func runPath(_ run: UUID) -> String { run.uuidString.lowercased() }

    /// A 2xx with no body to read (204, 202).
    private func sendEmpty(_ req: URLRequest, body: Data? = nil) async throws {
        let (data, http) = try await send(req, body: body)
        guard (200..<300).contains(http.statusCode) else { throw apiError(data, status: http.statusCode) }
    }

    // MARK: - Download

    /// The request a download of `file` makes (the same one `download` sends): a background session needs the
    /// request, not the transfer. A keyed route carries the key, only to the server's own host; a public URL
    /// is never sent it.
    public func urlRequest(for file: RemoteFile) throws -> URLRequest {
        switch file {
        case .open(let url):
            var r = URLRequest(url: url, timeoutInterval: 60)
            r.httpMethod = "GET"
            return r                                           // never sent the key
        case .studioSource(let id):
            return try makeRequest("GET", "/studio/\(id)/source", keyed: false, timeout: 60)
        case .libraryItem(let id):
            return try makeRequest("GET", "/library/items/\(id)/file", keyed: true, timeout: 60)
        }
    }

    public func download(
        _ file: RemoteFile, to destination: URL,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> URL {
        let req = try urlRequest(for: file)
        // A download task with its own delegate: the task-level delegate of `download(for:)` is
        // never told how many bytes have arrived (found with a loopback server, wave 1). The
        // per-call session copies the injected session's configuration, so stubs still apply.
        let job = DownloadJob(progress)
        let temp: URL
        let http: HTTPURLResponse
        do {
            (temp, http) = try await job.run(req, configuration: urlSession.configuration)
        } catch let e as URLError {
            throw CobaltError.network(e.code)
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = (try? Data(contentsOf: temp)) ?? Data()
            try? FileManager.default.removeItem(at: temp)
            throw apiError(body, status: http.statusCode)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Replaces an earlier file of that name, and nothing else: a directory (the inbox itself, if a
        // name ever resolved there) is never removed.
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: destination.path, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue else {
                try? fm.removeItem(at: temp)
                throw CocoaError(.fileWriteInvalidFileName)
            }
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: temp, to: destination)
        return destination
    }
}

// MARK: - Wire DTOs

private struct ErrorEnvelope: Decodable {
    struct Body: Decodable { var code: String? }
    var error: Body?
}

private struct ResolveWire: Decodable {
    struct Picker: Decodable { var type: String?; var url: URL; var thumb: URL? }
    var status: String
    var url: URL?
    var filename: String?
    var picker: [Picker]?
    var audio: URL?
    var error: ErrorEnvelope.Body?
}

private struct IDWire: Decodable {
    struct Make: Decodable { var job: String; var kind: String }
    var id: String; var url: String?; var queued: Bool?; var queueAhead: Int?
    var make: Make?
}
private struct LiveRunWire: Decodable { var pushing: Bool?; var started: Bool?; var reason: String? }
private struct LiveSelftestWire: Decodable {
    var configured: Bool?; var transport: String?; var host: String?; var jwt: String?
    var apnsStatus: Int?; var apnsReason: String?
}
private struct JobWire: Decodable { var job: String; var queued: Bool?; var queueAhead: Int? }

private struct MakeWire: Decodable {
    var status: String
    var job: String?
    var itemId: String?
    var url: URL?
    var bytes: Int64?
    var width: Int?
    var height: Int?
    var seconds: Double?
    var format: String?
    var cropped: [Int]?
    var upscaled: [Int]?
    var replaced: [String]?
    var phase: String?
    var framesDone: Int?
    var framesTotal: Int?
    var queueAhead: Int?
    var error: ErrorEnvelope.Body?
}

private struct PostVisibilityWire: Decodable {
    var items: [Lossy<LibraryFile>]?
    var cacheCleared: Bool?
    var remaining: [String]?
}

private struct MadeWire: Decodable {
    var item: LibraryFile?
    var replaced: [String]?
}

private struct UploadWire: Decodable {
    var id: String?
    var item: LibraryFile?
    var studioError: ErrorEnvelope.Body?
    var queued: Bool?
    var queueAhead: Int?
}

private struct RenderWire: Decodable {
    var status: String
    var job: String?
    var url: URL?
    var bytes: Int64?
    var width: Int?
    var height: Int?
    var seconds: Double?
    var phase: String?
    var framesDone: Int?
    var framesTotal: Int?
    var queueAhead: Int?
    var error: ErrorEnvelope.Body?
}

private struct PublishWire: Decodable {
    var url: URL
    var bytes: Int64?
    var contentType: String?
    var itemId: String?
}

private struct VisibilityWire: Decodable {
    var item: LibraryFile
    var cacheCleared: Bool?
}

private struct LibraryWire: Decodable {
    struct Counts: Decodable { var posts: Int?; var files: Int? }
    struct Usage: Decodable { var publicBytes: Int64?; var privateBytes: Int64? }
    var posts: [Lossy<LibraryPost>]
    var counts: Counts?
    var usage: Usage?
    var next: String?
}

private struct EmoteListWire: Decodable {
    var items: [EmoteHit]
}

// MARK: - Delegates

/// Refuses redirects so a 302 from plain cobalt is seen as a 302.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Reports upload progress. The task-level delegate of the async upload API does receive
/// `didSendBodyData` (a slow loopback server shows a figure per megabyte or so); only a download's
/// per-task delegate is blind to its bytes, which is why downloads use `DownloadJob`.
private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let throttle: ProgressThrottle

    init(_ handler: @escaping @Sendable (TransferProgress) -> Void) { self.throttle = ProgressThrottle(handler) }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        throttle.send(TransferProgress(bytes: totalBytesSent, total: totalBytesExpectedToSend > 0 ? totalBytesExpectedToSend : nil))
    }

    /// The upload is over: a figure held back by the throttle still goes out.
    func finish() { throttle.flush() }
}

/// One download: a `URLSessionDownloadTask` on a session of its own so the delegate hears every
/// `didWriteData`. The system deletes its temp file when `didFinishDownloadingTo` returns, so the
/// file is moved aside there. Cancelling the awaiting task cancels the download.
private final class DownloadJob: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<(URL, HTTPURLResponse), Error>?
        var file: URL?
        var moveError: Error?
    }

    private let throttle: ProgressThrottle
    private let state = Mutex(State())

    init(_ handler: @escaping @Sendable (TransferProgress) -> Void) { self.throttle = ProgressThrottle(handler) }

    func run(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> (URL, HTTPURLResponse) {
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(URL, HTTPURLResponse), Error>) in
                state.withLock { $0.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        throttle.send(TransferProgress(bytes: totalBytesWritten, total: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("cobalt-download-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            state.withLock { $0.file = kept }
        } catch {
            state.withLock { $0.moveError = error }
        }
    }

    /// A redirect to another host must not carry the key along.
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        var next = request
        if request.url?.host != task.originalRequest?.url?.host { next.setValue(nil, forHTTPHeaderField: "Authorization") }
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, file, moveError) = state.withLock { s -> (CheckedContinuation<(URL, HTTPURLResponse), Error>?, URL?, Error?) in
            defer { s.continuation = nil }
            return (s.continuation, s.file, s.moveError)
        }
        guard let continuation else { return }
        if let error {
            if let file { try? FileManager.default.removeItem(at: file) }
            continuation.resume(throwing: error)
        } else if let file, let http = task.response as? HTTPURLResponse {
            throttle.flush()
            continuation.resume(returning: (file, http))
        } else {
            continuation.resume(throwing: moveError ?? CobaltError.invalidResponse(httpStatus: 0))
        }
    }
}
