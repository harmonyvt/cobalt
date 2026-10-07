import Foundation

/// Adopting what the Mac's old `FolderSync` copied into the Finder folder (CONTRACT-OFFLINE.md 13.3), so the folder becomes
/// the one copy of each file and the hidden duplicate goes.
///
/// It reads `Sync/folder.json` and **never writes it**: a downgrade to 1.14.x finds its ledger intact and copies nothing
/// again. It runs inside `OfflineFolderGate`, in `reload()` before the scan, for the ledger section whose path is the
/// current root, and touches a file in the owner's folder in exactly one way: the identity tag on a file that passed every
/// check (and, on that same file only, it clears the backup exclusion cobalt leaked there). Nothing in the folder is moved,
/// renamed, created or deleted; a file the owner added, renamed, replaced or deleted is never adopted, tagged or touched.
///
/// For each ledger entry that is `done` with a file and its size, in this order, and the first failing check settles it:
/// one record has the key (`noRecord`) with no `visiblePath` yet; the file is a regular file inside the root (`missing`);
/// at the recorded size (`changed`); untagged or tagged with this record's id (`tagConflict`); the bytes equal the hidden
/// copy, or with the hidden copy evicted the file's mtime is not after the entry's time (`changed`); and the record is not
/// in use (`busy`, the one outcome that is not final). Then, per batch of 20: tag, one index write, delete the hidden copy.
enum FolderAdoption {
    /// How an entry ended without being adopted.
    enum Reason: String, Codable, Sendable, CaseIterable {
        case noRecord, missing, changed, tagConflict
        /// not final: the record is in use or its session is held; the next `reload()` tries again
        case busy
        /// not final: the tag could not be read or written
        case unreadable
    }

    /// `Sync/folder-adoption.json`: what was done per ledger section, and the hidden copies an interrupted run still owes a
    /// delete (named before the index write, so the next run can finish the job).
    struct Marker: Codable, Equatable, Sendable {
        struct Pending: Codable, Equatable, Sendable {
            var name: String                 // under `files/`
            var path: String                 // the folder file that replaced it, relative to the root
            var bytes: Int64
        }
        struct Section: Codable, Equatable, Sendable {
            var at: Date
            var adopted: Int = 0
            var skipped: [String: Int] = [:]
            var pendingCache: [Pending] = []
            /// How many ledger entries there were when the section completed: a later change runs it again.
            var entries: Int = 0
            var complete: Bool = false
        }
        var sections: [String: Section] = [:]
    }

    struct Outcome: Sendable {
        /// the index as written; nil when nothing was written
        var records: [OfflineStore.Record]?
        var ran = false
        var adopted = 0
        /// records that FolderSync would have copied next, now kept: promotion moves their hidden file into the folder
        var keptToMove = 0
        var skipped: [Reason: Int] = [:]
        var complete = false
        var interrupted: OfflineInterrupted?
    }

    static let markerName = "folder-adoption.json"
    /// FolderSync's `copyItem` keeps the cache file's mtime, so a folder file is never newer than its entry; this much
    /// slack covers a clock that moved.
    static let mtimeSlack: TimeInterval = 120
    static let batchSize = 20

    // MARK: the marker

