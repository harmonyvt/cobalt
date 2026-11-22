import Foundation
import ImageIO
import UniformTypeIdentifiers

// Instant upload from the share sheet (CONTRACT-SHARE-QUICK.md section 10). Photos and videos shared without a
// link (Photos, Files, a screenshot) go straight into the library: each one is copied into the app group's `Saves`
// and handed to the same background URLSession as the instant link save, as `PUT /studio/upload?name=&public=&queue=1`.
// The extension completes at once; the transfer daemon finishes the uploads and wakes the app, which reads the
// answers (`OriginalFetcher.applySaveAnswers`), deletes the copies and tells the owner.

/// One photo or video the host shared, copied where the background upload reads it from.
struct SharedUpload: Sendable, Equatable {
    var file: URL
    /// What the library shows (`IMG_0412.heic`).
    var name: String
    var contentType: String
    var bytes: Int64
}

/// The upload's task label: `upload:<stored file>/<name>`. The app deletes the stored copy by it and names the file in
/// what it tells the owner. A link save's label is the link itself, which never starts with `upload:`.
enum UploadLabel {
    static let prefix = "upload:"
    /// Every stored copy's name starts with this (`pruneSaveFiles` and the label check rely on it).
    static let storedPrefix = "upload-"

    static func make(stored: String, name: String) -> String { prefix + stored + "/" + name }

    static func parse(_ label: String) -> (stored: String, name: String)? {
        guard label.hasPrefix(prefix) else { return nil }
        let rest = label.dropFirst(prefix.count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let stored = String(rest[..<slash])
        let name = String(rest[rest.index(after: slash)...])
        // only a copy this code made: no path, no "..", our prefix
        guard stored.hasPrefix(storedPrefix), !stored.contains("/"), !stored.contains("..") else { return nil }
        return (stored, name.isEmpty ? stored : name)
    }
}

extension ShareInbox {
    /// The attachments that are a photo or a video.
    nonisolated static func mediaProviders(_ items: [NSExtensionItem]) -> [NSItemProvider] {
        items.flatMap { $0.attachments ?? [] }.filter { provider in
            provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
                || provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
        }
    }

    /// The type to ask `provider` for: the first registered type the server takes as it is (HEIC, JPEG, PNG, GIF, WebP,
    /// MP4, MOV), else plain image (made a JPEG after the copy) or plain movie (the server decides).
    nonisolated static func uploadTypeIdentifier(for provider: NSItemProvider) -> String? {
        let registered = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        if let direct = registered.first(where: { type in
            guard let ext = type.preferredFilenameExtension else { return false }
            return MIME.uploadTypes.contains(MIME.type(forFileName: "f.\(ext)"))
        }) {
            return direct.identifier
        }
        if registered.contains(where: { $0.conforms(to: .image) }) { return UTType.image.identifier }
        if registered.contains(where: { $0.conforms(to: .movie) }) { return UTType.movie.identifier }
        return nil
    }

    /// Copies each shared photo and video into `dir`, one at a time (the extension has ~120 MB; nothing goes through
    /// `Data`). A picture the server does not take (TIFF, RAW...) is made a JPEG. What could not be read, or is not a
    /// type the server takes, is counted in `unsupported`.
    nonisolated static func copyMedia(
        _ providers: [NSItemProvider], into dir: URL, job: UUID
    ) async -> (files: [SharedUpload], unsupported: Int) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var files: [SharedUpload] = []
        var unsupported = 0
        for (index, provider) in providers.enumerated() {
            guard let type = uploadTypeIdentifier(for: provider),
                  let copied = await copyFile(provider, type: type, into: dir, stem: "\(UploadLabel.storedPrefix)\(job.uuidString.lowercased())-\(index)")
            else { unsupported += 1; continue }
            if let file = finish(copied.url, suggested: provider.suggestedName, systemName: copied.systemName) {
                files.append(file)
            } else {
                try? FileManager.default.removeItem(at: copied.url)
                unsupported += 1
            }
        }
        return (files, unsupported)
    }

