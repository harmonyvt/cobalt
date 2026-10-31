import Foundation

// Cutouts (APP-API-CONTRACT 39.3, apple/CONTRACT-EDITOR.md 12): a picture's background taken out into a new private PNG in the
// library. `POST /library/items/<id>/cutout` either makes it on the server (JSON spec; `features.cutout_auto` for `auto` and for
// non-PNG pictures) or stores the PNG the app made itself (`content-type: image/png`, `CutoutMaker`).

/// What to take out.
public enum CutoutMode: String, Sendable, CaseIterable, Codable {
    /// Lift the subject off any background (the server: Cloudflare Images; the device: Vision).
    case auto
    /// Take out white.
    case white
    /// Take out one colour (`CutoutSpec.color`).
    case color
}

/// The JSON body of the route (keys as the server names them).
public struct CutoutSpec: Sendable, Equatable {
    public var mode: CutoutMode
    /// `#rrggbb`, for `.color`.
    public var color: String?
    /// 0...100 (default 20): how far from the colour still counts as background.
    public var tolerance: Double
    /// Only background that touches the picture's edge goes (default true: white eyes stay).
    public var edgesOnly: Bool
    /// 0...3 px (default 1).
    public var soften: Int
    /// Crop to what is left (default true).
    public var trim: Bool
    public var title: String?

    public init(
        mode: CutoutMode = .auto, color: String? = nil, tolerance: Double = 20, edgesOnly: Bool = true, soften: Int = 1,
        trim: Bool = true, title: String? = nil
    ) {
        self.mode = mode
        self.color = color
        self.tolerance = tolerance
        self.edgesOnly = edgesOnly
        self.soften = soften
        self.trim = trim
        self.title = title
    }
}

/// The new library file.
public struct CutoutResult: Sendable, Equatable {
    public var id: String
    public var name: String
    public var title: String
    public var width: Int
    public var height: Int
    public var mode: String

    public init(id: String, name: String, title: String, width: Int, height: Int, mode: String) {
        self.id = id
        self.name = name
        self.title = title
        self.width = width
        self.height = height
        self.mode = mode
    }

    /// The cutout as an editor source (a still PNG with alpha).
    public var source: EditSource {
        EditSource(id: id, name: name, kind: .photo, contentType: "image/png", width: width, height: height)
    }
}

public enum CutoutError: Error, Sendable, Equatable {
    case notFound, notImage, badRequest, tooLarge
    /// Nothing was left (lower the tolerance, try another mode).
    case empty
    /// The server cannot make this one itself (no Cloudflare Images): make it on the device.
    case off
    case failed, offline, unavailable
    case other(String)

    init(code: String, status: Int) {
        switch code {
        case "error.cutout.not_found": self = .notFound
        case "error.cutout.not_image": self = .notImage
        case "error.cutout.bad_request": self = .badRequest
        case "error.cutout.too_large": self = .tooLarge
        case "error.cutout.empty": self = .empty
        case "error.cutout.off": self = .off
        case "error.cutout.failed", "error.cutout.storage": self = .failed
        default: self = status == 503 ? .unavailable : .other(code)
        }
    }
}

/// The route. `HTTPCobaltClient` and `PreviewClient` conform; the editor reaches it as `ctx.client as? CutoutClient` (and only
/// with `features.cutout`).
public protocol CutoutClient: Sendable {
    /// The server makes the cutout of library file `id`.
    func makeCutout(of id: String, spec: CutoutSpec) async throws -> CutoutResult
    /// Stores `png` (made on the device) as the cutout of library file `id`.
    func uploadCutout(of id: String, png: Data, mode: CutoutMode, title: String?) async throws -> CutoutResult
}

/// The route's answer: `{status, item: {id, name, ...}, title, cutout: {width, height, mode}}`.
struct CutoutWire: Decodable {
    struct Item: Decodable { var id: String; var name: String? }
    struct Info: Decodable { var width: Int; var height: Int; var mode: String? }
    var item: Item
    var title: String?
    var cutout: Info

