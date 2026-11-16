import Foundation
import Observation

// The library's two views and what they share (CONTRACT-LIBRARY2 decisions 10-14, section 4.3): the
// remembered view mode, sort, filter and search, and `LibraryRow`, one media as the views show it.

public enum LibraryViewMode: String, Sendable, CaseIterable { case mosaic, table }

public enum LibrarySortKey: String, Sendable, CaseIterable { case date, title, length, size, resolution, files, visibility, offline, kind }

public struct LibrarySort: Sendable, Equatable {
    public var key: LibrarySortKey
    public var ascending: Bool

    public init(key: LibrarySortKey, ascending: Bool) {
        self.key = key
        self.ascending = ascending
    }

    /// The server's own order, and the default.
    public static let newest = LibrarySort(key: .date, ascending: false)

    /// "date.desc": what the device remembers.
    var stored: String { "\(key.rawValue).\(ascending ? "asc" : "desc")" }

    init?(stored: String) {
        let parts = stored.split(separator: ".")
        guard parts.count == 2, let key = LibrarySortKey(rawValue: String(parts[0])),
              parts[1] == "asc" || parts[1] == "desc" else { return nil }
        self.init(key: key, ascending: parts[1] == "asc")
    }
}

public enum LibraryShow: String, Sendable, CaseIterable { case everything, publicOnly, privateOnly, uploads, offline }

/// The kind chips (apple/CONTRACT-GALLERY.md 1.21): `all · videos · photos · galleries · webps`. A media is one kind
/// (`MediaItem.kind`) on the videos, photos and galleries chips. `webps` is every media with a webp the owner made (a
/// webp of a video or a slideshow webp; its tile's face is that webp), so a video with webps is on both videos and
/// webps. Remembered like the other view state.
public enum LibraryKindFilter: String, Sendable, CaseIterable {
    case all, videos, photos, galleries, webps, emotes

    /// An emote is only on the emotes chip. `all` and `webps` leave it out. `hasWebp`: the media holds a made webp.
    func passes(kind: MediaKind, emote: Bool, hasWebp: Bool = false) -> Bool {
        if emote { return self == .emotes }
        switch self {
        case .all: return true
        case .videos: return kind == .video
        case .photos: return kind == .photo
        case .galleries: return kind == .gallery
        case .webps: return kind == .webp || hasWebp
        case .emotes: return false
        }
    }

    /// The chips a media is counted under besides `all`: its kind's, plus `webps` when it holds a made webp.
    public static func chips(kind: MediaKind, hasWebp: Bool) -> [LibraryKindFilter] {
        let own: LibraryKindFilter = switch kind {
        case .video: .videos
        case .photo: .photos
        case .gallery: .galleries
        case .webp: .webps
        }
        return hasWebp && own != .webps ? [own, .webps] : [own]
    }
}

extension MediaKind {
    /// The kind sort's order, ascending: galleries, photos, videos, webps (the board `Library-Mixed`'s "sort: kind").
    public var sortRank: Int {
        switch self {
        case .gallery: return 0
        case .photo: return 1
        case .video: return 2
        case .webp: return 3
        }
    }
}

/// `UserDefaults` keys of the remembered view state.
enum LibraryDefaults {
    static let view = "library.view"
    static let sort = "library.sort"
    static let show = "library.show"
    static let kind = "library.kind"
}

/// One media as the views show it: derived, value, sortable (table key paths are non-optional).
public struct LibraryRow: Identifiable, Sendable, Equatable {
    public let id: String                // post id
    public let item: MediaItem
    public let title: String             // item.titleText
    public let service: String           // "instagram", "x", "file"
    public let length: Double            // -1 unknown
    public let width: Int?, height: Int?
    public let pixels: Int               // w×h, 0 unknown
    public let hasVideo: Bool            // the media has an original rendition
    public let originalIsImage: Bool     // that original is an image upload (png, jpg, heic, gif, webp)
    public let webps: Int
    public let fileCount: Int            // renditions
    public let bytes: Int64              // all of the post's files
    public let isPublic: Bool            // the video's link is public (a media with no video: any public file)
    public let visibilityRank: Int       // 1 public, 0 private (sort)
    public let date: Date                // item.latestAt
    public let faceAspect: Double        // h / w of the face, 16:9 (landscape) when unknown
    public let isUpload: Bool
    /// How much of the media is kept on this device (`MediaItem.offline`).
    public let offline: MediaOffline
    /// What the media is (`MediaItem.kind`): the chips, the kind column, the gallery tile's stack.
    public let kind: MediaKind
    /// The items of a gallery (`MediaItem.itemCount`: the count badge); 0 for every other media.
    public let itemCount: Int
    /// A 7TV emote. It is not counted with webps.
    public let emote: Bool
    /// The media holds a webp the owner made (a webp of a video, or a slideshow webp): it is on the webps chip.
    public let hasWebp: Bool

