import Foundation

// The booru tab in previews (APP-API-CONTRACT 72): every stage scenario has the routes, with placeholder posts (the image
// URLs point nowhere, so the grid shows its placeholder tiles). No real Danbooru content in previews or tests.

final class PreviewBooruState: @unchecked Sendable {
    private let lock = NSLock()
    private var _settings: BooruSettings

    init() {
        _settings = BooruSettings(level: .general, themes: [:], themeList: PreviewBooru.themes, blacklist: "")
    }

    var settings: BooruSettings {
        get { lock.withLock { _settings } }
        set { lock.withLock { _settings = newValue } }
    }
}

enum PreviewBooru {
    static let state = PreviewBooruState()

    static let themes: [BooruTheme] = [
        BooruTheme(id: "revealing", label: "revealing outfits", detail: "swimsuits, underwear, lingerie", default: .show, minLevel: .sensitive, tags: ["swimsuit"]),
        BooruTheme(id: "suggestive", label: "suggestive", detail: "poses and focus shots", default: .show, minLevel: .sensitive, tags: ["cleavage"]),
        BooruTheme(id: "partial", label: "partial nudity", detail: "topless, covered nudity", default: .hide, minLevel: .sensitive, tags: ["topless"]),
        BooruTheme(id: "violence", label: "violence and gore", detail: "blood, injury, guro", default: .hide, minLevel: .general, tags: ["blood"]),
        BooruTheme(id: "horror", label: "body horror", detail: "gross-out", default: .hide, minLevel: .general, tags: ["body_horror"]),
    ]

    static func post(_ i: Int, level: BooruLevel) -> BooruPost {
        let base = URL(string: "https://preview.invalid/booru/\(i)")!
        let ratings: [BooruLevel] = [.general, .general, .sensitive, .general, .sensitive, .general]
        let rating = min(ratings[i % ratings.count], level)
        return BooruPost(
            id: 1000 + i, rating: rating, blur: i % 7 == 5, media: i % 9 == 4 ? .animated : .image, ext: i % 9 == 4 ? "gif" : "png",
            width: i % 4 == 0 ? 1600 : 1000, height: i % 4 == 0 ? 900 : 1400, size: 2_100_000, score: 40 + i * 13, favs: 60 + i * 9,
            createdAt: "2026-11-18T10:00:00.000+09:00", source: "https://www.pixiv.net/artworks/\(100000 + i)",
            pageUrl: URL(string: "https://danbooru.donmai.us/posts/\(1000 + i)")!,
            thumbUrl: base.appendingPathComponent("thumb.jpg"), sampleUrl: base.appendingPathComponent("sample.jpg"),
            fileUrl: base.appendingPathComponent("file.png"),
            tags: BooruTags(artist: ["placeholder_artist"], character: ["placeholder_character"], copyright: ["placeholder_series"],
                            general: ["1girl", "umbrella", "rain", "smile"], meta: ["highres"]))
    }
}

extension PreviewClient: BooruClient {
    private func booruReady() async throws {
        try await clock.sleep(seconds: 0.25 * timeScale)
        guard scenario.hasStage else { throw PipelineFailure.unsupported }
    }

    public func booruPosts(_ query: BooruQuery, page: Int, level: BooruLevel?) async throws -> BooruPage {
        try await booruReady()
        let own = PreviewBooru.state.settings.level
        let lvl = level.map { min($0, own) } ?? own
        let posts = (0..<30).map { PreviewBooru.post((page - 1) * 30 + $0, level: lvl) }
        return BooruPage(level: lvl, posts: posts, hidden: BooruHidden(level: 4, theme: 2, blacklist: 1), nextPage: page < 3 ? page + 1 : nil)
    }

    public func booruAutocomplete(_ q: String) async throws -> [BooruSuggestion] {
        try await booruReady()
        return [
            BooruSuggestion(name: "\(q)_character", kind: .character, count: 12_400),
            BooruSuggestion(name: "\(q)_series", kind: .copyright, count: 8_100),
            BooruSuggestion(name: "\(q)", kind: .general, count: 3_200),
        ]
    }

    public func booruSettings() async throws -> BooruSettings {
        try await booruReady()
        return PreviewBooru.state.settings
    }

    public func updateBooruSettings(_ patch: BooruSettingsPatch) async throws -> BooruSettings {
        try await booruReady()
        var s = PreviewBooru.state.settings
        if let l = patch.level { s.level = l }
        if let t = patch.themes { s.themes.merge(t) { $1 } }
        if let b = patch.blacklist { s.blacklist = b }
        PreviewBooru.state.settings = s
        return s
    }

    public func booruFind(jpeg: Data) async throws -> [BooruMatch] {
        try await booruReady()
        return [
            BooruMatch(post: PreviewBooru.post(1, level: .general), similarity: 96),
            BooruMatch(post: PreviewBooru.post(2, level: .general), similarity: 71),
            BooruMatch(post: PreviewBooru.post(3, level: .general), similarity: 64),
        ]
    }

    public func booruLink(item: String, match: BooruMatch) async throws -> BooruCredit {
        try await booruReady()
        return BooruCredit(post: match.post)
    }
}
