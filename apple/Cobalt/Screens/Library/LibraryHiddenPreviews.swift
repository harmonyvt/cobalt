import CobaltKit
import SwiftUI

#if DEBUG
/// Previews of the hidden album on `AppModel.preview(.hidden)` (6 hidden posts, 3 rules): the locked card, the open
/// album as a mosaic and as a list, the select panel with `unhide` and `status…`, and the empty album.
private struct HiddenPreviewUnlockedKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// A preview opens the album already unlocked (the lock itself asks the system, which a preview cannot answer).
    var hiddenPreviewUnlocked: Bool {
        get { self[HiddenPreviewUnlockedKey.self] }
        set { self[HiddenPreviewUnlockedKey.self] = newValue }
    }
}

#Preview("hidden · locked", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.hidden, tab: .library) { model in
        let _ = { model.library.showingHidden = true }()
        LibraryScreen(model: model, tier: .compact)
    }
}
#Preview("hidden · album", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.hidden, tab: .library) { model in
        let _ = { model.library.showingHidden = true }()
        LibraryScreen(model: model, tier: .compact).environment(\.hiddenPreviewUnlocked, true)
    }
}
#Preview("hidden · album, list", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.hidden, tab: .library) { model in
        let _ = { model.library.showingHidden = true; model.library.viewMode = .table }()
        LibraryScreen(model: model, tier: .compact).environment(\.hiddenPreviewUnlocked, true)
    }
}
#Preview("hidden · album, iPad", traits: .fixedLayout(width: 1100, height: 760)) {
    PreviewHost(.hidden, tab: .library) { model in
        let _ = { model.library.showingHidden = true }()
        LibraryScreen(model: model, tier: .regular).environment(\.hiddenPreviewUnlocked, true)
    }
}
#Preview("hidden · chip off", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.hidden, tab: .library) { model in
        LibraryScreen(model: model, tier: .compact)
    }
}
#Preview("hidden · empty album", traits: .fixedLayout(width: 390, height: 600)) {
    HiddenAlbumEmpty()
}
#endif
