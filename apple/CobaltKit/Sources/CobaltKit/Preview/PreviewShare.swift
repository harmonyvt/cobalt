import Foundation
import Synchronization

// Gallery share links in previews (APP-API-CONTRACT 24): a server with `features.share_sets` and a `share_base_url`,
// three sample links, and the real rule (2..4 distinct files, all public now). `PreviewScenario.shareLinksEmpty` has no
// links yet; `.shareLinksFail` cannot list them. `.happy` and `.renditions` have the three samples.

extension PreviewScenario {
    /// The preview server has `features.share_sets`.
    var hasShareLinks: Bool {
        switch self {
        case .happy, .renditions, .shareLinksEmpty, .shareLinksFail: return true
        default: return false
        }
    }
}

extension PreviewData {
    /// `share_base_url` of the preview server.
    static let shareBase = URL(string: "https://share.capybaraharmony.com/")!

    static func shareURL(id: String) -> URL { shareBase.appendingPathComponent("g").appendingPathComponent(id) }

    /// The three sample links, newest first (`now` is when the preview server started):
    /// - `9000000000000000001` "harbour and the dog" (20 minutes ago): a video with its poster, a webp, a photo.
    /// - `9000000000000000002` (3 hours ago, untitled): two webps.
    /// - `9000000000000000003` "kitchen, coffee, city" (2 days ago): four files, and the video went private since (its
    ///   `url` is null), so the page shows three.
    static func shareSets(now: Date) -> [ShareSet] {
        func item(
            _ id: String, _ file: String?, _ type: String, poster: String? = nil, w: Int?, h: Int?, d: Double? = nil
        ) -> ShareSetItem {
            ShareSetItem(
                id: id, url: file.flatMap { URL(string: "https://media.capybaraharmony.com/\($0)") }, contentType: type,
                posterURL: poster.flatMap { URL(string: "https://media.capybaraharmony.com/\($0)") }, width: w, height: h, duration: d)
        }
        let video = item("PrEvIeWitem000001", "PrEvIeW011.mp4", "video/mp4", poster: "PrEvIeWp11.jpg", w: 720, h: 1280, d: 37.43)
        let dogWebp = item("PrEvIeWitem000003", "PrEvIeW001.webp", "image/webp", w: 480, h: 854, d: 10.1)
        let photo = item("PrEvIeWitem000030", "PrEvIeW021.jpg", "image/jpeg", w: 1080, h: 1350)
        let timerWebp = item("PrEvIeWitem000005", "PrEvIeW002.webp", "image/webp", w: 480, h: 568, d: 5.4)
        let cityWebp = item("PrEvIeWitem000010", "PrEvIeW004.webp", "image/webp", w: 480, h: 270, d: 5.0)
        let coffeeWebp = item("PrEvIeWitem000008", "PrEvIeW003.webp", "image/webp", w: 480, h: 480, d: 10.1)
        let wentPrivate = item("PrEvIeWitem000002", nil, "video/mp4", w: 720, h: 1280, d: 37.43)
        let photo2 = item("PrEvIeWitem000031", "PrEvIeW022.jpg", "image/jpeg", w: 1080, h: 1080)
        return [
            ShareSet(
                id: "9000000000000000001", url: shareURL(id: "9000000000000000001"), title: "harbour and the dog",
                createdAt: now.addingTimeInterval(-20 * 60), items: [video, dogWebp, photo]),
            ShareSet(
                id: "9000000000000000002", url: shareURL(id: "9000000000000000002"), title: nil,
                createdAt: now.addingTimeInterval(-3 * 3_600), items: [timerWebp, cityWebp]),
            ShareSet(
                id: "9000000000000000003", url: shareURL(id: "9000000000000000003"), title: "kitchen, coffee, city",
                createdAt: now.addingTimeInterval(-2 * 86_400), items: [coffeeWebp, cityWebp, wentPrivate, photo2]),
        ]
    }
}

/// What the preview "server" holds for `/share/sets`, and every call made (`"POST a,b"`, `"GET"`, `"DELETE <id>"`).
final class PreviewShareState: Sendable {
    private struct State {
        var sets: [ShareSet] = []
        var counter = 0
        var calls: [String] = []
        var listFails = false
    }

