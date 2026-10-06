import Foundation

/// How a file copied into the owner's folder is named, and how a clash is settled (the Mac's "save to a
/// folder", see `FolderSync`). Pure: no disk, no clock.
///
/// - an original: `<title>.<ext>`, the title being `MediaTitle`'s default for the media, so a link save
///   reads `instagram · DeHC9jcpfQW.mp4` and a file the owner uploaded keeps its own name;
/// - a webp: `<title> · webp <n>.webp`, `n` being the webp's 1-based place among the media's webps
///   (creation order, as the detail's tabs number them);
/// - a clash with a file already in the folder: ` (2)`, ` (3)` ... before the extension;
/// - a **gallery** (apple/CONTRACT-GALLERY.md 1.8) is a folder named by the title, holding `01.jpg` ... (an item, its
///   place in the post: a video item `03.mp4`), `slideshow.webp`, `slideshow.mp4`, `gallery image · 3 across.jpg`,
///   `03 · webp 1.webp` (a webp of an item, numbered as today) and `03 · crop 9:16.jpg`. A made file is replaced when it
///   is made again (R8), never numbered; the ` (2)` only covers a clash with the owner's own file.
///
/// The name is decided once, when the file is copied. Renaming the media in cobalt later does NOT rename
/// the file in the Mac's `FolderSync` (the owner may have renamed or moved it in Finder already). The offline
/// store's visible folder (CONTRACT-OFFLINE.md decision 8) follows a rename only while the file still has the
/// name cobalt gave it (`Record.givenName`); a file the owner renamed is never renamed again.
enum FolderNaming {
    /// The longest stem (before the extension) in UTF-8 bytes; APFS takes 255 per name, and this leaves
    /// room for ` (99)` and the extension.
    static let maxStemBytes = 200

    /// Whether `video` lives in a gallery's folder: an item or a made file, or a webp of a media that has items.
    static func isInGalleryFolder(_ video: StoredVideo, in media: StoredMedia?) -> Bool {
        video.role != nil || media?.items.isEmpty == false
    }

    /// Where `video` goes: the folder (nil = the root) and the file name inside it.
    struct Placement: Equatable {
        var folder: String?
        var name: String
    }

    static func placement(for video: StoredVideo, in media: StoredMedia?) -> Placement {
        Placement(
            folder: isInGalleryFolder(video, in: media) ? folderName(for: video, in: media) : nil,
            name: fileName(for: video, in: media))
    }

    /// The gallery's folder name: the media's title, as a safe single path component.
    static func folderName(for video: StoredVideo, in media: StoredMedia?) -> String {
        assemble(stem: baseTitle(for: video, in: media), ext: "")
    }

    /// `NN` of an item: its place in the post, from 1, two digits at least.
    static func itemNumber(_ index: Int) -> String { String(format: "%02d", index + 1) }

    /// The leaf name of a file in a gallery's folder; nil for a file that is not part of one.
    private static func galleryLeaf(for video: StoredVideo, in media: StoredMedia?) -> String? {
        guard isInGalleryFolder(video, in: media) else { return nil }
        let ext = fileExtension(of: video)
        switch video.role {
        case .item?:
            return assemble(stem: itemNumber(video.itemIndex ?? 0), ext: ext)
        case .slideshow?:
            return assemble(stem: "slideshow", ext: ext)
        case .export?:
            if case .galleryImage(let layout)? = video.madeKind { return assemble(stem: "gallery image · \(layout.label)", ext: ext) }
            return assemble(stem: "export", ext: ext)
        case .crop?:
            let n = video.madeFrom?.first.map { itemNumber($0) }
            let aspect = video.madeSpec.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }?["aspect"] as? String
            return assemble(stem: [n, "crop" + (aspect.map { " \($0)" } ?? "")].compactMap { $0 }.joined(separator: " · "), ext: ext)
        case nil:
            guard video.kind == .webp, let media else { return nil }
            // a webp of one item of the gallery: `03 · webp 1`, numbered among the media's webps as the tabs are
            let number = (media.webps.firstIndex { $0.id == video.id }).map { $0 + 1 } ?? 1
            let item = video.madeFrom?.first
                ?? media.items.first { !StoredMedia.isStill($0) }?.itemIndex ?? media.items.first?.itemIndex ?? 0
            return assemble(stem: "\(itemNumber(item)) · webp \(number)", ext: ext)
        }
    }

    /// The file name for `video`, a rendition of `media`.
    static func fileName(for video: StoredVideo, in media: StoredMedia?) -> String {
        if let leaf = galleryLeaf(for: video, in: media) { return leaf }
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

    /// `unique` against the names already in a folder, compared case-insensitively (APFS and Files do): `taken`
    /// holds those names lowercased (`OfflineFolder.names(in:)`).
    static func unique(_ name: String, among taken: Set<String>) -> String {
        unique(name) { taken.contains($0.lowercased()) }
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
