import Foundation

// The repost tools' wire and result types (apple/CONTRACT-GALLERY.md 1.23-1.24, wave A7).

/// The answer of `PUT /library/items/<id>/made` (APP-API-CONTRACT 18.6): the made file's v3 row and the rows it replaced
/// (a crop replaces none; crops accumulate).
public struct MadeUpload: Sendable, Equatable {
    public var file: LibraryFile
    public var replaced: [String]

    public init(file: LibraryFile, replaced: [String] = []) {
        self.file = file
        self.replaced = replaced
    }
}

/// Where a repost frame goes (CONTRACT-GALLERY 1.24). Nothing is uploaded and no rendition is made.
public enum RepostTarget: Sendable, Equatable {
    /// iPhone and iPad: the owner's Photos, one new photo per frame (never recorded in the album sync).
    case photos
    /// The Mac: a folder the owner picked; the files are named `photo 3 · 9:16.jpg`.
    case folder(URL)
    /// The share sheet: the frames are made into a temporary folder and handed back; the caller removes them.
    case files
}

public struct RepostResult: Sendable, Equatable {
    /// The frames that were made, in the order asked (for `.photos` they are already removed).
    public var files: [URL]
    /// Items that are not photos (a video or a gif) and were left out.
    public var skipped: Int
}

/// A photo's file to read pixels from: the copy on this device, or a temporary download of the server's.
public struct FrameSource: Sendable, Equatable {
    public var url: URL
    public var isTemporary: Bool

    /// Removes a temporary download; a file the device keeps stays.
    public func discard() {
        if isTemporary { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }
}
