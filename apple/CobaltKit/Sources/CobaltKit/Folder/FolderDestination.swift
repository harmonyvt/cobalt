import Foundation

/// An opened folder: its url, and the end of the security scope when a bookmark opened it. `stop()` is
/// idempotent; the scope also ends when the value is released, so a pass cannot leak it.
final class FolderAccess: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var scoped: Bool

    init(url: URL, scoped: Bool) {
        self.url = url
        self.scoped = scoped
    }

    func stop() {
        lock.lock()
        let was = scoped
        scoped = false
        lock.unlock()
        if was { url.stopAccessingSecurityScopedResource() }
    }

    deinit { stop() }
}

/// The folder the copies go to: the default one, or one the owner chose, kept as a security-scoped
/// bookmark so it keeps working after the app is sandboxed (a plain path does not survive that).
enum FolderDestination {
    enum Resolution: Sendable {
        /// Open and writable-looking. `id` names its section of the ledger.
        case ready(FolderAccess, id: String, path: String)
        /// A chosen folder that is gone (deleted, an unmounted disk): nothing is created in its place.
        case missing(path: String)
        /// The default folder could not be made (a sandbox without the Movies entitlement, a full disk).
        case notAllowed(path: String)
    }

    static let folderName = "cobalt"

    /// The owner's real home, even from a sandbox (where `NSHomeDirectory()` is the container).
    static func realHome() -> URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithFileSystemRepresentation: dir, isDirectory: true, relativeTo: nil)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// `~/Movies/cobalt`.
    static var defaultURL: URL {
        realHome().appendingPathComponent("Movies", isDirectory: true).appendingPathComponent(folderName, isDirectory: true)
    }

    /// The same folder under two spellings (a symlink, a trailing slash) compares equal.
    static func canonical(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }

    // MARK: Bookmarks

    static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: bookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// The folder a bookmark points at, with its scope opened (`stop()` on the result closes it). `stale` is
    /// true when the system says the bookmark should be remade (the folder moved or was renamed).
    static func resolve(bookmark: Data) -> (access: FolderAccess, stale: Bool)? {
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark, options: bookmarkResolutionOptions, relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        return (FolderAccess(url: url, scoped: scoped), stale)
    }

    #if os(macOS)
    private static var bookmarkCreationOptions: URL.BookmarkCreationOptions { [.withSecurityScope] }
    private static var bookmarkResolutionOptions: URL.BookmarkResolutionOptions { [.withSecurityScope, .withoutUI] }
    #else
    private static var bookmarkCreationOptions: URL.BookmarkCreationOptions { [] }
    private static var bookmarkResolutionOptions: URL.BookmarkResolutionOptions { [.withoutUI] }
    #endif

    // MARK: Opening

    /// Opens the destination the ledger records (the default one when it records none). The default folder
    /// is created when it is missing; a chosen folder never is.
    static func open(ledger: FolderLedger, defaultFolder: URL) -> Resolution {
        let fm = FileManager.default
        guard let record = ledger.destination else {
            let path = defaultFolder.path
            do {
                try fm.createDirectory(at: defaultFolder, withIntermediateDirectories: true)
            } catch {
                return .notAllowed(path: path)
            }
            return .ready(FolderAccess(url: defaultFolder, scoped: false), id: FolderLedger.defaultID, path: path)
        }
        let access: FolderAccess
        if let bookmark = record.bookmark {
            guard let resolved = resolve(bookmark: bookmark) else { return .missing(path: record.path) }
            access = resolved.access
            if resolved.stale, let fresh = try? makeBookmark(for: access.url) {
                ledger.refreshDestination(bookmark: fresh, path: access.url.path)
            } else if access.url.path != record.path, let again = try? makeBookmark(for: access.url) {
                ledger.refreshDestination(bookmark: again, path: access.url.path)       // moved in Finder: the bookmark followed it
            }
        } else {
            access = FolderAccess(url: URL(fileURLWithPath: record.path, isDirectory: true), scoped: false)
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: access.url.path, isDirectory: &isDir), isDir.boolValue else {
            access.stop()
            return .missing(path: access.url.path)
        }
        return .ready(access, id: record.id, path: access.url.path)
    }
}
