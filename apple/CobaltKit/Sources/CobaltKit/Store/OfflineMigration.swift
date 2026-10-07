import Foundation

// The one-time migration (CONTRACT-OFFLINE.md section 2): the first launch of the offline build moves every file
// the old store kept into the visible folder.
//
// There is no "done" flag that could lie. A record the old store wrote has `keep == nil`; a build that saves
// always writes true or false. "Migrate" is: every record with `keep == nil` and a file in `files/` becomes kept
// and moves in (tag, rename, index write: `OfflineFolder.promote`). It is evaluated on every launch and finds
// nothing after the first. A crash at any point leaves a state the next launch settles (section 2.3).

extension OfflineStore {
    /// Section 2. A no-op without a visible root (the extension, the Mac) and when nothing is legacy. A record
    /// in use waits for the next `reload()`. Records go newest first, 20 to an index write, off the main actor.
    public func runMigrationIfNeeded() async {
        guard visibleRoot != nil else { return }
        // The Mac's visible root is the owner's own Finder folder (13.2.1): the legacy files FolderSync already copied
        // there must not be moved in beside them as "(2)" duplicates. Adoption (`FolderAdoption`) does this job there.
        guard rootMode == .documents else { return }
        let legacy = Set(records.filter { $0.fileName != nil && $0.keep == nil && !isInUse($0.id) }.map(\.id))
        guard !legacy.isEmpty else { return }
        let hidden = root
        let flagged = await OfflineFolderGate.shared.exclusive {
            await OfflineFolder.flagLegacy(hiddenRoot: hidden, ids: legacy)
        }
        if let written = flagged.records { adopt(written) }
        guard !flagged.flagged.isEmpty else { return }
        let outcome = await promote(only: flagged.flagged)
        if outcome.interrupted != nil { return }
        Telemetry.log(.info, .store, "offline migration", data: [
            "moved": .int(outcome.moved), "failed": .int(outcome.failed), "bytes": .bytes(outcome.bytes),
            "root": .string(AppGroup.location.kind.rawValue)])
        if outcome.moved > 0, let syncDirectory {
            let stamp = now()
            OfflineFolder.writeMigrationMarker(in: syncDirectory, now: stamp)
        }
    }

    /// When the migration first moved files (the Settings footnote); nil before, and in tests.
    public var migratedAt: Date? { syncDirectory.flatMap { OfflineFolder.readMigrationMarker(in: $0) } }
}
