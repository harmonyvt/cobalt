import Foundation

/// Titles (CONTRACT-LIBRARY2 decisions 1 and 6): one resolver for every place a media is named, and one
/// validator shared with the server (`PATCH /library/items/<id>/post`).
public enum MediaTitle {
    public static let maxLength = 80            // Unicode code points
    public static let notifyLength = 60         // Hark label limit (APP-API-CONTRACT 9.2)

    public enum Resolved: Sendable, Equatable {
        case custom(String)
        case post(service: String, ref: String?)    // link save: "instagram · Dd7P496wolG"
        case file(String)                           // upload / Photos / share file: name without extension
        case none                                   // "cobalt"
    }

    /// Decision 1. `service` "upload" or empty counts as nil. `fileName` is the original's name
    /// (server `title`, else the local original's name).
    ///
    /// Order: the custom title; a link save (`service · ref`); a file (its name without the media
    /// extension); a bare service (a link save the server gave no ref); `cobalt`.
    public static func resolve(custom: String?, service: String?, ref: String?, fileName: String?) -> Resolved {
        if let custom, let cleaned = clean(custom) { return .custom(cleaned) }
        let svc = realService(service)
        let ref = ref.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        if let svc, let ref { return .post(service: svc, ref: ref) }
        if let fileName {
            let stripped = stripExtension(fileName).trimmingCharacters(in: .whitespacesAndNewlines)
            if !stripped.isEmpty { return .file(stripped) }
        }
        if let svc { return .post(service: svc, ref: nil) }
        return .none
    }

    /// Decision 6: trimmed, controls stripped, cut to 80 code points on a Character boundary; nil when empty.
    /// Stripped: U+0000-U+001F, U+007F-U+009F, U+2028, U+2029.
    public static func clean(_ raw: String) -> String? {
        var scalars = String.UnicodeScalarView()
        for s in raw.unicodeScalars where !isControl(s) { scalars.append(s) }
        let stripped = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        let cut = prefix(stripped, codePoints: maxLength).trimmingCharacters(in: .whitespacesAndNewlines)
        return cut.isEmpty ? nil : cut
    }

    /// Strips only media extensions: mp4 mov m4v gif webp png jpg jpeg heic (case-insensitive).
    public static func stripExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        let ext = name[name.index(after: dot)...].lowercased()
        return mediaExtensions.contains(ext) ? String(name[..<dot]) : name
    }

    /// Flattened text ("instagram · Dd7P496wolG", "cobalt"), cut to `limit` code points with "…"
    /// (the result, ellipsis included, is at most `limit` code points).
    public static func text(_ r: Resolved, limit: Int = maxLength) -> String {
        let full: String
        switch r {
        case .custom(let t): full = t
        case .post(let service, let ref): full = ref.map { "\(service) · \($0)" } ?? service
        case .file(let name): full = name
        case .none: full = "cobalt"
        }
        guard limit > 0 else { return "" }
        guard full.unicodeScalars.count > limit else { return full }
        guard limit > 1 else { return "…" }
        return prefix(full, codePoints: limit - 1) + "…"
    }

    // MARK: -

    static let mediaExtensions: Set<String> = ["mp4", "mov", "m4v", "gif", "webp", "png", "jpg", "jpeg", "heic"]

    private static func realService(_ service: String?) -> String? {
        guard let s = service?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty,
              s.lowercased() != "upload" else { return nil }
        return s
    }

    private static func isControl(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x00...0x1F, 0x7F...0x9F, 0x2028, 0x2029: true
        default: false
        }
    }

    /// The longest run of whole `Character`s that fits in `codePoints` Unicode scalars.
    static func prefix(_ s: String, codePoints: Int) -> String {
        var count = 0
        var end = s.startIndex
        for index in s.indices {
            let n = s[index].unicodeScalars.count
            if count + n > codePoints { break }
            count += n
            end = s.index(after: index)
        }
        return String(s[..<end])
    }
}

extension MediaItem {
    /// The custom title: the server's (`post.customTitle`), else this device's copy (`localTitle`,
    /// decision 8). Nil when neither is set.
    public var customTitle: String? {
        for candidate in [post?.customTitle, localTitle] {
            if let candidate, let cleaned = MediaTitle.clean(candidate) { return cleaned }
        }
        return nil
    }

    /// The original's name: the server's `title` (the cleaned upload name), else the local media's.
    var fileName: String? { post?.title ?? local?.title }

    public var title: MediaTitle.Resolved {
        MediaTitle.resolve(custom: customTitle, service: service, ref: ref, fileName: fileName)
    }

    public var titleText: String { MediaTitle.text(title) }

    /// The title without the custom one: the rename alert's message ("leave it empty to use ...").
    public var defaultTitleText: String {
        MediaTitle.text(MediaTitle.resolve(custom: nil, service: service, ref: ref, fileName: fileName))
    }
}
