import Foundation
import Synchronization

// Hidden posts and auto-hide rules in previews (APP-API-CONTRACT 37). Every preview server that has `features.privateLinks`
// also has `features.hidden`. `.happy` and `.hidden` start with six hidden posts (hidden by you, by a rule and by the chat)
// and three rules: "upload" (on, 22 hits), `instagram.com/close.friends.acct` (on, 4 hits) and "selfie" (off, 14 hits); the
// other servers start with none. Hiding moves a post into the album, `off` / `public` / `private` move it back, and the
// library page leaves hidden posts out and carries `counts.hidden`. The rules behave like the routes: values are normalized,
// a bad one is `400 error.hidden.bad_rule`, the 51st is `409 error.hidden.too_many`, an unknown id `404
// error.hidden.not_found`, and a preview counts what `apply` would hide.

extension PreviewScenario {
    /// The preview starts with hidden posts and rules (the other servers with `features.hidden` start with none).
    var hasHiddenSeed: Bool {
        switch self {
        case .happy, .hidden: return true
        default: return false
        }
    }
}

extension PreviewData {
    /// The rule ids of the sample rules (16 base62 characters, as the server's).
    static let hiddenRuleIDs = ["PrEvIeWrule00001", "PrEvIeWrule00002", "PrEvIeWrule00003"]

    /// The three sample rules, oldest first.
    static func hiddenRules(now: Date) -> [HideRule] {
        [
            HideRule(
                id: hiddenRuleIDs[0], kind: .upload, value: "", enabled: true, hits: 22,
                createdAt: now.addingTimeInterval(-20 * 86_400), updatedAt: now.addingTimeInterval(-3 * 86_400)),
            HideRule(
                id: hiddenRuleIDs[1], kind: .site, value: "instagram.com/close.friends.acct", enabled: true, hits: 4,
                createdAt: now.addingTimeInterval(-9 * 86_400), updatedAt: now.addingTimeInterval(-9 * 86_400)),
            HideRule(
                id: hiddenRuleIDs[2], kind: .about, value: "selfie", enabled: false, hits: 14,
                createdAt: now.addingTimeInterval(-6 * 86_400), updatedAt: now.addingTimeInterval(-1 * 86_400)),
        ]
    }

    /// Six hidden posts, most recently hidden first: two by hand, three by a rule, one by the chat. Every file is off.
    static func hiddenPosts(now: Date) -> [LibraryPost] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        func at(_ days: Int, _ h: Int, _ m: Int) -> Date {
            (cal.date(byAdding: .day, value: -days, to: today) ?? today).addingTimeInterval(Double(h * 3_600 + m * 60))
        }
        func post(
            _ key: String, service: String, link: String?, title: String, custom: String? = nil, dur: Double, w: Int, h: Int,
            when: Date, poster: String, by: HiddenBy, rule: String? = nil
        ) -> LibraryPost {
            let file = LibraryFile(
                id: "\(key)-src", kind: .private, source: service == "upload" ? .upload : .saved, name: title,
                url: nil, contentType: "video/mp4", bytes: Int64(dur * 450_000), width: w, height: h, duration: dur,
                createdAt: when, mediaName: nil, deletable: false, posterURL: URL(string: poster), wireVisibility: .private)
            return LibraryPost(
                id: key, service: service, link: link.flatMap(URL.init(string:)), title: title, duration: dur, width: w,
                height: h, createdAt: when, session: nil, files: [file], customTitle: custom, posterURL: URL(string: poster),
                hidden: true, hiddenBy: by, hiddenRule: rule)
        }
        let poster = "https://media.capybaraharmony.com/"
        return [
            post("PrEvIeWhidden0001", service: "upload", link: nil, title: "from photos · 14 oct.mp4", custom: "getting ready",
                 dur: 12.4, w: 1080, h: 1920, when: at(0, 9, 12), poster: poster + "PrEvIeWp41.jpg", by: .rule, rule: PreviewData.hiddenRuleIDs[0]),
            post("PrEvIeWhidden0002", service: "upload", link: nil, title: "IMG_2204.mov", custom: "mirror fit",
                 dur: 8.1, w: 1080, h: 1920, when: at(1, 21, 40), poster: poster + "PrEvIeWp42.jpg", by: .you),
            post("PrEvIeWhidden0003", service: "instagram", link: "https://www.instagram.com/stories/close.friends.acct/3901234567/",
                 title: "instagram_cf_story", custom: "cf story", dur: 9.6, w: 720, h: 1280, when: at(2, 18, 5),
                 poster: poster + "PrEvIeWp43.jpg", by: .rule, rule: PreviewData.hiddenRuleIDs[1]),
            post("PrEvIeWhidden0004", service: "upload", link: nil, title: "desk-tour.mp4", custom: "desk tour",
                 dur: 31.2, w: 1920, h: 1080, when: at(4, 15, 22), poster: poster + "PrEvIeWp44.jpg", by: .you),
            post("PrEvIeWhidden0005", service: "x", link: "https://x.com/i/status/2105999911112222333",
                 title: "twitter_2105999911112222333", dur: 14.0, w: 720, h: 1280, when: at(6, 11, 48),
                 poster: poster + "PrEvIeWp45.jpg", by: .chat),
            post("PrEvIeWhidden0006", service: "upload", link: nil, title: "IMG_2171.mov", custom: "gym selfie",
                 dur: 5.3, w: 1080, h: 1920, when: at(9, 7, 31), poster: poster + "PrEvIeWp46.jpg", by: .rule, rule: PreviewData.hiddenRuleIDs[2]),
        ]
    }
}

