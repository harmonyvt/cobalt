import Foundation

/// The disk side of "save to a folder": claims, names, copies. Everything here is synchronous file IO and
/// runs off the main actor (`FolderSync` calls it from detached tasks); it holds no UI state.
struct FolderWorker: Sendable {
    /// One thing to copy.
    struct Candidate: Sendable, Equatable {
        var key: String
        var source: URL
        var bytes: Int64
        /// The name it would get in an empty folder (`FolderNaming`); a clash adds ` (2)` at copy time.
        var name: String
        var createdAt: Date
        /// A gallery's folder inside the destination (apple/CONTRACT-GALLERY.md 1.8); nil = the destination itself.
        var folder: String?
        /// The media the file belongs to: one folder per media, found again by its tag.
        var media: String = ""
    }

    enum Outcome: Sendable, Equatable {
        case copied
        case skipped
        case stop(FolderSync.Problem)
    }

    struct Counts: Sendable, Equatable {
        var saved = 0
        var waiting = 0
        var existing = 0
        var gaveUp = 0
        /// key -> the name of the copy in the folder, for every done entry.
        var files: [String: String] = [:]
    }

    let ledger: FolderLedger
    let destination: URL
    let id: String
    let path: String
    let clock: any PipelineClock

    static let partPrefix = ".cobalt-"
    static let partSuffix = ".part"

    private var fm: FileManager { .default }

    // MARK: What is there

    /// Every record the store has a file for.
    static func hasFile(_ video: StoredVideo) -> Bool {
        guard let file = video.fileURL else { return false }
        return FileManager.default.fileExists(atPath: file.path)
    }

    /// First time this folder is seen: what the store already holds is "already there" (no entry yet →
    /// skipped(preexisting)), copied only if the owner says so. `before` limits it to records older than
    /// that moment, so a save that landed after launch is still copied. Records without a file are marked
    /// too: refilling an old evicted video later is not a new save. Returns how many are now "already
    /// there" and have a file (the number the backfill offer shows).
    @discardableResult
    func markExisting(_ videos: [StoredVideo], before: Date?) -> Int {
        let items = ledger.items(id)
        var keys: [String] = []
        var seen: Set<String> = []
        for v in videos {
            if let before, v.createdAt >= before { continue }
            let key = PhotosKey.of(v)
            guard seen.insert(key).inserted, items[key] == nil else { continue }
            keys.append(key)
        }
        ledger.skipPreexisting(id, keys, path: path, now: clock.now())
        ledger.ensureSection(id, path: path)
        return counts(videos).existing
    }

    /// "add N": makes the already-there items that have a file eligible again.
    func includeExisting(_ videos: [StoredVideo]) {
        let items = ledger.items(id)
        var keys: [String] = []
        var seen: Set<String> = []
        for v in videos where Self.hasFile(v) {
            let key = PhotosKey.of(v)
            guard seen.insert(key).inserted, items[key]?.state == .skipped, items[key]?.skip == .preexisting else { continue }
            keys.append(key)
        }
        ledger.unskipPreexisting(id, keys)
    }

    /// Eligible and not settled yet, oldest first.
    func pending(_ videos: [StoredVideo], media: [StoredMedia]) -> [Candidate] {
        let items = ledger.items(id)
        var byID: [String: StoredMedia] = [:]
        for m in media { for r in m.renditions { byID[r.id] = m } }
        var seen: Set<String> = []
        var out: [Candidate] = []
        for v in videos {
            guard let file = v.fileURL else { continue }
            let key = PhotosKey.of(v)
            if let e = items[key], e.state == .done || e.state == .skipped { continue }
            guard seen.insert(key).inserted, fm.fileExists(atPath: file.path) else { continue }
            let placement = FolderNaming.placement(for: v, in: byID[v.id])
            out.append(Candidate(
                key: key, source: file, bytes: Self.size(of: file), name: placement.name, createdAt: v.createdAt,
                folder: placement.folder, media: v.mediaID))
        }
        return out.sorted { $0.createdAt < $1.createdAt }
    }

    func counts(_ videos: [StoredVideo]) -> Counts {
        let items = ledger.items(id)
        var c = Counts()
        for (key, e) in items {
            if e.state == .done {
                c.saved += 1
                if let f = e.file { c.files[key] = f }
            }
            if e.state == .skipped, e.skip == .gaveUp { c.gaveUp += 1 }
        }
        var seen: Set<String> = []
        for v in videos {
            let key = PhotosKey.of(v)
            guard seen.insert(key).inserted, Self.hasFile(v) else { continue }
            guard let e = items[key] else { c.waiting += 1; continue }
            switch e.state {
            case .claimed, .failed: c.waiting += 1
            case .skipped where e.skip == .preexisting: c.existing += 1
            default: break
            }
        }
        return c
    }

    // MARK: Copying