    public init(item: MediaItem) {
        self.item = item
        id = item.post?.id ?? item.id
        title = item.titleText
        let postService = item.post?.service?.trimmingCharacters(in: .whitespaces).lowercased()
        isUpload = item.post.map { _ in postService == nil || postService == "" || postService == "upload" }
            ?? (item.service == nil)
        service = isUpload ? "file" : (item.service ?? "file")
        offline = item.offline
        kind = item.kind
        itemCount = item.kind == .gallery ? item.itemCount : 0
        emote = item.post?.isEmote ?? false
        hasWebp = item.hasMadeWebp

        let source = item.video ?? item.face
        let duration = source.duration ?? item.face.duration ?? item.post?.duration
        length = duration.flatMap { $0 > 0 ? $0 : nil } ?? -1
        width = source.width ?? item.face.width
        height = source.height ?? item.face.height
        pixels = (width ?? 0) * (height ?? 0)
        hasVideo = item.video != nil
        originalIsImage = Self.isImage(item.video)
        webps = item.webpCount
        fileCount = item.renditions.count

        if let files = item.post?.files, !files.isEmpty {
            bytes = files.reduce(0) { $0 + ($1.bytes ?? 0) }
        } else {
            bytes = item.renditions.reduce(0) { $0 + ($1.bytes ?? 0) }
        }
        // CONTRACT-VISIBILITY decision 13: the badge is the video's switch, not "some file is public" (a private
        // video with public webps is private). A media with no video is as public as its newest link.
        if let video = item.video {
            isPublic = video.visibility == .public
        } else {
            isPublic = item.renditions.contains { $0.visibility == .public }
        }
        visibilityRank = isPublic ? 1 : 0
        date = item.latestAt
        let face = item.face
        if let w = face.width, let h = face.height, w > 0, h > 0 {
            faceAspect = Double(h) / Double(w)
        } else {
            faceAspect = 9.0 / 16.0
        }
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "webp"]

    private static func isImage(_ video: Rendition?) -> Bool {
        guard let video else { return false }
        for type in [video.file?.contentType, video.hosted?.contentType] {
            if let type { return type.lowercased().hasPrefix("image/") }
        }
        if let url = video.local?.fileURL, imageExtensions.contains(url.pathExtension.lowercased()) { return true }
        if let name = video.local?.name, imageExtensions.contains((name as NSString).pathExtension.lowercased()) { return true }
        return false
    }

    // MARK: sort, filter, search

    /// Ties break by date (newest first), then id, whichever way the key runs.
    static func areInIncreasingOrder(_ a: LibraryRow, _ b: LibraryRow, by sort: LibrarySort) -> Bool {
        let order: ComparisonResult
        switch sort.key {
        case .date: order = compare(a.date, b.date)
        case .title: order = a.title.compare(b.title, options: [.caseInsensitive, .diacriticInsensitive, .numeric])
        case .length: order = compare(a.length, b.length)
        case .size: order = compare(a.bytes, b.bytes)
        case .resolution: order = compare(a.pixels, b.pixels)
        case .files: order = compare(a.fileCount, b.fileCount)
        case .visibility: order = compare(a.visibilityRank, b.visibilityRank)
        case .offline: order = compare(a.offline, b.offline)
        case .kind: order = compare(a.kind.sortRank, b.kind.sortRank)
        }
        if order != .orderedSame { return sort.ascending ? order == .orderedAscending : order == .orderedDescending }
        if sort.key != .date, a.date != b.date { return a.date > b.date }
        return a.id < b.id
    }

