import CobaltKit
import SwiftUI

// The pieces the mosaic, the table and the list share: the row's words, the face's picture and its
// thumbnail, the title in two inks.

/// Words the library says about a row. Kept here so the screen never edits the shared `Copy.swift`;
/// lowercase, like everything else.
enum LibraryRowCopy {
    /// "instagram Dd7P496wolG": the title without its separator dot, for VoiceOver.
    static func spoken(_ row: LibraryRow) -> String {
        row.title.replacingOccurrences(of: " · ", with: " ")
    }

    /// "14.8 s": a row's length; "—" when unknown.
    static func length(_ row: LibraryRow) -> String {
        row.length > 0 ? Format.seconds(row.length) : "—"
    }

    /// "720×1280"; "—" when unknown.
    static func resolution(_ row: LibraryRow) -> String {
        guard let w = row.width, let h = row.height, w > 0, h > 0 else { return "—" }
        return Format.size(w, h)
    }

    /// "12.8 MB": every file of the post; "—" when none has a size.
    static func size(_ row: LibraryRow) -> String {
        row.bytes > 0 ? Format.bytes(row.bytes) : "—"
    }

    /// "video + webp ×3", "image", "webp ×2".
    static func files(_ row: LibraryRow) -> String {
        Copy.Library2.files(
            original: row.hasVideo ? (row.originalIsImage ? .image : .video) : nil, webps: row.webps)
    }

    /// The service cell: `instagram`, `x`, `file` for an upload.
    static func service(_ row: LibraryRow) -> String {
        row.isUpload ? Copy.Library2.serviceFile : row.service
    }

    static func visibility(_ row: LibraryRow) -> String {
        row.isPublic ? Copy.Library2.isPublic : Copy.Library2.isPrivate
    }

    /// "14.8 s · 720×1280 · 12.8 MB · today 21:04": the two-line row's second line (unknown parts are left out).
    static func meta(_ row: LibraryRow, now: Date) -> String {
        var parts: [String] = []
        if row.length > 0 { parts.append(length(row)) }
        if row.pixels > 0 { parts.append(resolution(row)) }
        if row.bytes > 0 { parts.append(size(row)) }
        parts.append(Format.when(row.date, now: now))
        return parts.joined(separator: " · ")
    }

    /// The face's type: `webp`, `webp ×3`, or the video face's container (`mp4`, `mov`, `gif`, `png`).
    static func type(_ row: LibraryRow) -> String {
        let item = row.item
        if item.face.isWebp { return Copy.Media.webpCount(row.webps) }
        let video = item.video
        for contentType in [video?.file?.contentType, video?.hosted?.contentType] {
            guard let contentType = contentType?.lowercased() else { continue }
            switch contentType {
            case "video/quicktime": return "mov"
            case "video/mp4": return "mp4"
            case "image/gif": return "gif"
            case "image/png": return "png"
            case "image/jpeg": return "jpg"
            case "image/heic", "image/heif": return "heic"
            case "image/webp": return "webp"
            default: break
            }
        }
        let name = video?.local?.name ?? video?.file?.name ?? ""
        let ext = (name as NSString).pathExtension.lowercased()
        if !ext.isEmpty, ext.count <= 4 { return ext }
        return row.originalIsImage ? "photo" : "mp4"
    }

    /// The type's symbol, for a tile too narrow for its word.
    static func typeSymbol(_ row: LibraryRow) -> String {
        if row.item.face.isWebp { return Symbol.Library.typeWebp }
        return row.originalIsImage ? Symbol.Library.typePhoto : Symbol.Library.typeVideo
    }
}

// MARK: - the picture

/// Where a face's picture comes from, in order (CONTRACT-LIBRARY2 decision 12). A video face: this device's
/// poster, the server's `poster_url`, the first frame of the hosted mp4. A webp face (the server makes no webp
/// posters): this device's poster, the first frame of the public webp, then the video's poster as a stand-in
/// at the wrong crop (the device's own, then the server's). Empty = nothing to show: the grey frame.
enum FaceChain {
    static func sources(for item: MediaItem) -> [LibraryPictureSource] {
        var out: [LibraryPictureSource] = []
        func add(_ source: LibraryPictureSource) { if !out.contains(source) { out.append(source) } }
        let face = item.face
        if let url = face.local?.posterURL { add(.file(url)) }
        if face.isWebp {
            if let url = face.publicURL ?? item.webps.last(where: { $0.publicURL != nil })?.publicURL { add(.image(url)) }
            if let url = item.video?.local?.posterURL { add(.file(url)) }
            if let url = item.video?.posterURL ?? item.post?.posterURL { add(.image(url)) }
        } else {
            if let url = face.posterURL ?? item.post?.posterURL { add(.image(url)) }
            if let hosted = item.video?.hosted, let url = hosted.url {
                if hosted.contentType?.lowercased().hasPrefix("image/") == true { add(.image(url)) } else { add(.videoFrame(url)) }
            } else if let url = face.publicURL {
                add(.videoFrame(url))
            }
            if let url = item.local?.renditions.compactMap(\.posterURL).first { add(.file(url)) }
        }
        return out
    }
}

