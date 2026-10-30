import Foundation

/// What the device remembers of the hidden posts, so the lists that show the device's own media can leave a hidden post's
/// offline copy out before any network answered (cold launch, offline, after a reset; APP-API-CONTRACT 37.7: "offline
/// copies stay on the device but are listed only in the hidden album").
///
/// One `Entry` per hidden post, with the keys `MediaItem.joins` matches a stored media to a post by: the post's id and its
/// session's id, its file ids, the public links of its files and their `media_name`s (a webp switched off lists no link).
/// Persisted in the app-group defaults by `Settings.hiddenIndex` and cleared on a server change.
public struct HiddenIndex: Sendable, Equatable, Codable {
    public struct Entry: Sendable, Equatable, Codable {
        public var post: String
        public var session: String?
        public var files: [String]
        public var urls: [String]
        public var names: [String]

        public init(_ post: LibraryPost) {
            self.post = post.id
            self.session = post.session?.id
            self.files = post.files.map(\.id)
            self.urls = post.files.compactMap { $0.url?.absoluteString }
            self.names = post.files.compactMap(\.mediaName)
        }
    }

    public private(set) var entries: [String: Entry]

    // Derived lookups, rebuilt whenever `entries` changes (not stored).
    public private(set) var postIDs: Set<String> = []
    public private(set) var fileIDs: Set<String> = []
    private var urls: Set<String> = []
    private var names: Set<String> = []

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
        rebuild()
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.entries = try c.decodeIfPresent([String: Entry].self, forKey: .entries) ?? [:]
        rebuild()
    }

    private enum CodingKeys: String, CodingKey { case entries }

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    private mutating func rebuild() {
        postIDs = Set(entries.values.flatMap { [$0.post] + ($0.session.map { [$0] } ?? []) })
        fileIDs = Set(entries.values.flatMap(\.files))
        urls = Set(entries.values.flatMap(\.urls))
        names = Set(entries.values.flatMap(\.names))
    }

    public func contains(post id: String) -> Bool { entries[id] != nil }

    /// Remembers these posts (new ones are added, known ones take the newer keys).
    public mutating func add(_ posts: [LibraryPost]) {
        guard !posts.isEmpty else { return }
        for post in posts { entries[post.id] = Entry(post) }
        rebuild()
    }

    /// Forgets these posts (unhidden, or gone from the server).
    public mutating func remove(posts ids: some Sequence<String>) {
        let before = entries.count
        for id in ids { entries[id] = nil }
        if entries.count != before { rebuild() }
    }

    /// Forgets files that were deleted; a post left with none is forgotten.
    public mutating func remove(files gone: Set<String>) {
        var changed = false
        for (id, var entry) in entries where !gone.isDisjoint(with: entry.files) {
            entry.files.removeAll { gone.contains($0) }
            entries[id] = entry.files.isEmpty ? nil : entry
            changed = true
        }
        if changed { rebuild() }
    }

    /// The server's whole list of hidden posts: what is not on it is no longer hidden.
    public mutating func replace(with posts: [LibraryPost]) {
        entries = Dictionary(posts.map { ($0.id, Entry($0)) }, uniquingKeysWith: { first, _ in first })
        rebuild()
    }

    // MARK: - matching

    /// A device media belongs to a hidden post: the same test as `MediaItem.joins` over the remembered keys.
    public func matches(_ local: StoredMedia) -> Bool {
        guard !entries.isEmpty else { return false }
        if !local.sessionIDs.isDisjoint(with: postIDs) { return true }
        return local.webps.contains { webp in
            guard let url = webp.remoteURL else { return false }
            if urls.contains(url.absoluteString) { return true }
            return MediaItem.mediaName(of: url).map(names.contains) ?? false
        }
    }

    /// One stored file belongs to a hidden post, on its own keys (the Photos album sync reads files, not medias).
    public func matches(_ video: StoredVideo) -> Bool {
        guard !entries.isEmpty else { return false }
        if let id = video.sessionID, postIDs.contains(id) { return true }
        if let id = video.libraryID, fileIDs.contains(id) || postIDs.contains(id) { return true }
        for url in [video.remoteURL, video.publicURL].compactMap({ $0 }) {
            if urls.contains(url.absoluteString) { return true }
            if let name = MediaItem.mediaName(of: url), names.contains(name) { return true }
        }
        return false
    }
}
