import Foundation
import UniformTypeIdentifiers

/// A file the user picked, measured but not yet copied.
struct IntakeFile: Sendable, Equatable {
    var url: URL
    var name: String
    var bytes: Int64
    var contentType: String
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
}

struct SystemFileIntake: FileIntake {
    func inspect(_ url: URL) throws -> IntakeFile {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let name = url.lastPathComponent
        return IntakeFile(url: url, name: name, bytes: bytes, contentType: MIME.type(forFileName: name))
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