/// What the preview "server" holds for hidden posts and rules, and every call made (`"STATUS hidden 2"`, `"RULE add upload"`).
final class PreviewHiddenState: Sendable {
    private struct State {
        /// Hidden posts, most recently hidden first. A post of the library fixtures that was hidden is in here too.
        var hidden: [LibraryPost] = []
        /// Hidden posts that were not in the fixtures and have been unhidden: the library lists them again.
        var released: [LibraryPost] = []
        /// Posts of the fixtures that are hidden now (so the library page leaves them out).
        var fixtureHidden: Set<String> = []
        /// The status a visible post was last given (the files `shown` lists follow it).
        var statuses: [String: PostStatus] = [:]
        var rules: [HideRule] = []
        var counter = 0
        var calls: [String] = []
    }

    private let state = Mutex(State())

    func seed(hidden: [LibraryPost], rules: [HideRule]) {
        state.withLock { s in
            s.hidden = hidden
            s.rules = rules
        }
    }

    var calls: [String] { state.withLock { $0.calls } }
    func record(_ call: String) { state.withLock { $0.calls.append(call) } }

    var hidden: [LibraryPost] { state.withLock { $0.hidden } }
    var count: Int { state.withLock { $0.hidden.count } }
    var released: [LibraryPost] { state.withLock { $0.released } }
    var fixtureHidden: Set<String> { state.withLock { $0.fixtureHidden } }
    var rules: [HideRule] { state.withLock { $0.rules } }

    /// A hidden or released post by its id or one of its files' ids.
    func known(_ id: String) -> LibraryPost? {
        state.withLock { s in
            (s.hidden + s.released).first { $0.id == id || $0.files.contains { $0.id == id } }
        }
    }

    /// Hides `post` (`by`), its files off. Idempotent for a post that is hidden already.
    func hide(_ post: LibraryPost, fromFixtures: Bool, by: HiddenBy, rule: String? = nil) {
        state.withLock { s in
            var p = post
            p.hidden = true
            p.hiddenBy = by
            p.hiddenRule = rule
            p.visibility = p.visibility == nil ? nil : .private
            for i in p.files.indices { Self.off(&p.files[i]) }
            s.hidden.removeAll { $0.id == p.id }
            s.hidden.insert(p, at: 0)
            s.released.removeAll { $0.id == p.id }
            s.statuses[p.id] = nil
            if fromFixtures { s.fixtureHidden.insert(p.id) }
        }
    }

