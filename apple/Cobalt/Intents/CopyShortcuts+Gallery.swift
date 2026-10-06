import CobaltKit
import Foundation

/// What the Shortcuts actions say about galleries (CONTRACT-GALLERY.md 1.13; the words of CONTRACT-PARALLEL.md 15.6 for
/// the rest, `Copy+Shortcuts.swift`). Lowercase like the rest of cobalt. Kept here, with the intents that use it, because
/// `Copy+Shortcuts.swift` is compiled into the share extension and widgets too and these words are the app's alone.
extension Copy.Shortcuts {
    /// Asked to bring cobalt forward on a system that cannot wait for the make (before iOS and macOS 27).
    static let continueForMake = "cobalt has to stay open to make it."

    /// The dialog "Save links" ends with: nothing when everything went and was only handed over.
    /// - partial: "saved 2 of 3 links; 1 couldn't be sent: …".
    /// - a gallery that was saved but not made: the save stands and the dialog says why not.
    /// - a gallery with an item that could not be fetched, once the save is known.
    static func saveDialog(_ outcome: ShortcutSaveOutcome) -> String? {
        var lines: [String] = []
        if outcome.isPartial { lines.append(partial(outcome, noun: "link")) }
        lines += outcome.makeFailures.map(makeFailed)
        for save in outcome.saves where save.itemsFailed > 0 {
            lines.append(itemsFailed(save))
        }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    /// "saved x · @handle. the slideshow webp couldn't be made: webps stop at 60 s. open cobalt to make the mp4."
    static func makeFailed(_ failure: ShortcutMakeFailure) -> String {
        "saved \(failure.title). the \(failure.what) couldn't be made: \(makeReason(failure.failure, what: failure.what))"
    }

    /// "saved 9 of 10 photos of x · @handle. 1 couldn't be fetched."
    static func itemsFailed(_ save: ShortcutSave) -> String {
        let total = save.itemCount ?? 0
        let saved = max(0, total - save.itemsFailed)
        return "saved \(saved) of \(total) items of \(save.title). \(save.itemsFailed) couldn't be fetched."
    }

    /// Why a make failed, in words (the server's codes arrive with the render phase's prefix).
    static func makeReason(_ failure: PipelineFailure, what: String) -> String {
        guard case .server(let raw) = failure else { return Copy.failure(failure) }
        let code = raw.hasPrefix(PipelineFailure.renderPhasePrefix) ? String(raw.dropFirst(PipelineFailure.renderPhasePrefix.count)) : raw
        switch code {
        case "error.webp.too_long":
            return what == "slideshow webp"
                ? "webps stop at 60 s. open cobalt to make the mp4."
                : "it would be too long."
        case "error.studio.too_few_photos": return "a gallery image needs 2 photos."
        case "error.studio.not_gallery": return "a slideshow needs 2 or more items."
        default: return "the server's encoder stopped. the photos are untouched."
        }
    }
}
