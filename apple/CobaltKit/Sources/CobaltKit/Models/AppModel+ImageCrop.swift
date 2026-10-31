import CoreGraphics
import Foundation

// Cropping a picture of the library (APP-API-CONTRACT 44, apple/CONTRACT-EDITOR.md 13): the library's viewer and context menu
// open the crop sheet; `save a copy` makes a new private PNG next to the picture (the picture is never changed) and the
// library lists it.

extension AppModel {
    /// The server takes crops (`features.image_crop`) and the client can send them.
    public var canCropImages: Bool { capabilities.imageCrop && ctx.client is any ImageCropClient }

    /// `rendition` is a library file the route can crop: a picture the library lists.
    public func canCropImage(_ rendition: Rendition) -> Bool {
        guard canCropImages, let file = rendition.file else { return false }
        let type = file.contentType?.lowercased() ?? ""
        return type.isEmpty || type.hasPrefix("image/")
    }

    /// The picture behind `rendition` at full size (EXIF orientation applied, at most 8192 px a side): the copy on this
    /// device, else a download of the server's file.
    public func cropPicture(of rendition: Rendition) async throws -> CGImage {
        let source = try await frameSource(of: rendition)
        let url = source.url
        let decoded: ImageCropPicture? = await Task.detached(priority: .userInitiated) {
            defer { source.discard() }
            return ImageCropper.decode(url).map(ImageCropPicture.init)
        }.value
        guard let decoded else { throw ImageCropError.failed }
        return decoded.image
    }

    /// `save a copy`: the crop of `rendition` made on the device from `picture` (or by the server when it is nil or the device
    /// cannot), then the library is refreshed so the new file shows.
    @discardableResult
    public func cropImage(of rendition: Rendition, picture: CGImage?, spec: ImageCropSpec) async throws -> ImageCropResult {
        guard canCropImages, let file = rendition.file, let client = ctx.client as? any ImageCropClient else {
            throw ImageCropError.off
        }
        let server = capabilities.canServerCropImage(contentType: file.contentType, cutout: spec.cutout)
        let result = try await ImageCropRun.make(of: file.id, picture: picture, spec: spec, client: client, server: server)
        Task { await library.refresh() }
        return result
    }
}
