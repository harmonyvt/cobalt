import Foundation

// Rich tool cards (APP-API-CONTRACT section 38): every `cobalt.*` call a chat code step made, as a chip, and a card for the
// calls with something to see. Everything is optional on the wire: a call or card that does not decode is dropped, never
// the step, and a card type this app does not know is a chip only.

/// One call of a code step: the op, how long it took, how it ended and its card.
public struct ChatToolCall: Sendable, Equatable, Decodable {
    public enum Status: String, Sendable, Equatable {
        /// It ran.
        case done
        /// It threw; `error` says why (the model saw the same line).
        case error
        /// It waits for the owner's yes on a confirm card (33.5).
        case asked
    }

    /// The op name, `library.search`.
    public var op: String
    public var ms: Int
    public var status: Status
    public var error: String?
    public var card: ChatToolCard?

    public init(op: String, ms: Int = 0, status: Status = .done, error: String? = nil, card: ChatToolCard? = nil) {
        self.op = op
        self.ms = ms
        self.status = status
        self.error = error
        self.card = card
    }

    enum CodingKeys: String, CodingKey { case op, ms, status, error, card }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        op = try c.decode(String.self, forKey: .op)
        ms = c.lenient(Double.self, .ms).map { Int($0.rounded()) } ?? 0
        status = c.lenient(String.self, .status).flatMap(Status.init(rawValue:)) ?? .done
        error = c.lenient(String.self, .error)
        card = ((try? c.decodeIfPresent(Lossy<ChatToolCard>.self, forKey: .card)) ?? nil)?.value
    }
}

/// What a call shows (38.2). The cases mirror the wire's `type`.
public enum ChatToolCard: Sendable, Equatable, Decodable {
    case search(Search)
    case look(postIDs: [String])
    case emotes(Emotes)
    case edit(Edit)
    case job(Job)
    case box(Box)
    case files(Files)
    case link(Link)
    case collection(Folder)
    case saved(Saved)
    case facts(Facts)

    // MARK: the shapes

    /// `library.search` / `library.list`: what it looked for and its best hits.
    public struct Search: Sendable, Equatable, Decodable {
        public struct Hit: Sendable, Equatable, Decodable {
            public var postID: String
            public var score: Double?
            public init(postID: String, score: Double? = nil) { self.postID = postID; self.score = score }
            enum CodingKeys: String, CodingKey { case postID = "postId", score }
        }
        public var query: String
        public var within: String?
        public var total: Int
        public var hits: [Hit]

        public init(query: String, within: String? = nil, total: Int, hits: [Hit]) {
            self.query = query
            self.within = within
            self.total = total
            self.hits = hits
        }

        enum CodingKeys: String, CodingKey { case query, within, total, hits }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            query = c.lenient(String.self, .query) ?? ""
            within = c.lenient(String.self, .within)
            total = c.lenient(Int.self, .total) ?? 0
            hits = c.lossyArray(Hit.self, .hits)
        }

