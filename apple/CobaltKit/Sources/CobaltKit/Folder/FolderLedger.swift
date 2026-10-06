import Foundation

/// One item's record in the folder ledger.
struct FolderEntry: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case claimed, done, failed, skipped }
    enum Skip: String, Codable, Sendable { case preexisting, gaveUp }

    var state: State
    var at: Date
    /// The name the copy has (or, while `claimed`, will have) in the folder.
    var file: String?
    /// The size the copy must have to count as finished.
    var bytes: Int64?
    /// The launch that holds a `claimed` entry: a claim from another launch is in doubt at once (the
    /// process that made it is gone), no waiting for the clock.
    var by: String?
    var code: Int?
    var tries: Int = 0
    var skip: Skip?
}

/// Where the copies go, as the owner chose it. `bookmark == nil` is the default folder (`~/Movies/cobalt`).
struct FolderDestinationRecord: Codable, Equatable, Sendable {
    /// Names this destination's section of the ledger. Choosing a folder the ledger already knows (by path)
    /// brings its section back, so going back to an old folder never copies everything again.
    var id: String
    /// A security-scoped bookmark of the chosen folder (the path alone stops working once the app is sandboxed).
    var bookmark: Data?
    /// The path when it was chosen or last resolved: for display and for recognising the same folder again.
    var path: String
}

struct FolderSection: Codable, Equatable, Sendable {
    var path: String
    var items: [String: FolderEntry] = [:]
}

struct FolderStateFile: Codable, Equatable, Sendable {
    var destination: FolderDestinationRecord?
    var sections: [String: FolderSection] = [:]
}

/// `FolderLedger`: `Sync/folder.json` next to the photos ledger, read and written under `NSFileCoordinator`
/// (it is `PhotosLedger`'s sibling and answers the same rules).
///
/// - **Never twice.** An item is claimed here before its file is touched, and marked done once the copy is
///   in place under its final name. Done is forever: nothing ever looks again at whether the file is still
///   there, so what the owner deletes, renames or moves out of the folder is never put back.
/// - **Survives a kill mid-copy.** The copy is written to a hidden `.part` file and renamed into place, so
///   the final name only ever holds a whole file. A claim left by a dead launch is settled on the next
///   pass: the final name exists at the right size → done, else the copy is started again.
/// - **Per folder.** Entries live in a section per destination (`FolderDestinationRecord.id`). A new
///   folder starts with an empty section, so what cobalt already holds is "already there" and offered,
///   never copied behind the owner's back.
final class FolderLedger: Sendable {
    /// A claim from this launch older than this is "in doubt" (a copy that took longer than this died).
    static let staleClaim: TimeInterval = 600
    static let maxTries = 3
    static let defaultID = "default"
    /// Which launch is asking; claims made by another one are the dead process's.
    static let launchID = UUID().uuidString

    private let file: CoordinatedFile<FolderStateFile>

    init(directory: URL) {
        file = CoordinatedFile(url: directory.appendingPathComponent("folder.json"), empty: FolderStateFile())
    }

    private static let sharedInstance = FolderLedger(directory: AppGroup.directory("Sync"))
    static func shared() -> FolderLedger { sharedInstance }

    var url: URL { file.url }

    // MARK: Reading

    func snapshot() -> FolderStateFile { file.read() }
    var destination: FolderDestinationRecord? { file.read().destination }
    var destinationID: String { file.read().destination?.id ?? Self.defaultID }
    func hasSection(_ dest: String) -> Bool { file.read().sections[dest] != nil }
    func items(_ dest: String) -> [String: FolderEntry] { file.read().sections[dest]?.items ?? [:] }
    func entry(_ dest: String, _ key: String) -> FolderEntry? { file.read().sections[dest]?.items[key] }

    // MARK: Destination

    /// Records a chosen folder. Returns its id: the section of a folder with the same path when there is
    /// one, else a new one.
    @discardableResult
    func choose(path: String, bookmark: Data?, isDefault: Bool) -> String {
        file.mutate { f in
            if isDefault {
                f.destination = nil
                if f.sections[Self.defaultID] == nil { f.sections[Self.defaultID] = FolderSection(path: path) }
                f.sections[Self.defaultID]?.path = path
                return Self.defaultID
            }
            let existing = f.sections.first { $0.key != Self.defaultID && $0.value.path == path }?.key
            let id = existing ?? UUID().uuidString
            f.destination = FolderDestinationRecord(id: id, bookmark: bookmark, path: path)
            if f.sections[id] == nil { f.sections[id] = FolderSection(path: path) }
            return id
        }
    }

