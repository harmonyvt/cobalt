import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
public final class LibraryModel {
    public internal(set) var posts: [LibraryPost] = []
    public internal(set) var postCount: Int = 0
    public internal(set) var fileCount: Int = 0
    public internal(set) var isLoading: Bool = false
    public internal(set) var failure: PipelineFailure?
    public internal(set) var hasMore: Bool = false
    public var expandedPostID: String?                    // one card open at a time
    /// Evicted items being fetched again (`redownload(_:)`), by `StoredVideo.id`, with the bytes so
    /// far. An entry exists exactly while its download runs, so a card can show a ring from it.
    public internal(set) var redownloads: [String: TransferProgress] = [:]

    @ObservationIgnored let ctx: PipelineContext
    @ObservationIgnored var cursor: String?
    @ObservationIgnored var redownloadTasks: [String: Task<StoredVideo, Error>] = [:]

    static let pageSize = 20

    init(context: PipelineContext, seed: LibraryPage? = nil) {
        self.ctx = context
        if let seed { apply(seed, replacing: true) }
    }

    func reset() {
        posts = []; postCount = 0; fileCount = 0; failure = nil; hasMore = false; cursor = nil
        expandedPostID = nil
    }

    func apply(_ page: LibraryPage, replacing: Bool) {
        if replacing {
            posts = page.posts
        } else {
            let known = Set(posts.map(\.id))
            posts += page.posts.filter { !known.contains($0.id) }
        }
        postCount = page.postCount
        fileCount = page.fileCount
        cursor = page.next
        hasMore = page.next != nil
    }

    public func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let client = ctx.client
            let page = try await client.library(cursor: nil, limit: Self.pageSize)
            apply(page, replacing: true)
            failure = nil
        } catch {
            if let f = pipelineFailure(from: error, during: .saving) { failure = f }
        }
    }

    public func loadMore() async {
        guard !isLoading, hasMore, let cursor else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let client = ctx.client
            let page = try await client.library(cursor: cursor, limit: Self.pageSize)
            apply(page, replacing: false)
            failure = nil
        } catch {
            if let f = pipelineFailure(from: error, during: .saving) { failure = f }
        }
    }

    public func copyLink(_ file: LibraryFile) {
        guard let url = file.url else { return }
        ctx.clipboard.copy(url.absoluteString)
    }

    /// To Photos. On macOS the caller uses `fileExporter` with `localCopy` instead.
    public func save(_ file: LibraryFile) async throws {
        let (url, isTemp) = try await copy(file)
        do {
            try await ctx.photos.save(fileURL: url, isImage: file.contentType?.hasPrefix("image/") ?? false)
        } catch {
            if isTemp { try? FileManager.default.removeItem(at: url) }
            throw pipelineFailure(from: error, during: .saving) ?? error
        }
        if isTemp { try? FileManager.default.removeItem(at: url) }
    }

    /// A file on disk with this item's bytes: the stored original when the device has it, else a
    /// download (keyed for a private copy, open for a public file).
    public func localCopy(_ file: LibraryFile) async throws -> URL {
        try await copy(file).0
    }

    /// Private copy → public link (copied to the clipboard).
    public func host(_ file: LibraryFile) async throws -> URL {
        do {
            let hosted = try await ctx.client.publish(item: file.id)
            ctx.clipboard.copy(hosted.url.absoluteString)
            await refresh()
            return hosted.url
        } catch {
            throw pipelineFailure(from: error, during: .saving, limits: ctx.capabilities.limits) ?? error
        }
    }

    /// Only when `file.deletable`; removes it from `posts`.
    public func delete(_ file: LibraryFile) async throws {
        guard file.deletable, let name = file.mediaName else { throw PipelineFailure.unsupported }
        do {
            try await ctx.client.deleteMedia(name: name)
        } catch {
            throw pipelineFailure(from: error, during: .saving, limits: ctx.capabilities.limits) ?? error
        }
        guard let index = posts.firstIndex(where: { $0.files.contains { $0.id == file.id } }) else { return }
        posts[index].files.removeAll { $0.id == file.id }
        fileCount = max(0, fileCount - 1)
        if posts[index].files.isEmpty {
            if expandedPostID == posts[index].id { expandedPostID = nil }
            posts.remove(at: index)
            postCount = max(0, postCount - 1)
        }
    }

    /// The server confirmed these files gone (a partial or a whole-post delete): they leave `posts`,
    /// and a post left with no file goes with them.
    func drop(files ids: Set<String>) {
        guard !ids.isEmpty else { return }
        for index in posts.indices.reversed() {
            let before = posts[index].files.count
            posts[index].files.removeAll { ids.contains($0.id) }
            let removed = before - posts[index].files.count
            guard removed > 0 else { continue }
            fileCount = max(0, fileCount - removed)
            if posts[index].files.isEmpty {
                if expandedPostID == posts[index].id { expandedPostID = nil }
                posts.remove(at: index)
                postCount = max(0, postCount - 1)
            }
        }
    }

    /// A whole post is gone on the server.
    func drop(post id: String) {
        guard let index = posts.firstIndex(where: { $0.id == id }) else { return }
        fileCount = max(0, fileCount - posts[index].files.count)
        postCount = max(0, postCount - 1)
        if expandedPostID == id { expandedPostID = nil }
        posts.remove(at: index)
    }

    // MARK: -

    func copy(_ file: LibraryFile) async throws -> (URL, Bool) {
        let fm = FileManager.default
        let post = posts.first { $0.files.contains { $0.id == file.id } }
        // The device's own entry for this item, kept or evicted (CONTRACT-LIVE.md 4.2): the stored
        // original of a private copy, or the stored webp of a public file.
        let stored: StoredVideo?
        if file.role == .privateCopy {
            stored = ctx.store.videos.first {
                $0.kind == .original && (($0.sessionID != nil && $0.sessionID == post?.session?.id)
                    || ($0.link != nil && $0.link == post?.link))
            }
        } else if let url = file.url {
            stored = ctx.store.videos.first { $0.kind == .webp && $0.remoteURL == url }
        } else {
            stored = nil
        }
        if let url = stored?.fileURL, fm.fileExists(atPath: url.path) { return (url, false) }

        let remote: RemoteFile
        if file.role == .privateCopy {
            remote = .libraryItem(id: file.id)
        } else if let url = file.url {
            remote = .open(url)
        } else {
            throw PipelineFailure.unsupported
        }
        var name = file.name
        if (name as NSString).pathExtension.isEmpty,
           let type = file.contentType, let ext = UTType(mimeType: type)?.preferredFilenameExtension {
            name += ".\(ext)"
        }
        let downloaded: URL
        do {
            downloaded = try await ctx.client.download(remote, to: ctx.store.inboxURL(for: name), progress: { _ in })
        } catch {
            throw pipelineFailure(from: error, during: .saving, limits: ctx.capabilities.limits) ?? error
        }
        // An evicted entry takes the download back (and becomes the newest for eviction) instead of
        // leaving a second copy behind; with "keep videos on this iphone" off it stays a temp file.
        if let stored, ctx.settings.keepVideosOnDevice,
           let refilled = try? await ctx.store.attach(file: downloaded, to: stored.id, move: true),
           let url = refilled.fileURL {
            return (url, false)
        }
        return (downloaded, true)
    }
}
