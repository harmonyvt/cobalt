import Foundation

// The store's side of the visible folder (CONTRACT-OFFLINE.md): moving kept files in, keeping and un-keeping,
// re-reading the root, following the owner's renames and the media's. All file work runs behind
// `OfflineFolderGate` on `@concurrent` hops; this file only decides what to do, on the main actor, from the
// index in memory.

extension OfflineStore {
    // MARK: the gate and the root

    /// The root as it is right now, when it can be used: the visible root while `rootState == .ready`, else nil.
    var usableRoot: URL? { rootState == .ready ? visibleRoot : nil }

    /// Keeps the gate's view of the root in step with `visibleRoot` and `rootState`.
    func publishRoot() { rootBox.set(usableRoot) }

    /// Runs `body` alone behind `OfflineFolderGate`, with the root read when the gate is entered, not when the caller
    /// decided to wait for it: a relocation (13.5) swaps the root inside the gate, and a scan or a move that waited
    /// behind it must never run against the old one. `root` is nil when there is none or it is not `.ready`.
    func inGate<T: Sendable>(_ body: @escaping @Sendable (_ root: URL?) async -> T) async -> T {
        let box = rootBox
        return await OfflineFolderGate.shared.exclusive { await body(box.current) }
    }

    /// Whether this store excludes server-backed files from backup: on iOS only. The Mac folder is the owner's, and Time
    /// Machine is their backup of it (13.2.3).
    var excludesBackup: Bool { rootMode == .documents }

    /// `.macFolder`: asks the provider where the root is and who it is, and applies the answer: inside the gate for the box
    /// the gate's work reads, then to the properties the screens read. A no-op in `.documents`. Called by `reload()`, the
    /// scan and the promotion, so a disk swapped under the same path is never written to.
    @discardableResult
    func resolveRoot() async -> RootState {
        guard rootMode == .macFolder else { return .ready }
        guard let provider = rootProvider else {
            // a store with no provider (a test's root): the directory is there or it is not; nothing is created
            guard let configured = visibleRoot else { return rootState }
            var isDirectory: ObjCBool = false
            let there = FileManager.default.fileExists(atPath: configured.path, isDirectory: &isDirectory) && isDirectory.boolValue
            let state: RootState = there ? .ready : .unreachable(path: configured.path)
            if state != rootState { rootState = state }
            publishRoot()
            return state
        }
        let box = rootBox
        let resolution = await OfflineFolderGate.shared.exclusive { () -> MacRootResolution in
            let resolution = provider.resolve()
            box.set(resolution.state == .ready ? resolution.url : nil)
            return resolution
        }
        apply(resolution)
        return rootState
    }

    /// The provider's answer: the root (it may have moved), its scope and its state.
    private func apply(_ resolution: MacRootResolution) {
        rootAccess?.stop()
        rootAccess = resolution.access
        if visibleRoot.map(FolderDestination.canonical) != FolderDestination.canonical(resolution.url) {
            swapRoot(resolution.url)
        }
        if resolution.state != rootState {
            rootState = resolution.state
            Telemetry.log(.info, .store, "offline root state", data: ["state": .string(String(describing: resolution.state).prefix(24).description)])
        }
        publishRoot()
    }

    /// Swaps the root. Callers hold the gate (or have just left it with the box already swapped): nothing else reads or
    /// writes the old one meanwhile.
    func swapRoot(_ url: URL) {
        let watching = watcher != nil
        stopWatching()
        visibleRoot = url
        adopt(records)                                        // every record's file url resolves against the new root
        if watching { startWatching() }
        publishRoot()
    }

    // MARK: moving in

