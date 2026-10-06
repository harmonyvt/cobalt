import CobaltKit
import ImageIO
import SwiftUI

// The hero of a picture that is a still (CONTRACT-GALLERY 1.19-1.20): a photo item, a crop, an older single photo, and a
// gallery image (which scrolls inside its frame when it is a long strip). Always a picture at its own aspect: the file when
// the device holds it, else the server's public file, else the poster, with a small cloud badge for "not on this device".
// A tap opens the full-screen viewer (pinch and double-tap zoom).

// MARK: - where a picture comes from

/// What the viewer draws: the file on this device, the server's public file, or only a small poster. Pure, so the same
/// choice reaches the hero and the full-screen viewer.
enum PhotoSource: Equatable, Sendable {
    case file(URL)
    case remote(URL)
    case poster(URL)
    case none

    init(_ r: Rendition) {
        if let url = r.local?.fileURL, FileManager.default.fileExists(atPath: url.path) {
            self = .file(url)
        } else if let url = r.publicURL ?? r.file?.url {
            self = .remote(HeroSource.resolve(url))
        } else if let url = r.local?.posterURL.flatMap({ FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }) ?? r.posterURL {
            self = .poster(HeroSource.resolve(url))
        } else {
            self = .none
        }
    }

    var url: URL? {
        switch self {
        case .file(let url), .remote(let url), .poster(let url): return url
        case .none: return nil
        }
    }

    /// The full picture, not a thumbnail of it.
    var isFull: Bool {
        switch self {
        case .file, .remote: return true
        case .poster, .none: return false
        }
    }

    /// The device has the file.
    var isHere: Bool {
        if case .file = self { return true }
        return false
    }
}

/// Decodes pictures off the main thread at a size, with a cache of its own (`ImageLoader` keys by URL only, so a 360 px
/// poster would answer a 1400 px request). Bounded by decoded bytes.
actor PhotoDecoder {
    static let shared = PhotoDecoder()

    private final class Holder: Sendable {
        let box: ImageBox
        init(_ box: ImageBox) { self.box = box }
    }

    private let cache: NSCache<NSString, Holder> = {
        let c = NSCache<NSString, Holder>()
        c.totalCostLimit = 96 * 1024 * 1024
        return c
    }()

    func image(at url: URL, maxPixel: Int) -> ImageBox? {
        let key = "\(url.path)|\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) { return hit.box }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let box = ImageBox(image)
        cache.setObject(Holder(box), forKey: key, cost: max(1, image.bytesPerRow * image.height))
        return box
    }

    static func load(_ source: PhotoSource, maxPixel: Int) async -> ImageBox? {
        guard let url = source.url else { return nil }
        if url.isFileURL { return await shared.image(at: url, maxPixel: maxPixel) }
        return await LibraryPictureLoader.shared.picture(.image(url), maxPixel: maxPixel)
    }
}

/// A picture filling its frame (`fill`) or sitting whole in it. Reports the aspect it decoded, for a rendition whose size the
/// record does not carry.
struct PhotoSurface: View {
    let source: PhotoSource
    var maxPixel = 1400
    var fill = true
    @Binding var aspect: CGFloat?
    @State private var image: ImageBox?

    init(source: PhotoSource, maxPixel: Int = 1400, fill: Bool = true, aspect: Binding<CGFloat?> = .constant(nil)) {
        self.source = source
        self.maxPixel = maxPixel
        self.fill = fill
        self._aspect = aspect
    }

    var body: some View {
        // the picture is an overlay of a clear box, so it never changes the frame the hero's aspect gives (a `.fill` image
        // inside a stack would report its overflow as its size)
        Color.clear
            .overlay {
                ZStack {
                    Rectangle().fill(FrameGradient.fill(1))
                    if let image {
                        Image(decorative: image.image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: fill ? .fill : .fit)
                            .transition(.opacity)
                    }
                }
            }
            .clipped()
        .animation(.easeOut(duration: 0.25), value: image != nil)
        .task(id: source) {
            let loaded = await PhotoDecoder.load(source, maxPixel: maxPixel)
            guard !Task.isCancelled else { return }
            image = loaded
            if let loaded, loaded.image.height > 0 { aspect = CGFloat(loaded.image.width) / CGFloat(loaded.image.height) }
        }
    }
}

// MARK: - a photo

/// A photo, a crop or an older single photo: at its own aspect, at most `maxHeight` tall, the type capsule top right and
/// the full-screen button bottom right. A tap or a double-tap opens the viewer.
struct PhotoHero: View {
    let rendition: Rendition
    var item: MediaItem?
    var maxHeight: CGFloat = 360

    @State private var fullScreen: HeroFullScreen?
    @State private var decoded: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var source: PhotoSource { PhotoSource(rendition) }

    /// The record's own size, else what decoding found, else a portrait photo's.
    private var aspect: CGFloat {
        if let w = rendition.width, let h = rendition.height, w > 0, h > 0 { return CGFloat(w) / CGFloat(h) }
        return decoded ?? 4.0 / 5.0
    }

    private func open() {
        let source = source
        guard source != .none else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = reduceMotion
        withTransaction(transaction) {
            fullScreen = .photo(source: source, aspect: aspect, name: rendition.itemLabel ?? rendition.tabName)
        }
    }

