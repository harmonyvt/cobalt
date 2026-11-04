import Foundation

/// The read-only Capystore location in Finder (Phase 1). One folder per non-hidden post, and only the
/// originals inside it: gallery items, or a single post's upload / saved / studio / emote file. Webp
/// previews, crops, slideshows, exports and hosted copies stay out unless they are all the post has.
///
/// Identifiers are server ids (`post:<post key>`, `file:<media item id>`), never the display name.
/// The extension refreshes by walking `GET /library` and diffs this snapshot. Nothing here imports
/// FileProvider, so the naming and the diff are tests.
public enum FinderLibrary {
    /// A post or a file. The raw string is the file provider item identifier.
    public enum Ref: Hashable, Sendable, Codable, Equatable {
        case post(String)
        case file(String)

        public var raw: String {
            switch self {
            case .post(let id): return "post:\(id)"
            case .file(let id): return "file:\(id)"
            }
        }

        public init?(raw: String) {
            if let id = raw.dropPrefix("post:"), !id.isEmpty { self = .post(id); return }
            if let id = raw.dropPrefix("file:"), !id.isEmpty { self = .file(id); return }
            return nil
        }
    }

    /// One row Finder can show. A folder has no bytes and no content URL. A private original has
    /// `privateFileID` (GET `/library/items/:id/file`); a public file has `contentURL` and no key.
    public struct Node: Hashable, Sendable, Codable, Equatable {
        public var ref: Ref
        public var parent: Ref?
        public var name: String
        public var isFolder: Bool
        public var mime: String?
        /// UTI (`public.mpeg-4`, `public.jpeg`, `public.folder`, …) so Quick Look knows the file.
        public var typeIdentifier: String
        public var bytes: Int64?
        public var createdAt: Date
        /// Public bytes (the CDN). Nil for a folder and for a private original.
        public var contentURL: URL?
        /// Set when the bytes are the keyed library file route, not `contentURL`.
        public var privateFileID: String?
        /// A JPEG or PNG Finder can fetch with no key (a poster, or the image itself).
        public var thumbnailURL: URL?
        public var contentVersion: Data
        public var metadataVersion: Data
        public var childCount: Int?

        public var raw: String { ref.raw }
    }

    public struct Snapshot: Equatable, Sendable, Codable {
        public var nodes: [String: Node]
        /// Post identifiers, newest first (the order `GET /library` returned).
        public var rootChildren: [String]
        public var children: [String: [String]]
        public var anchor: Data

        public init(nodes: [String: Node], rootChildren: [String], children: [String: [String]], anchor: Data) {
            self.nodes = nodes
            self.rootChildren = rootChildren
            self.children = children
            self.anchor = anchor
        }

        public func node(_ raw: String) -> Node? { nodes[raw] }

        public func children(of parent: String?) -> [String] {
            guard let parent else { return rootChildren }
            return children[parent] ?? []
        }

        public static func encoded(_ snapshot: Snapshot) throws -> Data {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(snapshot)
        }

        public static func decoded(_ data: Data) throws -> Snapshot {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            return try decoder.decode(Snapshot.self, from: data)
        }
    }

    public struct Delta: Equatable, Sendable {
        /// Created or changed item identifiers (raw).
        public var updated: [String]
        public var deleted: [String]
    }

    /// What an incremental enumeration should do with the anchor the system handed back.
    public enum Sync: Equatable, Sendable {
        /// The library matches the anchor. Report nothing.
        case current(Snapshot)
        /// The anchor is not the snapshot we last gave the system. The system should list from scratch.
        case rescan
        case apply(Delta, Snapshot)
    }

    public static let pageLimit = 50
    /// A walk stops here so a cursor that never ends cannot pin the extension.
    public static let postCap = 5_000

    /// Pages of `GET /library` (the caller asks for `v=3`) into one list. Hidden posts are dropped.
    /// A repeated cursor, an empty page, or `postCap` ends the walk.
    public static func collect(
        cap: Int = postCap,
        page: (_ cursor: String?) async throws -> LibraryPage
    ) async throws -> [LibraryPost] {
        var posts: [LibraryPost] = []
        var seen = Set<String>()
        var cursor: String?
        var used = Set<String>()
        while posts.count < cap {
            if let cursor, !used.insert(cursor).inserted { break }
            let next = try await page(cursor)
            for post in next.posts where !post.hidden && seen.insert(post.id).inserted {
                posts.append(post)
                if posts.count == cap { break }
            }
            guard let step = next.next, step != cursor else { break }
            cursor = step
        }
        return posts
    }

    /// The originals Finder shows for one post. Empty when the post has nothing that can be opened.
    public static func originals(in post: LibraryPost) -> [LibraryFile] {
        let items = post.files.filter { $0.galleryRole == .item }
        if !items.isEmpty { return items.sorted(by: fileOrder) }
        let plain = post.files.filter { !isPreview($0) }
        if !plain.isEmpty { return plain.sorted(by: fileOrder) }
        let fallback = post.files.filter { file in
            file.source != .made && file.galleryRole != .slideshow && file.galleryRole != .crop && file.galleryRole != .export
        }
        return fallback.sorted(by: fileOrder)
    }