    /// Moves kept records whose file waits in `files/` into the visible folder: tag, rename (or copy then
    /// rename across volumes), one index write per 20. `only` limits it to those ids. Skips records in use and,
    /// when `respectHolds` (the `reload()` pass), records of a session another part of the app still holds (a
    /// live share job or pending original: the extension's quick view must not lose a path it holds). Returns
    /// how many files moved. No-op without a visible root.
    @discardableResult
    func promote(only ids: Set<String>?, respectHolds: Bool = false) async -> OfflineFolder.PromoteOutcome {
        guard visibleRoot != nil else { return OfflineFolder.PromoteOutcome() }
        // an unreachable, wrong or unwritable root: the kept file waits in `files/` and `reload()` tries again (13.2.5)
        if rootMode == .macFolder, await resolveRoot() != .ready { return OfflineFolder.PromoteOutcome() }
        var requests: [OfflineFolder.MoveRequest] = []
        let candidates = records
            .filter { $0.keep == true && $0.fileName != nil && $0.visiblePath == nil && (ids?.contains($0.id) ?? true) }
            .sorted { $0.added > $1.added }                                    // newest first
        for r in candidates {
            if isInUse(r.id) { continue }
            if respectHolds, let session = r.sessionID, sessionIsHeld?(session) == true { continue }
            guard let video = videos.first(where: { $0.id == r.id }), let name = r.fileName else { continue }
            let owner = media(containing: r.id)
            let placement = FolderNaming.placement(for: video, in: owner)
            let preferred = placement.name
            let tag = OfflineTag(
                id: r.id, media: r.media, kind: r.kind, session: r.sessionID, remote: r.remoteURL?.absoluteString,
                link: r.link?.absoluteString, created: r.createdAt.timeIntervalSince1970, title: r.title,
                role: r.role, item: r.itemIndex, lib: r.libraryID)
            requests.append(OfflineFolder.MoveRequest(
                id: r.id, source: root.appendingPathComponent("files/\(name)"), tag: tag, preferredName: preferred,
                excludeFromBackup: excludesBackup && r.hasServerCopy, folder: placement.folder, media: r.media))
        }
        guard !requests.isEmpty else { return OfflineFolder.PromoteOutcome() }
        let (hidden, ops, stamp, work) = (root, ops, now(), requests)
        let outcome = await inGate { root in
            guard let root else { return OfflineFolder.PromoteOutcome() }
            return await OfflineFolder.promote(work, hiddenRoot: hidden, visibleRoot: root, ops: ops, now: stamp)
        }
        if let written = outcome.records { adopt(written) }
        if rootMode == .macFolder {
            if outcome.full { rootDiskFull = true } else if outcome.moved > 0 { rootDiskFull = false }
        }
        if outcome.moved + outcome.failed > 0 {
            Telemetry.log(.info, .store, "offline promote", data: [
                "moved": .int(outcome.moved), "failed": .int(outcome.failed), "bytes": .bytes(outcome.bytes)])
        }
        return outcome
    }

    /// Keeps (`true`) or stops keeping (`false`) the records `ids`.
    ///
    /// `true` flags the records and moves the files that are here into the visible folder; the ids that have no
    /// file at all are returned (the caller downloads them). `false` on a record with a file is
    /// `removeOfflineCopy`; on one without, it only clears the wish.
    @discardableResult
    public func setKeep(_ keep: Bool, ids: [String]) async -> [String] {
        let wanted = Set(ids)
        guard !wanted.isEmpty else { return [] }
        if keep {
            // a store nobody promotes from has no kept files (`canKeep`): keeping is a no-op there, and nothing is downloaded
            guard canKeep else { return [] }
            guard let merged = try? Self.mutate(root: root, { records in
                for i in records.indices where wanted.contains(records[i].id) { records[i].keep = true }
            }) else { return [] }
            adopt(merged)
            if visibleRoot != nil { await promote(only: wanted) }
            let have = Dictionary(records.map { ($0.id, $0.hasFile) }, uniquingKeysWith: { first, _ in first })
            return ids.filter { have[$0] == false }
        }
        for id in ids { await removeOfflineCopy(id) }
        return []
    }

    // MARK: re-reading the root (decision 7)