    private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }

    func passes(_ show: LibraryShow) -> Bool {
        switch show {
        case .everything: true
        case .publicOnly: isPublic
        case .privateOnly: !isPublic
        case .uploads: isUpload
        case .offline: offline != .none
        }
    }

    /// The text a search reads: the resolved title, the custom title, service, ref and file names.
    var searchText: String {
        var parts = [title, item.customTitle ?? "", service, item.service ?? "", item.ref ?? "", item.post?.title ?? ""]
        parts += item.post?.files.map(\.name) ?? []
        parts += item.local?.renditions.map(\.name) ?? []
        return parts.joined(separator: "\n")
    }

    func matches(folded query: String) -> Bool {
        searchText.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(query)
    }
}

extension LibraryModel {
    /// A search, a filter other than `everything` or a sort other than newest first needs every post: the
    /// server pages by latest activity only (decision 14).
    public var needsWholeLibrary: Bool {
        !trimmedQuery.isEmpty || show != .everything || sort != .newest || kindFilter != .all
    }

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - the rows, built off the main thread (8.17)

extension AppModel {
    /// The posts as rows: joined with the device's media, filtered by `show` and the kind chip, searched by `query`,
    /// sorted by `sort` (`LibraryRowsBuilder.build`). In the app this is the last finished snapshot: a view reading it
    /// observes only the snapshot, and a change to any input builds the next one off the main thread
    /// (`libraryRowInputsChanged`). Joining, filtering and sorting every post in the library's body cost a 914 ms frame
    /// on the switch to the library (8.16).
    public var libraryRows: [LibraryRow] { librarySnapshot.rows }

    /// How many loaded posts each kind chip has (the album's while the hidden chip is on), from the same build.
    public var libraryKindCounts: [LibraryKindFilter: Int] { librarySnapshot.kindCounts }

    /// The rows the library has settled on: every input change made so far is built in. For a caller that just changed
    /// what the library holds and decides by the rows that follow ("open in library", the sky map), where the snapshot
    /// may still be a build behind.
    public func settledLibraryRows() async -> [LibraryRow] {
        guard !libraryRowsInline, libraryRowsEngine.started else { return libraryRows }
        // A change made while a build runs starts another; a few rounds always catch up (each is one build).
        for _ in 0..<8 {
            guard let task = scheduleLibraryRows(libraryRowsInputs) else { break }
            await task.value
        }
        return libraryRowsSnapshot.rows
    }

    /// Everything the rows read, copied out of the models (each read here is observed by whoever reads this).
    var libraryRowsInputs: LibraryRowsInputs {
        LibraryRowsInputs(
            posts: library.posts, hiddenPosts: library.hiddenPosts, showingHidden: library.showingHidden,
            hiddenServed: capabilities.hidden, search: library.activeSearchResults, hiddenIndex: hiddenIndex,
            show: library.show, kind: library.kindFilter, query: library.trimmedQuery, sort: library.sort,
            media: store.media, localTitles: library.localTitles)
    }

    /// Previews and tests build inline, on the reader's thread, so a test that changes the library reads the rows that
    /// follow at once (every library test does). The app builds off the main thread.
    var libraryRowsInline: Bool { libraryRowsEngine.inline ?? ctx.isPreview }

    private var librarySnapshot: LibraryRowsSnapshot {
        if libraryRowsInline {
            // Reads every input, so a view is invalidated by each of them, but builds only when one really changed.
            let inputs = libraryRowsInputs
            if let memo = libraryRowsEngine.memo, memo.inputs == inputs { return memo.snapshot }
            let built = EngineClock.measure("library.rows") { LibraryRowsBuilder.build(inputs) }
            libraryRowsEngine.memo = LibraryRowsMemo(inputs: inputs, snapshot: built)
            return built
        }
        if !libraryRowsEngine.started {
            // The first read builds synchronously, once, on the reader's thread: the library's first frame shows its
            // tiles instead of an empty grid for a frame. Every later build runs off the main thread. The snapshot is
            // written before anything reads it, so the view reading this is not invalidated by its own write.
            libraryRowsEngine.started = true
            let inputs = watchLibraryRowInputs()
            let built = EngineClock.measure("library.rows") { LibraryRowsBuilder.build(inputs) }
            libraryRowsEngine.wanted = inputs
            libraryRowsEngine.publishes &+= 1
            libraryRowsSnapshot = built
            return built
        }
        return libraryRowsSnapshot
    }

