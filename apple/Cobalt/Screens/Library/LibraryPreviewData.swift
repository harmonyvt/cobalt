#if DEBUG
import CobaltKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Debug-only fixtures for the library's previews and simulator evidence. Synthetic posts (decoded from the same
/// JSON the server sends, so they take the real code path) with pictures drawn on first use into a temp folder:
/// a poster per post at the post's own aspect (the post's `poster_url` is that file), and one animated GIF that
/// stands in for every public webp (ImageIO animates it exactly like a webp). Nothing leaves the process.
///
///   -previewLibraryCount N   append N synthetic media to the library's rows (older than the preview fixture's)
///   -previewLibraryFail 1    one of them points at a picture that is not there (the failed tile)
///   -previewLibraryState S   empty | failed | loading: the screen shows that state, whatever the scenario holds
enum LibraryPreviewData {
    /// (width, height) of the faces, repeated.
    private static let dims: [(Int, Int)] = [
        (720, 1280), (1080, 1080), (1920, 1080), (480, 600), (1206, 2622), (720, 1280), (1080, 1350), (1280, 720),
    ]

    private static let folder: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cobalt-library-preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func color(hue: Double) -> CGColor {
        CGColor(red: 0.45 + 0.4 * cos(2 * .pi * hue), green: 0.45 + 0.4 * cos(2 * .pi * (hue + 1 / 3)),
                blue: 0.45 + 0.4 * cos(2 * .pi * (hue + 2 / 3)), alpha: 1)
    }

    /// A gradient with a disc, `width` pixels wide at `aspect` (height ÷ width).
    private static func image(width: Int, aspect: Double, hue: Double, shift: Double = 0) -> CGImage? {
        let height = max(1, Int((Double(width) * aspect).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let colors = [color(hue: hue), color(hue: hue + 0.18)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(
                gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: CGFloat(width), y: 0), options: [])
        }
        let radius = Double(min(width, height)) * 0.22
        context.setFillColor(CGColor(gray: 1, alpha: 0.35))
        context.fillEllipse(in: CGRect(
            x: Double(width) * (0.3 + 0.4 * shift) - radius, y: Double(height) * 0.5 - radius, width: radius * 2, height: radius * 2))
        return context.makeImage()
    }

    private static func write(_ image: CGImage, to url: URL, type: UTType = .jpeg) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    /// The poster of synthetic media `i` (drawn once).
    static func poster(_ i: Int) -> URL {
        let (w, h) = dims[i % dims.count]
        let url = folder.appendingPathComponent("poster-\(i % 24).jpg")
        if !FileManager.default.fileExists(atPath: url.path),
           let picture = image(width: 360, aspect: Double(h) / Double(w), hue: Double(i % 24) / 24) {
            write(picture, to: url)
        }
        return url
    }

    /// One animated GIF, three frames; stands in for every public webp.
    static let animated: URL = {
        let url = folder.appendingPathComponent("moving.gif")
        guard !FileManager.default.fileExists(atPath: url.path),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 3, nil)
        else { return url }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (n, hue) in [0.0, 0.33, 0.66].enumerated() {
            if let frame = image(width: 240, aspect: 16.0 / 9, hue: hue, shift: Double(n) / 2) {
                CGImageDestinationAddImage(destination, frame, [
                    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.35]] as CFDictionary)
            }
        }
        CGImageDestinationFinalize(destination)
        return url
    }()

    // MARK: posts

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            Date(timeIntervalSince1970: try decoder.singleValueContainer().decode(Double.self) / 1000)
        }
        return d
    }()

    private static func file(
        _ id: String, kind: String, source: String, name: String, url: URL?, type: String, bytes: Int, w: Int, h: Int,
        d: Double, at ms: Double, poster: URL?, deletable: Bool = false
    ) -> [String: Any] {
        var out: [String: Any] = [
            "id": id, "kind": kind, "source": source, "name": name, "content_type": type, "bytes": bytes,
            "width": w, "height": h, "duration": d, "created_at": ms, "deletable": deletable,
        ]
        if let url { out["url"] = url.absoluteString; out["media_name"] = url.lastPathComponent }
        if let poster { out["poster_url"] = poster.absoluteString }
        return out
    }

    /// `count` synthetic media, newest first, a day or more older than the preview fixture's newest.
    static func rows(count: Int, failing: Bool = false, now: Date = Date()) -> [LibraryRow] {
        var json: [[String: Any]] = []
        let base = now.timeIntervalSince1970 * 1000 - 2 * 86_400_000
        for i in 0..<count {
            let (w, h) = dims[i % dims.count]
            let id = String(format: "SYN%05d", i)
            let at = base - Double(i) * 2_700_000
            let d = 4 + Double((i * 7) % 40) / 2
            let kind = i % 6
            var poster: URL? = poster(i)
            if failing, i == 3 { poster = URL(fileURLWithPath: "/nonexistent/missing.jpg") }
            let isUpload = kind == 3
            let name = isUpload ? "IMG_\(4000 + i).mov" : "instagram_\(id)"
            var files: [[String: Any]] = []
            let pubVideo = file("\(id)-v", kind: "public", source: "host", name: name + ".mp4",
                                url: URL(string: "https://media.capybaraharmony.com/\(id).mp4"), type: "video/mp4",
                                bytes: 3_000_000 + i * 90_000, w: w, h: h, d: d, at: at, poster: poster)
            let privateCopy = file("\(id)-p", kind: "private", source: isUpload ? "upload" : "saved", name: name, url: nil,
                                   type: isUpload ? "video/quicktime" : "video/mp4", bytes: 3_000_000 + i * 90_000,
                                   w: w, h: h, d: d, at: at - 10_000, poster: kind == 1 ? nil : poster)
            func webp(_ n: Int) -> [String: Any] {
                file("\(id)-w\(n)", kind: "public", source: "studio", name: "\(name).webp", url: animated, type: "image/webp",
                     bytes: 900_000 + n * 300_000, w: min(w, 480), h: Int(Double(min(w, 480)) * Double(h) / Double(w)),
                     d: 5.4, at: at + Double(n) * 600_000, poster: nil, deletable: true)
            }
            switch kind {
            case 0: files = [pubVideo, privateCopy] + (0..<(1 + i % 3)).map(webp)       // video + webps
            case 1: files = [privateCopy]                                                // private only, no picture
            case 2: files = [pubVideo, privateCopy]                                      // video face with a poster
            case 3: files = [pubVideo, privateCopy]                                      // an upload
            case 4: files = [webp(0)]                                                    // a webp and nothing else
            default: files = [pubVideo, privateCopy, webp(0)]
            }
            var post: [String: Any] = [
                "id": id, "service": isUpload ? "upload" : (i % 2 == 0 ? "instagram" : "x"), "title": name,
                "duration": d, "width": w, "height": h, "created_at": at, "files": files,
            ]
            if !isUpload { post["link"] = "https://www.instagram.com/reel/\(id)/" }
            if let poster, kind != 1 { post["poster_url"] = poster.absoluteString }
            if isUpload, i % 12 == 3 { post["custom_title"] = "pinch and drag, take \(i / 12 + 1)" }
            json.append(post)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let posts = try? decoder.decode([LibraryPost].self, from: data) else { return [] }
        return posts.compactMap { MediaItem.merge(local: nil, post: $0) }.map { LibraryRow(item: $0) }
    }
}

