import Foundation
import UniformTypeIdentifiers

// What "keep offline" needs to know about one rendition (CONTRACT-OFFLINE.md decision 9): where its bytes may
// still live, best first, the key it is tracked under, and what to do when the file lands. Pure functions: the
// engine (`OfflineDownloads`) and `LibraryModel.redownload` share them.

// MARK: - Public vocabulary (section 5)

/// Why a download ended for good (or gave up). Codable: a failed entry is kept in the queue ledger.
public enum OfflineFailure: Sendable, Equatable, Codable {
    /// Every place that might have the file said it is gone.
    case gone
    /// The network never let it finish (five tries).
    case unreachable
    /// The server refused the key (401 / 403).
    case auth
    /// This device is full.
    case full
    /// Anything else the server said (an HTTP status).
    case other(Int)
}

/// One rendition as the owner sees it, as far as being on this device goes.
public enum RenditionOffline: Sendable, Equatable {
    /// Kept, and the file is here (in Files on iOS).
    case offline(bytes: Int64)
    /// The file is here but nobody asked to keep it: the cache may take it.
    case cached(bytes: Int64)
    case downloading(TransferProgress)
    /// Queued, or asked and not moving yet (no network, or behind the two connections the session allows).
    case waiting
    case failed(OfflineFailure)
    /// Not here, and there is somewhere to fetch it from.
    case none
    /// Not here, and nothing to fetch it from (a plain cobalt save with no server copy).
    case unavailable
}

/// The key a rendition's download is tracked under: the server's file id when the library lists one, else the
/// local record's id. `AppModel.offlineState(of:)` also checks every alias, so a rendition whose library listing
/// arrives (or goes) mid-download keeps its state.
public enum OfflineKey {
    public static func of(_ r: Rendition) -> String {
        if let id = r.file?.id ?? r.hosted?.id { return "f:\(id)" }
        if let local = r.local { return "l:\(local.id)" }
        // nothing fetchable and nothing local (a bare link): never shared between media
        if let url = r.publicURL { return "u:\(url.absoluteString)" }
        return "r:\(r.id)"
    }

    /// Every key this rendition has been or may be tracked under, primary first.
    static func aliases(of r: Rendition) -> [String] {
        var out: [String] = [of(r)]
        for id in r.serverFileIDs { out.append("f:\(id)") }
        if let local = r.local { out.append("l:\(local.id)") }
        var seen: Set<String> = []
        return out.filter { seen.insert($0).inserted }
    }
}

// MARK: - A place to fetch from

/// `RemoteFile`, Codable: the queue ledger keeps the sources it has not tried yet.
enum OfflineSource: Codable, Equatable, Sendable {
    case open(URL)
    case studioSource(session: String)
    case libraryItem(id: String)

    var remoteFile: RemoteFile {
        switch self {
        case .open(let url): return .open(url)
        case .studioSource(let session): return .studioSource(session: session)
        case .libraryItem(let id): return .libraryItem(id: id)
        }
    }

    init(_ file: RemoteFile) {
        switch file {
        case .open(let url): self = .open(url)
        case .studioSource(let session): self = .studioSource(session: session)
        case .libraryItem(let id): self = .libraryItem(id: id)
        }
    }
}

/// One thing to fetch and what to do with it when it lands. Everything a background wake needs is in here (the
/// app may be started fresh, with no library loaded).
struct OfflineJob: Codable, Equatable, Sendable {
    /// A record the store does not have yet: a library post kept offline on a device that never held it.
    struct NewRecord: Codable, Equatable, Sendable {
        var kind: StoredVideo.Kind
        var media: MediaInfo
        var sessionID: String?
        var link: URL?
        var remoteURL: URL?
        var publicURL: URL?
        /// The server's date, so an old post does not jump to the front of the orbit.
        var createdAt: Date
        var title: String?
        /// The device's media this joins (its other renditions), when it has one.
        var mediaID: String?
        /// A gallery's item or a file made from it (apple/CONTRACT-GALLERY.md 4); nil on every other rendition.
        var role: GalleryRole?
        var itemIndex: Int?
        var madeFrom: [Int]?
        var madeSpec: Data?
        var libraryID: String?
    }