    /// Unhides `post` and gives it `status` (`off`, `public` or `private`); a post that is visible already only changes status.
    func release(_ post: LibraryPost, fromFixtures: Bool, status: PostStatus) {
        state.withLock { s in
            if let was = s.hidden.first(where: { $0.id == post.id }) {
                s.hidden.removeAll { $0.id == post.id }
                s.fixtureHidden.remove(post.id)
                if !fromFixtures {
                    var p = was
                    p.hidden = false
                    p.hiddenBy = nil
                    p.hiddenRule = nil
                    s.released.removeAll { $0.id == p.id }
                    s.released.append(p)
                }
            }
            s.statuses[post.id] = status
        }
    }

    /// `post` as the library page lists it: its files follow the last status it was given.
    func applying(to post: LibraryPost, links: PreviewPrivateState, now: Date) -> LibraryPost {
        guard let status = state.withLock({ $0.statuses[post.id] }) else { return post }
        var p = post
        for i in p.files.indices {
            switch status {
            case .public:
                p.files[i].wireVisibility = .public
                p.files[i].privateURL = nil
                if p.files[i].url == nil {
                    p.files[i].url = PreviewData.mediaBase.appendingPathComponent(p.files[i].mediaName ?? "\(p.files[i].id).mp4")
                }
            case .private:
                Self.off(&p.files[i])
                p.files[i].privateURL = links.link(.item, p.files[i].id, now: now)?.url
            case .off, .hidden:
                Self.off(&p.files[i])
            }
        }
        if p.visibility != nil {
            p.visibility = p.files.first { $0.role == .privateCopy }?.visibility ?? (p.files.contains { $0.isPublic } ? .public : .private)
        }
        return p
    }

    private static func off(_ file: inout LibraryFile) {
        file.wireVisibility = .private
        file.privateURL = nil
        file.url = nil
    }

    // MARK: rules

    /// The kind and the value as the server stores them (37.3), or nil for `error.hidden.bad_rule`.
    static func normalize(_ kind: HiddenRuleKind, _ raw: String) -> String? {
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        switch kind {
        case .upload:
            return ""
        case .words:
            return (1...60).contains(collapsed.count) ? collapsed : nil
        case .about:
            return (1...40).contains(collapsed.count) ? collapsed : nil
        case .site:
            var v = collapsed
            for scheme in ["https://", "http://"] where v.hasPrefix(scheme) { v = String(v.dropFirst(scheme.count)) }
            if v.hasPrefix("www.") { v = String(v.dropFirst(4)) }
            while v.hasSuffix("/") { v.removeLast() }
            guard !v.contains(" "), !v.isEmpty else { return nil }
            let parts = v.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            var host = String(parts[0])
            guard host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") else { return nil }
            if host == "twitter.com" { host = "x.com" }
            return parts.count > 1 ? "\(host)/\(parts[1])" : host
        }
    }

    /// Whether the rule matches the post (the preview's version of 37.3: a site by its link, words and about by its titles).
    static func matches(_ kind: HiddenRuleKind, _ value: String, _ post: LibraryPost) -> Bool {
        switch kind {
        case .upload:
            return post.service == "upload"
        case .words, .about:
            let text = ([post.customTitle, post.title, post.link?.absoluteString] + post.files.map { $0.name }).compactMap { $0 }
            return text.contains { $0.lowercased().contains(value) }
        case .site:
            guard let link = post.link, var host = link.host?.lowercased() else { return false }
            for prefix in ["www.", "m.", "vm."] where host.hasPrefix(prefix) { host = String(host.dropFirst(prefix.count)) }
            if host == "twitter.com" { host = "x.com" }
            let want = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            let wantHost = String(want[0])
            guard host == wantHost || host.hasSuffix("." + wantHost) else { return false }
            guard want.count > 1 else { return true }
            let path = link.path.lowercased()
            let prefix = "/" + want[1]
            return path == prefix || path.hasPrefix(prefix + "/")
        }
    }

    func list() -> HiddenRules {
        state.withLock { HiddenRules(rules: $0.rules, hidden: $0.hidden.count, held: 0) }
    }