    /// A webp preview, a made file, a hosted copy, or a crop / slideshow / export. A gallery `item`
    /// is not a preview. A webp the owner uploaded (or an emote) is the file itself.
    public static func isPreview(_ file: LibraryFile) -> Bool {
        switch file.galleryRole {
        case .slideshow, .crop, .export: return true
        case .item, nil: break
        }
        switch file.source {
        case .webp, .made, .host: return true
        case .upload, .saved, .emote: return false
        case .studio: return file.contentType?.lowercased().hasPrefix("image/webp") == true
        }
    }

    public static func make(posts: [LibraryPost]) -> Snapshot {
        var nodes: [String: Node] = [:]
        var root: [String] = []
        var children: [String: [String]] = [:]
        var folderNames = Set<String>()
        for post in posts where !post.hidden {
            let files = originals(in: post)
            guard !files.isEmpty else { continue }
            let folder = uniqueFolderName(for: post, files: files, taken: &folderNames)
            let postRef = Ref.post(post.id)
            var fileNames = Set<String>()
            var childRaws: [String] = []
            for file in files {
                let name = uniqueFileName(file, taken: &fileNames)
                let node = fileNode(file, in: post, parent: postRef, name: name)
                nodes[node.raw] = node
                childRaws.append(node.raw)
            }
            let folderNode = Node(
                ref: postRef, parent: nil, name: folder, isFolder: true, mime: nil,
                typeIdentifier: folderTypeIdentifier, bytes: nil, createdAt: post.createdAt,
                contentURL: nil, privateFileID: nil, thumbnailURL: folderThumbnail(post, files: files),
                contentVersion: token(["folder", post.id, childRaws.joined(separator: ",")]),
                metadataVersion: token(["meta", folder, String(childRaws.count)]),
                childCount: childRaws.count)
            nodes[folderNode.raw] = folderNode
            root.append(folderNode.raw)
            children[folderNode.raw] = childRaws
        }
        let anchor = token(root.flatMap { raw -> [String] in
            guard let node = nodes[raw] else { return [] }
            var parts = [raw, node.name]
            for id in children[raw] ?? [] {
                guard let file = nodes[id] else { continue }
                parts.append(contentsOf: [id, file.name, hex(file.contentVersion), hex(file.metadataVersion)])
            }
            return parts
        })
        return Snapshot(nodes: nodes, rootChildren: root, children: children, anchor: anchor)
    }

    public static func delta(from old: Snapshot, to new: Snapshot) -> Delta {
        var updated: [String] = []
        var deleted: [String] = []
        var ids: [String] = []
        for raw in new.rootChildren {
            ids.append(raw)
            ids.append(contentsOf: new.children[raw] ?? [])
        }
        for raw in ids {
            guard let node = new.nodes[raw] else { continue }
            if let was = old.nodes[raw], was.name == node.name, was.parent == node.parent,
               was.contentVersion == node.contentVersion, was.metadataVersion == node.metadataVersion,
               was.typeIdentifier == node.typeIdentifier, was.bytes == node.bytes {
                continue
            }
            updated.append(raw)
        }
        let fresh = Set(new.nodes.keys)
        for raw in old.nodes.keys where !fresh.contains(raw) {
            deleted.append(raw)
        }
        return Delta(updated: updated, deleted: deleted.sorted())
    }

    public static func sync(anchor: Data?, previous: Snapshot?, current: Snapshot) -> Sync {
        if anchor == current.anchor { return .current(current) }
        guard let previous, previous.anchor == anchor else { return .rescan }
        let diff = delta(from: previous, to: current)
        if diff.updated.isEmpty && diff.deleted.isEmpty { return .current(current) }
        return .apply(diff, current)
    }

    /// `GET /library` and the file routes throw `CobaltError`. The extension maps this, not the error text.
    public enum Failure: Error, Equatable, Sendable {
        case unauthorized
        case unreachable
        case notFound
        case other
    }

    public static func failure(from error: Error) -> Failure {
        if let error = error as? Failure { return error }
        guard let error = error as? CobaltError else {
            if error is URLError { return .unreachable }
            return .other
        }
        switch error {
        case .noAPIKey: return .unauthorized
        case .api(_, let status) where status == 401: return .unauthorized
        case .api(_, 404): return .notFound
        case .network: return .unreachable
        case .cancelled: return .other
        default: return .other
        }
    }

    /// UTI for Quick Look and the Finder icon. Unknown types fall through to the file extension, then `public.data`.
    public static func typeIdentifier(mime: String?, filename: String) -> String {
        switch normalizedMIME(mime) {
        case "video/mp4", "video/mpeg4": return "public.mpeg-4"
        case "video/quicktime": return "com.apple.quicktime-movie"
        case "image/jpeg", "image/jpg": return "public.jpeg"
        case "image/png": return "public.png"
        case "image/gif": return "com.compuserve.gif"
        case "image/webp": return "org.webmproject.webp"
        case "image/heic", "image/heif": return "public.heic"
        default: return typeIdentifier(fileExtension: (filename as NSString).pathExtension)
        }
    }

