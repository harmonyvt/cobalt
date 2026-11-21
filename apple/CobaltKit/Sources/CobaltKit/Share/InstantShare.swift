import Foundation
import UniformTypeIdentifiers

// Instant share, the extension's side (CONTRACT-SHARE-QUICK.md section 9; the engine and its transports are
// in `Background/InstantSave.swift`). The share extension calls `InstantShare.run` as early as it can: it
// reads the link, queues the save, tells the owner with a quiet local notification and returns. Nothing in
// here shows a view or waits for the save.

/// What was shared, as far as the instant path cares.
enum InstantIntake: Sendable, Equatable {
    case link(URL)
    /// Photos or videos and no link: each one is uploaded on a background session (`ShareUploads`).
    case file
    case none
}

extension ShareInbox {
    /// The first link in what the host shared: a URL attachment, a URL in text, the item's own text. A link
    /// wins over a photo or a video (saving the link server-side is the point). Nothing is copied or loaded
    /// beyond the link itself.
    static func loadLinkOnly(_ items: [NSExtensionItem]) async -> InstantIntake {
        let providers = items.flatMap { $0.attachments ?? [] }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let link = await loadURL(provider), LinkInfo(link) != nil { return .link(link) }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let string = await loadString(provider), let link = LinkInfo.firstLink(in: string) { return .link(link) }
        }
        for item in items {
            for string in [item.attributedContentText?.string, item.attributedTitle?.string] {
                if let string, let link = LinkInfo.firstLink(in: string) { return .link(link) }
            }
        }
        if ShareUploads.hasMedia(providers) { return .file }
        return .none
    }
}

