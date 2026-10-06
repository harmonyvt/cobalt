import CobaltKit
import SwiftUI

// The one place the library reaches lane A2's combine sheet (Screens/Combine/CombineSheet.swift): the context menu's
// `make from this post…` of a gallery asks for the sheet on that media (`CombineSheet(model:media:)`, which opens on the
// slideshow webp like the detail's entry). A change to the sheet's init is a change here and nowhere else.

/// Presents the combine sheet for the media the controller is making something from. The sheet has its own detents and
/// close button; a make it starts is a job of the queue, so dismissing it never stops it.
struct LibraryCombineSheet: ViewModifier {
    let model: AppModel
    @Bindable var controller: LibraryController

    func body(content: Content) -> some View {
        content.sheet(item: $controller.combining) { item in
            CombineSheet(model: model, media: item)
        }
    }
}
