import Foundation

/// How a file copied into the owner's folder is named, and how a clash is settled (the Mac's "save to a
/// folder", see `FolderSync`). Pure: no disk, no clock.
///
/// - an original: `<title>.<ext>`, the title being `MediaTitle`'s default for the media, so a link save
///   reads `instagram · DeHC9jcpfQW.mp4` and a file the owner uploaded keeps its own name;
/// - a webp: `<title> · webp <n>.webp`, `n` being the webp's 1-based place among the media's webps
///   (creation order, as the detail's tabs number them);
/// - a clash with a file already in the folder: ` (2)`, ` (3)` ... before the extension.
///
/// The name is decided once, when the file is copied. Renaming the media in cobalt later does NOT rename
/// the file: the owner may have renamed or moved it in Finder already, and a file that changes name under
/// the owner is worse than one that kept the name it was given.
enum FolderNaming {
    /// The longest stem (before the extension) in UTF-8 bytes; APFS takes 255 per name, and this leaves
    /// room for ` (99)` and the extension.
    static let maxStemBytes = 200

    /// The file name for `video`, a rendition of `media`.
    static func fileName(for video: StoredVideo, in media: StoredMedia?) -> String {
        let title = baseTitle(for: video, in: media)
        let ext = fileExtension(of: video)
        var stem = title
        if video.kind == .webp {
            let number = (media?.webps.firstIndex { $0.id == video.id }).map { $0 + 1 }
            stem = "\(title) · webp \(number ?? 1)"
        }
        return assemble(stem: stem, ext: ext)
    }

    /// `MediaTitle`'s answer for the media this video belongs to, as text. Cut to the length the app
    /// shows everywhere; "cobalt" when there is nothing else to call it.
    static func baseTitle(for video: StoredVideo, in media: StoredMedia?) -> String {
        let link = media?.link ?? video.link
        let info = link.flatMap { LinkInfo($0) }
        let custom = media?.customTitle ?? video.title
        let fileName = media?.title ?? stripWebp(video.name)
        let resolved = MediaTitle.resolve(custom: custom, service: info?.service, ref: info?.ref, fileName: fileName)
        return MediaTitle.text(resolved)
    }

    /// The file's own extension (a GIF is stored as mp4), else the kind's.
    static func fileExtension(of video: StoredVideo) -> String {
        let own = video.fileURL?.pathExtension.lowercased() ?? ""
        if !own.isEmpty, own.count <= 5, own.allSatisfy({ $0.isLetter || $0.isNumber }) { return own }
        return video.kind == .webp ? "webp" : "mp4"
    }

    /// `stem.ext`, made one safe path component: separators and controls out, no leading dot, the stem cut
    /// (never the extension) to `maxStemBytes`.
    static func assemble(stem: String, ext: String) -> String {
        var clean = SafeFileName.clean(stem) ?? "cobalt"
        clean = cut(clean, bytes: maxStemBytes)
        // trailing dots and spaces read badly in Finder and on other systems
        while let last = clean.last, last == "." || last == " " { clean.removeLast() }
        if clean.isEmpty { clean = "cobalt" }
        return ext.isEmpty ? clean : "\(clean).\(ext)"
    }

    /// `name`, or `stem (2).ext`, `stem (3).ext` ... the first one `taken` does not claim.
    static func unique(_ name: String, taken: (String) -> Bool) -> String {
        guard taken(name) else { return name }
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var n = 2
        while n < 10_000 {
            let candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            if !taken(candidate) { return candidate }
            n += 1
        }
        return "\(stem) (\(UUID().uuidString.prefix(8))).\(ext)"
    }

    // MARK: -

    private static func stripWebp(_ name: String) -> String {
        name.lowercased().hasSuffix(".webp") ? String(name.dropLast(5)) : name
    }

    /// The longest run of whole characters that fits in `bytes` bytes of UTF-8.
    private static func cut(_ s: String, bytes: Int) -> String {
        guard s.utf8.count > bytes else { return s }
        var out = ""
        var used = 0
        for ch in s {
            let n = String(ch).utf8.count
            if used + n > bytes { break }
            out.append(ch)
            used += n
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