extension InstantShare {
    /// Whether a link could be a post of several items, decided by its shape alone (no network): the share sheet asks the
    /// server what a link is only when this is true. A reel, a video, a plain media file can never be a gallery, so they
    /// go straight to today's instant save: no resolve, no "checking" sheet, no 8 s wait, and the server resolves once.
    ///
    /// Only these are looked into: Instagram `/p/` (and any Instagram shape that is not a reel, `/reels/` or `/tv/`),
    /// X / Twitter statuses (a `/video/<n>` suffix says which video, so that one is a single file), TikTok `/photo/`
    /// (a `/video/` link is a video; a short link is unknown), and every host that is not named here.
    public static func mayBeGallery(_ link: URL) -> Bool {
        let host = (link.host(percentEncoded: false) ?? "").lowercased()
        func on(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        let parts = link.pathComponents.filter { $0 != "/" && !$0.isEmpty }.map { $0.lowercased() }
        // a plain media file: a video, audio or one image (its own extension, a query does not count)
        let file = (link.path as NSString).pathExtension.lowercased()
        let media: Set<String> = [
            "mp4", "mov", "m4v", "webm", "mkv", "avi", "mpg", "mpeg", "3gp", "mp3", "m4a", "aac", "wav", "flac", "ogg", "opus",
            "gif", "jpg", "jpeg", "png", "webp", "heic", "heif", "avif",
        ]
        if media.contains(file) { return false }
        if on("instagram.com") || on("instagr.am") {
            return !parts.contains { ["reel", "reels", "tv"].contains($0) }
        }
        if on("youtube.com") || on("youtu.be") || on("youtube-nocookie.com") { return false }
        if on("tiktok.com") {
            return !parts.contains("video")
        }
        if on("x.com") || on("twitter.com") || on("fxtwitter.com") || on("vxtwitter.com") {
            guard let status = parts.firstIndex(where: { $0 == "status" || $0 == "statuses" }) else { return true }
            // `/status/<id>/video/<n>`: one video of the post
            return !parts.dropFirst(status + 2).contains("video")
        }
        return true
    }

    /// What the extension does with what was shared (the extension's entry point, called from `viewDidLoad`).
    public enum Start: Sendable {
        /// A link: the flow asks the server what it is. One item is saved and the extension closes without showing
        /// anything; a gallery gets the compact sheet (`ShareGalleryFlow`).
        case flow(ShareGalleryFlow)
        /// Shared photos and videos are with the system's transfer daemon (`ShareUploads`): the caller completes at once.
        case uploaded
        /// A file this build cannot send in the background (no app group), or anything else the instant path cannot
        /// do: the caller builds the full sheet.
        case needsSheet
        /// Nothing could be queued: the caller shows its one-line card.
        case failed(Failure)
    }

    /// What `run` and `start` share: the link (nil: photos or videos), the settings and a client for this process's key.
    private struct Prepared {
        var link: LinkInfo?
        var settings: Settings
        var client: HTTPCobaltClient
    }

    @MainActor
    private static func prepare(inputItems: [NSExtensionItem], files: Bool = false) async -> Either<Prepared, Result> {
        let intake = await ShareInbox.loadLinkOnly(inputItems)
        let link: LinkInfo?
        switch intake {
        case .file:
            // the background upload needs the app group; without it the full sheet uploads one file itself
            guard files, URLSessionSaveTransport.current.background else { return .right(.needsSheet) }
            link = nil
        case .none:
            Telemetry.log(.info, .share, "share instant", data: ["result": "no-link"])
            return .right(.failed(.noLink))
        case .link(let url):
            guard let info = LinkInfo(url) else { return .right(.failed(.noLink)) }
            link = info
        }
        let settings = Settings.shared()
        let server = settings.serverURL
        let keychain = settings.keychain
        // No key this process can read (a build whose keychain group did not survive a re-sign): say so now
        // instead of queueing a request the server will refuse.
        guard Settings.apiKey(in: keychain, forServer: server) != nil else {
            Telemetry.log(.info, .share, "share instant", data: ["result": "no-key", "root": .string(AppGroup.location.kind.rawValue)])
            return .right(.failed(.noKey))
        }
        let client = HTTPCobaltClient(baseURL: server, apiKey: { Settings.apiKey(in: keychain, forServer: server) })
        return .left(Prepared(link: link, settings: settings, client: client))
    }

    private enum Either<L, R> {
        case left(L), right(R)
    }

    /// The extension's whole path for a link (CONTRACT-GALLERY.md 1.12): the flow is started and returned. A file shared
    /// without a link is `.needsSheet`; no key or no link is `.failed`.
    @MainActor
    public static func start(inputItems: [NSExtensionItem]) async -> Start {
        switch await prepare(inputItems: inputItems, files: true) {
        case .right(.needsSheet): return .needsSheet
        case .right(.failed(let failure)): return .failed(failure)
        case .right(.saved): return .needsSheet
        case .left(let prepared):
            guard let link = prepared.link else {
                return await upload(inputItems: inputItems, settings: prepared.settings, client: prepared.client)
            }
            let flow = ShareGalleryFlow.live(link: link, client: prepared.client, settings: prepared.settings)
            flow.begin()
            return .flow(flow)
        }
    }

    /// Shared photos and videos (CONTRACT-SHARE-QUICK.md 9.10): copied into the app group, each handed to the background
    /// session as an upload, a quiet "uploading to capystore" posted, done. Nothing is shown unless none could be sent.
    @MainActor
    private static func upload(inputItems: [NSExtensionItem], settings: Settings, client: HTTPCobaltClient) async -> Start {
        let started = Date()
        let saves = AppGroup.directory("Saves")
        let loaded = await ShareUploads.load(inputItems, into: ShareUploads.directory(saves: saves))
        var log: [String: TelemetryValue] = [
            "files": .int(loaded.files.count), "unsupported": .int(loaded.unsupported), "tooLarge": .int(loaded.tooLarge),
            "overLimit": .int(loaded.overLimit), "bytes": .bytes(loaded.files.reduce(0) { $0 + $1.bytes }),
        ]
        guard !loaded.files.isEmpty else {
            Telemetry.log(.info, .share, "share upload", data: log.merging(["result": "nothing"]) { a, _ in a })
            return .failed(loaded.tooLarge > 0 ? .tooLarge : .noMedia)
        }
        var engine = InstantShareEngine(
            transport: URLSessionSaveTransport(mode: .background, resourceTimeout: 6 * 3600), directory: saves)
        engine.makePublic = settings.newSavesPublic
        let job = UUID()
        let result = await engine.enqueue(files: loaded.files, client: client, job: job)
        log["result"] = .string(name(of: result))
        log["ms"] = .int(Int(Date().timeIntervalSince(started) * 1000))
        Telemetry.log(.info, .share, "share upload", data: log)
        switch result {
        case .saved:
            await Notifications.postInstantSaving(
                job: job, title: "uploading to capystore", body: ShareUploads.summary(loaded.files))
            return .uploaded
        case .needsSheet:
            for file in loaded.files { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
            return .needsSheet
        case .failed(let failure):
            for file in loaded.files { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
            return .failed(failure)
        }
    }

    /// The whole instant path for what the host shared, with no gallery sheet: the link is saved at once, whatever it
    /// is (what the owner's `show the full share sheet`-less 1.13 did). Kept for the debug harness and the tests.
    ///
    /// - `.saved`: the save is queued; the caller completes the request at once.
    /// - `.needsSheet`: a file; the caller builds the full sheet.
    /// - `.failed`: nothing could be queued; the caller shows its one-line card.
    @MainActor
    public static func run(inputItems: [NSExtensionItem]) async -> Result {
        let started = Date()
        let prepared: Prepared
        switch await prepare(inputItems: inputItems) {
        case .right(let result): return result
        case .left(let value): prepared = value
        }
        guard let link = prepared.link else { return .needsSheet }
        let settings = prepared.settings, client = prepared.client
        let transport = URLSessionSaveTransport.current
        var engine = InstantShareEngine(transport: transport, directory: AppGroup.directory("Saves"))
        engine.makePublic = settings.newSavesPublic
        engine.ytdlp = settings.saveWithYtdlp
        let job = UUID()
        let label = InstantShareEngine.label(for: link)
        // The notification is a local write; it runs beside the request, never in front of it.
        async let notified: Void = Notifications.postInstantSaving(job: job, label: label)
        let result = await engine.enqueue(link: link, client: client, job: job)
        await notified
        if case .failed = result { Notifications.removeInstantSaving(job: job) }
        Telemetry.log(.info, .share, "share instant", data: [
            "result": .string(Self.name(of: result)), "background": .bool(transport.background),
            "ms": .int(Int(Date().timeIntervalSince(started) * 1000)), "root": .string(AppGroup.location.kind.rawValue),
        ])
        return result
    }

    private static func name(of result: Result) -> String {
        switch result {
        case .saved: return "saved"
        case .needsSheet: return "needs-sheet"
        case .failed(let f): return "failed-\(f)"
        }
    }
}
