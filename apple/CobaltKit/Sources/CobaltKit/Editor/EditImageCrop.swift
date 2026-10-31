import CoreGraphics
import Foundation
import ImageIO

// Cropping pictures (APP-API-CONTRACT 44.1, apple/CONTRACT-EDITOR.md 13): a new private PNG in the library, linked to the picture
// it came from. `POST /library/items/<id>/crop` either stores the PNG the app made itself (`content-type: image/png`,
// `ImageCropper`) or makes it on the server (JSON spec; `features.cutout_auto` for non-PNG pictures and for `cutout`).

/// The new library file.
public struct ImageCropResult: Sendable, Equatable {
    public var id: String
    public var name: String
    public var title: String
    public var width: Int
    public var height: Int

    public init(id: String, name: String, title: String, width: Int, height: Int) {
        self.id = id
        self.name = name
        self.title = title
        self.width = width
        self.height = height
    }

    /// The crop as an editor source (a still PNG, with alpha when the background went).
    public var source: EditSource {
        EditSource(id: id, name: name, kind: .photo, contentType: "image/png", width: width, height: height)
    }
}

/// The route. `HTTPCobaltClient` and `PreviewClient` conform; callers reach it as `client as? any ImageCropClient` (and only
/// with `features.image_crop`).
public protocol ImageCropClient: Sendable {
    /// The server makes the crop of library file `id` (JSON body).
    func cropImage(of id: String, spec: ImageCropSpec) async throws -> ImageCropResult
    /// Stores `png` (made on the device) as the crop of library file `id`; `spec` says what was done (the query).
    func uploadImageCrop(of id: String, png: Data, spec: ImageCropSpec) async throws -> ImageCropResult
}

/// The route's answer: `{status, item: {id, name, ...}, title, crop: {width, height}}`.
struct ImageCropWire: Decodable {
    struct Item: Decodable { var id: String; var name: String? }
    struct Info: Decodable { var width: Int; var height: Int }
    var item: Item
    var title: String?
    var crop: Info

    var result: ImageCropResult {
        let title = self.title ?? "crop"
        return ImageCropResult(id: item.id, name: item.name ?? "\(title).png", title: title, width: crop.width, height: crop.height)
    }
}

extension Capabilities {
    /// The server can make this crop itself (44.1): its own PNG reading covers a PNG without a background removal; anything
    /// else needs Cloudflare Images (`features.cutout_auto`).
    public func canServerCropImage(contentType: String?, cutout: Bool) -> Bool {
        guard imageCrop else { return false }
        if cutoutAuto { return true }
        let png = contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "image/png"
        return png && !cutout
    }
}

/// Makes a crop: on the device when the picture is here (and the result fits the upload), else on the server.
public enum ImageCropRun {
    /// `picture` is the stored picture at full size (nil when it is not on this device). `server`: the server can make this
    /// one itself (`Capabilities.canServerCropImage`). A box under 2 x 2 px throws `.tooSmall` at once; a background removal
    /// that finds nothing throws `.empty` when the server cannot try.
    @MainActor
    public static func make(
        of id: String, picture: CGImage?, spec: ImageCropSpec, client: any ImageCropClient, server: Bool
    ) async throws -> ImageCropResult {
        var png: Data?
        var deviceError: Error?
        if let picture {
            let box = ImageCropPicture(picture)
            do {
                png = try await Task.detached(priority: .userInitiated) {
                    let made = try ImageCropper.make(box.image, spec)
                    return ImageCropper.png(made)
                }.value
            } catch ImageCropError.tooSmall {
                throw ImageCropError.tooSmall
            } catch {
                deviceError = error
            }
        }
        if let png {
            return try await client.uploadImageCrop(of: id, png: png, spec: spec)
        }
        guard server else {
            if let cut = deviceError as? CutoutError, cut == .empty { throw ImageCropError.empty }
            if picture != nil, deviceError == nil { throw ImageCropError.tooLarge }      // too big to upload
            throw deviceError == nil ? ImageCropError.off : ImageCropError.failed
        }
        return try await client.cropImage(of: id, spec: spec)
    }
}

extension HTTPCobaltClient: ImageCropClient {
    public func cropImage(of id: String, spec: ImageCropSpec) async throws -> ImageCropResult {
        let data: Data
        do { data = try spec.jsonBody() } catch { throw ImageCropError.other("encode") }
        let req = try imageCropRequest(id, query: [], timeout: 90)
        return try await imageCropSend(req, body: data, contentType: "application/json")
    }

    public func uploadImageCrop(of id: String, png: Data, spec: ImageCropSpec) async throws -> ImageCropResult {
        let req = try imageCropRequest(id, query: spec.query, timeout: 120)
        return try await imageCropSend(req, body: png, contentType: "image/png")
    }

    private func imageCropRequest(_ id: String, query: [(String, String)], timeout: TimeInterval) throws -> URLRequest {
        do {
            return try makeRequest("POST", "/library/items/\(Self.encode(id))/crop", query: query, keyed: true, timeout: timeout)
        } catch {
            throw ImageCropError.other("request")
        }
    }

    private func imageCropSend(_ request: URLRequest, body: Data, contentType: String) async throws -> ImageCropResult {
        var req = request
        req.httpBody = body
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let answer: (Data, HTTPURLResponse)
        do {
            answer = try await send(req)
        } catch let e as CobaltError {
            if case .network = e { throw ImageCropError.offline }
            throw ImageCropError.other("network")
        }
        let (data, http) = answer
        guard (200..<300).contains(http.statusCode) else {
            struct Err: Decodable { struct E: Decodable { var code: String? }; var error: E? }
            let code = (try? JSONDecoder().decode(Err.self, from: data))?.error?.code ?? "http \(http.statusCode)"
            throw ImageCropError(code: code, status: http.statusCode)
        }
        guard let wire = try? JSONDecoder().decode(ImageCropWire.self, from: data) else {
            throw ImageCropError.other("invalid response")
        }
        return wire.result
    }
}

extension PreviewClient: ImageCropClient {
    public func cropImage(of id: String, spec: ImageCropSpec) async throws -> ImageCropResult {
        editorState.record("POST /library/items/\(id)/crop")
        let from = editorState.source(id)
        let size = ImageCropper.outputSize(spec, width: from?.width ?? 600, height: from?.height ?? 600) ?? (width: 600, height: 600)
        return previewCrop(of: id, title: spec.title, width: size.width, height: size.height)
    }

    public func uploadImageCrop(of id: String, png: Data, spec: ImageCropSpec) async throws -> ImageCropResult {
        editorState.record("POST /library/items/\(id)/crop png")
        var width = 600, height = 600
        if let source = CGImageSourceCreateWithData(png as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            width = (props[kCGImagePropertyPixelWidth] as? Int) ?? width
            height = (props[kCGImagePropertyPixelHeight] as? Int) ?? height
        }
        return previewCrop(of: id, title: spec.title, width: width, height: height)
    }

    /// A new preview file, known to the preview editor from now on.
    private func previewCrop(of id: String, title: String?, width: Int, height: Int) -> ImageCropResult {
        let from = editorState.source(id)
        let base = title ?? "\(from?.shortName ?? "picture") crop"
        let newID = "PrEvIeWcrp" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6))
        let result = ImageCropResult(id: newID, name: "\(base).png", title: base, width: width, height: height)
        var source = result.source
        source.posterURL = from?.posterURL
        editorState.addSource(source)
        return result
    }
}
