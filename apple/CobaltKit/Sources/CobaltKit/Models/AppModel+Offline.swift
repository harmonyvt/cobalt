import Foundation

// "keep offline" as the screens use it (CONTRACT-OFFLINE.md section 5): the state of a rendition and of a media,
// and the four actions. The engine is `OfflineDownloads`; the store says which files are here.

extension AppModel {
    // MARK: - State

    /// Where a rendition is on this device right now.
    ///
    /// The engine's word comes first (downloading, waiting, failed), under any key the rendition is known by; then
    /// the store's: a file in the visible folder that the owner keeps is `offline`, any other file is `cached`
    /// (the limit may take it). With no file, `none`, or `unavailable` when there is nowhere to fetch it from.
    public func offlineState(of rendition: Rendition) -> RenditionOffline {
        for key in OfflineKey.aliases(of: rendition) {
            if let state = offlineDownloads.states[key] { return state }
        }
        if let local = rendition.local, local.place != nil {
            return local.isOffline ? .offline(bytes: local.bytes) : .cached(bytes: local.bytes)
        }
        let sources = OfflineSources.sources(for: rendition, session: nil, now: ctx.clock.now())
        return sources.isEmpty ? .unavailable : .none
    }

    /// A media at a glance: how much is kept, the combined progress while anything downloads or waits, and whether
    /// any rendition failed. `downloading` carries the bytes so far and the total (nil while a size is unknown).
    public func offlineState(of item: MediaItem) -> (offline: MediaOffline, downloading: TransferProgress?, failed: Bool) {
        var active = false
        var failed = false
        var bytes: Int64 = 0
        var total: Int64? = 0
        for rendition in item.renditions {
            switch offlineState(of: rendition) {
            case .downloading(let p):
                active = true
                bytes += p.bytes
                total = Self.add(total, p.total ?? rendition.bytes)
            case .waiting:
                active = true
                total = Self.add(total, rendition.bytes)
            case .failed:
                failed = true
            default:
                break
            }
        }
        return (item.offline, active ? TransferProgress(bytes: bytes, total: total) : nil, failed)
    }

    private static func add(_ a: Int64?, _ b: Int64?) -> Int64? {
        guard let a, let b else { return nil }
        return a + b
    }

    // MARK: - Actions

    /// "keep offline": every rendition of the media that is not kept yet (server-only webps included), or just
    /// `rendition`. A cached file only flips to kept and moves into Files (no download); the rest go to the background
    /// session. A rendition already kept, already going or with nothing to fetch it from is left alone; a failed one
    /// starts again (the retry is this same action). The states are visible at once.
    public func keepOffline(_ item: MediaItem, rendition: Rendition? = nil) {
        let targets = rendition.map { [$0] } ?? item.renditions
        let now = ctx.clock.now()
        var flip: [String] = []
        var jobs: [OfflineJob] = []
        for r in targets {
            switch offlineState(of: r) {
            case .offline, .downloading, .waiting, .unavailable:
                continue
            case .cached:
                if let id = r.local?.id { flip.append(id) }
            case .none, .failed:
                if let job = OfflineSources.job(for: r, in: item, mediaBase: capabilities.mediaBaseURL, now: now) { jobs.append(job) }
            }
        }
        offlineDownloads.enqueue(jobs)
        guard !flip.isEmpty else { return }
        let store = store
        Task { @MainActor in
            // an id that has no file any more (evicted meanwhile) is fetched like any other
            let missing = await store.setKeep(true, ids: flip)
            guard !missing.isEmpty else { return }
            let again = targets.filter { r in r.local.map { missing.contains($0.id) } ?? false }
                .compactMap { OfflineSources.job(for: $0, in: item, mediaBase: capabilities.mediaBaseURL, now: now) }
            offlineDownloads.enqueue(again)
        }
    }

    /// "stop downloading": cancels the task, drops its resume data and its queue entry. A post-only media whose
    /// download was cancelled has no local record (nothing was added).
    public func stopDownloading(_ item: MediaItem, rendition: Rendition? = nil) {
        let targets = rendition.map { [$0] } ?? item.renditions
        offlineDownloads.cancel(keys: targets.flatMap { OfflineKey.aliases(of: $0) })
    }

    /// "remove offline copy": the file goes (not the trash), the record, poster and flipbook stay, and a download of
    /// it that is still running stops. Kept or cached, in Files or hidden. True when a file was removed; false when
    /// there was none, or it is in use (a run is reading it).
    @discardableResult
    public func removeOfflineCopy(_ item: MediaItem, rendition: Rendition? = nil) async -> Bool {
        let targets = rendition.map { [$0] } ?? item.renditions
        offlineDownloads.cancel(keys: targets.flatMap { OfflineKey.aliases(of: $0) })
        // the owner may have renamed or deleted it in Files since the last foreground
        await store.scanVisibleRoot()
        var removed = false
        for r in targets {
            guard let id = r.local?.id, store.videos.first(where: { $0.id == id })?.place != nil else { continue }
            if await store.removeOfflineCopy(id) { removed = true }
        }
        return removed
    }

    /// The server holds nothing to bring this rendition back from: removing its file cannot be undone.
    public func isOnlyCopy(_ rendition: Rendition) -> Bool {
        guard let local = rendition.local, local.place != nil else { return false }
        if rendition.file != nil || rendition.hosted != nil || rendition.publicURL != nil { return false }
        return !OfflineStore.hasServerCopy(
            kind: local.kind, sessionID: local.sessionID, remoteURL: local.remoteURL, publicURL: local.publicURL)
    }

    // MARK: - Files

    /// `shareddocuments://<path>`: Files opened at the folder `item` has a kept file in, or at the visible folder
    /// itself (`item` nil). iOS only. Nil when there is no visible folder, when the media has nothing kept in it, and
    /// everywhere if gate G-O found the scheme does not open Files (`OfflineDownloads.showInFilesVerified`).
    public func showInFilesURL(_ item: MediaItem?) -> URL? {
        #if os(iOS)
        guard OfflineDownloads.showInFilesVerified, let root = store.visibleRoot else { return nil }
        guard let item else { return Self.filesURL(for: root) }
        // the store's current record: a rename or move in Files since the item was built is already followed
        let current = item.local.flatMap { store.media(id: $0.id) }?.renditions ?? item.renditions.compactMap(\.local)
        guard let file = current.first(where: { $0.place == .offline && $0.fileURL != nil })?.fileURL else { return nil }
        return Self.filesURL(for: file.deletingLastPathComponent())
        #else
        return nil
        #endif
    }

    /// The scheme Files answers to (percent-encoded path, a folder).
    static func filesURL(for directory: URL) -> URL? {
        guard let path = directory.standardizedFileURL.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "shareddocuments://" + path)
    }
}
