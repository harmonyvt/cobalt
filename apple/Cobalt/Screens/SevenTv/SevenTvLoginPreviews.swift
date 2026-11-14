import CobaltKit
import SwiftUI

// Previews of the login sheet (APP-API-CONTRACT 57.12): the web view is a placeholder; the states are the model's.

#Preview("7tv · log in · loading the page", traits: .fixedLayout(width: 390, height: 800)) {
    PreviewHost(.stageNotConnected, tab: .stage) { model in
        SevenTvLoginSheet(store: model.sevenTv, previewPhase: .browsing)
    }
}
#Preview("7tv · log in · linking", traits: .fixedLayout(width: 390, height: 800)) {
    PreviewHost(.stageNotConnected, tab: .stage) { model in
        SevenTvLoginSheet(store: model.sevenTv, previewPhase: .linking)
    }
}
#Preview("7tv · log in · linked", traits: .fixedLayout(width: 390, height: 800)) {
    PreviewHost(.stageNotConnected, tab: .stage) { model in
        SevenTvLoginSheet(store: model.sevenTv, previewPhase: .linked("capybaraharmony"))
    }
}
#Preview("7tv · log in · error", traits: .fixedLayout(width: 390, height: 800)) {
    PreviewHost(.stageNotConnected, tab: .stage) { model in
        SevenTvLoginSheet(store: model.sevenTv, previewPhase: .failed(.tokenInvalid))
    }
}