    private let state = Mutex(State())

    var sets: [ShareSet] { state.withLock { $0.sets } }
    var calls: [String] { state.withLock { $0.calls } }

    func seed(_ sets: [ShareSet], listFails: Bool) {
        state.withLock { $0.sets = sets; $0.listFails = listFails }
    }

    /// Tests: `GET /share/sets` answers 503 while this is true.
    var listFails: Bool {
        get { state.withLock { $0.listFails } }
        set { state.withLock { $0.listFails = newValue } }
    }

    func record(_ call: String) { state.withLock { $0.calls.append(call) } }

    func list() -> [ShareSet]? {
        state.withLock { $0.listFails ? nil : $0.sets.sorted { $0.createdAt > $1.createdAt } }
    }

    func add(items: [ShareSetItem], title: String?, at now: Date) -> ShareSet {
        state.withLock { s in
            s.counter += 1
            let id = "9100000000000000" + String(format: "%03d", s.counter)
            let made = ShareSet(id: id, url: PreviewData.shareURL(id: id), title: title, createdAt: now, items: items)
            s.sets.insert(made, at: 0)
            return made
        }
    }

    func remove(_ id: String) -> Bool {
        state.withLock { s in
            guard s.sets.contains(where: { $0.id == id }) else { return false }
            s.sets.removeAll { $0.id == id }
            return true
        }
    }
}

extension PreviewClient {
    /// `POST /share/sets` against the preview library (what it lists now, switches and deletes included): `badRequest`
    /// unless 2..4 distinct ids and a title of 1..80 characters (or none), `notPublic(ids)` for the files that are
    /// missing or private, else the new link, first in the list.
    public func createShareSet(items: [String], title: String?) async throws -> ShareSet {
        shareState.record("POST " + items.joined(separator: ","))
        try await clock.sleep(seconds: 0.4 * timeScale)
        guard scenario.hasShareLinks else { throw PipelineFailure.unsupported }
        let cleaned = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cleaned, cleaned.isEmpty || cleaned.count > ShareSetRule.titleLimit { throw ShareSetError.badRequest }
        guard items.count >= ShareSetRule.minimum, items.count <= PreviewData.capabilities(for: scenario).limits.shareSetMax,
              Set(items).count == items.count else { throw ShareSetError.badRequest }
        let posts = try await library(cursor: nil, limit: 100, v2: visibility != .off).posts
        var wire: [ShareSetItem] = []
        var refused: [String] = []
        for id in items {
            guard let post = posts.first(where: { $0.files.contains { $0.id == id } }),
                  let file = post.files.first(where: { $0.id == id }), file.isPublic, let url = file.url else {
                refused.append(id)
                continue
            }
            let isVideo = file.contentType?.lowercased().hasPrefix("video/") == true
            wire.append(ShareSetItem(
                id: id, url: url, contentType: file.contentType, posterURL: file.posterURL ?? (isVideo ? post.posterURL : nil),
                width: file.width, height: file.height, duration: file.duration))
        }
        if !refused.isEmpty { throw ShareSetError.notPublic(refused) }
        return shareState.add(items: wire, title: cleaned, at: clock.now())
    }

    /// `GET /share/sets`: newest first; `.shareLinksFail` answers `503`.
    public func shareSets() async throws -> [ShareSet] {
        shareState.record("GET")
        try await clock.sleep(seconds: 0.3 * timeScale)
        guard scenario.hasShareLinks else { throw PipelineFailure.unsupported }
        guard let sets = shareState.list() else { throw ShareSetError.unavailable }
        return sets
    }

    /// `DELETE /share/sets/<id>`: the link goes; an id the server does not hold is `.notFound`.
    public func revokeShareSet(id: String) async throws {
        shareState.record("DELETE " + id)
        try await clock.sleep(seconds: 0.3 * timeScale)
        guard scenario.hasShareLinks else { throw PipelineFailure.unsupported }
        guard shareState.remove(id) else { throw ShareSetError.notFound }
    }
}
