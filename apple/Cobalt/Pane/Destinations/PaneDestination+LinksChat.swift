import CobaltKit
import SwiftUI

// Links and chat pages in the pane. OWNED BY THE LINKS/CHAT LANE.
//
// - link(id):        a share link (`ShareSet`) id (`Screens/Links/LinkPanePage.swift`); spanned, its files go across both
//                    screens, a file's tap opens `.post(id)`.
// - collection(id):  a collection id (`Screens/Links/CollectionPanePage.swift`); a link's tap opens `.link(id)`.
// - chat: anything the AI made opens as `.post(id)` (PaneDestination+LibraryHome.swift, built by the library lane); the
//   conversation itself is never the pane: the thread list pushes it in the chat tab's own stack
//   (`Screens/Chat/ChatScreen.swift`).
extension PaneDestination {
    @MainActor @ViewBuilder
    static func link(_ id: String, model: AppModel, pane: Pane) -> some View {
        LinkPanePage(model: model, id: id)
    }

    @MainActor @ViewBuilder
    static func collection(_ id: String, model: AppModel, pane: Pane) -> some View {
        CollectionPanePage(model: model, id: id)
    }
}