        /// The best score, for the bars.
        public var topScore: Double? { hits.compactMap(\.score).max() }
    }

    /// `emotes.find` / `emotes.save`: 7TV emotes, animated.
    public struct Emotes: Sendable, Equatable, Decodable {
        public struct Emote: Sendable, Equatable, Decodable, Identifiable {
            public var id: String
            public var name: String
            public var animated: Bool
            public var url: URL
            /// Saved in the library: its file id.
            public var libraryID: String?
            public init(id: String, name: String, animated: Bool = true, url: URL, libraryID: String? = nil) {
                self.id = id
                self.name = name
                self.animated = animated
                self.url = url
                self.libraryID = libraryID
            }
            enum CodingKeys: String, CodingKey { case id, name, animated, url, libraryID = "libraryId" }
            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = try c.decode(String.self, forKey: .id)
                name = c.lenient(String.self, .name) ?? ""
                animated = c.lenient(Bool.self, .animated) ?? false
                guard let raw = c.lenient(String.self, .url), let u = URL(string: raw), u.scheme == "https" else {
                    throw DecodingError.dataCorruptedError(forKey: .url, in: c, debugDescription: "an emote needs an https url")
                }
                url = u
                libraryID = c.lenient(String.self, .libraryID)
            }
        }
        public var query: String?
        /// `top_weekly`, `trending_daily`, ... (section 20.1); nil for a name search.
        public var sort: String?
        /// `emotes.save`: the emote it saved.
        public var saved: Bool
        public var emotes: [Emote]

        public init(query: String? = nil, sort: String? = nil, saved: Bool = false, emotes: [Emote]) {
            self.query = query
            self.sort = sort
            self.saved = saved
            self.emotes = emotes
        }

        enum CodingKeys: String, CodingKey { case query, sort, saved, emotes }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            query = c.lenient(String.self, .query)
            sort = c.lenient(String.self, .sort)
            saved = c.lenient(Bool.self, .saved) ?? false
            emotes = c.lossyArray(Emote.self, .emotes)
        }
    }

    /// `edits.get` / `create` / `update` / `addOverlay`: the project as a small timeline.
    public struct Edit: Sendable, Equatable, Decodable {
        public enum Change: String, Sendable, Equatable { case created, updated, viewed }

        public struct Clip: Sendable, Equatable, Decodable, Identifiable {
            public enum Kind: String, Sendable, Equatable { case video, photo, gif, webp, emote, cutout }
            public var id: String
            public var item: String
            public var postID: String?
            public var kind: Kind?
            public var title: String?
            public var picture: URL?
            /// On the output timeline, seconds.
            public var at: Double
            public var length: Double
            /// The part of the source it plays.
            public var sourceIn: Double
            public var sourceOut: Double
            public var speed: Double
            public var pitch: Double?
            /// Added by this call.
            public var isNew: Bool

            public init(
                id: String, item: String = "", postID: String? = nil, kind: Kind? = .video, title: String? = nil, picture: URL? = nil,
                at: Double, length: Double, sourceIn: Double = 0, sourceOut: Double = 0, speed: Double = 1, pitch: Double? = nil, isNew: Bool = false
            ) {
                self.id = id
                self.item = item
                self.postID = postID
                self.kind = kind
                self.title = title
                self.picture = picture
                self.at = at
                self.length = length
                self.sourceIn = sourceIn
                self.sourceOut = sourceOut
                self.speed = speed
                self.pitch = pitch
                self.isNew = isNew
            }

            /// A still or looping picture rather than a video.
            public var isPicture: Bool { kind != nil && kind != .video }

            enum CodingKeys: String, CodingKey {
                case id, item, postID = "postId", kind, title, picture, at, length, sourceIn = "in", sourceOut = "out", speed, pitch, isNew
            }
            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = c.lenient(String.self, .id) ?? UUID().uuidString
                item = c.lenient(String.self, .item) ?? ""
                postID = c.lenient(String.self, .postID)
                kind = c.lenient(String.self, .kind).flatMap(Kind.init(rawValue:))
                title = c.lenient(String.self, .title)
                picture = c.lenient(String.self, .picture).flatMap(URL.init(string:))
                at = max(0, c.lenient(Double.self, .at) ?? 0)
                length = max(0, c.lenient(Double.self, .length) ?? 0)
                sourceIn = c.lenient(Double.self, .sourceIn) ?? 0
                sourceOut = c.lenient(Double.self, .sourceOut) ?? 0
                speed = c.lenient(Double.self, .speed) ?? 1
                pitch = c.lenient(Double.self, .pitch)
                isNew = c.lenient(Bool.self, .isNew) ?? false
            }
        }

        public struct Track: Sendable, Equatable, Decodable, Identifiable {
            public var isMain: Bool
            /// The overlay layer (0 for the main track and the first overlay layer).
            public var index: Int
            public var clips: [Clip]
            public var id: String { isMain ? "main" : "overlay-\(index)" }
            public init(isMain: Bool, index: Int = 0, clips: [Clip]) {
                self.isMain = isMain
                self.index = index
                self.clips = clips
            }
            enum CodingKeys: String, CodingKey { case name, index, clips }
            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                isMain = (c.lenient(String.self, .name) ?? "main") == "main"
                index = c.lenient(Int.self, .index) ?? 0
                clips = c.lossyArray(Clip.self, .clips)
            }
        }

        public struct Render: Sendable, Equatable, Decodable {
            public var status: String
            public var progress: Double?
            public var postID: String?
            public init(status: String, progress: Double? = nil, postID: String? = nil) {
                self.status = status
                self.progress = progress
                self.postID = postID
            }
            enum CodingKeys: String, CodingKey { case status, progress, postID = "postId" }
            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                status = c.lenient(String.self, .status) ?? ""
                progress = c.lenient(Double.self, .progress)
                postID = c.lenient(String.self, .postID)
            }
        }

        public var projectID: String
        public var title: String?
        public var revision: Int?
        public var duration: Double
        public var width: Int?
        public var height: Int?
        public var change: Change
        public var tracks: [Track]
        public var render: Render?

        public init(
            projectID: String, title: String? = nil, revision: Int? = nil, duration: Double, width: Int? = nil, height: Int? = nil,
            change: Change = .viewed, tracks: [Track], render: Render? = nil
        ) {
            self.projectID = projectID
            self.title = title
            self.revision = revision
            self.duration = duration
            self.width = width
            self.height = height
            self.change = change
            self.tracks = tracks
            self.render = render
        }

        enum CodingKeys: String, CodingKey { case projectID = "projectId", title, revision, duration, width, height, change, tracks, render }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            projectID = try c.decode(String.self, forKey: .projectID)
            title = c.lenient(String.self, .title)
            revision = c.lenient(Int.self, .revision)
            width = c.lenient(Int.self, .width)
            height = c.lenient(Int.self, .height)
            change = c.lenient(String.self, .change).flatMap(Change.init(rawValue:)) ?? .viewed
            tracks = c.lossyArray(Track.self, .tracks)
            render = (try? c.decodeIfPresent(Render.self, forKey: .render)) ?? nil
            let end = tracks.flatMap(\.clips).map { $0.at + $0.length }.max() ?? 0
            duration = max(c.lenient(Double.self, .duration) ?? 0, end)
        }

        /// The clips this call added.
        public var added: [Clip] { tracks.flatMap(\.clips).filter(\.isNew) }
        /// The clip order for "the clip at this time": overlays first (top layer first), then main.
        public func clips(at seconds: Double) -> [Clip] {
            tracks.reversed().flatMap(\.clips).filter { $0.at <= seconds && seconds < $0.at + $0.length }
        }
    }

    /// A make job, an editor render, `jobs.wait` / `jobs.onDone`.
    public struct Job: Sendable, Equatable, Decodable {
        public var op: String
        public var job: String
        /// opening, queued, running, done, error, cancelled
        public var status: String
        public var progress: Double?
        public var error: String?
        public var postID: String?
        public var kind: String?
        public var seconds: Double?
        public var width: Int?
        public var height: Int?
        public var bytes: Int64?
        public var shareURL: URL?
        public var watching: Bool
        public var projectID: String?

        public init(
            op: String, job: String = "", status: String, progress: Double? = nil, error: String? = nil, postID: String? = nil, kind: String? = nil,
            seconds: Double? = nil, width: Int? = nil, height: Int? = nil, bytes: Int64? = nil, shareURL: URL? = nil, watching: Bool = false,
            projectID: String? = nil
        ) {
            self.op = op
            self.job = job
            self.status = status
            self.progress = progress
            self.error = error
            self.postID = postID
            self.kind = kind
            self.seconds = seconds
            self.width = width
            self.height = height
            self.bytes = bytes
            self.shareURL = shareURL
            self.watching = watching
            self.projectID = projectID
        }

        public var isDone: Bool { status == "done" }
        public var isFailed: Bool { status == "error" || status == "cancelled" }

        enum CodingKeys: String, CodingKey {
            case op, job, status, progress, error, postID = "postId", kind, seconds, width, height, bytes, shareURL = "shareUrl", watching, projectID = "projectId"
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            op = c.lenient(String.self, .op) ?? ""
            job = c.lenient(String.self, .job) ?? ""
            status = c.lenient(String.self, .status) ?? "queued"
            progress = c.lenient(Double.self, .progress)
            error = c.lenient(String.self, .error)
            postID = c.lenient(String.self, .postID)
            kind = c.lenient(String.self, .kind)
            seconds = c.lenient(Double.self, .seconds)
            width = c.lenient(Int.self, .width)
            height = c.lenient(Int.self, .height)
            bytes = c.lenient(Double.self, .bytes).map { Int64($0) }
            shareURL = c.lenient(String.self, .shareURL).flatMap(URL.init(string:))
            watching = c.lenient(Bool.self, .watching) ?? false
            projectID = c.lenient(String.self, .projectID)
        }
    }

    /// `box.run`: the command and the ends of what it printed.
    public struct Box: Sendable, Equatable, Decodable {
        public var cmd: String
        public var code: Int?
        public var timedOut: Bool
        public var stdout: String
        public var stderr: String
        public init(cmd: String, code: Int? = 0, timedOut: Bool = false, stdout: String = "", stderr: String = "") {
            self.cmd = cmd
            self.code = code
            self.timedOut = timedOut
            self.stdout = stdout
            self.stderr = stderr
        }
        enum CodingKeys: String, CodingKey { case cmd, code, timedOut, stdout, stderr }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            cmd = c.lenient(String.self, .cmd) ?? ""
            code = c.lenient(Int.self, .code)
            timedOut = c.lenient(Bool.self, .timedOut) ?? false
            stdout = c.lenient(String.self, .stdout) ?? ""
            stderr = c.lenient(String.self, .stderr) ?? ""
        }
        public var succeeded: Bool { code == 0 && !timedOut }
    }

    /// `box.pull` (in) / `box.save` (out): files that moved between the library and the box.
    public struct Files: Sendable, Equatable, Decodable {
        public struct File: Sendable, Equatable, Decodable {
            public var name: String
            public var bytes: Int64?
            public init(name: String, bytes: Int64? = nil) { self.name = name; self.bytes = bytes }
            enum CodingKeys: String, CodingKey { case name, bytes }
            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                name = c.lenient(String.self, .name) ?? ""
                bytes = c.lenient(Double.self, .bytes).map { Int64($0) }
            }
        }
        public var isIn: Bool
        public var files: [File]
        public var postID: String?
        public init(isIn: Bool, files: [File], postID: String? = nil) {
            self.isIn = isIn
            self.files = files
            self.postID = postID
        }
        enum CodingKeys: String, CodingKey { case direction, files, postID = "postId" }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            isIn = c.lenient(String.self, .direction) != "out"
            files = c.lossyArray(File.self, .files)
            postID = c.lenient(String.self, .postID)
        }
    }

    /// `links.create` / `rotate` / `private`.
    public struct Link: Sendable, Equatable, Decodable {
        public var id: String?
        public var url: URL
        public var title: String?
        public var files: Int?
        public var isPrivate: Bool
        public init(id: String? = nil, url: URL, title: String? = nil, files: Int? = nil, isPrivate: Bool = false) {
            self.id = id
            self.url = url
            self.title = title
            self.files = files
            self.isPrivate = isPrivate
        }
        enum CodingKeys: String, CodingKey { case id, url, title, files, isPrivate = "private" }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.lenient(String.self, .id)
            guard let raw = c.lenient(String.self, .url), let u = URL(string: raw), u.scheme == "https" else {
                throw DecodingError.dataCorruptedError(forKey: .url, in: c, debugDescription: "a link needs an https url")
            }
            url = u
            title = c.lenient(String.self, .title)
            files = c.lenient(Int.self, .files)
            isPrivate = c.lenient(Bool.self, .isPrivate) ?? false
        }
    }

    /// `collections.*` / `sets.*`.
    public struct Folder: Sendable, Equatable, Decodable {
        public enum Change: String, Sendable, Equatable { case created, added, updated }
        public var isSet: Bool
        public var id: String
        public var name: String
        /// Links in a collection, collections in a set.
        public var count: Int?
        public var change: Change
        public init(isSet: Bool = false, id: String, name: String, count: Int? = nil, change: Change = .updated) {
            self.isSet = isSet
            self.id = id
            self.name = name
            self.count = count
            self.change = change
        }
        enum CodingKeys: String, CodingKey { case of, id, name, count, change }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            isSet = c.lenient(String.self, .of) == "set"
            id = try c.decode(String.self, forKey: .id)
            name = c.lenient(String.self, .name) ?? ""
            count = c.lenient(Int.self, .count)
            change = c.lenient(String.self, .change).flatMap(Change.init(rawValue:)) ?? .updated
        }
    }

    /// `library.save`: the post a link became.
    public struct Saved: Sendable, Equatable, Decodable {
        public var postIDs: [String]
        public var title: String?
        /// ready, saving, queued, error
        public var status: String?
        public init(postIDs: [String], title: String? = nil, status: String? = "ready") {
            self.postIDs = postIDs
            self.title = title
            self.status = status
        }
        enum CodingKeys: String, CodingKey { case postIDs = "postIds", title, status }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            postIDs = c.lossyArray(String.self, .postIDs)
            title = c.lenient(String.self, .title)
            status = c.lenient(String.self, .status)
        }
    }

    /// Any other change: a title and a few rows ("renamed", "made private").
    public struct Facts: Sendable, Equatable, Decodable {
        public struct Row: Sendable, Equatable { public var name: String; public var value: String }
        public var title: String
        public var rows: [Row]
        public var postIDs: [String]
        public init(title: String, rows: [Row] = [], postIDs: [String] = []) {
            self.title = title
            self.rows = rows
            self.postIDs = postIDs
        }
        enum CodingKeys: String, CodingKey { case title, rows, postIDs = "postIds" }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = c.lenient(String.self, .title) ?? ""
            rows = (c.lenient([[String]].self, .rows) ?? []).compactMap { $0.count == 2 ? Row(name: $0[0], value: $0[1]) : nil }
            postIDs = c.lossyArray(String.self, .postIDs)
        }
    }

    // MARK: decoding

    enum TypeKey: String, CodingKey { case type, postIDs = "postIds" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: TypeKey.self)
        switch try c.decode(String.self, forKey: .type) {
        case "search": self = .search(try Search(from: decoder))
        case "look": self = .look(postIDs: c.lossyArray(String.self, .postIDs))
        case "emotes": self = .emotes(try Emotes(from: decoder))
        case "edit": self = .edit(try Edit(from: decoder))
        case "job": self = .job(try Job(from: decoder))
        case "box": self = .box(try Box(from: decoder))
        case "files": self = .files(try Files(from: decoder))
        case "link": self = .link(try Link(from: decoder))
        case "collection": self = .collection(try Folder(from: decoder))
        case "saved": self = .saved(try Saved(from: decoder))
        case "facts": self = .facts(try Facts(from: decoder))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown card \(other)")
        }
    }

    /// The posts the card draws, for the thread's `posts` map.
    public var postIDs: [String] {
        switch self {
        case .search(let s): return s.hits.map(\.postID)
        case .look(let ids): return ids
        case .emotes(let e): return e.emotes.compactMap(\.libraryID)
        case .edit(let e): return e.tracks.flatMap(\.clips).compactMap(\.postID) + [e.render?.postID].compactMap { $0 }
        case .job(let j): return [j.postID].compactMap { $0 }
        case .files(let f): return [f.postID].compactMap { $0 }
        case .saved(let s): return s.postIDs
        case .facts(let f): return f.postIDs
        case .box, .link, .collection: return []
        }
    }
}

