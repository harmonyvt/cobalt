import Foundation

// The library's two views and what they share (CONTRACT-LIBRARY2 decisions 10-14, section 4.3): the
// remembered view mode, sort, filter and search, and `LibraryRow`, one media as the views show it.

public enum LibraryViewMode: String, Sendable, CaseIterable { case mosaic, table }

public enum LibrarySortKey: String, Sendable, CaseIterable { case date, title, length, size, resolution, files, visibility }

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

public enum LibraryShow: String, Sendable, CaseIterable { case everything, publicOnly, privateOnly, uploads }

/// `UserDefaults` keys of the remembered view state.
enum LibraryDefaults {
    static let view = "library.view"
    static let sort = "library.sort"
    static let show = "library.show"
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
    public let isPublic: Bool            // any public file
    public let visibilityRank: Int       // 1 public, 0 private (sort)
    public let date: Date                // item.latestAt
    public let faceAspect: Double        // h / w of the face, 16:9 (landscape) when unknown
    public let isUpload: Bool

    public init(item: MediaItem) {
        self.item = item
        id = item.post?.id ?? item.id
        title = item.titleText
        let postService = item.post?.service?.trimmingCharacters(in: .whitespaces).lowercased()
        isUpload = item.post.map { _ in postService == nil || postService == "" || postService == "upload" }
            ?? (item.service == nil)
        service = isUpload ? "file" : (item.service ?? "file")

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
            isPublic = files.contains { $0.kind == .public }
        } else {
            bytes = item.renditions.reduce(0) { $0 + ($1.bytes ?? 0) }
            isPublic = item.renditions.contains { $0.publicURL != nil }
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
        !trimmedQuery.isEmpty || show != .everything || sort != .newest
    }

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension AppModel {
    /// The posts as rows: joined with the device's media, filtered by `show`, searched by `query`, sorted
    /// by `sort`.
    public var libraryRows: [LibraryRow] {
        var rows = library.posts.map { LibraryRow(item: mediaItem(for: $0)) }
        if library.show != .everything { rows = rows.filter { $0.passes(library.show) } }
        let query = library.trimmedQuery
        if !query.isEmpty {
            let folded = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            rows = rows.filter { $0.matches(folded: folded) }
        }
        let sort = library.sort
        return rows.sorted { LibraryRow.areInIncreasingOrder($0, $1, by: sort) }
    }
}