    enum Target: Codable, Equatable, Sendable {
        /// The record exists (evicted, or never had a file): the file is attached to it.
        case existing(id: String)
        case new(NewRecord)
    }

    var key: String
    /// Every key the rendition is known under (the engine answers state queries for all of them).
    var aliases: [String]
    var target: Target
    /// Best first.
    var sources: [OfflineSource]
    var expectedBytes: Int64?
    /// The inbox name, with a real extension: the store derives the stored file's extension from it.
    var fileName: String

    /// The photos ledger / folder ledger key the finished file will have, so the origin skip can be applied
    /// before the file lands (see `OfflineDownloads.land`).
    @MainActor
    func notNewKeys(store: OfflineStore) -> [String] {
        switch target {
        case .existing(let id):
            guard let video = store.videos.first(where: { $0.id == id }) else { return [] }
            return [PhotosKey.of(video)]
        case .new(let n):
            return [PhotosKey.of(kind: n.kind, sessionID: n.sessionID, remoteURL: n.remoteURL, storeID: "")]
        }
    }
}

// MARK: - Building jobs

enum OfflineSources {
    /// Where a rendition's bytes may live, best first. The first 404/409/410 moves to the next.
    ///
    /// - video: the post's private copy (keyed, durable, Range-aware, either visibility), the hosted file's URL,
    ///   the studio session's source while it lives (7 days), the URL this device first downloaded it from.
    /// - webp: its public URL, the private route when the file is switchable (a webp switched private has no
    ///   public URL), the URL this device recorded.
    static func sources(for r: Rendition, session: LibrarySession?, now: Date) -> [OfflineSource] {
        var out: [OfflineSource] = []
        func add(_ source: OfflineSource) { if !out.contains(source) { out.append(source) } }
        switch r.kind {
        case .video:
            if let file = r.file { add(.libraryItem(id: file.id)) }
            if let url = r.hosted?.url { add(.open(url)) }
            if let url = r.publicURL { add(.open(url)) }
            let sid = r.local?.sessionID ?? session?.id
            // a session the library says is over is not tried (a local record's own session may be older than the post's)
            let alive = session.map { $0.id != sid || $0.expiresAt > now } ?? true
            if let sid, alive { add(.studioSource(session: sid)) }
            if let url = r.local?.remoteURL { add(.open(url)) }
        case .webp:
            let isPrivate = r.file?.wireVisibility == .private
            if !isPrivate, let url = r.file?.url ?? r.publicURL { add(.open(url)) }
            if let file = r.file, file.canToggleVisibility || isPrivate { add(.libraryItem(id: file.id)) }
            if !isPrivate, let url = r.local?.remoteURL { add(.open(url)) }
        case .item, .slideshow, .galleryImage, .crop:
            // a gallery's item or a file made from it: the post's own row (keyed, either visibility), then its public link
            if let file = r.file { add(.libraryItem(id: file.id)) }
            if let url = r.publicURL { add(.open(url)) }
            if let url = r.local?.remoteURL { add(.open(url)) }
        }
        return out
    }

    /// The job for a rendition that has no file here. Nil when there is nowhere to fetch it from.
    static func job(
        for r: Rendition, in item: MediaItem, mediaBase: URL?, now: Date
    ) -> OfflineJob? {
        let sources = sources(for: r, session: item.post?.session, now: now)
        guard !sources.isEmpty else { return nil }
        let key = OfflineKey.of(r)
        let name = r.local?.name ?? r.file?.name ?? r.hosted?.name ?? item.post?.title ?? "cobalt"
        let fileName = inboxName(name, ext: fileExtension(of: r))
        let target: OfflineJob.Target
        if let local = r.local {
            target = .existing(id: local.id)
        } else {
            let sessionID = item.post.map { $0.session?.id ?? $0.id } ?? r.local?.sessionID
            let remote: URL? = r.isWebp ? (r.file?.url ?? r.publicURL ?? privateWebpURL(r.file, mediaBase: mediaBase)) : nil
            let info = MediaInfo(
                name: name, duration: r.duration, width: r.width, height: r.height, bytes: r.bytes,
                isImage: !r.isWebp && isImage(r))
            var record = OfflineJob.NewRecord(
                kind: r.isWebp || r.isAnimatedMade ? .webp : .original, media: info, sessionID: sessionID,
                link: item.link ?? item.post?.link,
                remoteURL: remote, publicURL: r.isWebp ? nil : (r.isPublic ? r.publicURL : nil),
                createdAt: r.createdAt, title: item.customTitle, mediaID: item.local?.id)
            if let file = r.file, r.isItem || r.isMade {
                record.role = r.isItem ? .item : file.galleryRole
                record.itemIndex = r.itemIndex
                record.madeFrom = r.isMade ? item.itemIndices(of: file.madeFrom) : nil
                record.madeSpec = file.madeSpec?.data
                record.libraryID = file.id
            }
            target = .new(record)
        }
        return OfflineJob(
            key: key, aliases: OfflineKey.aliases(of: r), target: target, sources: sources, expectedBytes: r.bytes,
            fileName: fileName)
    }

