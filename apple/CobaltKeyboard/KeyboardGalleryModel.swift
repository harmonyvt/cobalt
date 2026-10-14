import CobaltKit
import Foundation
import Observation

enum KeyboardWords {
    static let idle = "tap copies · hold for the link"
    static let copied = "copied. paste it in."
    static let noKey = "cobalt can't find your key from here"
    static let noAccess = "allow full access to copy from your library."
    static let noPublicLinks = "no public links: the post is private."
    static let tooBig = "too big to copy."
}

/// Which rendition a library tile shows, downloads, and links. The face is the one the library shows.
enum KeyboardFace {
    static func of(_ post: LibraryPost) -> Rendition? {
        MediaItem.merge(local: nil, post: post)?.face
    }

    /// `face.publicURL` when it is http or https. Never `post.link` (that is the source page).
    static func publicLink(of post: LibraryPost) -> URL? {
        guard let face = of(post) else { return nil }
        return httpURL(face.publicURL)
    }

    /// Poster first, then the post's poster, then the public URL of a still. Never a video file.
    static func thumbnailURL(post: LibraryPost, face: Rendition) -> URL? {
        if let poster = face.posterURL { return poster }
        if let poster = post.posterURL { return poster }
        guard isPicture(face) else { return nil }
        return httpURL(face.publicURL)
    }

    /// An image content type, or a webp rendition. Anything else is shown as a video.
    static func isPicture(_ face: Rendition) -> Bool {
        if isWebpRendition(face) { return true }
        return contentType(of: face)?.hasPrefix("image/") == true
    }

    static func label(post: LibraryPost, face: Rendition?) -> String {
        if let custom = nonempty(post.customTitle) { return custom }
        if let title = nonempty(post.title) { return title }
        if let face, !isPicture(face) { return "video" }
        return "photo"
    }

    /// Public https URL (never sent the key), else the private file, else the hosted file.
    static func remoteFile(for face: Rendition) -> RemoteFile? {
        if let url = httpURL(face.publicURL) { return .open(url) }
        if let file = face.file { return .libraryItem(id: file.id) }
        if let hosted = face.hosted { return .libraryItem(id: hosted.id) }
        return nil
    }

    /// Public URL's path extension, else the library file name, else a known content type. Nil means do not copy.
    static func fileExtension(face: Rendition, remote: RemoteFile) -> String? {
        if case .open(let url) = remote, let ext = mediaExtension(url.pathExtension) { return ext }
        if let name = face.file?.name ?? face.hosted?.name, let ext = mediaExtension((name as NSString).pathExtension) {
            return ext
        }
        switch contentType(of: face) {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/png": return "png"
        case "image/webp": return "webp"
        case "image/gif": return "gif"
        case "image/heic", "image/heif": return "heic"
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        default: return nil
        }
    }

    static func storageID(face: Rendition, remote: RemoteFile) -> String {
        let raw: String
        switch remote {
        case .libraryItem(let id): raw = id
        case .open, .studioSource: raw = face.file?.id ?? face.hosted?.id ?? face.id
        }
        let safe = String(raw.map { ch in
            (ch.isASCII && (ch.isLetter || ch.isNumber)) || ch == "-" || ch == "_" ? ch : "-"
        })
        return safe.isEmpty ? "cobalt" : safe
    }

    private static func isWebpRendition(_ face: Rendition) -> Bool {
        if face.isWebp || face.isAnimatedMade { return true }
        return contentType(of: face) == "image/webp"
    }

    private static func contentType(of face: Rendition) -> String? {
        guard let raw = face.file?.contentType ?? face.hosted?.contentType else { return nil }
        let base = raw.split(separator: ";", maxSplits: 1).first.map(String.init) ?? raw
        let type = base.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return type.isEmpty ? nil : type
    }

