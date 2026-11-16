import Foundation
import Observation

/// "variants" (APP-API-CONTRACT 20.2): a long press on an emote of a 7TV set lists every emote on 7TV with that emote's own
/// name (`SevenTvSetItem.name`, never the set's alias), most used first.
///
/// - `load()` reads page 1; `loadMore()` the next. A page can come back with none of the name (an older server that has no
///   `exact`, so the app filters it here), so each step reads on, up to `pagesPerStep` pages, until it has something new
///   or 7TV has no more.
/// - The same emote twice (7TV's pages can overlap) is kept once.
@MainActor @Observable
public final class SevenTvVariantsModel: Identifiable {
    public enum State: Sendable, Equatable {
        case loading, loaded, failed
    }

    public let id = UUID()
    /// The emote that was held.
    public let emote: SevenTvSetItem
    public private(set) var items: [EmoteHit] = []
    public private(set) var state: State = .loading
    public private(set) var hasMore = false
    public private(set) var loadingMore = false

    /// The name looked up: the emote's own 7TV name.
    public var name: String { emote.name }
    /// Other emotes than the held one.
    public var othersCount: Int { items.filter { $0.id != emote.emoteID }.count }

    static let pagesPerStep = 4

    @ObservationIgnored private let fetch: @MainActor (String, Int) async throws -> EmotePage
    @ObservationIgnored private var page = 0
    @ObservationIgnored private var token = 0

    public init(emote: SevenTvSetItem, fetch: @escaping @MainActor (String, Int) async throws -> EmotePage) {
        self.emote = emote
        self.fetch = fetch
    }

    public func load() async {
        token += 1
        let mine = token
        state = .loading
        items = []
        page = 0
        hasMore = false
        do {
            try await step(mine)
            guard mine == token else { return }
            state = .loaded
        } catch {
            guard mine == token else { return }
            state = .failed
        }
    }

    public func loadMore() async {
        guard state == .loaded, hasMore, !loadingMore else { return }
        let mine = token
        loadingMore = true
        defer { if mine == token { loadingMore = false } }
        do {
            try await step(mine)
        } catch {
            guard mine == token else { return }
            hasMore = false
        }
    }

    /// Reads pages until one adds an emote, 7TV has no more, or `pagesPerStep` pages were read.
    private func step(_ mine: Int) async throws {
        for _ in 0..<Self.pagesPerStep {
            let next = page + 1
            let found = try await fetch(name, next)
            guard mine == token else { return }
            page = next
            hasMore = found.hasMore
            let seen = Set(items.map(\.id))
            let fresh = EmoteVariants.keep(found.items, name: name).filter { !seen.contains($0.id) }
            items += fresh
            if !fresh.isEmpty || !found.hasMore { return }
        }
    }
}
