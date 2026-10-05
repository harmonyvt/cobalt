import Foundation
import Photos

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Clipboard

@MainActor
protocol Clipboard: AnyObject {
    func copy(_ text: String)
}

@MainActor
final class SystemClipboard: Clipboard {
    func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

/// Used by previews and tests: remembers what was copied instead of touching the pasteboard.
@MainActor
final class MemoryClipboard: Clipboard {
    private(set) var copies: [String] = []
    var last: String? { copies.last }
    func copy(_ text: String) { copies.append(text) }
}

// MARK: - App activity

/// Whether the app is the active (foreground, focused) app: "your webp is ready" is posted only
/// when it is not.
@MainActor
protocol AppActivity: AnyObject {
    var isActive: Bool { get }
}

/// Previews, tests and the share sheet: always active, so nothing is posted unless a test injects
/// its own.
@MainActor
final class AlwaysActive: AppActivity {
    var isActive: Bool { true }
}

/// Follows the platform's active/resign notifications by name (no UIKit/AppKit symbol, so the
/// same file builds into extensions). Starts inactive: the first "did become active" of a launch
/// in the foreground arrives right after the app model is made.
@MainActor
final class SystemAppActivity: AppActivity {
    private(set) var isActive = false
    private var observers: [any NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        #if os(macOS)
        let becameActive = "NSApplicationDidBecomeActiveNotification"
        let resigned = "NSApplicationDidResignActiveNotification"
        #else
        let becameActive = "UIApplicationDidBecomeActiveNotification"
        let resigned = "UIApplicationWillResignActiveNotification"
        #endif
        observers.append(center.addObserver(forName: Notification.Name(becameActive), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isActive = true }
        })
        observers.append(center.addObserver(forName: Notification.Name(resigned), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isActive = false }
        })
    }
}

// MARK: - Photos

enum PhotosError: Error, Sendable, Equatable {
    case denied                          // the owner said no (or the device restricts Photos)
    case unreadable                      // the file to add is not there (or not readable by this process)
    case failed(code: Int)               // Photos refused the file: `NSError.code` for the log
}

protocol PhotosSaver: Sendable {
    /// Adds the file to the library. Returns the new asset's `localIdentifier` when PhotoKit gave one.
    @discardableResult
    func save(fileURL: URL, isImage: Bool) async throws -> String?
}

/// Add-only access, as the system reports it.
enum PhotosAccess: Sendable, Equatable { case notDetermined, denied, authorized }

/// Read-write access, as the system reports it (CONTRACT-SYNC.md F1: only `.authorized` can make or
/// find an album; `.limited` can add but not fetch albums).
enum PhotosReadWrite: Sendable, Equatable { case notDetermined, denied, limited, authorized }

/// A user album, by PhotoKit's identifier.
struct PhotosAlbum: Sendable, Equatable {
    var id: String
    var title: String
}

/// The PhotoKit calls the saver and the sync make, so the decisions around them can be tested
/// without a photo library (and without the extension that makes them hard to reproduce).
protocol PhotoLibrary: Sendable {
    func status() -> PhotosAccess
    func requestAccess() async -> PhotosAccess
    @discardableResult
    func add(fileURL: URL, isImage: Bool) async throws -> String?

    // read-write era (the album)
    func readWriteStatus() -> PhotosReadWrite
    func requestReadWrite() async -> PhotosReadWrite
    /// Creates the asset (and puts it in `albumID` inside the same change block). `placeholder` is
    /// called inside the change block with the new asset's identifier, before PhotoKit commits.
    func addAsset(
        fileURL: URL, isImage: Bool, albumID: String?, placeholder: @escaping @Sendable (String) -> Void
    ) async throws -> String
    /// Which of these identifiers still resolve to an asset (needs read access).
    func existingAssets(among ids: [String]) -> Set<String>
    /// The user album with this identifier, else the user album with this title.
    func findAlbum(id: String?, title: String) -> PhotosAlbum?
    func createAlbum(title: String) async throws -> PhotosAlbum
    func addToAlbum(assetIDs: [String], albumID: String) async throws
}

extension PhotoLibrary {
    // A library with no album calls (older fakes): nothing beyond add-only.
    func readWriteStatus() -> PhotosReadWrite { .denied }
    func requestReadWrite() async -> PhotosReadWrite { .denied }
    func addAsset(
        fileURL: URL, isImage: Bool, albumID: String?, placeholder: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let id = try await add(fileURL: fileURL, isImage: isImage) ?? UUID().uuidString
        placeholder(id)
        return id
    }
    func existingAssets(among ids: [String]) -> Set<String> { Set(ids) }
    func findAlbum(id: String?, title: String) -> PhotosAlbum? { nil }
    func createAlbum(title: String) async throws -> PhotosAlbum { throw PhotosError.denied }
    func addToAlbum(assetIDs: [String], albumID: String) async throws { throw PhotosError.denied }
}

/// The identifier a change block hands out, carried out of its `@Sendable` closure.
private final class AssetIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func set(_ id: String) { lock.lock(); value = id; lock.unlock() }
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
}

