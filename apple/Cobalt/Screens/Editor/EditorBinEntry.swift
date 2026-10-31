import CobaltKit
import Foundation

/// A library file the bin offers: what the editor can do with it, as an `EditSource` ready for `EditSession.add` /
/// `addOverlay`. Built from the loaded library posts (the same files `EditorStore.create(from:)` reads: a post's original,
/// a gallery's items), so the ids are the server's library file ids.
struct EditorBinEntry: Identifiable, Equatable {
    let source: EditSource
    /// The post's title, for the search field.
    let postTitle: String
    /// A 7TV emote the library keeps (APP-API-CONTRACT 39.2): the add sheet's emotes tab.
    var isEmote = false

    /// What the add sheet's tabs sort by (apple/CONTRACT-EDITOR.md 12).
    enum Shelf: String, CaseIterable, Identifiable {
        case videos, images, emotes
        var id: String { rawValue }
    }

    var shelf: Shelf {
        if isEmote { return .emotes }
        return source.kind == .video ? .videos : .images
    }

    /// A picture whose background can be taken out (a photo, a gif or webp's first frame).
    var canCutout: Bool { source.kind == .photo || source.kind == .gif }

    var id: String { source.id }

    /// A file the editor takes: mp4 and mov videos, gifs, jpgs and pngs (apple/CONTRACT-EDITOR.md decision 1), and webps on a
    /// server with layers (39.2).
    var isEditable: Bool { source.kind != .unsupported }

    /// All the files the loaded library holds that are on the server, newest post first.
    @MainActor
    static func entries(_ model: AppModel) -> [EditorBinEntry] {
        var out: [EditorBinEntry] = []
        var seen = Set<String>()
        // webp sources (emotes, animated webps) came with layers and cutouts (39.2)
        let webp = model.capabilities.limits.editOverlayTracks > 1

        func add(_ rendition: Rendition, post: LibraryPost, type: MediaType?, title: String) {
            guard let file = rendition.file, seen.insert(file.id).inserted else { return }
            let kind = classify(contentType: file.contentType, name: file.name, type: type, webp: webp)
            let source = EditSource(
                id: file.id, name: file.name, kind: kind, contentType: file.contentType,
                width: rendition.width ?? file.width, height: rendition.height ?? file.height,
                duration: rendition.duration ?? file.duration, bytes: file.bytes,
                posterURL: rendition.posterURL ?? file.posterURL ?? post.posterURL, available: true)
            out.append(EditorBinEntry(source: source, postTitle: title))
        }

        for post in model.library.posts where post.isEmote {
            guard webp else { break }
            let title = post.customTitle ?? post.title ?? ""
            for file in post.files where file.source == .emote && seen.insert(file.id).inserted {
                let kind = classify(contentType: file.contentType, name: file.name, type: nil, webp: true)
                guard kind != .unsupported else { continue }
                let source = EditSource(
                    id: file.id, name: file.name, kind: kind, contentType: file.contentType, width: file.width,
                    height: file.height, duration: nil, bytes: file.bytes, posterURL: file.url ?? file.posterURL, available: true)
                out.append(EditorBinEntry(source: source, postTitle: title.isEmpty ? source.shortName : title, isEmote: true))
            }
        }
        for post in model.library.posts where !post.isEmote {
            let item = model.mediaItem(for: post)
            let title = item.titleText
            if item.kind == .gallery {
                for rendition in item.items { add(rendition, post: post, type: rendition.itemType, title: title) }
            } else if let video = item.video {
                add(video, post: post, type: nil, title: title)
            }
        }
        return out
    }

    /// What a file is to the editor: by content type, then by extension, then by the gallery item's own word.
    static func classify(contentType: String?, name: String, type: MediaType?, webp: Bool = false) -> EditSourceKind {
        let ext = (name as NSString).pathExtension.lowercased()
        if let ct = contentType?.lowercased() {
            switch ct {
            case "video/mp4", "video/quicktime", "video/x-m4v": return .video
            case "image/gif": return .gif
            case "image/jpeg", "image/jpg", "image/png": return .photo
            case "image/webp" where webp: return .photo
            default: break
            }
            if ct.hasPrefix("video/") || ct.hasPrefix("image/") { return .unsupported }       // webm, mkv, heic, webp, ...
        }
        switch ext {
        case "mp4", "mov", "m4v": return .video
        case "gif": return .gif
        case "jpg", "jpeg", "png": return .photo
        case "webp" where webp: return .photo
        case "webm", "mkv", "heic", "heif", "webp", "avi": return .unsupported
        default: break
        }
        switch type {
        case .video?: return .video
        case .gif?: return .gif
        case .photo?: return .photo
        case nil: return .unsupported
        }
    }
}

/// What a dragged bin tile carries: the file, as text, so a drop on the timeline needs nothing from the bin. A plain string
/// is the one payload every platform's drag and drop takes without a declared type.
struct EditorDragPayload: Codable {
    static let prefix = "capystore-edit:"

    var id: String
    var name: String
    var kind: String
    var width: Int?
    var height: Int?
    var duration: Double?
    var bytes: Int64?
    var poster: String?

    init(_ source: EditSource) {
        id = source.id
        name = source.name
        kind = source.kind.rawValue
        width = source.width
        height = source.height
        duration = source.duration
        bytes = source.bytes
        poster = source.posterURL?.absoluteString
    }

    var text: String {
        guard let data = try? JSONEncoder().encode(self), let json = String(data: data, encoding: .utf8) else { return Self.prefix }
        return Self.prefix + json
    }

    var source: EditSource {
        EditSource(
            id: id, name: name, kind: EditSourceKind(rawValue: kind) ?? .unsupported, width: width, height: height,
            duration: duration, bytes: bytes, posterURL: poster.flatMap(URL.init(string:)))
    }

    /// The file a dropped string names; nil for any other text.
    static func source(from text: String) -> EditSource? {
        guard text.hasPrefix(prefix), let data = String(text.dropFirst(prefix.count)).data(using: .utf8),
              let payload = try? JSONDecoder().decode(EditorDragPayload.self, from: data) else { return nil }
        return payload.source
    }
}
