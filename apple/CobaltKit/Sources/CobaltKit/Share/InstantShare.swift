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
    /// The whole instant path for what the host shared. Call it from `viewDidLoad`.
    ///
    /// - `.saved`: the save is queued; the caller completes the request at once.
    /// - `.needsSheet`: a file; the caller builds the full sheet.
    /// - `.failed`: nothing could be queued; the caller shows its one-line card.
    @MainActor
    public static func run(inputItems: [NSExtensionItem]) async -> Result {
        let started = Date()
        let intake = await ShareInbox.loadLinkOnly(inputItems)
        let link: LinkInfo
        switch intake {
        case .file: return .needsSheet
        case .none:
            Telemetry.log(.info, .share, "share instant", data: ["result": "no-link"])
            return .failed(.noLink)
        case .link(let url):
            guard let info = LinkInfo(url) else { return .failed(.noLink) }
            link = info
        }
        let settings = Settings.shared()
        let server = settings.serverURL
        let keychain = settings.keychain
        // No key this process can read (a build whose keychain group did not survive a re-sign): say so now
        // instead of queueing a request the server will refuse.
        guard Settings.apiKey(in: keychain, forServer: server) != nil else {
            Telemetry.log(.info, .share, "share instant", data: ["result": "no-key", "root": .string(AppGroup.location.kind.rawValue)])
            return .failed(.noKey)
        }
        let client = HTTPCobaltClient(baseURL: server, apiKey: { Settings.apiKey(in: keychain, forServer: server) })
        let transport = URLSessionSaveTransport.current
        let engine = InstantShareEngine(transport: transport, directory: AppGroup.directory("Saves"))
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