struct SystemPhotoLibrary: PhotoLibrary {
    private static func access(_ s: PHAuthorizationStatus) -> PhotosAccess {
        switch s {
        case .authorized, .limited: return .authorized
        case .denied, .restricted: return .denied
        default: return .notDetermined
        }
    }

    private static func readWrite(_ s: PHAuthorizationStatus) -> PhotosReadWrite {
        switch s {
        case .authorized: return .authorized
        case .limited: return .limited
        case .denied, .restricted: return .denied
        default: return .notDetermined
        }
    }

    func status() -> PhotosAccess { Self.access(PHPhotoLibrary.authorizationStatus(for: .addOnly)) }

    func requestAccess() async -> PhotosAccess {
        Self.access(await PHPhotoLibrary.requestAuthorization(for: .addOnly))
    }

    func readWriteStatus() -> PhotosReadWrite { Self.readWrite(PHPhotoLibrary.authorizationStatus(for: .readWrite)) }

    func requestReadWrite() async -> PhotosReadWrite {
        Self.readWrite(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    @discardableResult
    func add(fileURL: URL, isImage: Bool) async throws -> String? {
        let box = AssetIDBox()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = false
            request.addResource(with: isImage ? .photo : .video, fileURL: fileURL, options: options)
            if let id = request.placeholderForCreatedAsset?.localIdentifier { box.set(id) }
        }
        return box.get()
    }

    func addAsset(
        fileURL: URL, isImage: Bool, albumID: String?, placeholder: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let box = AssetIDBox()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = false                 // Photos keeps its own copy; eviction never touches it
            request.addResource(with: isImage ? .photo : .video, fileURL: fileURL, options: options)
            guard let created = request.placeholderForCreatedAsset else { return }
            box.set(created.localIdentifier)
            placeholder(created.localIdentifier)           // written into the claim before the commit
            if let albumID,
               let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject,
               let change = PHAssetCollectionChangeRequest(for: album) {
                change.addAssets([created] as NSArray)
            }
        }
        guard let id = box.get() else { throw PhotosError.failed(code: -1) }
        return id
    }

    func existingAssets(among ids: [String]) -> Set<String> {
        guard !ids.isEmpty else { return [] }
        var found: Set<String> = []
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
            found.insert(asset.localIdentifier)
        }
        return found
    }

    func findAlbum(id: String?, title: String) -> PhotosAlbum? {
        if let id, let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject {
            return PhotosAlbum(id: album.localIdentifier, title: album.localizedTitle ?? title)
        }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "localizedTitle = %@", title)
        let found = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options)
        guard let album = found.firstObject else { return nil }
        return PhotosAlbum(id: album.localIdentifier, title: album.localizedTitle ?? title)
    }

    func createAlbum(title: String) async throws -> PhotosAlbum {
        let box = AssetIDBox()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            box.set(request.placeholderForCreatedAssetCollection.localIdentifier)
        }
        guard let id = box.get() else { throw PhotosError.failed(code: -1) }
        return PhotosAlbum(id: id, title: title)
    }

    func addToAlbum(assetIDs: [String], albumID: String) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject,
                  let change = PHAssetCollectionChangeRequest(for: album) else { return }
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
            change.addAssets(assets)
        }
    }
}

/// "save to photos". The old version asked for permission with `requestAuthorization` and treated any
/// answer but "authorized" as a refusal; inside a share extension that call can answer
/// "not determined" without ever showing a prompt, which turned the first tap into a silent
/// failure. Now only a real refusal stops the save: with the answer still open the change is
/// attempted anyway, and PhotoKit asks for add-only access itself when it has to.
struct SystemPhotosSaver: PhotosSaver {
    var library: any PhotoLibrary = SystemPhotoLibrary()

    @discardableResult
    func save(fileURL: URL, isImage: Bool) async throws -> String? {
        guard FileManager.default.isReadableFile(atPath: fileURL.path) else { throw PhotosError.unreadable }
        var access = library.status()
        if access == .notDetermined { access = await library.requestAccess() }
        guard access != .denied else { throw PhotosError.denied }
        do {
            return try await library.add(fileURL: fileURL, isImage: isImage)
        } catch let e as PhotosError {
            throw e
        } catch {
            // Photos says "not authorized" with a PHPhotosError of its own when the answer it was
            // asked for was "no".
            let code = (error as NSError).code
            if (error as NSError).domain == PHPhotosErrorDomain, code == PHPhotosError.accessUserDenied.rawValue
                || code == PHPhotosError.accessRestricted.rawValue { throw PhotosError.denied }
            throw PhotosError.failed(code: code)
        }
    }
}

/// The PHPhotosError number inside whatever a PhotoKit call threw.
func photosErrorCode(_ error: any Error) -> Int? {
    if let e = error as? PhotosError, case .failed(let code) = e { return code }
    let ns = error as NSError
    return ns.domain == PHPhotosErrorDomain ? ns.code : nil
}