/// A card of a step with the call that drew it (`ChatStep.cards`).
public struct ChatStepCard: Sendable, Equatable, Identifiable {
    /// The call's place in the step.
    public var id: Int
    public var call: ChatToolCall
    public var card: ChatToolCard
}

extension ChatStep {
    /// The cards of this step's calls, in call order. Two calls that drew the same thing (`jobs.wait` on a job a make
    /// started, a second look at an edit, a link rotated) keep only the later card, except that a plain look at an edit
    /// never hides the card that showed what changed.
    public var cards: [ChatStepCard] {
        var out: [ChatStepCard] = []
        for (i, call) in calls.enumerated() {
            guard let card = call.card else { continue }
            if let key = card.mergeKey, let j = out.firstIndex(where: { $0.card.mergeKey == key }) {
                if case .edit(let later) = card, later.change == .viewed, case .edit(let earlier) = out[j].card, earlier.change != .viewed {
                    continue
                }
                out.remove(at: j)
            }
            out.append(ChatStepCard(id: i, call: call, card: card))
        }
        return out
    }
}

extension ChatToolCard {
    /// Cards that describe the same thing share a key: the later one replaces the earlier.
    var mergeKey: String? {
        switch self {
        case .job(let j): return j.job.isEmpty ? nil : "job:\(j.job)"
        case .edit(let e): return "edit:\(e.projectID)"
        case .link(let l): return "link:\(l.url.absoluteString)"
        case .collection(let c): return "\(c.isSet ? "set" : "collection"):\(c.id)"
        default: return nil
        }
    }
}

extension KeyedDecodingContainer {
    /// The value when it is there and of that type; nil otherwise (never throws).
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }

    /// The elements that decode; an odd one is dropped.
    func lossyArray<T: Decodable>(_ type: T.Type, _ key: Key) -> [T] {
        ((try? decodeIfPresent([Lossy<T>].self, forKey: key)) ?? nil)?.compactMap(\.value) ?? []
    }
}