    /// Adds a rule; throws the route's refusals.
    func add(kind: HiddenRuleKind, value raw: String, now: Date) throws -> HideRule {
        try state.withLock { s in
            guard let value = Self.normalize(kind, raw) else { throw CobaltError.api(code: "error.hidden.bad_rule", httpStatus: 400) }
            guard s.rules.count < 50 else { throw CobaltError.api(code: "error.hidden.too_many", httpStatus: 409) }
            s.counter += 1
            let rule = HideRule(
                id: "PrEvIeWrule\(String(format: "%05d", 100 + s.counter))", kind: kind, value: value, enabled: true, hits: 0,
                createdAt: now, updatedAt: now)
            s.rules.append(rule)
            return rule
        }
    }

    func update(id: String, enabled: Bool?, value raw: String?, now: Date) throws -> HideRule {
        try state.withLock { s in
            guard let i = s.rules.firstIndex(where: { $0.id == id }) else {
                throw CobaltError.api(code: "error.hidden.not_found", httpStatus: 404)
            }
            if let raw {
                guard let value = Self.normalize(s.rules[i].kind, raw) else {
                    throw CobaltError.api(code: "error.hidden.bad_rule", httpStatus: 400)
                }
                s.rules[i].value = value
            }
            if let enabled { s.rules[i].enabled = enabled }
            s.rules[i].updatedAt = now
            return s.rules[i]
        }
    }

    func remove(id: String) throws {
        try state.withLock { s in
            guard s.rules.contains(where: { $0.id == id }) else { throw CobaltError.api(code: "error.hidden.not_found", httpStatus: 404) }
            s.rules.removeAll { $0.id == id }
        }
    }

    func addHits(_ n: Int, to id: String) {
        state.withLock { s in
            if let i = s.rules.firstIndex(where: { $0.id == id }) { s.rules[i].hits += n }
        }
    }
}

extension PreviewClient {
    /// The preview server has `features.hidden`.
    private var hasHidden: Bool { PreviewData.capabilities(for: scenario).hidden }

    /// Every post this server lists when nothing is hidden: the library fixtures (and what the editor rendered).
    private func fixturePosts() -> [LibraryPost] {
        let now = clock.now()
        var posts = PreviewData.libraryPage(now: now).posts
        if scenario.hasEditor {
            posts = editorState.libraryPosts(now: now, timeScale: timeScale, scenario: scenario) + posts
        }
        return posts
    }

    /// The posts the library lists now: not hidden, with the files their status gave them.
    func visibleHiddenAware() -> [LibraryPost] {
        let now = clock.now()
        let gone = hiddenState.fixtureHidden
        let base = fixturePosts().filter { !gone.contains($0.id) } + hiddenState.released
        return base.map { hiddenState.applying(to: $0, links: privateState, now: now) }
    }

    // MARK: status

    public func setStatus(ids: [String], status: PostStatus) async throws -> StatusChange {
        guard hasHidden else { throw PipelineFailure.unsupported }
        hiddenState.record("STATUS \(status.rawValue) \(ids.count)")
        guard (1...200).contains(ids.count) else { throw CobaltError.api(code: "error.library.bad_request", httpStatus: 400) }
        try await clock.sleep(seconds: 0.25 * timeScale)
        let now = clock.now()
        let fixtures = fixturePosts()
        var seen = Set<String>()
        var posts: [StatusChange.Post] = []
        var failed: [StatusChange.Failure] = []
        for id in ids {
            let inFixtures = fixtures.first { $0.id == id || $0.files.contains { $0.id == id } }
            guard let post = hiddenState.known(id) ?? inFixtures else {
                failed.append(.init(id: id, error: "error.library.not_found"))
                continue
            }
            guard seen.insert(post.id).inserted else { continue }
            if status == .private, PreviewData.capabilities(for: scenario).shareBaseURL == nil {
                failed.append(.init(id: id, error: "error.share.off"))
                continue
            }
            let fromFixtures = fixtures.contains { $0.id == post.id }
            // the private links follow the status: a new key for `private`, none otherwise (36.2, 37.4)
            for file in post.files {
                if status == .private { _ = privateState.enable(.item, file.id, now: now) } else { privateState.revoke(.item, file.id) }
            }
            if status == .hidden {
                hiddenState.hide(post, fromFixtures: fromFixtures, by: .you)
            } else {
                hiddenState.release(post, fromFixtures: fromFixtures, status: status)
            }
            let files = post.files.map { file -> StatusChange.File in
                let url = status == .private ? privateState.link(.item, file.id, now: now)?.url : nil
                return StatusChange.File(id: file.id, visibility: status == .public ? "public" : "private", privateURL: url)
            }
            posts.append(.init(id: id, postKey: post.id, status: status, files: files))
        }
        return StatusChange(posts: posts, failed: failed)
    }