    static func readMarker(in directory: URL) -> Marker {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(markerName)),
              let marker = try? decoder.decode(Marker.self, from: data) else { return Marker() }
        return marker
    }

    static func writeMarker(_ marker: Marker, in directory: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(marker) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(markerName), options: .atomic)
    }

    /// The ledger section whose path is `root` (by `FolderDestination.canonical`); `default` first when several agree.
    static func section(of root: URL, in state: FolderStateFile) -> (id: String, section: FolderSection)? {
        let wanted = FolderDestination.canonical(root)
        return state.sections.sorted { $0.key < $1.key }
            .first { FolderDestination.canonical(URL(fileURLWithPath: $0.value.path, isDirectory: true)) == wanted }
            .map { ($0.key, $0.value) }
    }

    /// Whether `run` has anything to do (a section that is complete and unchanged is skipped without a disk walk).
    static func needsRun(root: URL, ledger: FolderLedger, markerDirectory: URL) -> Bool {
        guard let found = section(of: root, in: ledger.snapshot()) else { return false }
        guard let done = readMarker(in: markerDirectory).sections[found.id] else { return true }
        return !(done.complete && done.entries == found.section.items.count && done.pendingCache.isEmpty)
    }

    // MARK: the run

    private struct Verified {
        var id: String
        var key: String
        var path: String
        var bytes: Int64
        /// the hidden copy to delete once the folder file is adopted (nil: none on disk)
        var cacheName: String?
        /// what the record's `fileName` must still be when the index is written
        var recordFileName: String?
        var tag: OfflineTag
        var url: URL
        var tagged: Bool
        var excluded: Bool
    }

    /// One pass for the section of `root`. Off the main actor, inside the gate (the caller's). `busy`: ids of records in
    /// use or whose session is held. `folderSyncWasOn`: the legacy `folderSync` setting (on unless the owner turned it off).
    @concurrent
    static func run(
        root: URL, hiddenRoot: URL, ledger: FolderLedger, markerDirectory: URL, busy: Set<String>, folderSyncWasOn: Bool,
        ops: any OfflineFileOps, now: Date
    ) async -> Outcome {
        var outcome = Outcome()
        guard let found = section(of: root, in: ledger.snapshot()) else { return outcome }
        let (sectionID, section) = (found.id, found.section)
        let items = section.items
        var marker = readMarker(in: markerDirectory)
        let firstRun = marker.sections[sectionID] == nil
        var mine = marker.sections[sectionID] ?? Marker.Section(at: now)

        // An interrupted run may still owe cache deletes: finish them first, each only against a whole folder copy.
        if !mine.pendingCache.isEmpty {
            settle(&mine, root: root, hiddenRoot: hiddenRoot, ops: ops)
            marker.sections[sectionID] = mine
            writeMarker(marker, in: markerDirectory)
        }
        if mine.complete, mine.entries == items.count, mine.pendingCache.isEmpty { return outcome }
        outcome.ran = true

        let records: [OfflineStore.Record]
        do { records = try OfflineStore.readRecordsChecked(root: hiddenRoot) } catch { return outcome }
        var byKey: [String: [OfflineStore.Record]] = [:]
        for r in records { byKey[PhotosKey.of(r.video(root: hiddenRoot, visibleRoot: root)), default: []].append(r) }

        // MARK: verify every done entry
        var verified: [Verified] = []
        var skipped: [Reason: Int] = [:]
        var taken: Set<String> = []
        for (key, e) in items.sorted(by: { $0.key < $1.key }) where e.state == .done {
            guard let file = e.file, let bytes = e.bytes else { continue }
            switch verdict(key: key, entry: e, file: file, bytes: bytes, candidates: byKey[key] ?? [], root: root, hiddenRoot: hiddenRoot, busy: busy) {
            case .adopt(let v):
                // two entries naming one file would tag it twice: the second is a conflict, never a second tag
                if taken.insert(v.path.lowercased()).inserted { verified.append(v) } else { skipped[.tagConflict, default: 0] += 1 }
            case .already: break
            case .skip(let reason): skipped[reason, default: 0] += 1
            }
        }

        // MARK: records FolderSync would have copied next (claimed, failed, no entry): kept, so promotion moves them in.
        // Only on the very first adoption this install ever makes (no section in the marker yet): what a later build saved with
        // "keep new saves offline" off, or kept hidden while another folder was the root, is the owner's choice, not a leftover.
        // A section FolderSync never wrote to (no entries at all, a folder the owner chose since) has nothing it "would have
        // copied": no entry means nothing there.
        var keepNow: Set<String> = []
        if firstRun, marker.sections.isEmpty {
            for r in records where r.visiblePath == nil && r.fileName != nil && r.keep != true {
                let e = items[PhotosKey.of(r.video(root: hiddenRoot, visibleRoot: root))]
                if let e { if e.state == .claimed || e.state == .failed { keepNow.insert(r.id) } }
                else if folderSyncWasOn, !items.isEmpty { keepNow.insert(r.id) }
            }
        }
        outcome.keptToMove = keepNow.count

        do {
            var firstWrite = true
            var start = 0
            while start < verified.count {
                var batch = Array(verified[start..<min(start + batchSize, verified.count)])
                start += batchSize
                // 1. tag (the only write to a file in the owner's folder), and clear the leaked backup exclusion
                var failedTag: [String] = []
                for v in batch where !v.tagged {
                    do { try ops.setTag(v.tag, at: v.url) } catch let interrupted as OfflineInterrupted { throw interrupted } catch {
                        failedTag.append(v.id)
                    }
                }
                if !failedTag.isEmpty {
                    skipped[.unreadable, default: 0] += failedTag.count
                    batch.removeAll { failedTag.contains($0.id) }
                }
                for v in batch where v.excluded { clearExclusion(v.url) }
                try ops.checkpoint(.adoptTagged)

                // 2. name the cache copies this batch will orphan, then one coordinated index write
                let owed = batch.compactMap { v in v.cacheName.map { Marker.Pending(name: $0, path: v.path, bytes: v.bytes) } }
                if !owed.isEmpty {
                    mine.pendingCache.append(contentsOf: owed)
                    marker.sections[sectionID] = mine
                    writeMarker(marker, in: markerDirectory)
                }
                try ops.checkpoint(.adoptMarked)
                let wholeBatch = batch
                let flip = firstWrite ? keepNow : []
                let writeLegacy = firstWrite
                var applied: Set<String> = []
                let written = try? OfflineStore.mutate(root: hiddenRoot) { index in
                    for v in wholeBatch {
                        // still what was checked: present, no folder path yet, same hidden file
                        guard let i = index.firstIndex(where: { $0.id == v.id }), index[i].visiblePath == nil,
                              index[i].fileName == v.recordFileName else { continue }
                        index[i].visiblePath = v.path
                        index[i].givenName = (v.path as NSString).lastPathComponent
                        index[i].keep = true
                        index[i].fileName = nil
                        index[i].placed = OfflineFolder.placed(at: v.url)
                        applied.insert(v.id)
                    }
                    for i in index.indices where flip.contains(index[i].id) && index[i].visiblePath == nil { index[i].keep = true }
                    if writeLegacy {
                        // a legacy record left as it was is cache, never "legacy, keep it" (13.2.1)
                        for i in index.indices where index[i].keep == nil { index[i].keep = false }
                    }
                }
                firstWrite = false
                if let written { outcome.records = written }
                outcome.adopted += applied.count
                try ops.checkpoint(.adoptIndexed)

                // 3. the hidden copy goes, only when the folder file is still there at its size
                for v in batch where applied.contains(v.id) {
                    guard let name = v.cacheName else { continue }
                    if ops.size(of: v.url) == v.bytes { try? ops.remove(hiddenRoot.appendingPathComponent("files/\(name)")) }
                    mine.pendingCache.removeAll { $0.name == name }
                }
                marker.sections[sectionID] = mine
                writeMarker(marker, in: markerDirectory)
            }
            // a pass with nothing to adopt still writes the keep flags
            if firstWrite, !keepNow.isEmpty || records.contains(where: { $0.keep == nil }) {
                if let written = try? OfflineStore.mutate(root: hiddenRoot, { index in
                    for i in index.indices where keepNow.contains(index[i].id) && index[i].visiblePath == nil { index[i].keep = true }
                    for i in index.indices where index[i].keep == nil { index[i].keep = false }
                }) { outcome.records = written }
            }
        } catch let interrupted as OfflineInterrupted {
            outcome.interrupted = interrupted
            outcome.skipped = skipped
            return outcome
        } catch {}

        outcome.skipped = skipped
        outcome.complete = skipped[.busy] == nil && skipped[.unreadable] == nil && mine.pendingCache.isEmpty
        mine.at = now
        mine.adopted += outcome.adopted
        mine.skipped = Dictionary(uniqueKeysWithValues: skipped.map { ($0.key.rawValue, $0.value) })
        mine.entries = items.count
        mine.complete = outcome.complete
        marker.sections[sectionID] = mine
        writeMarker(marker, in: markerDirectory)
        return outcome
    }

    // MARK: one entry

    private enum Verdict {
        case adopt(Verified)
        /// the record already has its path (an earlier run, or the scan): nothing to do
        case already
        case skip(Reason)
    }

    private static func verdict(
        key: String, entry e: FolderEntry, file: String, bytes: Int64, candidates: [OfflineStore.Record], root: URL, hiddenRoot: URL,
        busy: Set<String>
    ) -> Verdict {
        // 1. exactly one record has the key (several: the one whose hidden copy matches the recorded size, else the oldest)
        guard !candidates.isEmpty else { return .skip(.noRecord) }
        func cacheSize(_ r: OfflineStore.Record) -> Int64? {
            r.fileName.flatMap { OfflineStore.fileSize(hiddenRoot.appendingPathComponent("files/\($0)")) }
        }
        let record = candidates.count == 1 ? candidates[0]
            : candidates.first { cacheSize($0) == bytes } ?? candidates.min { $0.createdAt < $1.createdAt }!
        // 2. already adopted
        if record.visiblePath != nil { return .already }
        // 3. a regular file, inside the root
        guard let stat = regularFile(file, root: root) else { return .skip(.missing) }
        // 4. at the recorded size
        guard stat.size == bytes else { return .skip(.changed) }
        let url = root.appendingPathComponent(file)
        // 5. untagged, or tagged with this record's id (a crash after tagging)
        var tagged = false
        switch OfflineTag.probe(at: url) {
        case .untagged: break
        case .tag(let tag) where tag.id == record.id: tagged = true
        case .tag: return .skip(.tagConflict)
        case .unreadable: return .skip(.unreadable)
        }
        // 6. it is the file FolderSync copied: the same bytes as the hidden copy, or (hidden copy evicted) not newer than the entry
        let cache = record.fileName.map { hiddenRoot.appendingPathComponent("files/\($0)") }
        if let cache, OfflineStore.fileSize(cache) != nil {
            guard sameBytes(cache, url) else { return .skip(.changed) }
        } else {
            guard stat.modified <= e.at.addingTimeInterval(mtimeSlack) else { return .skip(.changed) }
        }
        // 7. not in use
        if busy.contains(record.id) { return .skip(.busy) }
        let held = cache.flatMap { OfflineStore.fileSize($0) != nil ? record.fileName : nil }
        return .adopt(Verified(
            id: record.id, key: key, path: file, bytes: bytes, cacheName: held, recordFileName: record.fileName,
            tag: OfflineTag(record: record), url: url, tagged: tagged, excluded: stat.excluded))
    }

    /// `file` (relative to `root`) as a regular file that is not a symlink and lies inside `root` once symlinks are
    /// resolved; nil otherwise.
    private static func regularFile(_ file: String, root: URL) -> (size: Int64, modified: Date, excluded: Bool)? {
        let parts = file.split(separator: "/", omittingEmptySubsequences: false)
        guard !file.isEmpty, !file.hasPrefix("/"), !parts.contains(".."), !parts.contains("") else { return nil }
        let url = root.appendingPathComponent(file)
        var st = stat()
        let ok = url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return lstat(path, &st) == 0
        }
        guard ok, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        let prefix = root.resolvingSymlinksInPath().path + "/"
        guard url.resolvingSymlinksInPath().path.hasPrefix(prefix) else { return nil }
        let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
        let excluded = (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup ?? false
        return (Int64(st.st_size), modified, excluded)
    }

    /// Both files read to the end, a megabyte at a time.
    static func sameBytes(_ a: URL, _ b: URL) -> Bool {
        guard let x = try? FileHandle(forReadingFrom: a), let y = try? FileHandle(forReadingFrom: b) else { return false }
        defer { try? x.close(); try? y.close() }
        while true {
            do {
                let p = try x.read(upToCount: 1 << 20) ?? Data()
                let q = try y.read(upToCount: 1 << 20) ?? Data()
                if p != q { return false }
                if p.isEmpty { return true }
            } catch { return false }
        }
    }

    /// cobalt leaked its own backup exclusion into the owner's folder (the copy carried the attribute): cleared on a file
    /// adopted, and nowhere else.
    private static func clearExclusion(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        var target = url
        try? target.setResourceValues(values)
    }

    /// Deletes the hidden copies an interrupted run named: only when no record uses the name any more and the folder file
    /// that replaced it is there at its size.
    private static func settle(_ section: inout Marker.Section, root: URL, hiddenRoot: URL, ops: any OfflineFileOps) {
        let index = (try? OfflineStore.readRecordsChecked(root: hiddenRoot)) ?? []
        let inUse = Set(index.compactMap(\.fileName))
        section.pendingCache.removeAll { owed in
            let cache = hiddenRoot.appendingPathComponent("files/\(owed.name)")
            guard OfflineStore.fileSize(cache) != nil else { return true }                 // already gone
            guard !inUse.contains(owed.name) else { return true }                          // a record has it again: not ours to delete
            guard ops.size(of: root.appendingPathComponent(owed.path)) == owed.bytes else { return false }   // the folder copy is not whole: wait
            try? ops.remove(cache)
            return true
        }
    }
}
