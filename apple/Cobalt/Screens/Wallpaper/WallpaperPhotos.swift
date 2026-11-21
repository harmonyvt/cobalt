#if os(iOS)
import CobaltKit
import Photos
import UIKit

/// Saves made wallpapers to Photos (apple/CONTRACT-WALLPAPER.md 4): each as one asset (a Live Photo when it has a video),
/// in the album "capystore wallpapers" when the owner gave full Photos access, else just into the library.
enum WallpaperPhotos {
    static let albumTitle = "capystore wallpapers"

    enum Failure: Error { case denied }

    /// Saves `files` in order and removes them afterwards. Returns whether they went into the album (not without full access).
    @discardableResult
    static func save(_ files: [WallpaperFiles]) async throws -> Bool {
        defer { files.forEach { $0.remove() } }
        var full = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if full == .notDetermined { full = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        let canAlbum = full == .authorized
        if !canAlbum {
            var add = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            if add == .notDetermined { add = await PHPhotoLibrary.requestAuthorization(for: .addOnly) }
            guard add == .authorized || add == .limited || full == .limited else { throw Failure.denied }
        }
        let albumID = canAlbum ? try await findOrCreateAlbum() : nil
        try await PHPhotoLibrary.shared().performChanges {
            var placeholders: [PHObjectPlaceholder] = []
            for file in files {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                request.addResource(with: .photo, fileURL: file.still, options: options)
                if let video = file.video {
                    let videoOptions = PHAssetResourceCreationOptions()
                    request.addResource(with: .pairedVideo, fileURL: video, options: videoOptions)
                }
                if let placeholder = request.placeholderForCreatedAsset { placeholders.append(placeholder) }
            }
            if let albumID,
               let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject,
               let change = PHAssetCollectionChangeRequest(for: album) {
                change.addAssets(placeholders as NSArray)
            }
        }
        return albumID != nil
    }

    /// The album's local identifier, made the first time.
    private static func findOrCreateAlbum() async throws -> String? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", albumTitle)
        if let found = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options).firstObject {
            return found.localIdentifier
        }
        let made = IDBox()
        try await PHPhotoLibrary.shared().performChanges {
            made.value = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumTitle)
                .placeholderForCreatedAssetCollection.localIdentifier
        }
        return made.value
    }

    private final class IDBox: @unchecked Sendable {
        var value: String?
    }

    /// Opens the Photos app (no app may open the wallpaper picker itself).
    @MainActor
    static func openPhotos() {
        if let url = URL(string: "photos-redirect://") { UIApplication.shared.open(url) }
    }
}
#endif