enum LibraryDebug {
    /// `-previewLibraryState empty|failed|loading`: the library shows that state with no rows, whatever the
    /// scenario holds, and does not load.
    static let state: LibraryProblemState? = {
        switch UserDefaults.standard.string(forKey: "previewLibraryState") {
        case "empty": return .empty
        case "failed": return .failed
        case "loading": return .loading
        default: return nil
        }
    }()

    /// `-previewLibraryCount N` (and `-previewLibraryFail 1`).
    static let launchRows: [LibraryRow] = {
        let count = UserDefaults.standard.integer(forKey: "previewLibraryCount")
        guard count > 0 else { return [] }
        return LibraryPreviewData.rows(count: count, failing: UserDefaults.standard.bool(forKey: "previewLibraryFail"))
    }()

    /// The model's rows, then the synthetic ones (older), filtered by the search text.
    static func merged(_ real: [LibraryRow], with extra: [LibraryRow], query: String) -> [LibraryRow] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let extra = q.isEmpty ? extra : extra.filter { $0.title.localizedStandardContains(q) }
        return real + extra
    }
}

private struct LibraryDebugRowsKey: EnvironmentKey {
    static var defaultValue: [LibraryRow] { LibraryDebug.launchRows }
}

extension EnvironmentValues {
    /// Synthetic rows a preview adds under the model's own.
    var libraryDebugRows: [LibraryRow] {
        get { self[LibraryDebugRowsKey.self] }
        set { self[LibraryDebugRowsKey.self] = newValue }
    }
}
#endif