    /// The scan: enumerate the visible root and settle the index with it (decision 6's table), in one
    /// coordinated write, off the main actor. A no-op without a visible root; an unreadable root changes
    /// nothing (`rootMissing`). Runs at launch and on every foreground (inside `reload()`), before an action on
    /// a kept file, after a background wake, and from the watcher.
    @discardableResult
    public func scanVisibleRoot() async -> OfflineScanReport {
        guard visibleRoot != nil else { return OfflineScanReport() }
        if rootMode == .macFolder { await resolveRoot() }
        let (hidden, ops, stamp, excludes) = (root, ops, now(), excludesBackup)
        let scanned = await inGate { root -> OfflineFolder.ScanResult? in
            guard let root else { return nil }
            return await OfflineFolder.scan(hiddenRoot: hidden, visibleRoot: root, now: stamp, ops: ops, excludesBackup: excludes)
        }
        guard let result = scanned else {
            // an unreachable root changes nothing at all (decision 6, last row; 13.6)
            return OfflineScanReport(rootMissing: true)
        }
        if result.report.indexUnreadable {
            return result.report                          // already in telemetry (once), with a copy of the index beside it
        }
        if result.report.rootMissing {
            Telemetry.log(.warn, .store, "offline scan root missing")
            return result.report
        }
        if result.records != records { adopt(result.records) }
        if result.report.changedIndex || result.report.untracked > 0 {
            Telemetry.log(.info, .store, "offline scan", data: [
                "followed": .int(result.report.followed), "unkept": .int(result.report.unkept),
                "adopted": .int(result.report.adopted), "rebuilt": .int(result.report.rebuilt),
                "untracked": .int(result.report.untracked)])
        }
        for id in result.rebuilt {
            await makePosterIfMissing(id)
            if let video = videos.first(where: { $0.id == id }) { onAdd?(video, .adopted) }
        }
        return result.report
    }

    /// A record rebuilt from a tag has no poster (the index that named it is gone): make one from the file.
    private func makePosterIfMissing(_ id: String) async {
        guard let record = records.first(where: { $0.id == id }), record.posterName == nil,
              let file = videos.first(where: { $0.id == id })?.fileURL else { return }
        let name = "\(id).jpg"
        let url = root.appendingPathComponent("posters", isDirectory: true).appendingPathComponent(name)
        guard await tools.poster(for: file, isImage: record.kind == .webp || Self.looksLikeImage(file.lastPathComponent), to: url)
        else { return }
        let bytes = Self.fileSize(url)
        if let merged = try? Self.mutate(root: root, { records in
            guard let i = records.firstIndex(where: { $0.id == id }), records[i].posterName == nil else { return }
            records[i].posterName = name
            records[i].posterBytes = bytes
        }) { adopt(merged) }
    }

    /// While cobalt is in front: watch the root (not its subfolders) and rescan, debounced to 0.5 s. Covers a
    /// drag and drop beside cobalt on an iPad; a change inside a subfolder waits for the next foreground.
    public func startWatching() {
        guard let visibleRoot, watcher == nil else { return }
        watcher = OfflineFolderWatcher(root: visibleRoot) { @Sendable [weak self] in
            Task { @MainActor [weak self] in await self?.scanVisibleRoot() }
        }
    }

    public func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    // MARK: names (decision 8)

    /// The media's title changed: every kept file whose name is still the one cobalt gave it (`givenName`) gets
    /// the new `FolderNaming` name, in its own folder; a file the owner renamed is never renamed again.
    func followTitle(media id: String) async {
        guard visibleRoot != nil, let current = media(id: id) else { return }
        var plan: [OfflineFolder.Rename] = []
        for video in current.renditions {
            guard let record = records.first(where: { $0.id == video.id }), let path = record.visiblePath,
                  let given = record.givenName, !isInUse(record.id),
                  (path as NSString).lastPathComponent == given else { continue }
            let preferred = FolderNaming.fileName(for: video, in: current)
            guard preferred != given else { continue }
            plan.append(OfflineFolder.Rename(id: record.id, path: path, preferredName: preferred))
        }
        guard !plan.isEmpty else { return }
        let (hidden, ops, work) = (root, ops, plan)
        let written = await inGate { root -> [Record]? in
            guard let root else { return nil }
            return await OfflineFolder.rename(work, hiddenRoot: hidden, visibleRoot: root, ops: ops)
        }
        if let written { adopt(written) }
    }
}

