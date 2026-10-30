import CobaltKit
import Foundation
import Observation
import Synchronization

enum KeyboardWords {
    static let idle = "tap copies · hold for the link"
    static let choose = "tap to choose · hold a choice for its link"
    static let chooseFile = "tap a choice to copy the file · hold for the link"
    static let chooseLink = "tap a choice to insert the link · hold to copy the file"
    static let copied = "copied. paste it in."
    static let noKey = "capystore can't find your key from here"
    static let noAccess = "allow full access to copy from your library."
    static let noPublicLinks = "no public links: the post is private."
    static let downloading = "downloading…"
    static var savedHere: String { "saved on this \(Copy.device)" }
    static func tooBig(_ bytes: Int64) -> String { "too big to copy (\(Format.bytes(bytes)))" }
    static let emoteEmpty = "no emotes yet. search to add one."
    static let emoteMiss = "nothing on 7tv for that"
    static let emoteDown = "7tv didn't answer."
    static func downloading(_ done: Int64, _ total: Int64) -> String { "downloading · \(Copy.bytesOf(done, total))" }
}

/// One file a tap can copy: the video, a webp, or the only photo.
struct KeyboardChoice: Identifiable, Equatable {
    let id: String
    let label: String
    let rendition: Rendition
}

struct KeyboardTransfer: Equatable {
    var title: String
    var detail: String
}

/// Which rendition a library tile shows, downloads, and links.
enum KeyboardFace {
    static let byteCap: Int64 = 200_000_000

    static func of(_ post: LibraryPost) -> Rendition? {
        MediaItem.merge(local: nil, post: post)?.face
    }

    static func item(of post: LibraryPost) -> MediaItem? {
        MediaItem.merge(local: nil, post: post)
    }

    /// `publicURL` when it is http or https. Never `post.link`.
    static func publicLink(of rendition: Rendition) -> URL? {
        httpURL(rendition.publicURL)
    }

    /// Poster first, then the post's poster, then the public URL of a still. Never a video file.
    static func thumbnailURL(post: LibraryPost, face: Rendition) -> URL? {
        if let poster = face.posterURL { return poster }
        if let poster = post.posterURL { return poster }
        guard isPicture(face) else { return nil }
        return httpURL(face.publicURL)
    }

    static func isPicture(_ face: Rendition) -> Bool {
        if isWebpRendition(face) { return true }
        return contentType(of: face)?.hasPrefix("image/") == true
    }

    static func label(post: LibraryPost, face: Rendition?) -> String {
        if let custom = nonempty(post.customTitle) { return custom }
        if let title = nonempty(post.title) { return title }
        if let face, !isPicture(face) { return "video" }
        return "photo"
    }

    static func fileTitle(label: String, rendition: Rendition) -> String {
        "\(label) · \(displayName(of: rendition))"
    }

    static func displayName(of rendition: Rendition) -> String {
        if let name = nonempty(rendition.file?.name ?? rendition.hosted?.name) { return name }
        if let remote = remoteFile(for: rendition), let ext = fileExtension(face: rendition, remote: remote) {
            return "file.\(ext)"
        }
        return "file"
    }

    /// Public https URL (never sent the key), else the private file, else the hosted file.
    static func remoteFile(for face: Rendition) -> RemoteFile? {
        if let url = httpURL(face.publicURL) { return .open(url) }
        if let file = face.file { return .libraryItem(id: file.id) }
        if let hosted = face.hosted { return .libraryItem(id: hosted.id) }
        return nil
    }

    /// Public URL's path extension, else the library file name, else a known content type. Nil means do not copy.
    static func fileExtension(face: Rendition, remote: RemoteFile) -> String? {
        if case .open(let url) = remote, let ext = mediaExtension(url.pathExtension) { return ext }
        if let name = face.file?.name ?? face.hosted?.name, let ext = mediaExtension((name as NSString).pathExtension) {
            return ext
        }
        switch contentType(of: face) {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/png": return "png"
        case "image/webp": return "webp"
        case "image/gif": return "gif"
        case "image/heic", "image/heif": return "heic"
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        default: return nil
        }
    }

