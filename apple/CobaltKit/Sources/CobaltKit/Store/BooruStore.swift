import Foundation
import Observation

/// The booru tab (APP-API-CONTRACT 72): this device's settings, the search and its pages. The server applies the level,
/// the hard block, the themes and the blacklist; this model only asks and assigns what changed.
///
/// Safe mode: while the screen is mirrored, recorded or sent to a TV (the screen tells the store through `safeMode`), every
/// request asks for general only. The server never answers above the device's own level, so safe mode can only lower it.
@MainActor @Observable
public final class BooruStore {
    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        case loaded
        /// The search failed with this code (`error.booru.*`, a network code).
        case failed(String)
    }

    public private(set) var settings: BooruSettings?
    public private(set) var settingsLoaded = false
    public private(set) var settingsError: String?
    public private(set) var posts: [BooruPost] = []
    public private(set) var hidden = BooruHidden()
    public private(set) var phase: Phase = .idle
    public private(set) var loadingMore = false
    public private(set) var nextPage: Int?
    public private(set) var dropped: [String] = []
    /// The level the last page was filtered at (lower than the device's while in safe mode).
    public private(set) var pageLevel: BooruLevel?
    public private(set) var suggestions: [BooruSuggestion] = []
    /// Posts the owner tapped to reveal (blurred ones), for this visit only.
    public private(set) var revealed: Set<Int> = []

    /// The search being shown. Change it with `search(_:)`.
    public private(set) var query = BooruQuery()
    /// The screen is mirrored, recorded or on a TV: ask for general only.
    public var safeMode = false {
        didSet { if safeMode != oldValue, phase != .idle { Task { await reload() } } }
    }

    /// The level asked for: general in safe mode, else the device's own (so Danbooru is asked for those ratings only and a
    /// page is not mostly posts the server then drops). The server never answers above the device's level either way.
    var askedLevel: BooruLevel? { safeMode ? .general : settings?.level }
    public var effectiveLevel: BooruLevel { safeMode ? .general : (settings?.level ?? .general) }
    public var available: Bool { client != nil }

    @ObservationIgnored private let ctx: PipelineContext
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var suggestGeneration = 0
    private var client: (any BooruClient)? { ctx.client as? any BooruClient }

    init(context: PipelineContext) {
        self.ctx = context
    }

    /// Reads the settings once, then the first page of the current search.
    public func load() async {
        if !settingsLoaded { await loadSettings() }
        if phase == .idle { await reload() }
    }

    public func loadSettings() async {
        guard let client else {
            settingsLoaded = true
            return
        }
        do {
            let s = try await client.booruSettings()
            if s != settings { settings = s }
            settingsError = nil
        } catch {
            settingsError = Self.code(error)
        }
        settingsLoaded = true
    }

    /// Changes the device's settings. Returns false (and keeps the old ones) when the server refused.
    @discardableResult
    public func update(_ patch: BooruSettingsPatch) async -> Bool {
        guard let client else { return false }
        do {
            let s = try await client.updateBooruSettings(patch)
            let changed = s != settings
            if changed { settings = s }
            settingsError = nil
            // new filters: start the grid over (blank, loading, page 1) so the change is plain to see
            if changed { await reload(fresh: true) }
            return true
        } catch {
            settingsError = Self.code(error)
            return false
        }
    }

    /// Adds one tag to the blacklist as its own line.
    @discardableResult
    public func blacklist(tag: String) async -> Bool {
        let current = settings?.blacklist ?? ""
        let lines = current.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !lines.contains(tag) else { return true }
        let next = current.isEmpty ? tag : current.hasSuffix("\n") ? current + tag : current + "\n" + tag
        return await update(BooruSettingsPatch(blacklist: next))
    }

    /// Runs a new search from page 1.
    public func search(_ query: BooruQuery) async {
        self.query = query
        await reload()
    }

    /// Page 1 again. `fresh` drops the posts shown first, so the grid shows loading instead of the old filters' posts.
    public func reload(fresh: Bool = false) async {
        guard let client else { return }
        generation += 1
        let gen = generation
        if query.tooManyTags {
            phase = .failed("error.booru.too_many_tags")
            return
        }
        if fresh {
            posts = []
            hidden = BooruHidden()
            nextPage = nil
        }
        phase = .loading
        revealed = []
        do {
            let page = try await client.booruPosts(query, page: 1, level: askedLevel)
            guard gen == generation else { return }
            posts = page.posts
            hidden = page.hidden
            nextPage = page.nextPage
            dropped = page.dropped
            pageLevel = page.level
            phase = .loaded
            // a page the filters emptied: read on, so the grid is not blank while more exists
            if page.posts.count < 12, page.nextPage != nil { await loadMore() }
        } catch {
            guard gen == generation else { return }
            phase = .failed(Self.code(error))
        }
    }

    /// The next page, appended. Up to three pages are read in one go when the filters keep emptying them.
    public func loadMore() async {
        guard let client, let start = nextPage, !loadingMore, phase == .loaded else { return }
        loadingMore = true
        defer { loadingMore = false }
        let gen = generation
        var page = start
        var added = 0
        for _ in 0..<3 {
            guard let next = try? await client.booruPosts(query, page: page, level: askedLevel), gen == generation else { return }
            let known = Set(posts.map(\.id))
            let fresh = next.posts.filter { !known.contains($0.id) }
            posts.append(contentsOf: fresh)
            hidden = hidden + next.hidden
            nextPage = next.nextPage
            added += fresh.count
            guard added < 12, let n = next.nextPage else { break }
            page = n
        }
    }

    public func reveal(_ id: Int) { revealed.insert(id) }

    /// Tag suggestions for the last word typed.
    public func suggest(_ text: String) async {
        suggestGeneration += 1
        let gen = suggestGeneration
        let word = text.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
        guard let client, word.count >= 2, !text.hasSuffix(" ") else {
            if !suggestions.isEmpty { suggestions = [] }
            return
        }
        try? await Task.sleep(for: .milliseconds(180))
        guard gen == suggestGeneration else { return }
        let found = (try? await client.booruAutocomplete(word)) ?? []
        guard gen == suggestGeneration else { return }
        if found != suggestions { suggestions = found }
    }

    public func clearSuggestions() {
        suggestGeneration += 1
        if !suggestions.isEmpty { suggestions = [] }
    }

    func reset() {
        generation += 1
        settings = nil
        settingsLoaded = false
        posts = []
        hidden = BooruHidden()
        phase = .idle
        nextPage = nil
    }

    static func code(_ error: Error) -> String {
        switch error as? CobaltError {
        case .api(let code, _): return code
        case .network: return "error.network"
        default: return "error.booru.generic"
        }
    }
}