// MARK: - The Mac folder (CONTRACT-OFFLINE.md section 13)

extension OfflineStore {
    /// 13.3: adopts the files `FolderSync` copied into the root, by tag, once per ledger section. A no-op outside
    /// `.macFolder`, while the root is not `.ready`, and when the section is complete. Never writes `folder.json`.
    func adoptFolderSyncFiles() async {
        guard rootMode == .macFolder, rootState == .ready, let ledger = folderLedger, let syncDirectory,
              let current = visibleRoot, FolderAdoption.needsRun(root: current, ledger: ledger, markerDirectory: syncDirectory)
        else { return }
        let busy = Set(records.filter { r in
            isInUse(r.id) || (r.sessionID.map { sessionIsHeld?($0) == true } ?? false)
        }.map(\.id))
        let legacyOn = defaults.object(forKey: "folderSync") as? Bool ?? true
        let (hidden, ops, stamp) = (root, ops, now())
        isAdopting = true
        defer { isAdopting = false }
        let outcome = await inGate { root -> FolderAdoption.Outcome in
            guard let root else { return FolderAdoption.Outcome() }
            return await FolderAdoption.run(
                root: root, hiddenRoot: hidden, ledger: ledger, markerDirectory: syncDirectory, busy: busy,
                folderSyncWasOn: legacyOn, ops: ops, now: stamp)
        }
        if let written = outcome.records { adopt(written) }
        guard outcome.ran else { return }
        var data: [String: TelemetryValue] = [
            "adopted": .int(outcome.adopted), "keptToMove": .int(outcome.keptToMove), "complete": .bool(outcome.complete)]
        for (reason, n) in outcome.skipped { data[reason.rawValue] = .int(n) }
        Telemetry.log(.info, .store, "folder adoption", data: data)
    }

    /// A record from before offline (`keep == nil`) is cache on the Mac, never "legacy, keep it" (13.2.1): the migration is
    /// off here, so nothing else would ever settle it.
    ///
    /// Only once an adoption that matches the root has run (`FolderAdoption` settles the legacy records itself, in its own pass),
    /// or when there is no ledger to adopt from. A ledger whose section names another folder than the root (an owner-chosen folder
    /// the bookmark resolved elsewhere) adopted nothing: the legacy records stay exactly as they were, `keep` untouched, until the
    /// adoption that matches runs (wave M review, evidence run).
    func normalizeLegacyKeeps() async {
        guard rootMode == .macFolder, records.contains(where: { $0.keep == nil }) else { return }
        if let ledger = folderLedger, let syncDirectory, let current = visibleRoot {
            guard let found = FolderAdoption.section(of: current, in: ledger.snapshot()),
                  FolderAdoption.readMarker(in: syncDirectory).sections[found.id] != nil else { return }
        }
        guard let merged = try? Self.mutate(root: root, { records in
            for i in records.indices where records[i].keep == nil { records[i].keep = false }
        }) else { return }
        adopt(merged)
    }

    /// How many kept files are in the visible root (what "move the 24 offline files" counts).
    var visibleKeptCount: Int { records.filter { $0.visiblePath != nil }.count }

