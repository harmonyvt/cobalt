import CobaltKit
import SwiftUI

// The one place the home screen reaches lane A2's combine sheet (Screens/Combine/CombineSheet.swift). The focus hero's
// `make from it` row asks for a sheet with an output chosen; this file turns that into A2's entry
// `CombineSheet(model:pipeline:output:)` (the gallery on the focus: its items follow the run and a make chosen while the
// save still runs waits for it, CONTRACT-GALLERY R7). Everything else in Home knows only `GalleryMakeKind`, so a change
// to the sheet's init is a change here and nowhere else.

extension GalleryMakeKind {
    /// The combine sheet's own name for the same three outputs.
    var combineOutput: CombineOutput {
        switch self {
        case .webp: return .slideshowWebp
        case .mp4: return .slideshowMp4
        case .image: return .galleryImage
        }
    }
}

/// What the focus presents for a tap on a make tile. The sheet picks its own detents and has its own close button.
struct GalleryCombineSheet: View {
    let model: AppModel
    let pipeline: Pipeline
    let kind: GalleryMakeKind

    var body: some View {
        CombineSheet(model: model, pipeline: pipeline, output: kind.combineOutput)
    }
}
