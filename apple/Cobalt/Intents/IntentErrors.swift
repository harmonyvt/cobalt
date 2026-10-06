import AppIntents
import CobaltKit
import Foundation

/// What an action throws (CONTRACT-PARALLEL.md 15.6): a plain sentence, lowercase, that Shortcuts and Siri show as is.
struct CobaltIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String

    init(message: String) { self.message = message }
    init(_ error: ShortcutError) { self.message = Copy.Shortcuts.message(error) }

    var localizedStringResource: LocalizedStringResource {
        LocalizedStringResource(String.LocalizationValue(message))
    }
}

enum IntentErrors {
    /// A `ShortcutError` becomes its words; a cancellation stays one (the system's stop button); anything else is a
    /// `PipelineFailure`'s or a server's own surprise, said the way the app says it.
    static func map(_ error: Error) -> Error {
        switch error {
        case let e as ShortcutError: return CobaltIntentError(e)
        case is CancellationError: return error
        case let e as CobaltIntentError: return e
        case let e as PipelineFailure: return CobaltIntentError(message: Copy.failure(e))
        default: return error
        }
    }

    /// The `IntentDialog` for a sentence of ours.
    static func dialog(_ text: String) -> IntentDialog {
        IntentDialog(LocalizedStringResource(String.LocalizationValue(text)))
    }
}

/// Results with an optional dialog. `ProvidesDialog` needs a dialog to build the result; the dialog is then taken off
/// again when there is nothing to say (CONTRACT-PARALLEL.md 15.6: "no dialog when all went").
enum IntentResults {
    static func saves(_ saves: [ShortcutSave], dialog: String? = nil) -> IntentResultContainer<[CobaltSave], Never, Never, IntentDialog> {
        var result: IntentResultContainer<[CobaltSave], Never, Never, IntentDialog> = .result(
            value: saves.map(CobaltSave.init), dialog: IntentErrors.dialog(dialog ?? "ok"))
        if dialog == nil { result.dialog = nil }
        return result
    }

    static func url(_ url: URL, dialog: String? = nil) -> IntentResultContainer<URL, Never, Never, IntentDialog> {
        var result: IntentResultContainer<URL, Never, Never, IntentDialog> = .result(
            value: url, dialog: IntentErrors.dialog(dialog ?? "ok"))
        if dialog == nil { result.dialog = nil }
        return result
    }
}
