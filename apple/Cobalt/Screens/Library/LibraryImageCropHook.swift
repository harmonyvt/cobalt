import CobaltKit
import SwiftUI

// The library's way into the picture crop sheet (apple/CONTRACT-EDITOR.md 13, APP-API-CONTRACT 44): `crop a copy…` in a
// picture's context menu (the first photo of the post) and in the viewer's `more` menu (the photo in view). The sheet's one
// button is `save a copy`: a new private PNG in the library, linked to the picture, which is never changed. Only with
// `features.image_crop`.

/// The picture the crop sheet is open on.
struct LibraryImageCropTarget: Identifiable {
    let item: MediaItem
    let rendition: Rendition
    var id: String { rendition.id }
}

extension LibraryController {
    /// The post's picture `crop a copy…` works on: its first photo the route can take; nil hides the item.
    func croppablePicture(_ item: MediaItem) -> Rendition? {
        guard model.canCropImages else { return nil }
        return ToolPhotos.photos(of: item).first { model.canCropImage($0) }
    }

    func cropPicture(_ item: MediaItem) {
        guard let rendition = croppablePicture(item) else { return }
        croppingPicture = LibraryImageCropTarget(item: item, rendition: rendition)
    }
}

extension ImageCropSheet {
    /// From the library: the picture of `rendition`, and `save a copy`. `done` gets the line to say once the copy is made.
    static func library(
        model: AppModel, rendition: Rendition, done: @escaping @MainActor (String) -> Void, close: @escaping () -> Void
    ) -> ImageCropSheet {
        let name = rendition.file.map { ($0.name as NSString).deletingPathExtension } ?? DetailWords.photo
        let save = ImageCropAction(title: Copy.Editor.cropSaveCopy, symbol: Symbol.Editor.cropSaveCopy) { spec, picture in
            try await model.cropImage(of: rendition, picture: picture, spec: spec)
            done(Copy.Editor.cropSaved)
        }
        let load: @MainActor () async throws -> CGImage = { try await model.cropPicture(of: rendition) }
        let serverCan: @MainActor (Bool) -> Bool = {
            model.capabilities.canServerCropImage(contentType: rendition.file?.contentType, cutout: $0)
        }
        return ImageCropSheet(name: name, load: load, serverCan: serverCan, primary: save, secondary: nil, close: close)
    }
}

/// Presents the crop sheet on the picture `target` names (the library screen, the viewer's menu).
struct LibraryImageCropPresenter: ViewModifier {
    let model: AppModel
    @Binding var target: LibraryImageCropTarget?
    let done: @MainActor (String) -> Void

    func body(content: Content) -> some View {
        content.sheet(item: $target) { picked in
            ImageCropSheet.library(model: model, rendition: picked.rendition, done: done) { target = nil }
        }
    }
}
