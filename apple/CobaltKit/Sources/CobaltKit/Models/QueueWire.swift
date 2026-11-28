import Foundation

// MARK: - GET /queue (APP-API-CONTRACT section 23; `features.queue`)

/// One snapshot of the server's own work for the queue tab: this key's view of the line (the same object
/// `GET /studio/line` answers), the search index's backlog and the posters still to make. Each part is nil when the
/// server could not read it (it answers 200 with `null` for that part). Decoded tolerantly: every field may be missing,
/// unknown keys are ignored, and a malformed part decodes to nil instead of failing the whole snapshot.
public struct QueueSnapshot: Sendable, Equatable {
    /// The library search index (`deploy/huggingface/embed`, the API Worker's 15-minute cron).
    public struct Search: Sendable, Equatable {
        /// One post the indexer takes next.
        public struct Next: Sendable, Equatable, Identifiable {
            public var postKey: String
            public var title: String?
            public var id: String { postKey }

            public init(postKey: String, title: String? = nil) {
                self.postKey = postKey
                self.title = title
            }
        }

        /// False when the server has no embedding Space (`EMBED_TOKEN` not set): every other field is then absent.
        public var enabled: Bool
        public var posts: Int
        public var indexed: Int
        public var pending: Int
        public var failed: Int
        /// A cron pass is embedding right now. Nil when the server cannot say (its run table is not there yet).
        public var running: Bool?
        public var lastRunAt: Date?
        /// Posts indexed in the last hour; nil when there was no pass in that hour (or the server cannot say).
        public var ratePerHour: Double?
        public var next: [Next]

        public init(
            enabled: Bool, posts: Int = 0, indexed: Int = 0, pending: Int = 0, failed: Int = 0, running: Bool? = nil,
            lastRunAt: Date? = nil, ratePerHour: Double? = nil, next: [Next] = []
        ) {
            self.enabled = enabled; self.posts = posts; self.indexed = indexed; self.pending = pending
            self.failed = failed; self.running = running; self.lastRunAt = lastRunAt; self.ratePerHour = ratePerHour
            self.next = next
        }

        /// 0...1 of the posts that are indexed; nil when there are no posts.
        public var fraction: Double? {
            guard posts > 0 else { return nil }
            return min(1, max(0, Double(indexed) / Double(posts)))
        }

        /// There is something to show: a backlog, or a pass running.
        public var hasWork: Bool { enabled && (pending > 0 || running == true) }
    }

    public struct Posters: Sendable, Equatable {
        public var pending: Int
        public init(pending: Int) { self.pending = pending }
    }

    /// One audio loudness leveling job returned by `GET /queue` (`audio`) or tracked locally by `AudioLevelStore`.
    public struct AudioLevelJob: Sendable, Equatable, Identifiable, Decodable {
        public enum State: String, Sendable, Equatable, Decodable {
            case rendering, ready, failed
        }

        public var itemID: String
        public var title: String
        public var state: State
        public var targetLufs: Double?
        public var outputLufs: Double?
        public var error: String?
        public var updatedAt: Date
        public var leveledAt: Date?

        public var id: String { itemID }
        public var isActive: Bool { state == .rendering }
        public var lastMoment: Date { leveledAt ?? updatedAt }

        public init(
            itemID: String, title: String, state: State, targetLufs: Double? = nil, outputLufs: Double? = nil,
            error: String? = nil, updatedAt: Date, leveledAt: Date? = nil
        ) {
            self.itemID = itemID
            self.title = title
            self.state = state
            self.targetLufs = targetLufs
            self.outputLufs = outputLufs
            self.error = error
            self.updatedAt = updatedAt
            self.leveledAt = leveledAt
        }

        private enum CodingKeys: String, CodingKey {
            case itemID = "itemId"
            case title, state
            case targetLufs
            case outputLufs
            case error
            case updatedAt
            case leveledAt
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            itemID = try c.decode(String.self, forKey: .itemID)
            let rawTitle = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil
            title = (rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? itemID
            state = try c.decode(State.self, forKey: .state)
            targetLufs = (try? c.decodeIfPresent(Double.self, forKey: .targetLufs)) ?? nil
            outputLufs = (try? c.decodeIfPresent(Double.self, forKey: .outputLufs)) ?? nil
            error = (try? c.decodeIfPresent(String.self, forKey: .error)) ?? nil
            let updatedMs = (try? c.decodeIfPresent(Double.self, forKey: .updatedAt)) ?? 0
            updatedAt = Date(timeIntervalSince1970: updatedMs / 1000)
            let leveledMs = (try? c.decodeIfPresent(Double.self, forKey: .leveledAt)) ?? nil
            leveledAt = leveledMs.map { Date(timeIntervalSince1970: $0 / 1000) }
        }