    /// Starts the rows engine before anything shows the library (8.18): the first build runs off the main thread, so the
    /// library's first read finds a finished snapshot instead of building one on the main thread (0.77 s in 8.17 (120)
    /// on a hot phone). Later changes are watched as usual. Does nothing in previews and tests (they build inline) or
    /// once the engine has started. Called at launch before the library loads: each load that follows is built off the
    /// main thread as it lands.
    public func warmLibraryRows() {
        guard !libraryRowsInline, !libraryRowsEngine.started else { return }
        libraryRowsEngine.started = true
        scheduleLibraryRows(watchLibraryRowInputs())
    }

    /// Reads the inputs under observation and arms a one-shot watch on them; returns what it read.
    @discardableResult
    private func watchLibraryRowInputs() -> LibraryRowsInputs {
        withObservationTracking {
            libraryRowsInputs
        } onChange: { [weak self] in
            // Called on the writer's thread before the write lands: hop to the main actor, where the new value is in.
            guard let self else { return }
            Task { @MainActor in self.libraryRowInputsChanged() }
        }
    }

    /// An input changed: watch again (so a change during the build starts the next one), then build what is there now.
    /// Several writes in one turn of the main actor fire the watch once and are built together.
    func libraryRowInputsChanged() {
        let inputs = watchLibraryRowInputs()
        scheduleLibraryRows(inputs)
    }

    /// Builds `inputs` off the main thread unless they are what the snapshot holds or what the build in flight was given.
    /// A newer build makes every older one stale: its result is dropped (generation counter), never published. The
    /// snapshot is assigned only when the rows or counts changed, so an input change that moves no row redraws nothing.
    /// Returns the build that will settle these inputs, or nil when the snapshot already holds them.
    @discardableResult
    func scheduleLibraryRows(_ inputs: LibraryRowsInputs) -> Task<Void, Never>? {
        if libraryRowsEngine.wanted == inputs { return libraryRowsEngine.task }
        libraryRowsEngine.generation &+= 1
        let generation = libraryRowsEngine.generation
        libraryRowsEngine.wanted = inputs
        libraryRowsEngine.task?.cancel()
        let previous = libraryRowsSnapshot
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let (built, changed) = LibraryRowsBuilder.buildOffMain(inputs, against: previous)
            // a newer build is already out: skip the hop (`finishLibraryRows` would drop it anyway)
            if Task.isCancelled { return }
            await self?.finishLibraryRows(built, changed: changed, generation: generation)
        }
        libraryRowsEngine.task = task
        return task
    }

    private func finishLibraryRows(_ built: LibraryRowsSnapshot, changed: Bool, generation: Int) {
        // a newer build is out: this one was made from inputs that are gone
        guard generation == libraryRowsEngine.generation else { return }
        libraryRowsEngine.task = nil
        guard changed else { return }
        libraryRowsEngine.publishes &+= 1
        libraryRowsSnapshot = built
    }
}

/// The rows engine's bookkeeping on `AppModel` (not observed: only `libraryRowsSnapshot` is).
struct LibraryRowsEngine {
    /// Nil: previews and tests inline, the app off the main thread. A test sets it to try the other path.
    var inline: Bool?
    /// Inline builds: the last one and what it was built from.
    var memo: LibraryRowsMemo?
    /// The first (synchronous) build happened and the inputs are watched.
    var started = false
    /// What the snapshot holds, or what the build in flight was given.
    var wanted: LibraryRowsInputs?
    var generation = 0
    var task: Task<Void, Never>?
    /// How many times a snapshot was assigned (the tests' equality gate).
    var publishes = 0
}

struct LibraryRowsMemo {
    var inputs: LibraryRowsInputs
    var snapshot: LibraryRowsSnapshot
}
