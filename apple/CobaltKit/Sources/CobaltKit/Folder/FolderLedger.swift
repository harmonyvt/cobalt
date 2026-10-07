import Foundation

/// One item's record in the folder ledger, as 1.14.x's `FolderSync` wrote it. Wave M reads these (the adoption of what
/// FolderSync copied, `FolderAdoption`) and never writes them: the ledger stays intact so a downgrade copies nothing again.
struct FolderEntry: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case claimed, done, failed, skipped }
    enum Skip: String, Codable, Sendable { case preexisting, gaveUp }

    var state: State
    var at: Date
    /// The name the copy has (or, while `claimed`, will have) in the folder, relative to the folder.
    var file: String?
    /// The size the copy must have to count as finished.
    var bytes: Int64?
    /// The launch that holds a `claimed` entry: a claim from another launch is in doubt at once (the
    /// process that made it is gone), no waiting for the clock.
    var by: String?
    var code: Int?
    var tries: Int = 0
    var skip: Skip?
    /// What a made file is within its post (`media|slideshow webp`), recorded with the plan: a later file of the same slot
    /// replaces this one in the folder (the file we wrote, named here), never numbered beside it. Nil for everything else.
    var slot: String?
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
    /// Which disk the chosen folder was on (`volumeUUIDStringKey`) and its file id (13.4): a resolved root whose volume or
    /// file id differs is another folder (`RootState.wrongFolder`). Nil in a record from 1.14.x: the first successful
    /// scan records them. Never recorded for the default folder.
    var volume: String?
    var fileID: Int64?
}

struct FolderSection: Codable, Equatable, Sendable {
    var path: String
    var items: [String: FolderEntry] = [:]
}

struct FolderStateFile: Codable, Equatable, Sendable {
    var destination: FolderDestinationRecord?
    var sections: [String: FolderSection] = [:]
}

/// `FolderLedger`: `Sync/folder.json`, read and written under `NSFileCoordinator` (it is `PhotosLedger`'s sibling).
///
/// From wave M it holds only what is read to adopt what `FolderSync` wrote (`FolderAdoption`, never written by it) and the
/// owner's choice of folder: `choose`, `refreshDestination`, `recordIdentity` and the readers. The claim, finish, fail and
/// skip API went with `FolderSync` and `FolderWorker`.
///
/// - **Per folder.** Entries live in a section per destination (`FolderDestinationRecord.id`).
final class FolderLedger: Sendable {
    static let defaultID = "default"

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
    /// one, else a new one. `volume` and `fileID` are the identity of the folder as chosen (13.4).
    @discardableResult
    func choose(path: String, bookmark: Data?, isDefault: Bool, volume: String? = nil, fileID: Int64? = nil) -> String {
        file.mutate { f in
            if isDefault {
                f.destination = nil
                if f.sections[Self.defaultID] == nil { f.sections[Self.defaultID] = FolderSection(path: path) }
                f.sections[Self.defaultID]?.path = path
                return Self.defaultID
            }
            let existing = f.sections.first { $0.key != Self.defaultID && $0.value.path == path }?.key
            let id = existing ?? UUID().uuidString
            f.destination = FolderDestinationRecord(id: id, bookmark: bookmark, path: path, volume: volume, fileID: fileID)
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

    /// The chosen folder's identity, recorded after a scan that succeeded (13.4). Writes nothing when the record already
    /// has one, and nothing for the default folder (no destination record).
    func recordIdentity(volume: String?, fileID: Int64?) {
        guard let current = file.read().destination, current.volume == nil, current.fileID == nil,
              volume != nil || fileID != nil else { return }
        file.mutate { f in
            guard var d = f.destination, d.volume == nil, d.fileID == nil else { return }
            d.volume = volume
            d.fileID = fileID
            f.destination = d
        }
    }

    /// Makes the section exist (an empty one) so "has this folder been set up" has an answer.
    func ensureSection(_ dest: String, path: String) {
        file.mutate { f in
            if f.sections[dest] == nil { f.sections[dest] = FolderSection(path: path) }
        }
    }
}
