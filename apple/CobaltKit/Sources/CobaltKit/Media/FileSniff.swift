import Foundation

/// What a file really is, read from its first bytes. A file that came without an extension was stored as `.mp4`
/// (or `.webp`), so a picture could sit on disk as `<id>.mp4`; Photos then refused it as a video ("couldn't save to
/// photos", owner 2026-11-21). The name is a guess, the bytes are not.
enum FileSniff {
    enum Kind: Equatable, Sendable {
        case image(ext: String)
        case video(ext: String)

        var ext: String {
            switch self {
            case .image(let e), .video(let e): return e
            }
        }

        var isImage: Bool {
            if case .image = self { return true }
            return false
        }
    }

    /// The kind of the file at `url`, or nil when it cannot be read or is none we know.
    static func kind(of url: URL) -> Kind? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 32) else { return nil }
        return kind(of: head)
    }

    static func kind(of data: Data) -> Kind? {
        let b = [UInt8](data.prefix(32))
        func at(_ i: Int, _ s: String) -> Bool {
            let want = Array(s.utf8)
            return b.count >= i + want.count && Array(b[i..<(i + want.count)]) == want
        }
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return .image(ext: "jpg") }
        if b.count >= 4, b[0] == 0x89, at(1, "PNG") { return .image(ext: "png") }
        if at(0, "GIF8") { return .image(ext: "gif") }
        if at(0, "RIFF"), at(8, "WEBP") { return .image(ext: "webp") }
        if b.count >= 4, b[0] == 0x1A, b[1] == 0x45, b[2] == 0xDF, b[3] == 0xA3 {
            return .video(ext: "webm")
        }
        if at(4, "ftyp") {
            let brand = b.count >= 12 ? String(decoding: b[8..<12], as: UTF8.self) : ""
            switch brand {
            case "heic", "heix", "heim", "heis", "mif1", "msf1": return .image(ext: "heic")
            case "avif", "avis": return .image(ext: "avif")
            case "qt  ": return .video(ext: "mov")
            case "M4V ", "M4VH", "M4VP": return .video(ext: "m4v")
            default: return .video(ext: "mp4")
            }
        }
        return nil
    }

    /// The file to hand Photos. PhotoKit reads the type from the name, so it refuses a file with no extension (a
    /// library download whose server gave no usable content type sat in the inbox as a bare `<name>`: "couldn't save
    /// to photos", owner 2026-11-21) or one whose name disagrees with its bytes. Returns `file` when its name already
    /// fits, else a link (or copy) of it under the right extension in a temporary folder `discardPhotosCopy` removes.
    /// Off main: it reads the file's first bytes and may copy it.
    @concurrent
    nonisolated static func photosReady(_ file: URL, isImage: Bool) async throws -> (url: URL, isImage: Bool, temporary: Bool) {
        guard FileManager.default.isReadableFile(atPath: file.path) else { throw PhotosError.unreadable }
        let sniffed = kind(of: file)
        let image = sniffed?.isImage ?? isImage
        let ext = storedExtension(for: file, fallback: image ? "jpg" : "mp4")
        if ext == file.pathExtension.lowercased() { return (file, image, false) }
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("photos-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var base = file.deletingPathExtension().lastPathComponent
        if base.isEmpty { base = "cobalt" }
        let named = folder.appendingPathComponent(base, isDirectory: false).appendingPathExtension(ext)
        do {
            try fm.linkItem(at: file, to: named)
        } catch {
            do { try fm.copyItem(at: file, to: named) } catch {
                try? fm.removeItem(at: folder)
                throw error
            }
        }
        return (named, image, true)
    }

    /// Removes what `photosReady` made, if it made anything.
    @concurrent
    nonisolated static func discardPhotosCopy(_ ready: (url: URL, isImage: Bool, temporary: Bool)) async {
        guard ready.temporary else { return }
        try? FileManager.default.removeItem(at: ready.url.deletingLastPathComponent())
    }

    /// The extension to store `file` under: its own when it agrees with its bytes, else the bytes', else `fallback`.
    static func storedExtension(for file: URL, fallback: String) -> String {
        let own = file.pathExtension.lowercased()
        guard let sniffed = kind(of: file) else { return own.isEmpty ? fallback : own }
        if own.isEmpty { return sniffed.ext }
        let ownIsImage = OfflineStore.looksLikeImage("x.\(own)")
        return ownIsImage == sniffed.isImage ? own : sniffed.ext
    }
}