    var body: some View {
        let source = source
        PhotoSurface(source: source, maxPixel: 1400, aspect: $decoded)
            .overlay(alignment: .bottomLeading) { if !source.isHere { NotHereBadge() } }
            .heroFrame(aspect: aspect, maxHeight: maxHeight, label: rendition.typeLabel, expand: source == .none ? nil : { open() })
            .contentShape(Rectangle())
            .onTapGesture { open() }
            .heroFullScreen(item: $fullScreen) { _ in }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Copy.Media.heroA11y(rendition.itemLabel ?? rendition.tabName, evicted: !source.isHere))
            .accessibilityAddTraits([.isImage, .isButton])
            .accessibilityHint(Copy.Media.fullScreen)
            #if DEBUG
            .task(id: source) {
                // `-previewHeroFullScreen 1` (simulator evidence): opens the viewer by itself, like the player's
                guard UserDefaults.standard.bool(forKey: "previewHeroFullScreen"), source != .none else { return }
                try? await Task.sleep(for: .seconds(2.5))
                open()
            }
            #endif
    }
}

/// The small cloud capsule on a picture the device does not hold.
struct NotHereBadge: View {
    var body: some View {
        Image(systemName: Symbol.offlineMissing)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(CobaltColor.badgeInk)
            .frame(width: 24, height: 24)
            .background(CobaltColor.badgeBack, in: Circle())
            .padding(8)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - a gallery image

/// The borderless picture made from the post. A strip or a grid is taller than the screen: it fits the width and scrolls
/// vertically inside its frame (the frame is as tall as `maxHeight` allows); `side by side` fits the height and scrolls
/// sideways; anything near square just fits. The full-screen button opens the zoomable viewer on the same file.
struct GalleryImageHero: View {
    let rendition: Rendition
    var maxHeight: CGFloat = 360

    @State private var width: CGFloat = 0
    @State private var decoded: CGFloat?
    @State private var fullScreen: HeroFullScreen?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var source: PhotoSource { PhotoSource(rendition) }

    private var aspect: CGFloat {
        if let w = rendition.width, let h = rendition.height, w > 0, h > 0 { return CGFloat(w) / CGFloat(h) }
        return decoded ?? 0.5
    }

    /// The frame and the picture inside it, from the width the row gives and the picture's shape.
    static func geometry(aspect: CGFloat, width: CGFloat, maxHeight: CGFloat) -> (frame: CGSize, content: CGSize, axis: Axis.Set) {
        guard width > 0, aspect > 0 else { return (CGSize(width: max(width, 1), height: 1), CGSize(width: max(width, 1), height: 1), []) }
        if aspect < 0.85 {                                           // tall: fit the width, scroll down
            let content = CGSize(width: width, height: width / aspect)
            return (CGSize(width: width, height: min(maxHeight, content.height)), content, .vertical)
        }
        if aspect > 1.2 {                                            // wide: fit the height, scroll across
            let h = min(maxHeight, 260)
            let content = CGSize(width: h * aspect, height: h)
            return (CGSize(width: min(width, content.width), height: h), content, .horizontal)
        }
        let w = min(width, maxHeight * aspect)
        let size = CGSize(width: w, height: w / aspect)
        return (size, size, [])
    }

    private func open() {
        let source = source
        guard source != .none else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = reduceMotion
        withTransaction(transaction) { fullScreen = .photo(source: source, aspect: aspect, name: rendition.tabName) }
    }

    var body: some View {
        let source = source
        let g = Self.geometry(aspect: aspect, width: width, maxHeight: maxHeight)
        Group {
            if g.axis.isEmpty {
                PhotoSurface(source: source, maxPixel: 2400, aspect: $decoded)
                    .frame(width: g.content.width, height: g.content.height)
            } else {
                ScrollView(g.axis, showsIndicators: true) {
                    PhotoSurface(source: source, maxPixel: 5000, aspect: $decoded)
                        .frame(width: g.content.width, height: g.content.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(width: g.frame.width, height: g.frame.height)
        .overlay(alignment: .bottomLeading) { if !source.isHere { NotHereBadge() } }
        .overlay(alignment: .topTrailing) { DetailTypeBadge(label: rendition.typeLabel).padding(8) }
        .overlay(alignment: .bottomTrailing) {
            if source != .none { HeroFullScreenButton { open() }.padding(2) }
        }
        .clipShape(RoundedRectangle(cornerRadius: Metrics.thumbRadius, style: .continuous))
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .heroFullScreen(item: $fullScreen) { _ in }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Media.heroA11y(rendition.tabName, evicted: !source.isHere))
        #if DEBUG
        .task(id: source) {
            guard UserDefaults.standard.bool(forKey: "previewHeroFullScreen"), source != .none else { return }
            try? await Task.sleep(for: .seconds(2.5))
            open()
        }
        #endif
    }
}

// MARK: - a page that was never saved

/// The pager's page for an item that could not be fetched: the picture's own shape, outlined in red, with the item's name.
struct MissingHero: View {
    let index: Int
    var aspect: CGFloat = 4.0 / 5.0
    var maxHeight: CGFloat = 360
    var retrying = false

    var body: some View {
        RoundedRectangle(cornerRadius: Metrics.thumbRadius, style: .continuous)
            .strokeBorder(CobaltColor.errorText, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                VStack(spacing: 8) {
                    if retrying {
                        ProgressView().controlSize(.regular)
                    } else {
                        Image(systemName: Symbol.Gallery.missing).font(.system(size: 26, weight: .regular))
                    }
                    Text(Copy.Gallery.itemLabel(.photo, index: index))
                        .font(Font.cobalt(13, .medium, relativeTo: .footnote))
                }
                .foregroundStyle(CobaltColor.errorText)
            }
            .frame(maxWidth: .infinity, maxHeight: maxHeight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(Copy.Gallery.itemLabel(.photo, index: index)), not saved")
    }
}
