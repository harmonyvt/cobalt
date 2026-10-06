import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import CobaltKit

// Tests written before the offline folder store files the way a 1.10 save did: in the cache, evictable. The
// offline tests below say `keep:` explicitly; these keep every older call site meaning what it always meant.
extension OfflineStore {
    @discardableResult
    func add(
        file: URL, kind: StoredVideo.Kind, media: MediaInfo, sessionID: String?, link: URL?, remoteURL: URL?, move: Bool,
        publicURL: URL? = nil, mediaID: String? = nil, clip: WebpClip? = nil
    ) async throws -> StoredVideo {
        try await add(
            file: file, kind: kind, media: media, sessionID: sessionID, link: link, remoteURL: remoteURL, move: move,
            publicURL: publicURL, mediaID: mediaID, clip: clip, keep: false)
    }

    @discardableResult
    func attach(file: URL, to id: String, move: Bool) async throws -> StoredVideo {
        try await attach(file: file, to: id, move: move, keep: false)
    }
}

// MARK: - the offline folder rig


/// A 50-byte poster and no flipbook: no decoding.
struct OfflineTools: MediaTools {
    var posterBytes = 50
    func probe(file: URL) async -> MediaInfo? { nil }
    func frames(of input: FrameInput, duration: Double?, count: Int) -> AsyncThrowingStream<Frame, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func poster(for file: URL, isImage: Bool, to destination: URL) async -> Bool {
        guard posterBytes > 0 else { return false }
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? Data(repeating: 9, count: posterBytes).write(to: destination)) != nil
    }
    func previewFrames(of file: URL, animatedImage: Bool, count: Int, maxEdge: CGFloat) async -> [CGImage] { [] }
}

/// The system file operations, with a crash and a volume boundary on demand. After the crash point every
/// further change throws too: a crashed process does nothing more, and the rest of the run must not carry on.
final class Dead: Sendable { let flag = Mutex(false) }

struct TestFileOps: OfflineFileOps {
    /// Throws `OfflineInterrupted` at this step, as a crash would stop the run there.
    var crashAt: OfflineMoveStep?
    /// Every rename out of `files/` fails with EXDEV (another volume): the copy path.
    var crossVolume = false
    private let dead = Dead()
    private var system: SystemFileOps { SystemFileOps() }

    init(crashAt: OfflineMoveStep? = nil, crossVolume: Bool = false) {
        self.crashAt = crashAt
        self.crossVolume = crossVolume
    }

    private func alive() throws {
        if dead.flag.withLock({ $0 }) { throw OfflineInterrupted(step: crashAt ?? .tagged) }
    }

    func setTag(_ tag: OfflineTag, at url: URL) throws { try alive(); try system.setTag(tag, at: url) }
    func rename(_ from: URL, to: URL, exclusive: Bool) throws {
        try alive()
        if crossVolume, !from.lastPathComponent.hasSuffix(".part"), from.deletingLastPathComponent().lastPathComponent == "files" {
            throw POSIXError(.EXDEV)
        }
        try system.rename(from, to: to, exclusive: exclusive)
    }
    func copy(_ from: URL, to: URL) throws { try alive(); try system.copy(from, to: to) }
    func fullSync(_ url: URL) throws { try alive(); try system.fullSync(url) }
    func size(of url: URL) -> Int64? { system.size(of: url) }
    func remove(_ url: URL) throws { try alive(); try system.remove(url) }
    func checkpoint(_ step: OfflineMoveStep) throws {
        try alive()
        if step == crashAt {
            dead.flag.withLock { $0 = true }
            throw OfflineInterrupted(step: step)
        }
    }
}

/// Where the hidden store root sits: the app group's container (shared with the extension) or the app's own
/// Application Support (the owner's Feather build has no group). The visible root is `Documents` either way.
enum OfflineLayout: CaseIterable {
    case appGroup, fallback
    var hidden: String {
        switch self {
        case .appGroup: return "Shared/AppGroup/Videos"
        case .fallback: return "Data/Library/Application Support/Videos"
        }
    }
}

