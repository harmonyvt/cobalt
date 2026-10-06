import AppIntents
import CobaltKit
import Foundation

/// "Make webp" size (CONTRACT-PARALLEL.md 15.4): the two widths the server renders, or the app's setting.
enum CobaltWebpSize: String, AppEnum {
    case appDefault, small, large

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Size")
    static let caseDisplayRepresentations: [CobaltWebpSize: DisplayRepresentation] = [
        .appDefault: "App default",
        .small: "320",
        .large: "480",
    ]

    var shortcut: ShortcutWebpSize {
        switch self {
        case .appDefault: return .appDefault
        case .small: return .small
        case .large: return .large
        }
    }
}

/// "Make webp" (CONTRACT-PARALLEL.md 15.4): iOS and macOS 27. Renders an animated webp from a save and returns its public
/// link. It waits for the render itself (queued place, then frames, as the system's progress); stop cancels a render that
/// is still queued, and one that already started finishes on the server and is announced by Hark (15.6).
@available(iOS 27, macOS 27, *)
struct MakeWebpIntent: AppIntent, LongRunningIntent, CancellableIntent {
    static let title: LocalizedStringResource = "Make webp"
    static let description = IntentDescription(
        "Makes an animated webp from a saved video and returns its link. With no save given it uses your latest save with a video.",
        categoryName: "cobalt")
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Save", description: "Empty means your latest save with a video.")
    var save: CobaltSave?

    @Parameter(title: "Start", description: "Seconds from the start of the video.", default: 0)
    var start: Double

    @Parameter(title: "Length", description: "Seconds. Empty means as long as cobalt allows.")
    var length: Double?

    @Parameter(title: "Size", default: .appDefault)
    var size: CobaltWebpSize

    @Dependency var actions: ShortcutActions

    static var parameterSummary: some ParameterSummary {
        Summary("Make a webp of \(\.$save)") {
            \.$start
            \.$length
            \.$size
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<URL> & ProvidesDialog {
        do {
            let cancel = ShortcutCancel()
            progress.totalUnitCount = 100
            let report: ShortcutProgress = { done, total in
                progress.totalUnitCount = total
                progress.completedUnitCount = done
            }
            let saveID = save?.id
            let start = start
            let length = length
            let size = size.shortcut
            let actions = actions
            let url = try await performBackgroundTask(
                operation: { @Sendable in try await actions.makeWebp(of: saveID, start: start, length: length, size: size, cancel: cancel, progress: report) },
                onCancel: { _ in cancel.cancel() })
            return IntentResults.url(url)
        } catch {
            throw IntentErrors.map(error)
        }
    }
}
