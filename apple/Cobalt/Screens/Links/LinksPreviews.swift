#if DEBUG
import CobaltKit
import SwiftUI

// `#Preview`s of the links tab on the preview server: three sample links (a video + webp + photo, two webps, four
// files with one gone private), none yet, and a listing that fails. The thumbnails are network pictures, so they stay
// blank in a preview.

#Preview("links · happy", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.happy, tab: .links) { model in NavigationStack { LinksScreen(model: model) } }
}
#Preview("links · happy, dark", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.happy, tab: .links) { model in NavigationStack { LinksScreen(model: model) } }
        .preferredColorScheme(.dark)
}
#Preview("links · AX3 text", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.happy, tab: .links) { model in NavigationStack { LinksScreen(model: model) } }
        .dynamicTypeSize(.accessibility3)
}
#Preview("links · empty", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.shareLinksEmpty, tab: .links) { model in NavigationStack { LinksScreen(model: model) } }
}
#Preview("links · listing fails", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.shareLinksFail, tab: .links) { model in NavigationStack { LinksScreen(model: model) } }
}
#Preview("links · mac width", traits: .fixedLayout(width: 900, height: 700)) {
    PreviewHost(.happy, tab: .links) { model in NavigationStack { LinksScreen(model: model) } }
}
#endif
