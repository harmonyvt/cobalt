import Foundation
import Synchronization

/// How the preview server of `AppModel.previewSearch(_:)` answers `GET /library/search` (APP-API-CONTRACT 21). `.off`
/// (every other preview) is a server without `features.search`.
public enum PreviewSearchMode: Sendable, Equatable, CaseIterable {
    /// No `features.search`: the search field filters by name only.
    case off
    /// Every post has its vector (`index.pending` 0).
    case ready
    /// The index is catching up: 3 posts are found by name only so far.
    case indexing
    /// The Space is asleep: the first search answers `503 error.search.waking`, the next ones work.
    case waking
    /// The Space never wakes: every search answers `503 error.search.waking`.
    case stillWaking
    /// Every search answers `502 error.search.failed`.
    case failing
    /// `features.search` is on, but the server answers `503 error.search.off` (no Space configured).
    case disabled
}

/// Every search the preview server took, in order (`q` as sent).
final class PreviewSearchState: Sendable {
    private let state = Mutex<[String]>([])
    /// What the preview server holds for `/library/about` (`PreviewAbout.swift`).
    let about = PreviewAboutState()

    var calls: [String] { state.withLock { $0 } }

    /// Records a call and returns how many came in so far (this one included).
    func record(_ query: String) -> Int {
        state.withLock { calls in
            calls.append(query)
            return calls.count
        }
    }
}

extension PreviewData {
    /// What each preview post "shows", standing in for what the embedding reads off the poster.
    static let searchMeaning: [String: String] = [
        "Dd55fEyN1Yy": "harbour boats water wind sea waves",
        "Dd7P496wolG": "dog beach running sand ball",
        "2105435404002562056": "kitchen timer clock cooking loop",
        "2105432512428445875": "cat jump fail sofa",
        "Dd5JFkMDt4N": "coffee latte art cafe cup",
        "2105358343657427103": "city night drive lights road",
    ]

    private static func folded(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }

    /// The text the server embeds a post under: its custom title (else the lead file's name), its file names, the
    /// link's host and path.
    static func searchText(_ post: LibraryPost) -> String {
        var parts = [post.customTitle ?? post.files.first?.name ?? post.title ?? ""]
        parts += post.files.map(\.name)
        if let link = post.link { parts.append((link.host() ?? "") + link.path()) }
        return parts.joined(separator: " · ")
    }