    public static let folderTypeIdentifier = "public.folder"

    // MARK: - names

    static func uniqueFolderName(for post: LibraryPost, files: [LibraryFile], taken: inout Set<String>) -> String {
        let stem = MediaTitle.text(MediaTitle.resolve(
            custom: post.customTitle, service: post.service, ref: post.ref,
            fileName: files.first?.name ?? post.title))
        let base = FolderNaming.assemble(stem: stem, ext: "")
        let name = FolderNaming.unique(base, among: taken)
        taken.insert(name.lowercased())
        return name
    }

    static func uniqueFileName(_ file: LibraryFile, taken: inout Set<String>) -> String {
        let ext = fileExtension(of: file)
        let rawStem = (file.name as NSString).deletingPathExtension
        let stemSource = rawStem.isEmpty ? file.name : rawStem
        let base = FolderNaming.assemble(stem: stemSource, ext: ext)
        let name = FolderNaming.unique(base, among: taken)
        taken.insert(name.lowercased())
        return name
    }

    static func fileExtension(of file: LibraryFile) -> String {
        let own = (file.name as NSString).pathExtension
        if !own.isEmpty, own.count <= 8, own.allSatisfy({ $0.isLetter || $0.isNumber }) { return own }
        return preferredExtension(mime: file.contentType) ?? "bin"
    }

    public static func preferredExtension(mime: String?) -> String? {
        switch normalizedMIME(mime) {
        case "video/mp4", "video/mpeg4": return "mp4"
        case "video/quicktime": return "mov"
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/heic", "image/heif": return "heic"
        default: return nil
        }
    }

    public static func isImageMIME(_ mime: String?) -> Bool {
        normalizedMIME(mime)?.hasPrefix("image/") == true
    }

    /// An https URL Finder may fetch for a thumbnail. Anything else is refused.
    public static func thumbnailURL(_ url: URL?) -> URL? {
        guard let url, url.scheme?.lowercased() == "https" else { return nil }
        return url
    }

    // MARK: -

    static func fileNode(_ file: LibraryFile, in post: LibraryPost, parent: Ref, name: String) -> Node {
        let mime = file.contentType
        let type = typeIdentifier(mime: mime, filename: name)
        let created = file.createdAt
        let tokenBase = [file.id, String(file.bytes ?? -1), String(created.timeIntervalSince1970)]
        let publicURL = thumbnailURL(file.url)
        let thumb = thumbnailURL(file.posterURL)
            ?? (isImageMIME(mime) ? publicURL : nil)
            ?? thumbnailURL(post.posterURL)
        return Node(
            ref: .file(file.id), parent: parent, name: name, isFolder: false, mime: mime,
            typeIdentifier: type, bytes: file.bytes, createdAt: created,
            contentURL: publicURL, privateFileID: publicURL == nil ? file.id : nil,
            thumbnailURL: thumb,
            contentVersion: token(tokenBase),
            metadataVersion: token(["meta", name, type, parent.raw]),
            childCount: nil)
    }

    /// A public file URL is https. `file.url` is only used as the content URL when it is.
    static func folderThumbnail(_ post: LibraryPost, files: [LibraryFile]) -> URL? {
        thumbnailURL(post.posterURL) ?? files.compactMap { thumbnailURL($0.posterURL) }.first
    }

    static func fileOrder(_ a: LibraryFile, _ b: LibraryFile) -> Bool {
        let ai = a.itemIndex ?? Int.max
        let bi = b.itemIndex ?? Int.max
        if ai != bi { return ai < bi }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id < b.id
    }

    static func normalizedMIME(_ mime: String?) -> String? {
        guard let mime else { return nil }
        let base = mime.split(separator: ";", maxSplits: 1).first.map(String.init) ?? mime
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    static func typeIdentifier(fileExtension ext: String) -> String {
        switch ext.lowercased() {
        case "mp4", "m4v", "mpeg4": return "public.mpeg-4"
        case "mov", "qt": return "com.apple.quicktime-movie"
        case "jpg", "jpeg": return "public.jpeg"
        case "png": return "public.png"
        case "gif": return "com.compuserve.gif"
        case "webp": return "org.webmproject.webp"
        case "heic", "heif": return "public.heic"
        default: return "public.data"
        }
    }

    /// 8 bytes, stable for the same parts. A version and a sync anchor, not a security hash.
    static func token(_ parts: [String]) -> Data {
        var hash: UInt64 = 0xcbf29ce484222325
        for part in parts {
            for byte in part.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
            hash = (hash ^ 0xff) &* 0x100000001b3
        }
        let big = hash.bigEndian
        return withUnsafeBytes(of: big) { Data($0) }
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
