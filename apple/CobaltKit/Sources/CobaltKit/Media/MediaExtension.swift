import Foundation
import Synchronization
import UniformTypeIdentifiers

/// Picture, video or sound from a file extension, without asking Launch Services on the main thread. The first
/// `UTType(filenameExtension:)` of a process is a synchronous XPC round trip: a type badge in the save tab's orbit made it
/// from a view body and froze the launch for 0.6 s (PostHog hang_stack, 8.26 build 136). The extensions this app sees are
/// answered from a table; anything else asks once and is remembered.
public enum MediaExtension {
    public enum Kind: Sendable, Equatable { case image, movie, audio, other }

    private static let table: [String: Kind] = [
        "jpg": .image, "jpeg": .image, "png": .image, "gif": .image, "webp": .image, "heic": .image, "heif": .image,
        "avif": .image, "tif": .image, "tiff": .image, "bmp": .image, "dng": .image,
        "mp4": .movie, "mov": .movie, "m4v": .movie, "qt": .movie, "webm": .movie, "mkv": .movie, "avi": .movie,
        "3gp": .movie, "ts": .movie,
        "mp3": .audio, "m4a": .audio, "aac": .audio, "wav": .audio, "flac": .audio, "ogg": .audio, "opus": .audio,
    ]
    private static let asked = Mutex<[String: Kind]>([:])

    /// What the extension names (case does not matter; no dot).
    public static func kind(_ ext: String) -> Kind {
        let ext = ext.lowercased()
        if ext.isEmpty { return .other }
        if let known = table[ext] { return known }
        if let seen = asked.withLock({ $0[ext] }) { return seen }
        let kind: Kind
        if let type = UTType(filenameExtension: ext) {
            kind = type.conforms(to: .image) ? .image : type.conforms(to: .movie) ? .movie
                : type.conforms(to: .audio) ? .audio : .other
        } else {
            kind = .other
        }
        asked.withLock { $0[ext] = kind }
        return kind
    }

    public static func isImage(_ ext: String) -> Bool { kind(ext) == .image }
    public static func isMovie(_ ext: String) -> Bool { kind(ext) == .movie }
    /// A picture, a video or a sound (`.audiovisualContent` or `.image`).
    public static func isMedia(_ ext: String) -> Bool { kind(ext) != .other }
}