    /// A webp switched private lists no URL, but its name still says which local record is its twin
    /// (`MediaItem.isSameWebp` matches on the name): the media base plus the name.
    static func privateWebpURL(_ file: LibraryFile?, mediaBase: URL?) -> URL? {
        guard let file, file.url == nil, let name = file.mediaName, let base = mediaBase else { return nil }
        return base.appendingPathComponent(name)
    }

    static func isImage(_ r: Rendition) -> Bool {
        for type in [r.file?.contentType, r.hosted?.contentType] {
            if let type { return type.lowercased().hasPrefix("image/") }
        }
        return false
    }

    private static let knownExtensions: Set<String> = ["mp4", "mov", "m4v", "gif", "webp", "png", "jpg", "jpeg", "heic"]

    static func fileExtension(of r: Rendition) -> String {
        if r.isWebp || r.isAnimatedMade { return "webp" }
        for name in [r.local?.name, r.file?.name, r.hosted?.name] {
            if let name {
                let ext = (name as NSString).pathExtension.lowercased()
                if knownExtensions.contains(ext) { return ext }
            }
        }
        for type in [r.file?.contentType, r.hosted?.contentType] {
            if let type, let ext = UTType(mimeType: type)?.preferredFilenameExtension, knownExtensions.contains(ext) { return ext }
        }
        return "mp4"
    }

    static func inboxName(_ name: String, ext: String) -> String {
        let base = (name as NSString).pathExtension.lowercased() == ext ? String(name.dropLast(ext.count + 1)) : name
        return "\(base.isEmpty ? "cobalt" : base).\(ext)"
    }

    // MARK: failures

    /// The server (or the web) answered "not here": try the next place. Anything else (offline, a revoked key,
    /// a full disk) would fail the same way again.
    static func isGone(_ error: Error) -> Bool {
        guard let e = error as? CobaltError else { return false }
        switch e {
        case .api(let code, let status):
            return [404, 409, 410].contains(status)
                || ["error.studio.expired", "error.studio.not_found", "error.studio.not_ready"].contains(code)
        case .invalidResponse(let status):
            return [404, 410].contains(status)
        default:
            return false
        }
    }

    /// ENOSPC (a POSIX error, or Cocoa's own "out of space").
    static func isDiskFull(domain: String, code: Int) -> Bool {
        (domain == NSPOSIXErrorDomain && code == Int(ENOSPC)) || (domain == NSCocoaErrorDomain && code == NSFileWriteOutOfSpaceError)
    }

    static func isDiskFull(_ error: Error) -> Bool {
        let ns = error as NSError
        if isDiskFull(domain: ns.domain, code: ns.code) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError { return isDiskFull(domain: underlying.domain, code: underlying.code) }
        return false
    }

    /// The URL loading system's codes that mean "no network right now" (waiting, not failing).
    static func isNetworkLoss(_ code: Int) -> Bool {
        [
            NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost,
            NSURLErrorDNSLookupFailed, NSURLErrorNotConnectedToInternet, NSURLErrorInternationalRoamingOff,
            NSURLErrorCallIsActive, NSURLErrorDataNotAllowed, NSURLErrorSecureConnectionFailed,
        ].contains(code)
    }
}
