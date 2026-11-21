import Foundation
import Synchronization

// The app's half of the instant share (CONTRACT-SHARE-QUICK.md section 9): learning which sessions the
// share extension's `POST /studio` created, and keeping their originals.
//
// Two ways to learn, both ending in `adoptShared` (the same hand-off the share sheet used to make):
//  - the system wakes the app for the extension's background session (`handleWake`): the request's answer
//    carries the session id. Needs the app group (without it the extension has no background session);
//  - the app asks the server on every foreground (`discoverShares`, `GET /studio/recent`): covers a
//    force-quit app, a build with no app group, and a wake that never came.

/// What the extension's requests answered, kept until the app is on the main actor. Filled by the
/// session's delegate queue.
final class SaveAnswers: SaveEvents, @unchecked Sendable {
    struct Answer: Sendable, Equatable {
        var identifier: String
        var label: String
        /// nil: no HTTP answer (see `code`).
        var status: Int?
        var code: Int?
        var body: Data
    }

    private let inbox = Mutex<[Answer]>([])

    func saveResponded(identifier: String, task: Int, label: String, status: Int, body: Data) {
        inbox.withLock { $0.append(Answer(identifier: identifier, label: label, status: status, code: nil, body: body)) }
    }

    func saveFailed(identifier: String, task: Int, label: String, code: Int) {
        inbox.withLock { $0.append(Answer(identifier: identifier, label: label, status: nil, code: code, body: Data())) }
    }

    func saveEventsFinished(identifier: String) {}

    func drain() -> [Answer] { inbox.withLock { let all = $0; $0 = []; return all } }
}

extension OriginalFetcher {
    // MARK: Waking

    /// The system woke the app for an extension's save session: read what it answered.
    @MainActor
    func handleSaveWake(identifier id: String) async {
        let session = saveTransport.session(identifier: id, events: saveAnswers)
        await session.waitForEvents(timeout: 25)
        await applySaveAnswers()
    }

    /// 201 with a session id: keep its original. Anything else: say so, the owner shared something that
    /// did not save (and no Hark message will come for a session that was never made).
    @MainActor
    func applySaveAnswers() async {
        for answer in saveAnswers.drain() {
            let link = URL(string: answer.label)
            if answer.code == NSURLErrorCancelled { continue }
            if let status = answer.status, (200..<300).contains(status), let sid = Self.sessionID(in: answer.body) {
                adoptShared(id: sid, link: link, info: nil)
            } else {
                await instantFailed(link, answer.status)
            }
        }
    }

    /// `{"status":"success","id":"<22 base62>","url":…}`.
    static func sessionID(in body: Data) -> String? {
        struct Created: Decodable { var id: String? }
        guard let id = (try? JSONDecoder().decode(Created.self, from: body))?.id,
              id.count == 22, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return nil }
        return id
    }

    // MARK: Asking

    /// Foreground: the server's list of what this key shared from a share sheet. Skips what the ledger or
    /// the store already has, what failed (Hark said so), and everything when "keep videos" is off.
    @MainActor
    func discoverShares() async {
        guard discoversShares, keepsOriginals() else { return }
        for session in await recentShares() {
            if session.status == .error { continue }
            adoptShared(id: session.id, link: session.link.flatMap(URL.init(string:)), info: session)
        }
    }

    // MARK: Keeping

    /// Queues the original of a share-sheet session: a task that waits for the save (`?wait=90`), or
    /// plain when the save is ready. One per session: whatever the ledger or the store holds is left alone.
    @MainActor
    @discardableResult
    func adoptShared(id: String, link: URL?, info: StudioSession?) -> Bool {
        guard keepsOriginals(), pending.entry(id) == nil else { return false }
        if store.videos.contains(where: { $0.kind == .original && $0.sessionID == id }) { return false }
        // A gallery is not one original: `source` would give its lead item (a photo stored as a video, items 2-N never
        // kept). The app follows it as a gallery job instead; with no job to give it to nothing is queued.
        if let info, Self.isGallery(info) { return adoptGallery(id, link) }
        let name = info?.title ?? link.flatMap(LinkInfo.init)?.ref ?? id
        let media = MediaInfo(name: name, duration: info?.duration, width: info?.width, height: info?.height, bytes: info?.bytes, isImage: false)
        let source = HTTPCobaltClient(baseURL: serverURL(), apiKey: { nil }).sourceURL(session: id)
        // `sourceWait: true` even when the app has not read `features.source_wait` yet (a cold wake): a
        // server without it answers "not ready" at once, which only costs the retry.
        handOff(session: id, link: link, media: media, sourceURL: source, sourceWait: true, saveReady: info?.status == .ready)
        return true
    }

    /// A post of several items (`items` listed, or `item_count` 2 or more): saved whole, not as one original.
    static func isGallery(_ session: StudioSession) -> Bool {
        !session.items.isEmpty || (session.itemCount ?? 0) >= 2
    }

    /// `GET /studio/<sid>`, for at most 5 s (nil: unknown).
    @MainActor
    func lookUp(session id: String) async -> StudioSession? {
        let lookup = sessionInfo
        return await InstantShareEngine.within(5) { await lookup(id) }
    }

    /// A saving session has no title or size yet; the original's name comes from the session once it lands.
    @MainActor
    func enriched(_ media: MediaInfo, session id: String) async -> MediaInfo {
        guard media.duration == nil else { return media }
        return enriched(media, from: await lookUp(session: id))
    }

    @MainActor
    func enriched(_ media: MediaInfo, from found: StudioSession?) -> MediaInfo {
        guard media.duration == nil, let found else { return media }
        return MediaInfo(
            name: found.title ?? media.name, duration: found.duration ?? media.duration, width: found.width ?? media.width,
            height: found.height ?? media.height, bytes: media.bytes ?? found.bytes, isImage: media.isImage)
    }

    /// The extension's request bodies are only needed while the request runs; a day is generous.
    @MainActor
    func pruneSaveFiles() {
        let dir = savesDirectory()
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)         // file times are real time, not the pipeline's clock
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where name.hasSuffix(".json") {
            let url = dir.appendingPathComponent(name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: Live seams

    @MainActor
    static func liveClient() -> HTTPCobaltClient? {
        let settings = Settings.shared()
        let server = settings.serverURL
        let keychain = settings.keychain
        guard Settings.apiKey(in: keychain, forServer: server) != nil else { return nil }
        return HTTPCobaltClient(baseURL: server, apiKey: { Settings.apiKey(in: keychain, forServer: server) })
    }

    @MainActor
    static func liveRecentShares() async -> [StudioSession] {
        guard Notifications.runsInApp, let client = liveClient() else { return [] }
        return (try? await client.recentShares()) ?? []
    }

    @MainActor
    static func liveSessionInfo(_ id: String) async -> StudioSession? {
        guard Notifications.runsInApp else { return nil }
        // the session route is a capability URL: no key
        let client = HTTPCobaltClient(baseURL: Settings.shared().serverURL, apiKey: { nil })
        return try? await client.session(id, wait: 0)
    }
}
