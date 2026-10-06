import Foundation

// `AppModel.preview(.offline)` (CONTRACT-OFFLINE.md section 5): the library and the orbit with every state the
// offline screens draw, no network and no real media. Kept files are sparse files of the right size, tagged, in
// a temp "Documents", so the store reads them back through its own scan like it would on a phone.
//
// | what | where | state |
// |---|---|---|
// | `instagram_Dd7P496wolG` (video + 3 webps) | library post `Dd7P496wolG` | all kept |
// | `twitter_2105435404002562056` | library post `2105435404002562056` | some: video kept, webp server-only |
// | `instagram_Dd55fEyN1Yy` | library post `Dd55fEyN1Yy` (no local copy) | downloading, 40 % |
// | `twitter_2105358343657427103` | library post `2105358343657427103` (no local copy) | failed, gone |
// | `instagram_Dd7RFsmT45H` | orbit (a plain save, no file, no server copy) | unavailable |
// | `clip` | orbit (a plain save with its file, no server copy) | kept, the only copy |
// | `twitter_2105432512428445875` | orbit | cached |

enum PreviewOffline {
    static let someSession = "PrEvIeWsession0000000a3"
    static let downloadingPost = "Dd55fEyN1Yy"
    static let failedPost = "2105358343657427103"

    /// `PreviewData.orbit` with the offline scenario's changes: the second video belongs to the library post that
    /// has a server-only webp.
    static func seeds(now: Date) -> [StoredVideo] {
        var orbit = PreviewData.orbit(now: now)
        if let i = orbit.firstIndex(where: { $0.id == "preview-orbit-2" }) {
            orbit[i].sessionID = someSession
            orbit[i].mediaID = "preview-media-twitter2105435"
        }
        return (orbit + PreviewData.renditionSeeds(now: now)).sorted { $0.createdAt > $1.createdAt }
    }

    /// The records that are kept in the visible folder, with the size of their file.
    static let kept: [(id: String, bytes: Int64)] = [
        ("preview-dd7p-video", 4_331_778), ("preview-dd7p-webp-1", 4_500_000), ("preview-dd7p-webp-5", 2_371_210),
        ("preview-dd7p-webp-6", 1_600_000), ("preview-orbit-2", 256_000), ("preview-orbit-7", 1_800_000),
    ]
    /// The records whose file sits in the cache.
    static let cached: [(id: String, bytes: Int64)] = [("preview-orbit-3", 70_000)]

    /// Settings' numbers: "24 videos · 3.1 GB" kept, "3 videos · 210 MB" in the cache (5 GB limit).
    static let offlineTotal = StorageUsage(count: 24, bytes: 3_100_000_000, mediaCount: 24)
    static let cacheTotal = StorageUsage(count: 3, bytes: 210_000_000, mediaCount: 3)
}

extension OfflineStore {
    /// Puts the files of `PreviewOffline` on disk and in the index, and sets the usage figures Settings shows.
    func seedOfflinePreview() {
        guard let visibleRoot else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: visibleRoot, withIntermediateDirectories: true)
        try? fm.createDirectory(at: root.appendingPathComponent("files", isDirectory: true), withIntermediateDirectories: true)
        func sparse(_ url: URL, bytes: Int64) {
            fm.createFile(atPath: url.path, contents: nil)
            if let handle = try? FileHandle(forWritingTo: url) {
                try? handle.truncate(atOffset: UInt64(max(0, bytes)))
                try? handle.close()
            }
        }
        guard let merged = try? Self.mutate(root: root, { records in
            for item in PreviewOffline.kept {
                guard let i = records.firstIndex(where: { $0.id == item.id }) else { continue }
                let r = records[i]
                let name = "\(r.id).\(r.kind == .webp ? "webp" : "mp4")"
                let url = visibleRoot.appendingPathComponent(name)
                sparse(url, bytes: item.bytes)
                let tag = OfflineTag(
                    id: r.id, media: r.media, kind: r.kind, session: r.sessionID, remote: r.remoteURL?.absoluteString,
                    link: r.link?.absoluteString, created: r.createdAt.timeIntervalSince1970, title: r.title)
                try? XAttr.set(OfflineTag.attribute, tag.encoded(), at: url)
                records[i].fileName = nil
                records[i].visiblePath = name
                records[i].keep = true
                records[i].bytes = item.bytes
            }
            for item in PreviewOffline.cached {
                guard let i = records.firstIndex(where: { $0.id == item.id }) else { continue }
                let name = "\(records[i].id).mp4"
                sparse(root.appendingPathComponent("files/\(name)"), bytes: item.bytes)
                records[i].fileName = name
                records[i].visiblePath = nil
                records[i].keep = false
                records[i].bytes = item.bytes
            }
        }) else { return }
        adopt(merged)
        // what is not on disk in the preview is added to what is, so Settings reads like a phone in use
        let actual = Self.offlineUsage(of: merged)
        let wantOffline = PreviewOffline.offlineTotal, wantCache = PreviewOffline.cacheTotal
        offlineUsageBase = OfflineUsage(
            offline: StorageUsage(
                count: wantOffline.count - actual.offline.count, bytes: wantOffline.bytes - actual.offline.bytes,
                mediaCount: wantOffline.mediaCount - actual.offline.mediaCount),
            cache: StorageUsage(
                count: wantCache.count - actual.cache.count, bytes: wantCache.bytes - actual.cache.bytes,
                mediaCount: wantCache.mediaCount - actual.cache.mediaCount))
        usageBase = StorageUsage(
            count: wantOffline.count + wantCache.count - Self.usage(of: merged).count,
            bytes: wantOffline.bytes + wantCache.bytes - Self.usage(of: merged).bytes,
            mediaCount: wantOffline.mediaCount + wantCache.mediaCount - Self.usage(of: merged).mediaCount)
    }
}

extension AppModel {
    /// The downloading and the failed media of `.offline`: states the engine shows without any transfer.
    func seedOfflinePreviewStates() {
        var seeds: [(job: OfflineJob, state: RenditionOffline)] = []
        func video(of postID: String) -> (MediaItem, Rendition)? {
            guard let post = library.posts.first(where: { $0.id == postID }) else { return nil }
            let item = mediaItem(for: post)
            return item.video.map { (item, $0) }
        }
        let now = ctx.clock.now()
        if let (item, r) = video(of: PreviewOffline.downloadingPost),
           let job = OfflineSources.job(for: r, in: item, mediaBase: capabilities.mediaBaseURL, now: now) {
            let total = r.bytes ?? 8_300_000
            seeds.append((job, .downloading(TransferProgress(bytes: total * 2 / 5, total: total))))
        }
        if let (item, r) = video(of: PreviewOffline.failedPost),
           let job = OfflineSources.job(for: r, in: item, mediaBase: capabilities.mediaBaseURL, now: now) {
            seeds.append((job, .failed(.gone)))
        }
        offlineDownloads.seedPreview(seeds)
    }
}
