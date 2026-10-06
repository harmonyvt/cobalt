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

/// The `webp ×3` capsule, the offline mark and the public-link dot of a list row.
struct LibraryRowBadges: View {
    let row: LibraryRow
    let model: AppModel

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
            OfflineBadge(item: row.item, model: model, style: .row)
            Image(systemName: row.isPublic ? Symbol.Library.isPublic : Symbol.Library.isPrivate)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - offline (CONTRACT-OFFLINE decision 11)

/// What the library draws for one media's offline state. `none` and `cached` draw nothing, so the default stays
/// quiet: the cache is plumbing, and a file that may leave on its own is not "offline".
enum OfflineMark: Equatable {
    case quiet
    case partly
    case kept
    /// A download is running; the fraction is nil while the total is unknown.
    case downloading(Double?)
    /// Queued, with no network yet.
    case waiting
    case failed

    /// A download beats a failure, a failure beats a wait, and a wait beats the settled state.
    @MainActor
    init(item: MediaItem, model: AppModel) {
        let state = model.offlineState(of: item)
        let each = item.renditions.map { model.offlineState(of: $0) }
        // the item's `downloading` is also set while a rendition only waits, so look at the renditions
        let running = each.contains { if case .downloading = $0 { return true } else { return false } }
        if running, let progress = state.downloading {
            self = .downloading(OfflineWords.fraction(progress))
        } else if state.failed {
            self = .failed
        } else if each.contains(.waiting) {
            self = .waiting
        } else {
            switch state.offline {
            case .all: self = .kept
            case .some: self = .partly
            case .none: self = .quiet
            }
        }
    }

    var isVisible: Bool { self != .quiet }

    /// The glyph of the settled states; the ring (a download) and the wait draw their own.
    var symbol: String? {
        switch self {
        case .kept: return Symbol.offlineAll
        case .partly: return Symbol.offlineSome
        case .failed: return Symbol.offlineFailed
        case .waiting: return Symbol.offlineWaiting
        case .quiet, .downloading: return nil
        }
    }

    /// VoiceOver: `offline`, `partly offline`, `downloading, 40 percent`, `couldn't download`.
    var spoken: String? {
        switch self {
        case .quiet: return nil
        case .kept: return Copy.Offline.a11yAll
        case .partly: return Copy.Offline.a11ySome
        case .failed: return Copy.Offline.a11yFailed
        case .waiting: return Copy.Offline.a11yWaiting
        case .downloading(let fraction): return Copy.Offline.a11yDownloading(percent: fraction.map { Int(($0 * 100).rounded()) })
        }
    }

    /// The table cell's word.
    var cell: String? {
        switch self {
        case .quiet: return nil
        case .kept: return Copy.Offline.cellAll
        case .partly: return Copy.Offline.cellSome
        case .failed: return Copy.Offline.cellFailed
        case .waiting: return Copy.Offline.cellWaiting
        case .downloading(let fraction): return fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? Copy.Offline.cellWaiting
        }
    }
}

/// A determinate ring: the track, and the part done from 12 o'clock. With no total a quarter turn, still.
struct OfflineRing: View {
    let fraction: Double?
    let size: CGFloat
    let ink: Color

    var body: some View {
        ZStack {
            Circle().stroke(ink.opacity(0.3), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.04, fraction ?? 0.25))
                .stroke(ink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The offline badge of a media: on a tile a 20 pt dark disc beside the link dot (the same family as the other
/// badges), in a list row a quiet glyph, and nothing at all while nothing is kept. The download is a 14 pt ring.
/// A view of its own so a progress tick redraws this and not the tile.
struct OfflineBadge: View {
    enum Style { case tile, row }

    let item: MediaItem
    let model: AppModel
    var style: Style = .tile

    var body: some View {
        let mark = OfflineMark(item: item, model: model)
        if model.store.canKeep, mark.isVisible {
            switch style {
            case .tile: tile(mark)
            case .row: row(mark)
            }
        }
    }

    private func tile(_ mark: OfflineMark) -> some View {
        glyph(mark, size: 14, ink: mark == .failed ? Self.failedInk : CobaltColor.badgeInk)
            .frame(width: 20, height: 20)
            .background(CobaltColor.badgeBack, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.75))
    }

    private func row(_ mark: OfflineMark) -> some View {
        glyph(mark, size: 12, ink: mark == .failed ? CobaltColor.errorText : Color.secondary)
    }

    @ViewBuilder
    private func glyph(_ mark: OfflineMark, size: CGFloat, ink: Color) -> some View {
        if case .downloading(let fraction) = mark {
            OfflineRing(fraction: fraction, size: size, ink: ink)
        } else if let symbol = mark.symbol {
            Image(systemName: symbol).font(.system(size: size, weight: .regular)).foregroundStyle(ink)
        }
    }

    /// Light red that holds on the badge's dark disc in either appearance.
    private static let failedInk = Color(hex: 0xff5c6c)
}

/// The table's `offline` cell: the badge's glyph and a word, empty while nothing is kept.
struct OfflineCell: View {
    let item: MediaItem
    let model: AppModel

    var body: some View {
        let mark = OfflineMark(item: item, model: model)
        if model.store.canKeep, let word = mark.cell {
            HStack(spacing: 5) {
                OfflineBadge(item: item, model: model, style: .row)
                Text(word)
                    .font(CobaltType.caption)
                    .foregroundStyle(mark == .failed ? CobaltColor.errorText : Color.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(mark.spoken ?? word)
        }
    }
}

/// The confirm of "remove offline copy" from a context menu (a menu cannot hold a dialog, so the tile, the list
/// and the table do): the server keeps a copy, or the file here is the only one.
struct OfflineRemoveConfirm: ViewModifier {
    @Binding var item: MediaItem?
    let model: AppModel

    private func onlyCopy(_ item: MediaItem?) -> Bool {
        item?.renditions.contains { rendition in
            if case .offline = model.offlineState(of: rendition) { return model.isOnlyCopy(rendition) }
            return false
        } ?? false
    }

    func body(content: Content) -> some View {
        content.confirmationDialog(
            OfflineWords.removeTitle(onlyCopy: onlyCopy(item)),
            isPresented: Binding(get: { item != nil }, set: { if !$0 { item = nil } }),
            titleVisibility: .visible, presenting: item
        ) { asked in
            Button(Copy.remove, role: .destructive) { Task { await model.removeOfflineCopy(asked) } }
            Button(Copy.keep, role: .cancel) {}
        } message: { asked in
            Text(OfflineWords.removeMessage(onlyCopy: onlyCopy(asked)))
        }
    }
}

extension View {
    func offlineRemoveConfirm(_ item: Binding<MediaItem?>, model: AppModel) -> some View {
        modifier(OfflineRemoveConfirm(item: item, model: model))
    }
}

#if DEBUG
// The offline badge and column on `AppModel.preview(.offline)`: one media kept, one partly, one downloading at 40 %,
// one that failed, one waiting.
#Preview("library · offline, mosaic", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.offline, tab: .library) { model in
        NavigationStack { LibraryScreen(model: model, tier: .compact) }
    }
}
#Preview("library · offline, list", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.offline, tab: .library) { model in
        let _ = { model.library.viewMode = .table }()
        NavigationStack { LibraryScreen(model: model, tier: .compact) }
    }
}
#Preview("library · offline, table", traits: .fixedLayout(width: 1100, height: 700)) {
    PreviewHost(.offline, tab: .library) { model in
        let _ = { model.library.viewMode = .table }()
        LibraryScreen(model: model, tier: .regular)
    }
}
#endif
