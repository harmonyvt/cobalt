import Foundation
import Observation

/// The Mac's "saves made anywhere land in the folder" (CONTRACT-OFFLINE.md 13.8): a check against the server's library at
/// launch, on every activation and every 5 minutes while the app runs, that downloads the saves made since "keep new saves
/// offline" was turned on. **This file is the public API stub of wave M1** (13.14): the screens build against it, and lane
/// M2/P fills it in (`PullLedger`, `check()`, the engine hand-off). Until then a check does nothing.
///
/// Platform-neutral CobaltKit; `isAvailable` is true where the store's root is the Mac's folder (`.macFolder`) only.
@MainActor @Observable
public final class SavePull {
    public enum Paused: Sendable, Equatable { case keepOff, folderUnreachable, auth, noServer }

    public struct Status: Sendable, Equatable {
        public var available: Bool
        public var lastChecked: Date?
        public var paused: Paused?
        /// downloads under way that this pull started
        public var pulling: Int

        public init(available: Bool = false, lastChecked: Date? = nil, paused: Paused? = nil, pulling: Int = 0) {
            self.available = available
            self.lastChecked = lastChecked
            self.paused = paused
            self.pulling = pulling
        }
    }

    @ObservationIgnored private let store: OfflineStore?
    var previewStatus: Status?

    public var status: Status {
        if let previewStatus { return previewStatus }
        guard let store else { return Status(available: false) }
        return Status(available: store.rootMode == .macFolder)
    }

    public var isAvailable: Bool { status.available }

    init(store: OfflineStore) {
        self.store = store
    }

    private init(preview: Status) {
        self.store = nil
        self.previewStatus = preview
    }

    /// One check, now. A stub in wave M1.
    public func check() async {}

    /// No disk, no network: for `#Preview`s and `AppModel.preview`.
    public static func preview(_ status: Status) -> SavePull { SavePull(preview: status) }

    /// Replaces a preview instance's status. No effect on the real one.
    public func setPreviewStatus(_ status: Status) {
        guard previewStatus != nil else { return }
        previewStatus = status
    }
}

extension AppModel {
    /// "keep new saves offline": writes the setting. Turning it on will rebaseline the pull (13.8; lane P).
    public func setKeepNewSaves(_ on: Bool) {
        settings.keepVideosOnDevice = on
    }

    /// Whether this session is in flight here and a download of it would be a second copy (13.9 layer 1): a job of the
    /// queue follows it, a share job of it is saving, rendering or uploading, or a pending original holds it.
    func holdsSession(_ id: String) -> Bool {
        if queue.jobs.contains(where: { $0.isLive && $0.pipeline.sessionID == id }) { return true }
        return store.sessionIsHeld?(id) == true
    }
}
