import AppIntents
import CobaltKit
import Foundation

/// "Get latest saves" filter (CONTRACT-PARALLEL.md 15.4).
enum CobaltSaveKind: String, AppEnum {
    case anything, videos, webps

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Kind")
    static let caseDisplayRepresentations: [CobaltSaveKind: DisplayRepresentation] = [
        .anything: "Anything",
        .videos: "Videos",
        .webps: "Webps",
    ]

    var shortcut: ShortcutSaveKind {
        switch self {
        case .anything: return .anything
        case .videos: return .videos
        case .webps: return .webps
        }
    }
}

/// "Get latest saves" (CONTRACT-PARALLEL.md 15.4): the newest saves in the library, as values the next action can use.
/// A locked phone shows nothing: titles and links of private saves need authentication.
struct LatestSavesIntent: AppIntent {
    static let title: LocalizedStringResource = "Get latest saves"
    static let description = IntentDescription("Gets the newest saves in your cobalt library.", categoryName: "cobalt")
    static var supportedModes: IntentModes { .background }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Count", description: "How many, 1 to 20.", default: 1, inclusiveRange: (1, 20))
    var count: Int

    @Parameter(title: "Kind", default: .anything)
    var kind: CobaltSaveKind

    @Dependency var actions: ShortcutActions

    static var parameterSummary: some ParameterSummary {
        Summary("Get the latest \(\.$count) \(\.$kind) saves")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[CobaltSave]> & ProvidesDialog {
        do {
            let saves = try await actions.latestSaves(count: count, kind: kind.shortcut)
            return IntentResults.saves(saves, dialog: Copy.Shortcuts.latest(saves))
        } catch {
            throw IntentErrors.map(error)
        }
    }
}