    /// 13.5: the owner chose another folder. Inside the gate: every kept file that is provably its own moves into the new
    /// root when `move` (and the old one is reachable), then the root swaps. `progress` is called as files go. The caller
    /// runs `reload()` after (adoption of the new folder's section, the scan, the promotion of what waited).
    ///
    /// `old` is the folder the owner is leaving, read by the caller **before** it named the new folder in the ledger (nil when
    /// the old one was not usable): anything that resolves the root between that write and this gate (a landing's promotion, the
    /// watcher's scan) swaps the box to the new folder, and a move that read the box here would find nothing to move and still
    /// swap the root, stranding every kept file in the old folder (wave M review S3).
    func switchRoot(
        to resolution: MacRootResolution, move: Bool, from old: URL?, progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> (moved: Int, stayed: Int, interrupted: OfflineInterrupted?) {
        await switchRoot(move: move, from: old, progress: progress) { resolution }
    }

    /// `switchRoot(to:move:from:)` for a caller that names the new folder itself: `resolve` runs **inside the gate**, first
    /// thing, so the ledger write that names the new folder and the move are one step to everything else (a scan or a promotion
    /// can no longer read the new folder before the files have left the old one and take them for deleted). The ledger still names
    /// the new folder before the first file moves: a crash mid-move reopens on the new folder, where what moved is found by tag.
    func switchRoot(
        move: Bool, from old: URL?, progress: (@Sendable (Int, Int) -> Void)? = nil,
        resolve: @escaping @Sendable () -> MacRootResolution
    ) async -> (moved: Int, stayed: Int, interrupted: OfflineInterrupted?) {
        let (hidden, ops, stamp) = (root, ops, now())
        let box = rootBox
        let (outcome, resolution) = await OfflineFolderGate.shared.exclusive { () -> (OfflineFolder.RelocateOutcome, MacRootResolution) in
            let resolution = resolve()
            let destination = resolution.url
            var outcome = OfflineFolder.RelocateOutcome()
            if move, resolution.state == .ready, let old, FolderDestination.canonical(old) != FolderDestination.canonical(destination) {
                outcome = await OfflineFolder.relocate(
                    hiddenRoot: hidden, from: old, to: destination, ops: ops, now: stamp, progress: progress)
            }
            // the swap happens inside the gate: whatever waited behind it reads the new root
            if outcome.interrupted == nil { box.set(resolution.state == .ready ? destination : nil) }
            return (outcome, resolution)
        }
        if outcome.interrupted == nil { finishSwitch(resolution) }
        if let written = try? Self.readRecordsChecked(root: root) { adopt(written) }
        Telemetry.log(.info, .store, "offline folder switched", data: [
            "moved": .int(outcome.moved), "stayed": .int(outcome.stayed), "move": .bool(move)])
        return (outcome.moved, outcome.stayed, outcome.interrupted)
    }

    private func finishSwitch(_ resolution: MacRootResolution) {
        trashRefused = false
        rootAccess?.stop()
        rootAccess = resolution.access
        swapRoot(resolution.url)
        rootState = resolution.state
        publishRoot()
    }

    /// 13.7: a made file (slideshow, gallery image) is being replaced by a remake. Its record goes; its visible file goes
    /// only when its name is still the one cobalt gave it (`givenName`): a file the owner renamed, or one crash recovery
    /// adopted (`givenName == nil`), is left where it is, untagged, and is theirs from then on. On the Mac a deleted file
    /// goes to the Trash. Call it before the new file's `add`, so the new file takes the free name. False: nothing changed
    /// (an unknown record, a tag that could not be read, an index that could not be written).
    @discardableResult
    public func replaceMade(_ id: String) async -> Bool {
        guard let record = records.first(where: { $0.id == id }) else { return false }
        // A crop is never replaced: the server keeps every crop (it replaces exports only), so no remake makes one stale.
        guard record.role != .crop else { return false }
        if record.visiblePath != nil {
            // the owner may have renamed it in Finder since the last scan: settle the paths first, then act on the index
            await scanVisibleRoot()
            let (hidden, ops, stamp) = (root, ops, now())
            let outcome = await inGate { root -> OfflineFolder.ReplaceVisible in
                guard let root else { return .refused }
                return OfflineFolder.replaceVisible(hiddenRoot: hidden, visibleRoot: root, id: id, ops: ops, now: stamp)
            }
            if outcome == .noTrash { trashRefused = true }
            else if outcome == .deleted { trashRefused = false }
            if outcome == .refused || outcome == .noTrash { return false }
        }
        var removed: Record?
        guard let merged = try? Self.mutate(root: root, { records in
            guard let i = records.firstIndex(where: { $0.id == id }) else { return }
            removed = records.remove(at: i)
        }) else { return false }
        guard let removed else { return false }
        Self.delete(
            Eviction(
                files: removed.fileName.map { [$0] } ?? [], posters: removed.posterName.map { [$0] } ?? [],
                previews: removed.previewNames ?? []),
            root: root)
        adopt(merged)
        return true
    }
}
