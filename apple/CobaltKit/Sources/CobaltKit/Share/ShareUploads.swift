import Foundation
import UniformTypeIdentifiers

// Photos and videos shared with no link (CONTRACT-SHARE-QUICK.md section 9.10). Like a link, a file share shows nothing
// that waits: every photo and video is copied into the app group (`Saves/uploads/<uuid>/<name>`) and handed to a
// background URLSession as `PUT /studio/upload?queue=1` (APP-API-CONTRACT section 3), then the extension completes. The
// system's transfer daemon sends the bytes after the share sheet is gone; when it finishes iOS wakes the app for the
// session (`OriginalFetcher.handleSaveWake`), which deletes the copy and says so only when an upload was refused.
//
// The server stores each file as a library post (`source 'upload'`) the moment its bytes arrive; a video or gif is read
// by a studio session that joins the line (`queue=1`) when the server is busy.

/// One photo or video the extension copied, ready to send.
struct ShareUploadFile: Sendable, Equatable {
    /// The copy, inside `Saves/uploads/<folder>/`.
    var url: URL
    /// The name the library shows (`IMG_0412.heic`).
    var name: String
    /// One of `MIME.uploadTypes`.
    var contentType: String
    var bytes: Int64

    /// The upload task's label: `upload:<folder>/<name>`, so the app can find (and delete) the copy from the answer alone.
    var label: String { ShareUploads.labelPrefix + url.pathComponents.suffix(2).joined(separator: "/") }
    var isVideo: Bool { contentType.hasPrefix("video/") }
}

enum ShareUploads {
    /// At most this many files from one share (the rest are left out and counted as skipped).
    static let maxFiles = 20
    /// `PUT /studio/upload` refuses more (413, APP-API-CONTRACT section 3).
    static let maxBytes: Int64 = 100_000_000
    /// The label every upload task carries; a save's label is its link.
    static let labelPrefix = "upload:"
    /// `Saves/uploads`: the copies, one folder per file.
    static func directory(saves: URL) -> URL { saves.appendingPathComponent("uploads", isDirectory: true) }

    /// What a share's files came to.
    struct Loaded: Sendable, Equatable {
        var files: [ShareUploadFile] = []
        /// Not a type the server takes (a tiff, an avif, a pdf…), or unreadable.
        var unsupported = 0
        /// Over `maxBytes`.
        var tooLarge = 0
        /// Past `maxFiles`.
        var overLimit = 0
    }

    /// Whether the share holds a photo or a video at all (nothing is loaded).
    static func hasMedia(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { p in
            p.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
                || p.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }
    }

    /// The best representation of `provider` the server takes: the first of its registered types (they come in the
    /// sender's order of fidelity, a Photos picture offers `public.heic` before `public.jpeg`) that is a picture or a
    /// video with an upload type. nil: nothing it offers can be uploaded.
    static func uploadType(_ identifiers: [String]) -> UTType? {
        for id in identifiers {
            guard let type = UTType(id), type.conforms(to: .image) || type.conforms(to: .movie) else { continue }
            guard let ext = type.preferredFilenameExtension else { continue }
            if MIME.uploadTypes.contains(MIME.type(forFileName: "file.\(ext)")) { return type }
        }
        return nil
    }

    /// The library's name for a copy: the sender's own name for the file when it gave one, with an extension the server
    /// can type it by (`type`'s, when the copy has none).
    static func name(for copy: URL, suggested: String?, type: UTType) -> String {
        var name = ShareInbox.fileName(for: copy, suggested: suggested)
        if (name as NSString).pathExtension.isEmpty, let ext = type.preferredFilenameExtension { name += ".\(ext)" }
        return name
    }