    /// The preview's ranking, deterministic: a stand-in cosine from the query's words found in a post's meaning or text
    /// (0.12 to 0.62, a hair less for each later post so ties keep the library's order), plus 0.3 when the whole query is
    /// in the post's text (the server's plain-text bonus). Every post is listed (no cut-off), best first, at most `limit`.
    static func searchHits(_ query: String, in posts: [LibraryPost], limit: Int) -> [LibrarySearchResult.Hit] {
        let q = folded(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let words = q.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let scored = posts.enumerated().map { index, post -> (index: Int, post: LibraryPost, score: Double) in
            let text = folded(searchText(post))
            let meaning = (searchMeaning[post.id] ?? "").split(separator: " ")
            let found = words.filter { w in text.contains(w) || meaning.contains { $0.hasPrefix(w) } }.count
            let cosine = 0.12 + (words.isEmpty ? 0 : 0.5 * Double(found) / Double(words.count)) - 0.001 * Double(index)
            let bonus = !q.isEmpty && text.contains(q) ? 0.3 : 0
            return (index, post, ((cosine + bonus) * 1000).rounded() / 1000)
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .prefix(max(1, min(50, limit)))
            .map { LibrarySearchResult.Hit(post: $0.post, score: $0.score) }
    }

    /// `GET /library/search/post` for the preview posts: one of each state (indexed with and without the poster, stale,
    /// pending, failed with a retry, gave up). Any other key is `404 error.library.not_found`.
    static func searchStatus(postKey: String, posts: [LibraryPost], now: Date) -> LibrarySearchStatus? {
        guard let post = posts.first(where: { $0.id == postKey }) else { return nil }
        let text = searchText(post)
        let title = post.customTitle ?? post.files.first?.name ?? post.title
        let poster = post.posterURL.flatMap { $0.host() == mediaBase.host() ? $0 : nil }
        let input = LibrarySearchStatus.Input(title: title, text: text, imageURL: poster)
        let model = "google/embeddinggemma-2"
        switch postKey {
        case "Dd55fEyN1Yy":
            return .init(postKey: postKey, state: .indexed, model: model, dims: 256, embeddedAt: now.addingTimeInterval(-2 * 3_600),
                         attempts: 1, hasImage: poster != nil, input: input, embeddedMatchesInput: true)
        case "Dd7P496wolG":
            return .init(postKey: postKey, state: .stale, model: model, dims: 256, embeddedAt: now.addingTimeInterval(-3 * 86_400),
                         attempts: 1, hasImage: false, input: input, embeddedMatchesInput: false)
        case "2105432512428445875":
            return .init(postKey: postKey, state: .pending, attempts: 0, input: input, embeddedMatchesInput: false)
        case "Dd5JFkMDt4N":
            return .init(postKey: postKey, state: .failed, failedAt: now.addingTimeInterval(-20 * 60),
                         retryAt: now.addingTimeInterval(40 * 60), attempts: 1, input: input, embeddedMatchesInput: false)
        case "2105358343657427103":
            return .init(postKey: postKey, state: .gaveUp, failedAt: now.addingTimeInterval(-26 * 3_600), attempts: 3,
                         input: input, embeddedMatchesInput: false)
        default:
            return .init(postKey: postKey, state: .indexed, model: model, dims: 256, embeddedAt: now.addingTimeInterval(-50 * 60),
                         attempts: 1, hasImage: poster != nil, input: input, embeddedMatchesInput: true)
        }
    }
}

extension PreviewClient {
    /// `GET /library/search` against `searchMode`, after a short think (0.4 s on the clock, scaled).
    public func librarySearch(query: String, limit: Int, version: Int?) async throws -> LibrarySearchResult {
        let n = searchState.record(query)
        try await clock.sleep(seconds: 0.4 * timeScale)
        switch searchMode {
        case .off: throw CobaltError.api(code: "error.api.generic", httpStatus: 404)
        case .disabled: throw CobaltError.api(code: "error.search.off", httpStatus: 503)
        case .failing: throw CobaltError.api(code: "error.search.failed", httpStatus: 502)
        case .stillWaking: throw CobaltError.api(code: "error.search.waking", httpStatus: 503)
        case .waking where n == 1: throw CobaltError.api(code: "error.search.waking", httpStatus: 503)
        case .waking, .ready, .indexing: break
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, q.count <= 200 else { throw CobaltError.api(code: "error.library.bad_request", httpStatus: 400) }
        let posts = try await library(cursor: nil, limit: 50).posts
        let pending = searchMode == .indexing ? min(3, posts.count) : 0
        return LibrarySearchResult(
            query: q, model: "google/embeddinggemma-2", hits: PreviewData.searchHits(q, in: posts, limit: limit),
            indexed: posts.count - pending, pending: pending)
    }

    /// `GET /library/search/post` for the preview posts (`PreviewData.searchStatus`).
    public func librarySearchStatus(postKey: String) async throws -> LibrarySearchStatus {
        try await clock.sleep(seconds: 0.2 * timeScale)
        let posts = try await library(cursor: nil, limit: 50).posts
        guard let status = PreviewData.searchStatus(postKey: postKey, posts: posts, now: clock.now()) else {
            throw CobaltError.api(code: "error.library.not_found", httpStatus: 404)
        }
        return status
    }
}

extension AppModel {
    /// The library's search against `mode` (see `PreviewSearchMode`), nothing on the network: the preview library,
    /// ranked by a deterministic stand-in for the server's embedding.
    public static func previewSearch(_ mode: PreviewSearchMode = .ready) -> AppModel {
        makePreviewSearch(mode, timeScale: 1, clock: SystemClock())
    }

    static func makePreviewSearch(_ mode: PreviewSearchMode, timeScale: Double, clock: any PipelineClock) -> AppModel {
        let ctx = PipelineContext.preview(.happy, timeScale: timeScale, clock: clock)
        let client = PreviewClient(scenario: .happy, timeScale: timeScale, clock: clock, search: mode)
        ctx.client = client
        var caps = ctx.capabilities
        caps.search = mode != .off
        caps.about = mode != .off
        caps.aboutSound = mode != .off
        ctx.capabilities = caps
        return AppModel(
            context: ctx, library: LibraryModel(context: ctx, seed: PreviewData.libraryPage(now: clock.now())),
            photosSync: PhotosSync.preview(.init(access: .album, enabled: false)),
            makeClient: { _ in client })
    }
}
