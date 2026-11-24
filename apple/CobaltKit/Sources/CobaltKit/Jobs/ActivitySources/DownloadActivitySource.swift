import Foundation

/// Downloads onto this device (`OfflineDownloads.rows`) and the photos album while it adds saves.
///
/// Phase 3 lane (b): `OfflineDownloads` holds every pull onto this device: the owner's "keep offline", the Mac's pulled saves, a
/// pipeline's own original, the library's copy for the share sheet (`OfflineDownloadRow.Origin.share`) and the share sheet's
/// pending originals (`.pendingOriginal`, from the extension's ledger). This file maps its rows one to one and says which
/// actions each kind has.
@MainActor
final class DownloadActivitySource: ActivitySource {
    let tier = ActivityTier.download
    private let offline: OfflineDownloads
    private let photos: PhotosSync

    init(offline: OfflineDownloads, photos: PhotosSync) {
        self.offline = offline
        self.photos = photos
    }

    func statuses(now: Date) -> [JobStatus] {
        var out = offline.rows.map { Self.status(of: $0, now: now) }
        let album = photos.status
        if album.enabled, let status = JobStatus(photos: album.progress, now: now) { out.append(status) }
        return out
    }

    /// `JobStatus(download:)` and what this kind of row can be asked to do. A failed share copy has no job to queue again (the
    /// share card's own "retry" owns that), and a pending original the server says is gone (the session ended) cannot be
    /// fetched again: both offer "dismiss" only.
    static func status(of row: OfflineDownloadRow, now: Date) -> JobStatus {
        let s = JobStatus(download: row, now: now)
        let noRetry = row.origin == .share || (row.origin == .pendingOriginal && row.state == .failed(.gone))
        guard noRetry, s.canRetry else { return s }
        return JobStatus(
            id: s.id, ref: s.ref, kind: s.kind, title: s.title, sourceHost: s.sourceHost, sessionID: s.sessionID,
            serverJobID: s.serverJobID, mediaID: s.mediaID, stage: s.stage, fraction: s.fraction, startedAt: s.startedAt,
            updatedAt: s.updatedAt, engine: s.engine, fallbackFrom: s.fallbackFrom, woke: s.woke, failedStep: s.failedStep,
            remote: s.remote, isFocused: s.isFocused, canFocus: s.canFocus, canCancel: s.canCancel, canRetry: false,
            canDismiss: s.canDismiss)
    }

    func perform(_ action: ActivityModel.Action, on status: JobStatus) async -> Bool {
        guard case .download(let key) = status.ref else { return false }
        switch action {
        case .cancel, .dismiss: offline.stop(key: key)
        case .retry: offline.retry(key: key)
        case .focus: break
        }
        return true
    }
}