    var result: CutoutResult {
        let title = self.title ?? "cutout"
        return CutoutResult(
            id: item.id, name: item.name ?? "\(title).png", title: title, width: cutout.width, height: cutout.height,
            mode: cutout.mode ?? "device")
    }
}

extension HTTPCobaltClient: CutoutClient {
    public func makeCutout(of id: String, spec: CutoutSpec) async throws -> CutoutResult {
        struct Body: Encodable {
            var mode: String
            var color: String?
            var tolerance: Double?
            var edges_only: Bool?
            var soften: Int?
            var trim: Bool
            var title: String?
        }
        let manual = spec.mode != .auto
        let body = Body(
            mode: spec.mode.rawValue, color: spec.mode == .color ? spec.color : nil, tolerance: manual ? spec.tolerance : nil,
            edges_only: manual ? spec.edgesOnly : nil, soften: manual ? spec.soften : nil, trim: spec.trim, title: spec.title)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do { data = try encoder.encode(body) } catch { throw CutoutError.other("encode") }
        let req = try cutoutRequest(id, query: [], timeout: 90)
        return try await cutoutSend(req, body: data, contentType: "application/json")
    }

    public func uploadCutout(of id: String, png: Data, mode: CutoutMode, title: String?) async throws -> CutoutResult {
        var query = [("mode", mode.rawValue)]
        if let title { query.append(("title", title)) }
        let req = try cutoutRequest(id, query: query, timeout: 120)
        return try await cutoutSend(req, body: png, contentType: "image/png")
    }

    private func cutoutRequest(_ id: String, query: [(String, String)], timeout: TimeInterval) throws -> URLRequest {
        do {
            return try makeRequest("POST", "/library/items/\(Self.encode(id))/cutout", query: query, keyed: true, timeout: timeout)
        } catch {
            throw CutoutError.other("request")
        }
    }

    private func cutoutSend(_ request: URLRequest, body: Data, contentType: String) async throws -> CutoutResult {
        var req = request
        req.httpBody = body
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let answer: (Data, HTTPURLResponse)
        do {
            answer = try await send(req)
        } catch let e as CobaltError {
            if case .network = e { throw CutoutError.offline }
            throw CutoutError.other("network")
        }
        let (data, http) = answer
        guard (200..<300).contains(http.statusCode) else {
            struct Err: Decodable { struct E: Decodable { var code: String? }; var error: E? }
            let code = (try? JSONDecoder().decode(Err.self, from: data))?.error?.code ?? "http \(http.statusCode)"
            throw CutoutError(code: code, status: http.statusCode)
        }
        guard let wire = try? JSONDecoder().decode(CutoutWire.self, from: data) else { throw CutoutError.other("invalid response") }
        return wire.result
    }
}

extension PreviewClient: CutoutClient {
    public func makeCutout(of id: String, spec: CutoutSpec) async throws -> CutoutResult {
        editorState.record("POST /library/items/\(id)/cutout")
        return previewCutout(of: id, mode: spec.mode.rawValue, title: spec.title)
    }

    public func uploadCutout(of id: String, png: Data, mode: CutoutMode, title: String?) async throws -> CutoutResult {
        editorState.record("POST /library/items/\(id)/cutout png")
        return previewCutout(of: id, mode: mode.rawValue, title: title)
    }

    /// A new preview file the size of the picture (or 600 x 600), known to the preview editor from now on.
    private func previewCutout(of id: String, mode: String, title: String?) -> CutoutResult {
        let from = editorState.source(id)
        let base = title ?? "\(from?.shortName ?? "picture") cutout"
        let newID = "PrEvIeWcut" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6))
        let result = CutoutResult(
            id: newID, name: "\(base).png", title: base, width: from?.width ?? 600, height: from?.height ?? 600, mode: mode)
        var source = result.source
        source.posterURL = from?.posterURL
        editorState.addSource(source)
        return result
    }
}