    static func storageID(face: Rendition, remote: RemoteFile) -> String {
        let raw: String
        switch remote {
        case .libraryItem(let id): raw = id
        case .open, .studioSource: raw = face.file?.id ?? face.hosted?.id ?? face.id
        }
        return safeID(raw)
    }

    static func safeID(_ raw: String) -> String {
        let safe = String(raw.map { ch in
            (ch.isASCII && (ch.isLetter || ch.isNumber)) || ch == "-" || ch == "_" ? ch : "-"
        })
        return safe.isEmpty ? "cobalt" : safe
    }

    static func canCopy(_ face: Rendition) -> Bool {
        guard let remote = remoteFile(for: face) else { return false }
        return fileExtension(face: face, remote: remote) != nil
    }

    private static func isWebpRendition(_ face: Rendition) -> Bool {
        if face.isWebp || face.isAnimatedMade { return true }
        return contentType(of: face) == "image/webp"
    }

    private static func contentType(of face: Rendition) -> String? {
        guard let raw = face.file?.contentType ?? face.hosted?.contentType else { return nil }
        let base = raw.split(separator: ";", maxSplits: 1).first.map(String.init) ?? raw
        let type = base.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return type.isEmpty ? nil : type
    }

    private static func httpURL(_ url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    private static func mediaExtension(_ raw: String) -> String? {
        let ext = raw.lowercased()
        guard !ext.isEmpty, ext.count <= 8, ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return ext
    }

    private static func nonempty(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Library pages for the gallery. One load at a time. The client is built here, not in CobaltKit.
@MainActor @Observable
final class KeyboardGalleryModel {
    enum Phase: Equatable { case loading, ready, empty, noKey, failed }

    enum Notice: Equatable {
        case copied
        case failed(String)
    }

    private(set) var posts: [LibraryPost] = []
    private(set) var phase: Phase = .loading
    private(set) var fullAccess = false
    var kind: LibraryKindFilter = .all
    /// The tile whose video / webp choices are open.
    var chooserPostID: String?
    /// On that row, a tap inserts the hosted link. Otherwise it copies the file.
    var sendsHostedLink = false
    /// The magnifying glass is open: letters go into `emoteQuery`, not into the host.
    var searching = false
    var emoteQuery = ""
    var emoteHits: [EmoteHit] = []
    var emoteNote: String?
    var savingEmoteID: String?
    private var rememberedKind: LibraryKindFilter = .all
    private var searchToken = 0
    /// Set while a file is being copied. Only that tile shows a working state.
    var busyID: String?
    var notice: Notice?
    var transfer: KeyboardTransfer?

    @ObservationIgnored var onCopy: @MainActor (LibraryPost, KeyboardChoice?) -> Void = { _, _ in }
    @ObservationIgnored var onHold: @MainActor (LibraryPost, KeyboardChoice?) -> Void = { _, _ in }
    @ObservationIgnored var onCopyEmote: @MainActor (EmoteHit) -> Void = { _ in }
    @ObservationIgnored var onHoldEmote: @MainActor (EmoteHit) -> Void = { _ in }

    @ObservationIgnored private var client: HTTPCobaltClient?
    /// What the server said on the last library load; nil before one.
    @ObservationIgnored private var capabilities: Capabilities?

    /// The link to insert for a public file: its rich link page when the server has them (APP-API-CONTRACT 22).
    func shareLink(for url: URL) -> URL {
        capabilities?.shareLink(for: url) ?? Settings.shared().shareLink(for: url)
    }
    @ObservationIgnored private var nextCursor: String?
    @ObservationIgnored private var loading = false

    private static let pageLimit = 30

    var visiblePosts: [LibraryPost] {
        posts.filter { post in
            guard let item = KeyboardFace.item(of: post) else { return false }
            let emote = post.isEmote
            switch kind {
            case .all: return !emote
            case .videos: return !emote && item.kind == .video
            case .photos: return !emote && item.kind == .photo
            case .galleries: return !emote && item.kind == .gallery
            case .webps: return !emote && (item.kind == .webp || item.hasMadeWebp)
            case .emotes: return emote
            }
        }
    }

    func choices(for post: LibraryPost) -> [KeyboardChoice] {
        guard let item = KeyboardFace.item(of: post) else { return [] }
        var out: [KeyboardChoice] = []
        if let original = item.renditions.first(where: { if case .video = $0.kind { return true }; return false }),
           KeyboardFace.canCopy(original) {
            let label = KeyboardFace.isPicture(original) ? "photo" : "video"
            out.append(KeyboardChoice(id: original.id, label: label, rendition: original))
        }
        let webps = item.renditions.filter { ($0.isWebp || $0.isAnimatedMade) && KeyboardFace.canCopy($0) }
        for (index, rendition) in webps.enumerated() {
            let number = rendition.webpNumber ?? (index + 1)
            let label = webps.count == 1 ? "webp" : "webp \(number)"
            out.append(KeyboardChoice(id: rendition.id, label: label, rendition: rendition))
        }
        if out.isEmpty, let face = KeyboardFace.of(post), KeyboardFace.canCopy(face) {
            let label = KeyboardFace.isPicture(face) ? "photo" : "video"
            out.append(KeyboardChoice(id: face.id, label: label, rendition: face))
        }
        return out
    }

    /// What a tap on this tile means under the current filter.
    func relevant(_ post: LibraryPost) -> [KeyboardChoice] {
        let all = choices(for: post)
        let picked: [KeyboardChoice]
        switch kind {
        case .videos:
            picked = all.filter { $0.label == "video" }
        case .webps:
            picked = all.filter { $0.label.hasPrefix("webp") }
        case .emotes:
            picked = all.filter { $0.label.hasPrefix("webp") || $0.label == "photo" }
        case .photos, .galleries:
            if let face = KeyboardFace.of(post), let match = all.first(where: { $0.id == face.id }) {
                picked = [match]
            } else {
                picked = Array(all.prefix(1))
            }
        case .all:
            picked = all
        }
        return picked.isEmpty ? all : picked
    }

    func beginSearch() {
        guard !searching else { return }
        rememberedKind = kind
        searching = true
        emoteQuery = ""
        emoteHits = []
        emoteNote = nil
        chooserPostID = nil
    }

    func stopSearch() {
        guard searching else { return }
        searching = false
        emoteQuery = ""
        emoteHits = []
        emoteNote = nil
        kind = rememberedKind
    }

    func type(_ text: String) {
        guard emoteQuery.count < 64 else { return }
        emoteQuery += text
    }

    func backspace() {
        guard !emoteQuery.isEmpty else { return }
        emoteQuery.removeLast()
    }

    func loadEmotes() async {
        let q = emoteQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        searchToken += 1
        let mine = searchToken
        emoteNote = nil
        guard searching, !q.isEmpty else {
            emoteHits = []
            return
        }
        guard let client else {
            emoteNote = KeyboardWords.noKey
            return
        }
        do {
            let found = try await client.searchEmotes(query: q)
            guard mine == searchToken, emoteQuery.trimmingCharacters(in: .whitespacesAndNewlines) == q else { return }
            emoteHits = found
            emoteNote = found.isEmpty ? KeyboardWords.emoteMiss : nil
        } catch {
            // A keystroke during the search cancels it: that is a newer search coming, not 7tv being down.
            guard mine == searchToken, !Task.isCancelled,
                  emoteQuery.trimmingCharacters(in: .whitespacesAndNewlines) == q else { return }
            emoteHits = []
            emoteNote = KeyboardWords.emoteDown
        }
    }

    func saveEmote(_ hit: EmoteHit) async {
        guard let client, savingEmoteID == nil else { return }
        savingEmoteID = hit.id
        defer { savingEmoteID = nil }
        do {
            let saved = try await client.saveEmote(id: hit.id)
            guard let index = emoteHits.firstIndex(where: { $0.id == hit.id }) else { return }
            var next = hit
            next.libraryID = saved.id
            next.libraryURL = saved.url
            emoteHits[index] = next
            begin(reset: true)                     // the saved emote shows under the emotes chip without a pull
        } catch {
            notice = .failed(KeyboardWords.emoteDown)
        }
    }

    /// A save made outside the search row (typing mode, a hold) shows its tick there too.
    func markSaved(_ hit: EmoteHit) {
        guard let index = emoteHits.firstIndex(where: { $0.id == hit.id }) else { return }
        emoteHits[index] = hit
    }

    /// The keyed client, built on first use, so the emote bar works before the library has loaded.
    func keyedClient() -> Result<HTTPCobaltClient, KeyboardClientMissing> {
        guard fullAccess else { return .failure(.noAccess) }
        let settings = Settings.shared()
        guard settings.apiKey() != nil else { return .failure(.noKey) }
        let server = settings.serverURL
        if client == nil || client?.baseURL != server {
            let keychain = Keychain.shared
            client = HTTPCobaltClient(
                baseURL: server,
                apiKey: { Settings.apiKey(in: keychain, forServer: server) })
        }
        guard let client else { return .failure(.noKey) }
        return .success(client)
    }

    func setKind(_ next: LibraryKindFilter) {
        guard kind != next else { return }
        kind = next
        chooserPostID = nil
        fillFilter()
    }

    func tap(_ post: LibraryPost) {
        let choices = relevant(post)
        if choices.count <= 1 {
            chooserPostID = nil
            onCopy(post, choices.first)
            return
        }
        chooserPostID = chooserPostID == post.id ? nil : post.id
    }

    func hold(_ post: LibraryPost) {
        guard busyID == nil else { return }
        let choices = relevant(post)
        if choices.count <= 1 {
            onHold(post, choices.first)
            return
        }
        chooserPostID = post.id
    }

    var asksToChoose: Bool {
        if chooserPostID != nil { return true }
        guard kind == .all else { return false }
        return visiblePosts.contains { choices(for: $0).count > 1 }
    }

    func setFullAccess(_ allowed: Bool) {
        fullAccess = allowed
    }

    func reloadIfEmpty() {
        guard fullAccess, posts.isEmpty else { return }
        begin(reset: true)
    }

    func refresh() async {
        guard fullAccess, !loading else { return }
        loading = true
        await run(reset: true)
    }

    func loadMoreIfNeeded(showing id: String) {
        guard posts.last?.id == id else { return }
        begin(reset: false)
    }

    /// A file already on this phone: the shelf the app published, else the shared cache. Nil downloads.
    func prepareLocal(_ rendition: Rendition) -> URL? {
        guard let root = Self.videosRoot() else { return nil }
        let ids = Set([rendition.file?.id, rendition.hosted?.id].compactMap { $0 })
        let link = rendition.publicURL?.absoluteString
        if let match = Self.shelfMatch(root: root, ids: ids, link: link) { return match }
        return Self.indexMatch(root: root, ids: ids, link: link, remote: rendition.publicURL)
    }

    /// Nil when the rendition has nothing to copy. Throws when the download fails.
    /// The file is under `tmp/cobalt-keyboard/` and the caller removes it.
    func prepareDownload(_ rendition: Rendition, title: String) async throws -> URL? {
        guard let remote = KeyboardFace.remoteFile(for: rendition) else { return nil }
        guard let ext = KeyboardFace.fileExtension(face: rendition, remote: remote) else { return nil }
        guard let client else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cobalt-keyboard", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appendingPathComponent("\(KeyboardFace.storageID(face: rendition, remote: remote)).\(ext)")
        transfer = KeyboardTransfer(title: title, detail: KeyboardWords.downloading)
        let relay = LineRelay { [weak self] detail in
            guard let self else { return }
            self.transfer = KeyboardTransfer(title: title, detail: detail)
        }
        do {
            return try await client.download(remote, to: dest) { progress in
                relay.push(downloadDetail(progress))
            }
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
    }

    private static func videosRoot() -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.capybaraharmony.cobalt") else { return nil }
        return container.appendingPathComponent("Videos", isDirectory: true)
    }

    private static func shelfMatch(root: URL, ids: Set<String>, link: String?) -> URL? {
        let manifest = root.appendingPathComponent("for-keyboard/manifest.json")
        guard let data = try? Data(contentsOf: manifest),
              let entries = try? JSONDecoder().decode([ShelfEntry].self, from: data) else { return nil }
        let hit = entries.first { entry in
            if let id = entry.libraryID, ids.contains(id) { return true }
            if let link, entry.publicURL == link { return true }
            return false
        }
        guard let hit else { return nil }
        let url = root.appendingPathComponent("for-keyboard/\(hit.file)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func indexMatch(root: URL, ids: Set<String>, link: String?, remote: URL?) -> URL? {
        let index = root.appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: index) else { return nil }
        let rows = (try? JSONDecoder().decode([IndexEntry].self, from: data)) ?? []
        let hit = rows.first { entry in
            guard let name = entry.fileName, !name.isEmpty else { return false }
            if let id = entry.libraryID, ids.contains(id) { return true }
            if let link, entry.publicURL?.absoluteString == link { return true }
            if let remote, entry.remoteURL == remote { return true }
            return false
        }
        guard let name = hit?.fileName else { return nil }
        let url = root.appendingPathComponent("files/\(name)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func begin(reset: Bool) {
        guard fullAccess else { return }
        guard !loading else { return }
        if !reset && nextCursor == nil { return }
        loading = true
        Task { await self.run(reset: reset) }
    }

    /// Keep paging while a filter has almost nothing on screen yet.
    private func fillFilter() {
        guard kind != .all, visiblePosts.count < 12, nextCursor != nil else { return }
        begin(reset: false)
    }

    private func run(reset: Bool) async {
        defer {
            loading = false
            fillFilter()
        }
        guard fullAccess else { return }
        if reset && posts.isEmpty { phase = .loading }
        let settings = Settings.shared()
        guard settings.apiKey() != nil else {
            client = nil
            posts = []
            nextCursor = nil
            phase = .noKey
            return
        }
        let server = settings.serverURL
        if client == nil || client?.baseURL != server {
            let keychain = Keychain.shared
            client = HTTPCobaltClient(
                baseURL: server,
                apiKey: { Settings.apiKey(in: keychain, forServer: server) })
        }
        guard let client else {
            phase = .noKey
            return
        }
        let cursor = reset ? nil : nextCursor
        do {
            let caps = await client.capabilities()
            if caps.kind != .unreachable { capabilities = caps }
            let page: LibraryPage
            if caps.gallery {
                page = try await client.library(cursor: cursor, limit: Self.pageLimit, v3: true)
            } else {
                page = try await client.library(cursor: cursor, limit: Self.pageLimit, v2: caps.visibility)
            }
            absorb(page, reset: reset, requested: cursor)
        } catch {
            if posts.isEmpty { phase = .failed }
            else { notice = .failed(Copy.actionFailed) }
        }
    }

    private func absorb(_ page: LibraryPage, reset: Bool, requested: String?) {
        var seen = Set(reset ? [] : posts.map(\.id))
        var next = reset ? [] : posts
        var added = 0
        for post in page.posts where seen.insert(post.id).inserted {
            // a hidden post never shows in the keyboard (APP-API-CONTRACT 37.7); the server leaves them out, this is the guard
            if post.hidden { continue }
            next.append(post)
            added += 1
        }
        posts = next
        if page.posts.isEmpty || (!reset && (page.next == requested || added == 0)) {
            nextCursor = nil
        } else {
            nextCursor = page.next
        }
        phase = posts.isEmpty ? .empty : .ready
    }
}

private struct ShelfEntry: Decodable {
    var libraryID: String?
    var publicURL: String?
    var file: String
    var bytes: Int64
}

private struct IndexEntry: Decodable {
    var libraryID: String?
    var publicURL: URL?
    var remoteURL: URL?
    var fileName: String?
}

private func downloadDetail(_ progress: TransferProgress) -> String {
    if let total = progress.total, total > 0 {
        return KeyboardWords.downloading(progress.bytes, total)
    }
    return KeyboardWords.downloading
}

/// Hands a download's latest line to the main actor. One hop at a time.
private final class LineRelay: Sendable {
    private struct State { var latest: String?; var scheduled = false }
    private let state = Mutex(State())
    private let apply: @MainActor @Sendable (String) -> Void

    init(_ apply: @escaping @MainActor @Sendable (String) -> Void) { self.apply = apply }

    func push(_ value: String) {
        let start = state.withLock { s -> Bool in
            s.latest = value
            if s.scheduled { return false }
            s.scheduled = true
            return true
        }
        guard start else { return }
        Task { @MainActor in
            while true {
                let next = self.state.withLock { s -> String? in
                    let value = s.latest
                    s.latest = nil
                    if value == nil { s.scheduled = false }
                    return value
                }
                guard let next else { return }
                self.apply(next)
            }
        }
    }
}