    /// Copies every photo and video of the share into `directory` (one new folder each), in the order shared.
    @MainActor
    static func load(_ items: [NSExtensionItem], into directory: URL) async -> Loaded {
        let providers = items.flatMap { $0.attachments ?? [] }.filter { hasMedia([$0]) }
        var loaded = Loaded()
        for provider in providers {
            guard loaded.files.count < maxFiles else { loaded.overLimit += 1; continue }
            guard let type = uploadType(provider.registeredTypeIdentifiers) else { loaded.unsupported += 1; continue }
            let folder = directory.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
            guard let file = await copy(provider, type: type, into: folder) else {
                loaded.unsupported += 1
                try? FileManager.default.removeItem(at: folder)
                continue
            }
            if file.bytes > maxBytes || file.bytes <= 0 {
                if file.bytes > maxBytes { loaded.tooLarge += 1 } else { loaded.unsupported += 1 }
                try? FileManager.default.removeItem(at: folder)
                continue
            }
            loaded.files.append(file)
        }
        return loaded
    }

    /// Copies with `FileManager` inside the handler (the system deletes its temp file right after); never through
    /// `Data`, the extension has ~120 MB.
    private static func copy(_ provider: NSItemProvider, type: UTType, into folder: URL) async -> ShareUploadFile? {
        let suggested = provider.suggestedName
        return await withCheckedContinuation { (continuation: CheckedContinuation<ShareUploadFile?, Never>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { source, _ in
                guard let source else { continuation.resume(returning: nil); return }
                let name = Self.name(for: source, suggested: suggested, type: type)
                let destination = folder.appendingPathComponent(name)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: source, to: destination)
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let contentType = MIME.type(forFileName: name)
                guard MIME.uploadTypes.contains(contentType) else { continuation.resume(returning: nil); return }
                let size = ((try? FileManager.default.attributesOfItem(atPath: destination.path)[.size]) as? NSNumber)?.int64Value ?? 0
                continuation.resume(returning: ShareUploadFile(url: destination, name: name, contentType: contentType, bytes: size))
            }
        }
    }

    /// The folder of the copy an upload's label names (`upload:<folder>/<name>`), inside `saves`; nil for anything else.
    static func folder(forLabel label: String, saves: URL) -> URL? {
        guard label.hasPrefix(labelPrefix) else { return nil }
        let parts = label.dropFirst(labelPrefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let folder = parts.first, UUID(uuidString: String(folder)) != nil,
              let name = parts.last, !name.isEmpty, name != "..", name != "."
        else { return nil }
        return directory(saves: saves).appendingPathComponent(String(folder), isDirectory: true)
    }

    /// The notification's line: `IMG_0412.heic`, or `3 photos and 2 videos`.
    static func summary(_ files: [ShareUploadFile]) -> String {
        if files.count == 1, let only = files.first { return only.name }
        let videos = files.filter(\.isVideo).count
        let photos = files.count - videos
        func count(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        switch (photos, videos) {
        case (_, 0): return count(photos, "photo")
        case (0, _): return count(videos, "video")
        default: return "\(count(photos, "photo")) and \(count(videos, "video"))"
        }
    }
}

extension InstantShareEngine {
    /// Hands every file to one background session as `PUT /studio/upload?queue=1` and returns once the system holds the
    /// tasks. Only the background transport can do this (a foreground wait would hold the sheet for the whole upload).
    func enqueue(files: [ShareUploadFile], client: HTTPCobaltClient, job: UUID) async -> InstantShare.Result {
        guard transport.background else { return .needsSheet }
        var requests: [(URLRequest, ShareUploadFile)] = []
        for file in files {
            do {
                requests.append((try client.shareUploadRequest(name: file.name, contentType: file.contentType, public: makePublic), file))
            } catch CobaltError.noAPIKey {
                return .failed(.noKey)
            } catch {
                return .failed(.couldNotStart)
            }
        }
        let session = transport.session(identifier: BackgroundSessionID.save(job: job), events: SaveSink())
        for (request, file) in requests { _ = session.upload(request, from: file.url, label: file.label) }
        await Self.race(registerWait) { await session.registered() }
        return .saved
    }
}
