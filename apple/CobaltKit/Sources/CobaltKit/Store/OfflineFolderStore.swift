import Foundation

// The store's side of the visible folder (CONTRACT-OFFLINE.md): moving kept files in, keeping and un-keeping,
// re-reading the root, following the owner's renames and the media's. All file work runs behind
// `OfflineFolderGate` on `@concurrent` hops; this file only decides what to do, on the main actor, from the
// index in memory.

extension OfflineStore {
    // MARK: moving in

    /// Moves kept records whose file waits in `files/` into the visible folder: tag, rename (or copy then
    /// rename across volumes), one index write per 20. `only` limits it to those ids. Skips records in use and,
    /// when `respectHolds` (the `reload()` pass), records of a session another part of the app still holds (a
    /// live share job or pending original: the extension's quick view must not lose a path it holds). Returns
    /// how many files moved. No-op without a visible root.
    @discardableResult
    func promote(only ids: Set<String>?, respectHolds: Bool = false) async -> OfflineFolder.PromoteOutcome {
        guard let visibleRoot else { return OfflineFolder.PromoteOutcome() }
        var requests: [OfflineFolder.MoveRequest] = []
        let candidates = records
            .filter { $0.keep == true && $0.fileName != nil && $0.visiblePath == nil && (ids?.contains($0.id) ?? true) }
            .sorted { $0.added > $1.added }                                    // newest first
        for r in candidates {
            if isInUse(r.id) { continue }
            if respectHolds, let session = r.sessionID, sessionIsHeld?(session) == true { continue }
            guard let video = videos.first(where: { $0.id == r.id }), let name = r.fileName else { continue }
            let preferred = FolderNaming.fileName(for: video, in: media(containing: r.id))
            let tag = OfflineTag(
                id: r.id, media: r.media, kind: r.kind, session: r.sessionID, remote: r.remoteURL?.absoluteString,
                link: r.link?.absoluteString, created: r.createdAt.timeIntervalSince1970, title: r.title)
            requests.append(OfflineFolder.MoveRequest(
                id: r.id, source: root.appendingPathComponent("files/\(name)"), tag: tag, preferredName: preferred,
                excludeFromBackup: r.hasServerCopy))
        }
        guard !requests.isEmpty else { return OfflineFolder.PromoteOutcome() }
        let (hidden, ops, stamp, work) = (root, ops, now(), requests)
        let outcome = await OfflineFolderGate.shared.exclusive {
            await OfflineFolder.promote(work, hiddenRoot: hidden, visibleRoot: visibleRoot, ops: ops, now: stamp)
        }
        if let written = outcome.records { adopt(written) }
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
        guard let visibleRoot else { return OfflineScanReport() }
        let (hidden, ops, stamp) = (root, ops, now())
        let result = await OfflineFolderGate.shared.exclusive {
            await OfflineFolder.scan(hiddenRoot: hidden, visibleRoot: visibleRoot, now: stamp, ops: ops)
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
        guard let visibleRoot, let current = media(id: id) else { return }
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
        let written = await OfflineFolderGate.shared.exclusive {
            await OfflineFolder.rename(work, hiddenRoot: hidden, visibleRoot: visibleRoot, ops: ops)
        }
        if let written { adopt(written) }
    }
}
