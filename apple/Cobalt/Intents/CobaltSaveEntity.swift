import AppIntents
import CobaltKit
import Foundation

/// A save's state as Shortcuts shows it (CONTRACT-PARALLEL.md 15.4 `CobaltSaveState`).
enum CobaltSaveState: String, AppEnum {
    case queued, saving, saved, failed

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Save state")
    static let caseDisplayRepresentations: [CobaltSaveState: DisplayRepresentation] = [
        .queued: "Waiting for the server",
        .saving: "Saving",
        .saved: "Saved",
        .failed: "Couldn't save",
    ]

    init(_ state: ShortcutSaveState) {
        switch state {
        case .queued: self = .queued
        case .saving: self = .saving
        case .saved: self = .saved
        case .failed: self = .failed
        }
    }

    var lowercase: String {
        switch self {
        case .queued: return "waiting for the server"
        case .saving: return "saving"
        case .saved: return "saved"
        case .failed: return "couldn't save"
        }
    }
}

/// One save, handed from action to action (CONTRACT-PARALLEL.md 15.4). `id` is the post key: the session id for a saved
/// link, the item id for an upload, both equal to `GET /library`'s post `id`.
struct CobaltSave: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "cobalt save")
    static let defaultQuery = CobaltSaveQuery()

    var id: String

    @Property(title: "Title")
    var title: String

    /// The page it came from (a saved link).
    @Property(title: "Link")
    var link: URL?

    @Property(title: "Service")
    var service: String?

    @Property(title: "State")
    var state: CobaltSaveState

    /// The original's public link, when it is public.
    @Property(title: "Public link")
    var publicLink: URL?

    /// Public links of its webps, newest first.
    @Property(title: "Webp links")
    var webpLinks: [URL]

    /// Seconds.
    @Property(title: "Duration")
    var duration: Double?

    @Property(title: "Created")
    var created: Date

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(service.map { "\($0) · " } ?? "")\(state.lowercase)")
    }

    init(_ save: ShortcutSave) {
        id = save.id
        title = save.title
        link = save.link
        service = save.service
        state = CobaltSaveState(save.state)
        publicLink = save.publicLink
        webpLinks = save.webpLinks
        duration = save.duration
        created = save.created
    }
}

/// `entities(for:)` looks in the loaded library model, then `GET /studio/<id>` (a link save), then the first library page;
/// `suggestedEntities()` is the first library page (20).
struct CobaltSaveQuery: EntityQuery {
    @Dependency var actions: ShortcutActions

    func entities(for identifiers: [String]) async throws -> [CobaltSave] {
        await actions.saves(for: identifiers).map(CobaltSave.init)
    }

    func suggestedEntities() async throws -> [CobaltSave] {
        await actions.suggestedSaves().map(CobaltSave.init)
    }
}