    /// A bookmark that resolved stale was remade, or the folder moved: keep the record current.
    func refreshDestination(bookmark: Data, path: String) {
        file.mutate { f in
            guard var d = f.destination else { return }
            d.bookmark = bookmark
            d.path = path
            f.destination = d
            f.sections[d.id]?.path = path
        }
    }

    /// Makes the section exist (an empty one) so "has this folder been set up" has an answer.
    func ensureSection(_ dest: String, path: String) {
        file.mutate { f in
            if f.sections[dest] == nil { f.sections[dest] = FolderSection(path: path) }
        }
    }

    // MARK: Claiming

    enum Claim: Equatable, Sendable {
        case claimed
        case alreadyDone
        case skipped
        case inFlight                   // this launch is on it right now
        case doubt(FolderEntry)         // a claim nobody is working on: settle it before going on
    }

    func claim(_ dest: String, _ key: String, now: Date) -> Claim {
        file.mutate { f in
            var section = f.sections[dest] ?? FolderSection(path: "")
            defer { f.sections[dest] = section }
            guard let e = section.items[key] else {
                section.items[key] = FolderEntry(state: .claimed, at: now, by: Self.launchID)
                return .claimed
            }
            switch e.state {
            case .done: return .alreadyDone
            case .skipped: return .skipped
            case .claimed:
                if e.by == Self.launchID, now.timeIntervalSince(e.at) < Self.staleClaim { return .inFlight }
                return .doubt(e)
            case .failed:
                var next = e
                next.state = .claimed
                next.at = now
                next.by = Self.launchID
                section.items[key] = next
                return .claimed
            }
        }
    }

    /// Takes over a claim in doubt (the owner of it is gone): a fresh claim of this launch.
    func reclaim(_ dest: String, _ key: String, now: Date) {
        file.mutate { f in
            guard var e = f.sections[dest]?.items[key], e.state == .claimed else { return }
            e.at = now
            e.by = Self.launchID
            e.file = nil
            f.sections[dest]?.items[key] = e
        }
    }

    /// The name this copy will have, kept before the copy starts so a pass after a kill can find it.
    func recordPlan(_ dest: String, _ key: String, file name: String, bytes: Int64) {
        file.mutate { f in
            guard var e = f.sections[dest]?.items[key], e.state == .claimed else { return }
            e.file = name
            e.bytes = bytes
            f.sections[dest]?.items[key] = e
        }
    }

    /// The copy is in place.
    func finish(_ dest: String, _ key: String, file name: String, now: Date) {
        file.mutate { f in
            var section = f.sections[dest] ?? FolderSection(path: "")
            var e = section.items[key] ?? FolderEntry(state: .done, at: now)
            e.state = .done
            e.at = now
            e.file = name
            e.by = nil
            e.code = nil
            e.skip = nil
            section.items[key] = e
            f.sections[dest] = section
        }
    }

    /// Back to "not tried": no room, folder missing, no permission. Nothing is counted against the item.
    func release(_ dest: String, _ key: String) {
        file.mutate { f in
            if f.sections[dest]?.items[key]?.state == .claimed { f.sections[dest]?.items[key] = nil }
        }
    }

    /// A failure that is not "try later": counted; the third becomes `skipped(gaveUp)`.
    @discardableResult
    func fail(_ dest: String, _ key: String, code: Int, now: Date) -> FolderEntry.State {
        file.mutate { f in
            var section = f.sections[dest] ?? FolderSection(path: "")
            var e = section.items[key] ?? FolderEntry(state: .failed, at: now)
            e.tries += 1
            e.code = code
            e.at = now
            e.by = nil
            if e.tries >= Self.maxTries {
                e.state = .skipped
                e.skip = .gaveUp
            } else {
                e.state = .failed
            }
            section.items[key] = e
            f.sections[dest] = section
            return e.state
        }
    }

    // MARK: Skipping

    /// Marks items that have no entry yet as "already there before the folder was on" (the backfill
    /// offer). An item that has an entry keeps it.
    func skipPreexisting(_ dest: String, _ keys: [String], path: String, now: Date) {
        guard !keys.isEmpty else { return }
        file.mutate { f in
            var section = f.sections[dest] ?? FolderSection(path: path)
            for key in keys where section.items[key] == nil {
                var e = FolderEntry(state: .skipped, at: now)
                e.skip = .preexisting
                section.items[key] = e
            }
            f.sections[dest] = section
        }
    }

    /// "add N": the entries `skipPreexisting` wrote for these keys go, so the items are eligible again.
    func unskipPreexisting(_ dest: String, _ keys: [String]) {
        guard !keys.isEmpty else { return }
        file.mutate { f in
            for key in keys where f.sections[dest]?.items[key]?.state == .skipped && f.sections[dest]?.items[key]?.skip == .preexisting {
                f.sections[dest]?.items[key] = nil
            }
        }
    }
}
