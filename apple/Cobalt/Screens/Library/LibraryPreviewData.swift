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

extension LibraryPreviewData {
    /// A library with the new kinds in it (apple/CONTRACT-GALLERY.md 1.21, board `Library-Mixed`): the Instagram carousel of 10
    /// with a slideshow webp made from it (so its tile moves), a photo from Photos with a crop, the X post of 4, a mixed
    /// post (2 photos, a video, a gif) with a gallery image, a single photo from a link, and five videos and webps (older).
    /// `-previewLibraryKinds 1` shows these on any scenario; the library previews use them with `.galleryInstagram`.
    static func galleryRows(now: Date = Date()) -> [LibraryRow] {
        let ms = now.timeIntervalSince1970 * 1000
        func item(
            _ post: String, _ n: Int, type: String = "image/jpeg", ext: String = "jpg", w: Int, h: Int, d: Double? = nil, bytes: Int,
            at: Double, poster: URL, isPublic: Bool, deletable: Bool = false
        ) -> [String: Any] {
            var out = file(
                "\(post)-i\(n)", kind: "private", source: "saved", name: String(format: "%02d.\(ext)", n + 1),
                url: isPublic ? poster : nil, type: type, bytes: bytes, w: w, h: h, d: d ?? 0, at: at, poster: poster)
            out["role"] = "item"
            out["item_index"] = n
            out["visibility"] = isPublic ? "public" : "private"
            out["visibility_toggle"] = true
            return out
        }
        func made(_ id: String, role: String, spec: [String: Any], name: String, type: String, url: URL?, w: Int, h: Int, bytes: Int, at: Double, poster: URL) -> [String: Any] {
            var out = file(id, kind: "public", source: "studio", name: name, url: url, type: type, bytes: bytes, w: w, h: h, d: 0, at: at, poster: poster)
            out["role"] = role
            out["made_spec"] = spec
            out["visibility"] = url == nil ? "private" : "public"
            return out
        }
        func post(
            _ id: String, service: String, link: String?, title: String, kind: String, count: Int, w: Int, h: Int, at: Double,
            poster: URL, files: [[String: Any]], custom: String? = nil
        ) -> [String: Any] {
            var out: [String: Any] = [
                "id": id, "service": service, "title": title, "width": w, "height": h, "created_at": at, "files": files,
                "kind": kind, "item_count": count, "poster_url": poster.absoluteString,
            ]
            if let link { out["link"] = link }
            if let custom { out["custom_title"] = custom }
            return out
        }
        var json: [[String: Any]] = []

        // the Instagram carousel: 10 photos, public, with the slideshow webp made from it
        let g1 = "GALLERY01"
        let g1At = ms - 20 * 60_000
        var g1Files = (0..<10).map { n in
            item(g1, n, w: 1080, h: 1350, bytes: 380_000 + n * 11_000, at: g1At, poster: poster(n + 3), isPublic: true)
        }
        g1Files.append(made("\(g1)-slide", role: "slideshow", spec: ["format": "webp", "items": Array(0..<10)], name: "slideshow.webp",
                            type: "image/webp", url: animated, w: 480, h: 600, bytes: 1_760_000, at: g1At + 90_000, poster: poster(3)))
        json.append(post(g1, service: "instagram", link: "https://www.instagram.com/p/Ddy0-gpGg5U/", title: "instagram_Ddy0-gpGg5U",
                         kind: "gallery", count: 10, w: 1080, h: 1350, at: g1At, poster: poster(3), files: g1Files))

        // a photo from Photos with a 9:16 crop
        let p1 = "PHOTO0001"
        let p1At = ms - 45 * 60_000
        var p1File = file("\(p1)-src", kind: "private", source: "upload", name: "IMG_2207.jpg", url: nil, type: "image/jpeg", bytes: 2_600_000,
                          w: 3024, h: 4032, d: 0, at: p1At, poster: poster(4))
        p1File["visibility"] = "private"
        json.append(post(p1, service: "upload", link: nil, title: "IMG_2207.jpg", kind: "photo", count: 1, w: 3024, h: 4032, at: p1At,
                         poster: poster(4), files: [p1File,
                            made("\(p1)-crop", role: "crop", spec: ["aspect": "9:16", "fill": "blur"], name: "IMG_2207 · crop 9:16.jpg",
                                 type: "image/jpeg", url: nil, w: 1080, h: 1920, bytes: 410_000, at: p1At + 60_000, poster: poster(4))]))

        // the X post of 4, private
        let g2 = "GALLERY02"
        let g2At = ms - 3 * 3_600_000
        let g2Sizes = [(1200, 1500), (1500, 1200), (1200, 1200), (1200, 1500)]
        json.append(post(g2, service: "x", link: "https://x.com/ilokineedsleep/status/2106850389551374806", title: "x_2106850389551374806",
                         kind: "gallery", count: 4, w: 1200, h: 1500, at: g2At, poster: poster(5),
                         files: g2Sizes.enumerated().map { n, size in
                             item(g2, n, w: size.0, h: size.1, bytes: 260_000, at: g2At, poster: poster(n + 5), isPublic: false)
                         }))

        // a mixed post: 2 photos, a video, a gif, and a gallery image
        let g3 = "GALLERY03"
        let g3At = ms - 26 * 3_600_000
        var g3Files = [
            item(g3, 0, w: 1080, h: 1350, bytes: 300_000, at: g3At, poster: poster(6), isPublic: false),
            item(g3, 1, w: 1080, h: 1350, bytes: 310_000, at: g3At, poster: poster(7), isPublic: false),
            item(g3, 2, type: "video/mp4", ext: "mp4", w: 1080, h: 1350, d: 12.4, bytes: 3_100_000, at: g3At, poster: poster(8), isPublic: false),
            item(g3, 3, type: "image/gif", ext: "gif", w: 1080, h: 1350, d: 3.2, bytes: 900_000, at: g3At, poster: poster(9), isPublic: false),
        ]
        g3Files.append(made("\(g3)-img", role: "export", spec: ["kind": "gallery", "layout": "grid3"], name: "gallery image · 3 across.jpg",
                            type: "image/jpeg", url: nil, w: 2160, h: 1350, bytes: 1_900_000, at: g3At + 60_000, poster: poster(6)))
        json.append(post(g3, service: "instagram", link: "https://www.instagram.com/p/DdMix1xedPo/", title: "instagram_DdMix1xedPo",
                         kind: "gallery", count: 4, w: 1080, h: 1350, at: g3At, poster: poster(6), files: g3Files))

        // a single photo from a link, public
        let p2 = "PHOTO0002"
        let p2At = ms - 3 * 86_400_000
        json.append(post(p2, service: "instagram", link: "https://www.instagram.com/p/DbS1ngLePh0/", title: "instagram_DbS1ngLePh0",
                         kind: "photo", count: 1, w: 1080, h: 1080, at: p2At, poster: poster(1),
                         files: [item(p2, 0, w: 1080, h: 1080, bytes: 220_000, at: p2At, poster: poster(1), isPublic: true)]))

        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let posts = try? decoder.decode([LibraryPost].self, from: data) else { return rows(count: 5) }
        let gallery = posts.compactMap { MediaItem.merge(local: nil, post: $0) }.map { LibraryRow(item: $0) }
        return gallery + rows(count: 5)
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

    /// `-previewLibraryKinds 1`: the gallery fixtures (`LibraryPreviewData.galleryRows`) as the synthetic rows.
    static var kindsWanted: Bool { UserDefaults.standard.bool(forKey: "previewLibraryKinds") }

    /// `-previewLibraryCount N` (and `-previewLibraryFail 1`).
    static let launchRows: [LibraryRow] = {
        if kindsWanted { return LibraryPreviewData.galleryRows() }
        let count = UserDefaults.standard.integer(forKey: "previewLibraryCount")
        guard count > 0 else { return [] }
        return LibraryPreviewData.rows(count: count, failing: UserDefaults.standard.bool(forKey: "previewLibraryFail"))
    }()

    /// The model's rows, then the synthetic ones (older), filtered by the search text and the kind chip. When the model has
    /// no rows of its own (the gallery previews), or the sort is the kind order, all of them are sorted together.
    static func merged(
        _ real: [LibraryRow], with extra: [LibraryRow], query: String, kind: LibraryKindFilter = .all, sort: LibrarySort = .newest
    ) -> [LibraryRow] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var extra = q.isEmpty ? extra : extra.filter { $0.title.localizedStandardContains(q) }
        if kind != .all { extra = extra.filter { LibraryKindChips.filter(for: $0.kind) == kind } }
        // the kind order groups the model's rows and the synthetic ones together; any other sort leaves the model's rows first
        guard real.isEmpty || sort.key == .kind else { return real + extra }
        return (real + extra).sorted { a, b in
            let order: ComparisonResult
            switch sort.key {
            case .title: order = a.title.localizedStandardCompare(b.title)
            case .size: order = a.bytes < b.bytes ? .orderedAscending : (a.bytes > b.bytes ? .orderedDescending : .orderedSame)
            case .kind: order = a.kind.sortRank < b.kind.sortRank ? .orderedAscending : (a.kind.sortRank > b.kind.sortRank ? .orderedDescending : .orderedSame)
            default: order = a.date < b.date ? .orderedAscending : (a.date > b.date ? .orderedDescending : .orderedSame)
            }
            if order != .orderedSame { return sort.ascending ? order == .orderedAscending : order == .orderedDescending }
            return a.date > b.date
        }
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
