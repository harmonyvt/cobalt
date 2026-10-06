import Foundation
import UniformTypeIdentifiers

// Instant share, the extension's side (CONTRACT-SHARE-QUICK.md section 9; the engine and its transports are
// in `Background/InstantSave.swift`). The share extension calls `InstantShare.run` as early as it can: it
// reads the link, queues the save, tells the owner with a quiet local notification and returns. Nothing in
// here shows a view or waits for the save.

/// What was shared, as far as the instant path cares.
enum InstantIntake: Sendable, Equatable {
    case link(URL)
    /// A movie file and no link: its upload runs inside the extension, so only the full sheet can do it.
    case file
    case none
}

extension ShareInbox {
    /// The first link in what the host shared: a URL attachment, a URL in text, the item's own text. A link
    /// wins over a movie file (saving the link server-side is the point). Nothing is copied or loaded
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
        if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.movie.identifier) }) { return .file }
        return .none
    }
}

extension InstantShare {
    /// What the extension does with what was shared (the extension's entry point, called from `viewDidLoad`).
    public enum Start: Sendable {
        /// A link: the flow asks the server what it is. One item is saved and the extension closes without showing
        /// anything; a gallery gets the compact sheet (`ShareGalleryFlow`).
        case flow(ShareGalleryFlow)
        /// A file, or anything the instant path cannot do: the caller builds the full sheet.
        case needsSheet
        /// Nothing could be queued: the caller shows its one-line card.
        case failed(Failure)
    }

    /// What `run` and `start` share: the link, the settings and a client for this process's key.
    private struct Prepared {
        var link: LinkInfo
        var settings: Settings
        var client: HTTPCobaltClient
    }

    @MainActor
    private static func prepare(inputItems: [NSExtensionItem]) async -> Either<Prepared, Result> {
        let intake = await ShareInbox.loadLinkOnly(inputItems)
        let link: LinkInfo
        switch intake {
        case .file: return .right(.needsSheet)
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
        switch await prepare(inputItems: inputItems) {
        case .right(.needsSheet): return .needsSheet
        case .right(.failed(let failure)): return .failed(failure)
        case .right(.saved): return .needsSheet
        case .left(let prepared):
            let flow = ShareGalleryFlow.live(link: prepared.link, client: prepared.client, settings: prepared.settings)
            flow.begin()
            return .flow(flow)
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
        let link = prepared.link, settings = prepared.settings, client = prepared.client
        let transport = URLSessionSaveTransport.current
        var engine = InstantShareEngine(transport: transport, directory: AppGroup.directory("Saves"))
        engine.makePublic = settings.newSavesPublic
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
