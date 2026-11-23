import CobaltKit
import SwiftUI

extension PaneAction {
    /// The pane's `share`: one action per form, under a `share` that opens them as a menu (or the one form alone).
    static func share(
        _ targets: ShareTargets, disabled: Bool = false, file: @escaping @MainActor () -> Void,
        links: @escaping @MainActor (URL) -> Void
    ) -> PaneAction? {
        let choices = targets.forms.map { form in
            PaneAction(form.title, systemImage: form.symbol, id: "share-\(form)") {
                if form == .file { file() } else if let url = targets.url(form) { links(url) }
            }
        }
        guard let only = choices.first else { return nil }
        if choices.count == 1 {
            return PaneAction(Copy.Media.share, systemImage: Symbol.Media.share, disabled: disabled, id: "share", perform: only.perform)
        }
        return PaneAction(Copy.Media.share, systemImage: Symbol.Media.share, disabled: disabled, id: "share", choices: choices) {}
    }
}