    /// Copies with `FileManager` inside the handler (the system deletes its temp file right after).
    private nonisolated static func copyFile(
        _ provider: NSItemProvider, type: String, into dir: URL, stem: String
    ) async -> (url: URL, systemName: String)? {
        await withCheckedContinuation { (continuation: CheckedContinuation<(url: URL, systemName: String)?, Never>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { source, _ in
                guard let source else { continuation.resume(returning: nil); return }
                let ext = source.pathExtension.lowercased()
                let destination = dir.appendingPathComponent(ext.isEmpty ? stem : "\(stem).\(ext)")
                do {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.copyItem(at: source, to: destination)
                    continuation.resume(returning: (destination, source.lastPathComponent))
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Names the copy and decides its upload type (by name, then first bytes); a picture of another type becomes a
    /// JPEG. Nil when it is none of the upload types.
    nonisolated static func finish(_ copy: URL, suggested: String?, systemName: String) -> SharedUpload? {
        var url = copy
        var name = fileName(for: copy, suggested: suggested ?? (systemName as NSString).deletingPathExtension)
        var found = MIME.identify(name: name, head: { MIME.head(of: url) })
        if !MIME.uploadTypes.contains(found.contentType) {
            let type = UTType(filenameExtension: copy.pathExtension)
            guard type?.conforms(to: .image) == true, let jpeg = makeJPEG(copy) else { return nil }
            try? FileManager.default.removeItem(at: copy)
            url = jpeg
            name = ((name as NSString).deletingPathExtension) + ".jpg"
            found = (name, "image/jpeg")
        }
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        guard bytes > 0 else { return nil }
        return SharedUpload(file: url, name: found.name, contentType: found.contentType, bytes: bytes)
    }

    /// A JPEG beside `source`, at most 4096 px on its long side (a full decode of a large RAW would not fit in the
    /// extension's memory), turned upright. Nil when ImageIO cannot read it.
    nonisolated static func makeJPEG(_ source: URL) -> URL? {
        guard let image = CGImageSourceCreateWithURL(source as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
        ]
        guard let picture = CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary) else { return nil }
        let destination = source.deletingPathExtension().appendingPathExtension("jpg")
        guard let out = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(out, picture, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(out) else {
            try? FileManager.default.removeItem(at: destination)
            return nil
        }
        return destination
    }
}

/// Hands every copied file to the background session. Never waits for an upload.
struct InstantUploadEngine: Sendable {
    var transport: any SaveTransport
    /// How long to wait for the system to confirm it holds the tasks.
    var registerWait: Double = 0.6
    /// Settings "make new saves public": `?public=1`.
    var makePublic = true

    func enqueue(_ files: [SharedUpload], client: HTTPCobaltClient, job: UUID) async -> InstantShare.Result {
        guard transport.background else { return .needsSheet }
        var requests: [(URLRequest, SharedUpload)] = []
        for file in files {
            do {
                requests.append((try client.shareUploadRequest(name: file.name, contentType: file.contentType, public: makePublic), file))
            } catch CobaltError.noAPIKey {
                return .failed(.noKey)
            } catch {
                return .failed(.couldNotStart)
            }
        }
        guard !requests.isEmpty else { return .failed(.couldNotStart) }
        let session = transport.session(identifier: BackgroundSessionID.uploadSave(job: job), events: SaveSink())
        for (request, file) in requests {
            _ = session.upload(request, from: file.file, label: UploadLabel.make(stored: file.file.lastPathComponent, name: file.name))
        }
        await InstantShareEngine.race(registerWait) { await session.registered() }
        return .saved
    }
}

extension InstantShare {
    /// Whether the share is photos or videos the instant upload takes even with "show the full share sheet" on: the
    /// full sheet only knows one video, so a picture, or several files, always upload.
    public static func uploadsEvenWithFullSheet(_ items: [NSExtensionItem]) -> Bool {
        let media = ShareInbox.mediaProviders(items)
        guard !media.isEmpty else { return false }
        if media.count > 1 { return true }
        return !media[0].hasItemConformingToTypeIdentifier(UTType.movie.identifier)
    }

    /// The upload words the "uploading" notification and the tests read: `IMG_0412.heic`, or `3 files`.
    static func uploadSummary(_ files: [SharedUpload]) -> String {
        files.count == 1 ? files[0].name : "\(files.count) files"
    }

    /// Copies what was shared and queues the uploads (the extension's path for photos and videos, CONTRACT-SHARE-QUICK.md
    /// section 10). `.needsSheet` on a build with no app group (no background session: the full sheet uploads one video
    /// in-process); `.failed` when nothing could be queued.
    @MainActor
    static func upload(_ providers: sending [NSItemProvider], settings: Settings, client: HTTPCobaltClient) async -> Start {
        let started = Date()
        let transport = URLSessionSaveTransport.current
        guard transport.background else { return .needsSheet }
        let job = UUID()
        let dir = AppGroup.directory("Saves")
        let copied = await ShareInbox.copyMedia(providers, into: dir, job: job)
        let limit = settings.knownCapabilities?.limits.maxUploadBytes ?? Capabilities.Limits.fork.maxUploadBytes
        var files: [SharedUpload] = []
        var tooLarge = 0
        for file in copied.files {
            if limit > 0, file.bytes > limit {
                try? FileManager.default.removeItem(at: file.file)
                tooLarge += 1
            } else {
                files.append(file)
            }
        }
        func log(_ result: String) {
            Telemetry.log(.info, .share, "share upload", data: [
                "result": .string(result), "files": .int(files.count), "too_large": .int(tooLarge),
                "unsupported": .int(copied.unsupported), "ms": .int(Int(Date().timeIntervalSince(started) * 1000)),
            ])
        }
        guard !files.isEmpty else {
            log("nothing")
            if tooLarge > 0 { return .failed(.tooLarge(limit: limit)) }
            return .failed(.unsupportedFile)
        }
        var engine = InstantUploadEngine(transport: transport)
        engine.makePublic = settings.newSavesPublic
        var body = uploadSummary(files)
        let skipped = tooLarge + copied.unsupported
        if skipped > 0 { body += " · \(skipped) skipped" }
        async let notified: Void = Notifications.postInstantSaving(job: job, title: "uploading to capystore", body: body)
        let result = await engine.enqueue(files, client: client, job: job)
        await notified
        switch result {
        case .saved:
            log("queued")
            return .uploaded(count: files.count)
        case .needsSheet:
            Notifications.removeInstantSaving(job: job)
            for file in files { try? FileManager.default.removeItem(at: file.file) }
            log("needs-sheet")
            return .needsSheet
        case .failed(let failure):
            Notifications.removeInstantSaving(job: job)
            for file in files { try? FileManager.default.removeItem(at: file.file) }
            log("failed-\(failure)")
            return .failed(failure)
        }
    }
}