    /// Removes the hidden `.part` files an earlier launch left behind (a kill mid-copy), and this
    /// launch's that are over an hour old.
    func cleanStrayParts(now: Date) {
        guard let names = try? fm.contentsOfDirectory(atPath: destination.path) else { return }
        let mine = Self.partPrefix + String(FolderLedger.launchID.prefix(8))
        for name in names where name.hasPrefix(Self.partPrefix) && name.hasSuffix(Self.partSuffix) {
            let url = destination.appendingPathComponent(name)
            if !name.hasPrefix(mine) {
                try? fm.removeItem(at: url)
            } else if let m = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date, now.timeIntervalSince(m) > 3600 {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// One item: claimed, copied to a hidden part file, renamed into place under a name nothing else in the
    /// folder has, then marked done. The store keeps its own copy (this copies, never moves).
    func copy(_ c: Candidate) -> Outcome {
        switch ledger.claim(id, c.key, now: clock.now()) {
        case .alreadyDone, .skipped, .inFlight:
            return .skipped
        case .claimed:
            break
        case .doubt(let old):
            // A claim from before a kill. The rename is atomic, so the planned name holds a file only
            // when the copy finished (at the planned size).
            if let name = old.file, Self.size(ofFileAt: destination.appendingPathComponent(name)) == (old.bytes ?? c.bytes) {
                ledger.finish(id, c.key, file: name, now: clock.now())
                return .skipped
            }
            ledger.reclaim(id, c.key, now: clock.now())
        }
        guard fm.fileExists(atPath: c.source.path) else {
            ledger.release(id, c.key)
            return .skipped
        }
        let size = Self.size(of: c.source)
        var lastError: (any Error)?
        for _ in 0..<5 {
            var directory = destination
            var prefix = ""
            if let folder = c.folder {
                // a gallery's files go into one folder of its own, found again by its tag
                var taken = OfflineFolder.names(in: destination)
                var chosen: [String: String] = [:]
                do {
                    let name = try OfflineFolder.galleryFolder(media: c.media, preferred: folder, root: destination, taken: &taken, folders: &chosen)
                    directory = destination.appendingPathComponent(name, isDirectory: true)
                    prefix = name + "/"
                } catch {
                    lastError = error
                    break
                }
            }
            let name = FolderNaming.unique(c.name) { fm.fileExists(atPath: directory.appendingPathComponent($0).path) }
            let final = directory.appendingPathComponent(name)
            ledger.recordPlan(id, c.key, file: prefix + name, bytes: size)
            let part = destination.appendingPathComponent(
                "\(Self.partPrefix)\(FolderLedger.launchID.prefix(8))-\(UUID().uuidString.prefix(8))\(Self.partSuffix)")
            do {
                try fm.copyItem(at: c.source, to: part)
                // no-clobber rename: a file the owner made under this name meanwhile is never replaced
                guard Self.renameExclusive(part, final) else {
                    let code = errno
                    try? fm.removeItem(at: part)
                    if code == EEXIST { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
                }
                ledger.finish(id, c.key, file: prefix + name, now: clock.now())
                return .copied
            } catch {
                try? fm.removeItem(at: part)
                lastError = error
                break
            }
        }
        return settle(lastError, key: c.key)
    }

    /// What a failure means: out of space, no permission and a vanished folder stop the pass and leave
    /// the item waiting; a vanished source is skipped; anything else is counted against the item.
    private func settle(_ error: (any Error)?, key: String) -> Outcome {
        guard let error else {
            // five names in a row were taken: count it, the next pass names it again
            ledger.fail(id, key, code: Int(EEXIST), now: clock.now())
            return .skipped
        }
        let codes = Self.codes(of: error)
        if codes.cocoa.contains(NSFileWriteOutOfSpaceError) || codes.posix.contains(ENOSPC) || codes.posix.contains(EDQUOT) {
            ledger.release(id, key)
            return .stop(.diskFull)
        }
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: destination.path, isDirectory: &isDir) || !isDir.boolValue {
            ledger.release(id, key)
            return .stop(.folderMissing)
        }
        if codes.cocoa.contains(NSFileWriteNoPermissionError) || codes.cocoa.contains(NSFileWriteVolumeReadOnlyError)
            || codes.posix.contains(EACCES) || codes.posix.contains(EPERM) || codes.posix.contains(EROFS) {
            ledger.release(id, key)
            return .stop(.notAllowed)
        }
        if codes.cocoa.contains(NSFileReadNoSuchFileError) || codes.cocoa.contains(NSFileNoSuchFileError) || codes.posix.contains(ENOENT) {
            // the folder is there (checked above), so the source went away under the copy
            ledger.release(id, key)
            return .skipped
        }
        ledger.fail(id, key, code: codes.cocoa.first ?? codes.posix.first.map(Int.init) ?? -1, now: clock.now())
        return .skipped
    }

    // MARK: Helpers

    static func size(of url: URL) -> Int64 { size(ofFileAt: url) ?? 0 }

    static func size(ofFileAt url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attrs[.size] as? NSNumber)?.int64Value
    }

    /// `rename(2)` that fails with EEXIST instead of replacing.
    static func renameExclusive(_ from: URL, _ to: URL) -> Bool {
        from.withUnsafeFileSystemRepresentation { f in
            to.withUnsafeFileSystemRepresentation { t in
                guard let f, let t else { errno = EINVAL; return false }
                return renamex_np(f, t, 0x0000_0004) == 0          // RENAME_EXCL
            }
        }
    }

    /// The Cocoa and POSIX codes in an error and the errors under it.
    static func codes(of error: any Error) -> (cocoa: [Int], posix: [Int32]) {
        var cocoa: [Int] = []
        var posix: [Int32] = []
        var current: NSError? = error as NSError
        var depth = 0
        while let e = current, depth < 4 {
            if e.domain == NSCocoaErrorDomain { cocoa.append(e.code) }
            if e.domain == NSPOSIXErrorDomain { posix.append(Int32(truncatingIfNeeded: e.code)) }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return (cocoa, posix)
    }
}
