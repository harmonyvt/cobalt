import Foundation

/// Where the Mac's visible root is right now and whether it can be used (CONTRACT-OFFLINE.md 13.1, 13.4, 13.6).
struct MacRootResolution: Sendable {
    /// The root, whether or not it is reachable: the store keeps this URL for the life of the app.
    var url: URL
    var state: RootState
    /// The security scope of a chosen folder, held open by the store (nil for the default folder and when unreachable).
    var access: FolderAccess?
    var isDefault: Bool
    /// The ledger section of this folder (`FolderAdoption` reads it).
    var sectionID: String
}

/// Reads the ledger's destination record and answers where the root is. Pure disk reads plus the default folder's
/// creation: safe to call often (the store does so on every reload, scan and promotion, so a disk swapped under the same
/// path is never written to).
struct MacRootProvider: Sendable {
    let ledger: FolderLedger
    let defaultFolder: URL

    init(ledger: FolderLedger, defaultFolder: URL = FolderDestination.defaultURL) {
        self.ledger = ledger
        self.defaultFolder = defaultFolder
    }

    func resolve() -> MacRootResolution {
        let record = ledger.destination
        let id = record?.id ?? FolderLedger.defaultID
        switch FolderDestination.open(ledger: ledger, defaultFolder: defaultFolder) {
        case .missing(let path):
            // a chosen folder that is gone (an unplugged disk): never re-created, never "every file deleted"
            return MacRootResolution(
                url: URL(fileURLWithPath: record?.path ?? path, isDirectory: true), state: .unreachable(path: path), access: nil,
                isDefault: record == nil, sectionID: id)
        case .notAllowed(let path):
            return MacRootResolution(
                url: defaultFolder, state: .notAllowed(path: path), access: nil, isDefault: true, sectionID: id)
        case .ready(let access, let sectionID, let path):
            var state = RootState.ready
            if let record, Self.differs(record, FolderDestination.identity(of: access.url)) {
                state = .wrongFolder(path: path)                 // another disk, or another folder, at the same path
            } else if !FileManager.default.isWritableFile(atPath: access.url.path) {
                state = .notAllowed(path: path)
            }
            return MacRootResolution(url: access.url, state: state, access: access, isDefault: record == nil, sectionID: sectionID)
        }
    }

    /// 13.4: only what both sides know is compared (an exFAT disk may report no file id: then the volume decides).
    static func differs(_ record: FolderDestinationRecord, _ now: FolderIdentity) -> Bool {
        if let was = record.volume, let is_ = now.volume, was != is_ { return true }
        if let was = record.fileID, let is_ = now.fileID, was != is_ { return true }
        return false
    }

    /// A chosen folder whose record has no identity yet (a record from 1.14.x) learns it after a scan that succeeded.
    func recordIdentity(ofRoot url: URL?) {
        guard let url, ledger.destination != nil else { return }
        let identity = FolderDestination.identity(of: url)
        ledger.recordIdentity(volume: identity.volume, fileID: identity.fileID)
    }
}