/// A face's picture, filling its frame: the first source of the chain that loads. Decoded off the main thread
/// at `maxPixel` and cached. No source at all leaves the grey frame; every source failing shows the glyph
/// (and `failed` says so, for VoiceOver); it tries again when the view comes back, and on `reload`.
struct FacePicture: View {
    let item: MediaItem
    let maxPixel: Int
    var reload = 0
    var showsGlyph = true
    var glyphSize: CGFloat = 26
    var gradient = 0
    @Binding var failed: Bool
    @State private var image: ImageBox?

    init(
        item: MediaItem, maxPixel: Int, reload: Int = 0, showsGlyph: Bool = true, glyphSize: CGFloat = 26,
        gradient: Int = 0, failed: Binding<Bool> = .constant(false)
    ) {
        self.item = item
        self.maxPixel = maxPixel
        self.reload = reload
        self.showsGlyph = showsGlyph
        self.glyphSize = glyphSize
        self.gradient = gradient
        _failed = failed
        // a picture this device already decoded is there in the first frame (no grey flash on scrolling back)
        _image = State(initialValue: LibraryPictureCache.shared.first(in: FaceChain.sources(for: item), maxPixel: maxPixel))
    }

    private struct LoadKey: Hashable {
        let chain: [LibraryPictureSource]
        let maxPixel: Int
        let reload: Int
    }

    var body: some View {
        let chain = FaceChain.sources(for: item)
        Rectangle()
            .fill(FrameGradient.fill(gradient))
            .overlay {
                if let image {
                    Image(decorative: image.image, scale: 1).resizable().scaledToFill().transition(.opacity)
                } else if failed && showsGlyph {
                    Image(systemName: Symbol.Library.pictureFailed)
                        .font(.system(size: glyphSize, weight: .regular))
                        .foregroundStyle(CobaltColor.badgeInk.opacity(0.6))
                        .accessibilityHidden(true)
                }
            }
            .clipped()
            .animation(.easeOut(duration: 0.2), value: image != nil)
            .task(id: LoadKey(chain: chain, maxPixel: maxPixel, reload: reload)) {
                guard !chain.isEmpty else {
                    image = nil
                    failed = false
                    return
                }
                if image == nil || reload > 0 { failed = false }
                for source in chain {
                    let box = await LibraryPictureLoader.shared.picture(source, maxPixel: maxPixel)
                    if Task.isCancelled { return }
                    if let box {
                        image = box
                        failed = false
                        return
                    }
                }
                image = nil
                failed = true
            }
    }
}

/// A square holding the face at its own aspect (a thumbnail in a row): the picture inside a rounded box.
struct LibraryThumb: View {
    let row: LibraryRow
    let side: CGFloat
    var reload = 0
    var maxPixel = 160

    private var box: CGSize {
        let aspect = MasonryPlan.clampAspect(row.faceAspect)
        // width / height = 1 / aspect: the long side fills the square
        return aspect >= 1
            ? CGSize(width: (side / aspect).rounded(), height: side)
            : CGSize(width: side, height: (side * aspect).rounded())
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: side > 30 ? 8 : 5, style: .continuous).fill(CobaltColor.elevated)
            FacePicture(item: row.item, maxPixel: maxPixel, reload: reload, showsGlyph: false, gradient: 1)
                .frame(width: box.width, height: box.height)
                .clipShape(RoundedRectangle(cornerRadius: side > 30 ? 5 : 3, style: .continuous))
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

// MARK: - the title

/// A row's title in two inks: a link save is the service in the primary ink and `· ref` in the caption's; an
/// upload or a custom title is one ink.
struct LibraryTitleText: View {
    let row: LibraryRow
    var size: CGFloat = 12.5
    var weight: CobaltFont.Weight = .semibold

    var body: some View {
        switch row.item.title {
        case .post(let service, let ref):
            let head = Text(service).font(Font.cobalt(size, weight, relativeTo: .body)).foregroundStyle(.primary)
            let tail = Text(ref.map { " · \($0)" } ?? "").font(Font.cobalt(size, .regular, relativeTo: .body)).foregroundStyle(.secondary)
            Text("\(head)\(tail)").lineLimit(1).truncationMode(.middle)
        default:
            Text(row.title)
                .font(Font.cobalt(size, weight, relativeTo: .body))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// The `webp ×3` capsule and the public-link dot of a list row.
struct LibraryRowBadges: View {
    let row: LibraryRow

    var body: some View {
        HStack(spacing: 6) {
            if row.webps > 0 {
                Text(Copy.Media.webpCount(row.webps))
                    .font(Font.cobalt(9.5, .medium, relativeTo: .caption2))
                    .foregroundStyle(CobaltColor.onText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(CobaltColor.text))
                    .fixedSize()
            }
            Image(systemName: row.isPublic ? Symbol.Library.isPublic : Symbol.Library.isPrivate)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }
}