@MainActor
final class OfflineRig {
    let base: URL
    let hidden: URL
    let visible: URL
    let sync: URL
    let defaults: UserDefaults
    private(set) var made = 0

    init(layout: OfflineLayout = .appGroup, limit: Int64? = nil) throws {
        // resolved, so paths read back from the file system compare equal (/var is /private/var)
        base = try makeTempDirectory().resolvingSymlinksInPath()
        hidden = base.appendingPathComponent(layout.hidden, isDirectory: true)
        visible = base.appendingPathComponent("Data/Documents", isDirectory: true)
        sync = base.appendingPathComponent("Shared/AppGroup/Sync", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: visible, withIntermediateDirectories: true)
        let suite = "cobalt.offline.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        LimitDefaults.write(limit, to: defaults)
    }

    /// `visible: false` is the share extension (and the Mac in wave 1).
    func store(visible useVisible: Bool = true, ops: TestFileOps = TestFileOps(), posterBytes: Int = 50) -> OfflineStore {
        OfflineStore(
            root: hidden, tools: OfflineTools(posterBytes: posterBytes), defaults: defaults,
            now: { Date() }, visibleRoot: useVisible ? visible : nil, ops: ops, syncDirectory: sync)
    }

    static let instagram = URL(string: "https://www.instagram.com/reel/DeHC9jcpfQW/")!

    @discardableResult
    func save(
        _ store: OfflineStore, _ name: String = "clip", bytes: Int = 1_000, kind: StoredVideo.Kind = .original,
        session: String? = nil, link: URL? = nil, remote: URL? = nil, keep: Bool = true, mediaID: String? = nil
    ) async throws -> StoredVideo {
        made += 1
        let file = try makeTempFile("\(name).\(kind == .webp ? "webp" : "mp4")", bytes: bytes)
        let info = MediaInfo(name: name, duration: 1, width: 10, height: 10, bytes: nil, isImage: false)
        return try await store.add(
            file: file, kind: kind, media: info, sessionID: session, link: link, remoteURL: remote, move: true,
            mediaID: mediaID, keep: keep)
    }

    func index() -> [OfflineStore.Record] { OfflineStore.readRecords(root: hidden) }
    func record(_ id: String) -> OfflineStore.Record? { index().first { $0.id == id } }

    /// Every regular file under the visible root (hidden ones too), relative paths, sorted.
    func visibleFiles(includingHidden: Bool = false) -> [String] {
        guard let walker = FileManager.default.enumerator(
            at: visible, includingPropertiesForKeys: [.isRegularFileKey],
            options: includingHidden ? [] : [.skipsHiddenFiles]) else { return [] }
        let prefix = visible.resolvingSymlinksInPath().path + "/"
        var out: [String] = []
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            out.append(String(url.resolvingSymlinksInPath().path.dropFirst(prefix.count)))
        }
        return out.sorted()
    }

    func cacheFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: hidden.appendingPathComponent("files").path)) ?? []).sorted()
    }

    func url(_ relative: String) -> URL { visible.appendingPathComponent(relative) }

    func bytesOnDisk(_ dir: URL) -> Int64 {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
        }
        return total
    }

    /// The invariants of decision 3, checked on the index and on disk.
    func checkInvariants(_ note: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
        for r in index() {
            #expect(!(r.fileName != nil && r.visiblePath != nil), "both tiers set \(note)", sourceLocation: sourceLocation)
            if r.visiblePath != nil { #expect(r.keep == true, "visiblePath implies keep \(note)", sourceLocation: sourceLocation) }
            if let name = r.fileName {
                #expect(FileManager.default.fileExists(atPath: hidden.appendingPathComponent("files/\(name)").path),
                        "cache file exists \(note)", sourceLocation: sourceLocation)
            }
            if let path = r.visiblePath {
                #expect(FileManager.default.fileExists(atPath: visible.appendingPathComponent(path).path),
                        "visible file exists \(note)", sourceLocation: sourceLocation)
            }
        }
    }
}