    // MARK: the album

    /// Pages of the album: the cursor is the offset of the next post.
    public func hiddenLibrary(cursor: String?, limit: Int) async throws -> LibraryPage {
        guard hasHidden else { throw PipelineFailure.unsupported }
        try await clock.sleep(seconds: 0.1 * timeScale)
        let all = hiddenState.hidden
        let start = cursor.flatMap(Int.init) ?? 0
        let size = max(1, min(50, limit))
        let slice = Array(all.dropFirst(start).prefix(size))
        let visible = visibleHiddenAware()
        return LibraryPage(
            posts: slice, postCount: visible.count, fileCount: visible.reduce(0) { $0 + $1.files.count },
            publicBytes: 0, privateBytes: 0, next: start + size < all.count ? String(start + size) : nil,
            hiddenCount: all.count)
    }

    // MARK: rules

    public func hiddenRules() async throws -> HiddenRules {
        guard hasHidden else { throw PipelineFailure.unsupported }
        try await clock.sleep(seconds: 0.1 * timeScale)
        return hiddenState.list()
    }

    public func createHiddenRule(kind: HiddenRuleKind, value: String, apply: Bool) async throws -> (rule: HideRule, applied: Int) {
        guard hasHidden else { throw PipelineFailure.unsupported }
        hiddenState.record("RULE add \(kind.rawValue)")
        try await clock.sleep(seconds: 0.2 * timeScale)
        let rule = try hiddenState.add(kind: kind, value: value, now: clock.now())
        let applied = apply ? applyRule(rule) : 0
        return (hiddenState.rules.first { $0.id == rule.id } ?? rule, applied)
    }

    public func previewHiddenRule(kind: HiddenRuleKind, value: String) async throws -> HiddenRulePreview {
        guard hasHidden else { throw PipelineFailure.unsupported }
        hiddenState.record("RULE preview \(kind.rawValue)")
        try await clock.sleep(seconds: 0.1 * timeScale)
        guard let normalized = PreviewHiddenState.normalize(kind, value) else {
            throw CobaltError.api(code: "error.hidden.bad_rule", httpStatus: 400)
        }
        let matches = visibleHiddenAware().filter { PreviewHiddenState.matches(kind, normalized, $0) }
        return HiddenRulePreview(matches: matches.count, sample: matches.prefix(6).map(\.id))
    }

    public func updateHiddenRule(id: String, enabled: Bool?, value: String?, apply: Bool) async throws -> (rule: HideRule, applied: Int) {
        guard hasHidden else { throw PipelineFailure.unsupported }
        hiddenState.record("RULE update \(id)")
        try await clock.sleep(seconds: 0.15 * timeScale)
        let rule = try hiddenState.update(id: id, enabled: enabled, value: value, now: clock.now())
        let applied = apply && rule.enabled ? applyRule(rule) : 0
        return (hiddenState.rules.first { $0.id == id } ?? rule, applied)
    }

    public func deleteHiddenRule(id: String) async throws {
        guard hasHidden else { throw PipelineFailure.unsupported }
        hiddenState.record("RULE delete \(id)")
        try await clock.sleep(seconds: 0.15 * timeScale)
        try hiddenState.remove(id: id)
    }

    /// Hides every visible post the rule matches, by the rule. How many.
    private func applyRule(_ rule: HideRule) -> Int {
        let fixtures = Set(fixturePosts().map(\.id))
        let matches = visibleHiddenAware().filter { PreviewHiddenState.matches(rule.kind, rule.value, $0) }
        for post in matches { hiddenState.hide(post, fromFixtures: fixtures.contains(post.id), by: .rule, rule: rule.id) }
        hiddenState.addHits(matches.count, to: rule.id)
        return matches.count
    }
}
