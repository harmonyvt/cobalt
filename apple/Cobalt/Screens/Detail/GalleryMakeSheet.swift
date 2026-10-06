import CobaltKit
import SwiftUI

/// `make from this post…` (CONTRACT-GALLERY 1.15): the detail's `more` menu and the make row open lane A2's combine sheet on
/// this media. It opens on the output of the tab the owner is looking at (a slideshow webp tab remakes the slideshow webp, a
/// gallery image tab remakes a gallery image; its own line says it replaces the one made before), else on the slideshow webp.
/// The sheet never owns a make: it is a job of the queue, so closing it at any moment stops nothing, and the finished file
/// arrives here as a tab (`MediaDetail` selects it).
struct GalleryMakeSheet: ViewModifier {
    let controller: DetailController
    let item: MediaItem
    let model: AppModel

    private var presented: Binding<Bool> {
        Binding(get: { controller.showsMakeSheet }, set: { controller.showsMakeSheet = $0 })
    }

    /// The output of the shown tab.
    private var output: CombineOutput {
        switch controller.selected(in: item).kind {
        case .slideshow(_, .mp4): return .slideshowMp4
        case .galleryImage: return .galleryImage
        default: return .slideshowWebp
        }
    }

    func body(content: Content) -> some View {
        content.sheet(isPresented: presented) {
            CombineSheet(model: model, media: item, output: output)
                #if os(macOS)
                .modifier(MacSheetSize())
                #endif
        }
    }
}

extension View {
    func makeSheet(controller: DetailController, item: MediaItem, model: AppModel) -> some View {
        modifier(GalleryMakeSheet(controller: controller, item: item, model: model))
    }
}
