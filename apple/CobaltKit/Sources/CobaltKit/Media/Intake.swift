import Foundation
import UniformTypeIdentifiers

/// A file the user picked, measured but not yet copied.
struct IntakeFile: Sendable, Equatable {
    var url: URL
    var name: String
    var bytes: Int64
    var contentType: String
    /// The photo library asset this file was picked from (`PhotosPickerItem.itemIdentifier`), so the
    /// album adopts that asset instead of adding the file to Photos a second time. Nil for Files.
    var photosAssetID: String? = nil
}

/// Reads a picked file's size and copies it into the store's inbox. Behind a seam so previews can
/// pretend a file of any size was picked.
protocol FileIntake: Sendable {
    func inspect(_ url: URL) throws -> IntakeFile
    /// Copies with `FileManager` (never through `Data`) and returns the copy's URL.
    func copyIn(_ file: IntakeFile, to destination: URL) async throws -> URL
}

enum MIME {
    /// What `PUT /studio/upload` accepts (APP-API-CONTRACT section 3, `UPLOAD_TYPES`).
    static let uploadTypes: Set<String> = [
        "image/gif", "image/webp", "image/png", "image/jpeg", "video/mp4", "video/quicktime", "image/heic",
    ]

    /// The content type to upload a file as: the extension's own type when the server takes it,
    /// otherwise the closest type it does take (an `.m4v` is an mp4, a `.heif` is a heic), else
    /// whatever the system says (the server then answers 415 and the pipeline says "unsupported").
    static func type(forFileName name: String) -> String {
        let ext = (name as NSString).pathExtension
        guard let type = UTType(filenameExtension: ext) else { return "application/octet-stream" }
        let preferred = type.preferredMIMEType ?? "application/octet-stream"
        if uploadTypes.contains(preferred) { return preferred }
        if type.conforms(to: .quickTimeMovie) { return "video/quicktime" }
        if type.conforms(to: .movie) { return "video/mp4" }
        if type.conforms(to: .heic) || type.conforms(to: .heif) { return "image/heic" }
        return preferred
    }

    /// The upload type a file's first bytes say it is, with its extension; nil when it is none of `uploadTypes`.
    /// The same signatures as the server's `sniffSave` (APP-API-CONTRACT section 3.1).
    static func sniff(_ head: Data) -> (contentType: String, ext: String)? {
        let b = [UInt8](head.prefix(16))
        let ascii = { (from: Int, to: Int) -> String in
            guard b.count >= to else { return "" }
            return String(decoding: b[from..<to], as: UTF8.self)
        }
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return ("image/jpeg", "jpg") }
        if b.count >= 8, Array(b[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] { return ("image/png", "png") }
        if ascii(0, 4) == "RIFF", ascii(8, 12) == "WEBP" { return ("image/webp", "webp") }
        if ascii(0, 6) == "GIF87a" || ascii(0, 6) == "GIF89a" { return ("image/gif", "gif") }
        if ascii(4, 8) == "ftyp" {
            let brand = ascii(8, 12)
            if heifBrands.contains(brand) { return ("image/heic", "heic") }
            if brand == "qt  " { return ("video/quicktime", "mov") }
            if mp4Brands.contains(brand) { return ("video/mp4", "mp4") }
        }
        return nil
    }

    private static let heifBrands: Set<String> = ["heic", "heix", "hevc", "mif1", "msf1"]
    private static let mp4Brands: Set<String> = [
        "isom", "iso2", "iso3", "iso4", "iso5", "iso6", "mp41", "mp42", "mp71", "avc1", "dash", "MSNV", "mmp4",
        "3gp4", "3gp5", "3gp6", "3gp7", "3ge6", "3ge7", "3gg6", "3g2a", "3g2b", "3g2c", "XAVC", "f4v ", "cmfc",
        "M4V ", "M4VH", "M4VP",
    ]

    /// A picked file's name and upload type. The extension decides; when it names nothing the server takes (a file
    /// called just "file"), the first bytes do, and the name gets the matching extension ("file" becomes "file.mp4").
    static func identify(name: String, head: () -> Data?) -> (name: String, contentType: String) {
        let byName = type(forFileName: name)
        if uploadTypes.contains(byName) { return (name, byName) }
        guard let data = head(), let sniffed = sniff(data) else { return (name, byName) }
        let hasExt = !(name as NSString).pathExtension.isEmpty
        return (hasExt ? name : "\(name).\(sniffed.ext)", sniffed.contentType)
    }

    /// The first `count` bytes of a file, nil when it cannot be read.
    static func head(of url: URL, count: Int = 16) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: count)
    }
}

struct SystemFileIntake: FileIntake {
    func inspect(_ url: URL) throws -> IntakeFile {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let found = MIME.identify(name: url.lastPathComponent, head: { MIME.head(of: url) })
        return IntakeFile(url: url, name: found.name, bytes: bytes, contentType: found.contentType)
    }

    func copyIn(_ file: IntakeFile, to destination: URL) async throws -> URL {
        let scoped = file.url.startAccessingSecurityScopedResource()
        defer { if scoped { file.url.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.copyItem(at: file.url, to: destination)
        return destination
    }
}