        /// True when `self` should beat `other` during local/server merge (settled states beat optimistic rendering,
        /// otherwise newer timestamp wins).
        func isFresher(than other: AudioLevelJob) -> Bool {
            if state != .rendering && other.state == .rendering { return true }
            if state == .rendering && other.state != .rendering { return updatedAt > other.updatedAt.addingTimeInterval(2) }
            return updatedAt >= other.updatedAt
        }
    }

    /// The server's clock when it answered (ms on the wire); nil when absent.
    public var now: Date?
    public var line: ServerLineSnapshot?
    public var search: Search?
    public var posters: Posters?
    /// The editor's renders (`features.editor`, APP-API-CONTRACT 31.13): the running ones, then those that ended in the last
    /// 30 minutes, newest first. Nil when the server has none to say (an older server, a failed read, or `null`).
    public var edits: [EditRender]?
    /// Active and recently settled audio loudness leveling jobs (`features.audio_leveling`).
    public var audio: [AudioLevelJob]?

    public init(
        now: Date? = nil, line: ServerLineSnapshot? = nil, search: Search? = nil, posters: Posters? = nil,
        edits: [EditRender]? = nil, audio: [AudioLevelJob]? = nil
    ) {
        self.now = now; self.line = line; self.search = search; self.posters = posters; self.edits = edits; self.audio = audio
    }

    /// Something on the server is moving right now (a job running or waiting in the line, an index pass running, a render or audio leveling going).
    /// `ServerActivityStore` decides its own cadence from the part of this that nobody in the app follows (3 s, else 30 s).
    public var isActive: Bool {
        if let line, line.running != nil || !line.entries.isEmpty { return true }
        if search?.running == true { return true }
        if edits?.contains(where: \.isActive) == true { return true }
        if audio?.contains(where: \.isActive) == true { return true }
        return false
    }
}

extension QueueSnapshot: Decodable {
    private enum CodingKeys: String, CodingKey { case now, line, search, posters, edits, audio }

    private struct WireSearch: Decodable {
        struct WireNext: Decodable { var postKey: String?; var title: String? }
        var enabled: Bool?
        var posts: Int?
        var indexed: Int?
        var pending: Int?
        var failed: Int?
        var running: Bool?
        var lastRunAt: Double?
        var ratePerHour: Double?
        var next: [Lossy<WireNext>]?
    }

    private struct WirePosters: Decodable { var pending: Int? }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        now = ((try? c.decodeIfPresent(Double.self, forKey: .now)) ?? nil).map { Date(timeIntervalSince1970: $0 / 1000) }
        line = (try? c.decodeIfPresent(ServerLineSnapshot.self, forKey: .line)) ?? nil
        if let s = (try? c.decodeIfPresent(WireSearch.self, forKey: .search)) ?? nil {
            let next = (s.next ?? []).compactMap(\.value).compactMap { n -> Search.Next? in
                guard let key = n.postKey, !key.isEmpty else { return nil }
                return Search.Next(postKey: key, title: n.title)
            }
            search = Search(
                enabled: s.enabled ?? false, posts: max(0, s.posts ?? 0), indexed: max(0, s.indexed ?? 0),
                pending: max(0, s.pending ?? 0), failed: max(0, s.failed ?? 0), running: s.running,
                lastRunAt: s.lastRunAt.map { Date(timeIntervalSince1970: $0 / 1000) }, ratePerHour: s.ratePerHour,
                next: next)
        } else {
            search = nil
        }
        posters = ((try? c.decodeIfPresent(WirePosters.self, forKey: .posters)) ?? nil).map { Posters(pending: max(0, $0.pending ?? 0)) }
        edits = ((try? c.decodeIfPresent([Lossy<EditRender>].self, forKey: .edits)) ?? nil).map { $0.compactMap(\.value) }
        audio = ((try? c.decodeIfPresent([Lossy<AudioLevelJob>].self, forKey: .audio)) ?? nil).map { $0.compactMap(\.value) }
    }
}