    private static func httpURL(_ url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    private static func mediaExtension(_ raw: String) -> String? {
        let ext = raw.lowercased()
        guard !ext.isEmpty, ext.count <= 8, ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return ext
    }

    private static func nonempty(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Library pages for the gallery. One load at a time. The client is built here, not in CobaltKit.
@MainActor @Observable
final class KeyboardGalleryModel {
    enum Phase: Equatable { case loading, ready, empty, noKey, failed }

    enum Notice: Equatable {
        case copied
        case failed(String)
    }

    private(set) var posts: [LibraryPost] = []
    private(set) var phase: Phase = .loading
    /// False until Allow Full Access is on. No network and no general pasteboard without it.
    private(set) var fullAccess = false
    /// Set while a tile's file is downloading. Only that tile shows a working state.
    var busyID: String?
    /// Replaces the idle caption until a later copy succeeds or a link insert clears it.
    var notice: Notice?

    @ObservationIgnored var onCopy: @MainActor (LibraryPost) -> Void = { _ in }
    @ObservationIgnored var onHold: @MainActor (LibraryPost) -> Void = { _ in }

    @ObservationIgnored private var client: HTTPCobaltClient?
    @ObservationIgnored private var nextCursor: String?
    @ObservationIgnored private var loading = false

    private static let pageLimit = 30

    func setFullAccess(_ allowed: Bool) {
        fullAccess = allowed
    }

    /// When the keyboard appears. Does nothing once a page is on screen, or without full access.
    func reloadIfEmpty() {
        guard fullAccess, posts.isEmpty else { return }
        begin(reset: true)
    }

    func refresh() async {
        guard fullAccess, !loading else { return }
        loading = true
        await run(reset: true)
    }

    func loadMoreIfNeeded(showing id: String) {
        guard posts.last?.id == id else { return }
        begin(reset: false)
    }

    /// Nil when the face has nothing to copy, or no real media extension. Throws when the download fails.
    /// The file is under `tmp/cobalt-keyboard/` and the caller removes it.
    func prepareFile(for post: LibraryPost) async throws -> URL? {
        guard let face = KeyboardFace.of(post) else { return nil }
        guard let remote = KeyboardFace.remoteFile(for: face) else { return nil }
        guard let ext = KeyboardFace.fileExtension(face: face, remote: remote) else { return nil }
        guard let client else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cobalt-keyboard", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appendingPathComponent("\(KeyboardFace.storageID(face: face, remote: remote)).\(ext)")
        do {
            return try await client.download(remote, to: dest) { _ in }
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
    }

    private func begin(reset: Bool) {
        guard fullAccess else { return }
        guard !loading else { return }
        if !reset && nextCursor == nil { return }
        loading = true
        Task { await self.run(reset: reset) }
    }

    private func run(reset: Bool) async {
        defer { loading = false }
        guard fullAccess else { return }
        if reset && posts.isEmpty { phase = .loading }
        let settings = Settings.shared()
        guard settings.apiKey() != nil else {
            client = nil
            posts = []
            nextCursor = nil
            phase = .noKey
            return
        }
        let server = settings.serverURL
        if client == nil || client?.baseURL != server {
            let keychain = Keychain.shared
            client = HTTPCobaltClient(
                baseURL: server,
                apiKey: { Settings.apiKey(in: keychain, forServer: server) })
        }
        guard let client else {
            phase = .noKey
            return
        }
        let cursor = reset ? nil : nextCursor
        do {
            // Same rule as PipelineContext.libraryPage. Not called: this target does not build a pipeline.
            let caps = await client.capabilities()
            let page: LibraryPage
            if caps.gallery {
                page = try await client.library(cursor: cursor, limit: Self.pageLimit, v3: true)
            } else {
                page = try await client.library(cursor: cursor, limit: Self.pageLimit, v2: caps.visibility)
            }
            absorb(page, reset: reset, requested: cursor)
        } catch {
            if posts.isEmpty { phase = .failed }
            else { notice = .failed(Copy.actionFailed) }
        }
    }

    private func absorb(_ page: LibraryPage, reset: Bool, requested: String?) {
        var seen = Set(reset ? [] : posts.map(\.id))
        var next = reset ? [] : posts
        var added = 0
        for post in page.posts where seen.insert(post.id).inserted {
            next.append(post)
            added += 1
        }
        posts = next
        if page.posts.isEmpty || (!reset && (page.next == requested || added == 0)) {
            nextCursor = nil
        } else {
            nextCursor = page.next
        }
        phase = posts.isEmpty ? .empty : .ready
    }
}
