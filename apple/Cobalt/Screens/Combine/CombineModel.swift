import CobaltKit
import CoreGraphics
import Foundation
import Observation

/// What the combine sheet makes (the segmented control; the entry point picks the first).
enum CombineOutput: String, CaseIterable, Identifiable, Sendable {
    case slideshowWebp, slideshowMp4, galleryImage

    var id: String { rawValue }

    var label: String {
        switch self {
        case .slideshowWebp: return Copy.Gallery.slideshowWebp
        case .slideshowMp4: return Copy.Gallery.slideshowMp4
        case .galleryImage: return Copy.Gallery.galleryImage
        }
    }

    var symbol: String {
        switch self {
        case .slideshowWebp: return Symbol.Gallery.slideshowWebp
        case .slideshowMp4: return Symbol.Gallery.slideshowMp4
        case .galleryImage: return Symbol.Gallery.galleryImage
        }
    }

    var isSlideshow: Bool { self != .galleryImage }
    var format: SlideshowPlan.Format { self == .slideshowMp4 ? .mp4 : .webp }

    /// The word of "making the …" and "couldn't make the …": the board says `video` for the mp4.
    var what: String {
        switch self {
        case .slideshowWebp: return Copy.Gallery.slideshowWebp
        case .slideshowMp4: return "video"
        case .galleryImage: return Copy.Gallery.galleryImage
        }
    }

    var makeLabel: String {
        switch self {
        case .slideshowWebp: return Copy.Gallery.makeWebp
        case .slideshowMp4: return Copy.Gallery.makeMp4
        case .galleryImage: return Copy.Gallery.makeImage
        }
    }

    init(_ make: GalleryMake) {
        switch make {
        case .slideshow(let plan): self = plan.format == .webp ? .slideshowWebp : .slideshowMp4
        case .image: self = .galleryImage
        }
    }
}

/// A way out the sheet offers under a reason (board `Gallery-Combine`).
enum CombineWay: Equatable, Identifiable {
    /// "use 6.0 s a photo".
    case perPhoto(Double)
    /// "make the mp4 instead".
    case makeMp4

    var id: String {
        switch self {
        case .perPhoto(let s): return "per-photo-\(s)"
        case .makeMp4: return "mp4"
        }
    }

    var label: String {
        switch self {
        case .perPhoto(let s): return Copy.Gallery.usePerPhoto(Copy.Gallery.length(s))
        case .makeMp4: return Copy.Gallery.makeMp4Instead
        }
    }
}

/// Where the sheet reads its items and sends its make.
enum CombineSource {
    /// A media of the library or the store (the detail's `more › make from this post`, the library): the make goes to
    /// `AppModel.make(_:from:)`.
    case media(MediaItem)
    /// The gallery on the focus (`Pipeline.state == .gallery`): items follow the run, a make chosen mid-save waits for the
    /// save (R7).
    case run(Pipeline)
}

/// What the sheet shows for the make it asked for.
enum CombinePhase: Equatable {
    case edit
    /// Chosen mid-save (R7): runs when the save is ready.
    case afterSave(GalleryMake, done: Int, of: Int)
    case sending(GalleryMake)
    case queued(GalleryMake, ahead: Int)
    case making(GalleryMake, fraction: Double)
    case done(GalleryMake, MadeResult)
    case failed(GalleryMake, PipelineFailure)

    var isEdit: Bool { self == .edit }
}

/// The combine sheet's state: which items are ticked and in which order, the one slider, the toggles, and the make it sent
/// (observed through the run that carries it, so closing the sheet never stops a make). Everything the sheet shows
/// is computed here from CobaltKit's rules (`SlideshowPlan.check`, `GalleryGeometry`, `MakeEstimate`): the sheet
/// decides nothing the server would decide otherwise.
@MainActor
@Observable
final class CombineModel {
    let app: AppModel
    let source: CombineSource

    // MARK: what the owner chose

    var output: CombineOutput
    /// The play order. May hold an id the post has lost; `orderedIDs` is what is shown.
    private var order: [Int] = []
    /// Items left out (everything is ticked by default, and a new item arrives ticked).
    private(set) var unticked: Set<Int> = []
    var selected: Int?
    var seconds = SlideshowPlan.defaultPhotoSeconds
    var fade = true
    var frame: SlideshowPlan.Frame = .asPosted
    var sound: SlideshowPlan.Sound = .none
    var layout: GalleryLayout = .grid3

    // MARK: the make

    private var run: Pipeline?
    private var shown = false
    private(set) var sending = false
    private var sentMake: GalleryMake?
    private var sendFailure: PipelineFailure?
    /// What this sheet made since it opened: a "make another" replaces these too.
    private var madeHere: Set<MadeKind> = []
    /// The media's items and pictures are read once, on first use: a presenter may build this sheet again on every
    /// refresh of its own view, and only the first model is kept.
    @ObservationIgnored private lazy var mediaItems: [GalleryItem] = {
        if case .media(let media) = source { return app.galleryItems(of: media) }
        return []
    }()
    @ObservationIgnored private lazy var mediaPictures: [Int: [LibraryPictureSource]] = {
        if case .media(let media) = source { return Self.pictures(of: media) }
        return [:]
    }()
    @ObservationIgnored private lazy var existing: Set<MadeKind> = {
        switch source {
        case .media(let media): return Set(media.made.compactMap(\.madeKind))
        case .run(let pipeline): return Set(madeKinds(of: pipeline))
        }
    }()
    @ObservationIgnored private lazy var madeTabs: [String] = {
        switch source {
        case .media(let media): return media.made.map(\.tabName)
        case .run(let pipeline): return madeKinds(of: pipeline).map(\.tabName)
        }
    }()
    @ObservationIgnored private var madeTabsAdded: [String] = []

    init(app: AppModel, source: CombineSource, output: CombineOutput) {
        self.app = app
        self.source = source
        self.output = output
        switch source {
        case .media(let media):
            if let sid = Self.session(of: media), let job = app.queue.galleryJob(session: sid) { adopt(job.pipeline) }
        case .run(let pipeline):
            adopt(pipeline)
        }
    }

    private func madeKinds(of pipeline: Pipeline) -> [MadeKind] {
        guard let sid = pipeline.sessionID else { return [] }
        return app.store.videos.filter { $0.sessionID == sid }.compactMap(\.madeKind)
    }

    /// A make already in flight for this post (the sheet was closed and opened again): show it.
    private func adopt(_ pipeline: Pipeline) {
        guard let make = pipeline.galleryRun?.make, make.isActive, let request = make.request else { return }
        run = pipeline
        shown = true
        sentMake = request
        output = CombineOutput(request)
    }

    // MARK: title and counts

    var title: String {
        switch source {
        case .media(let media): return media.titleText
        case .run(let pipeline): return pipeline.runTitle ?? pipeline.media?.name ?? ""
        }
    }

    var countText: String {
        let photos = items.filter(\.isPhoto).count
        return Copy.Gallery.count(photos: photos, videos: items.count - photos)
    }

    // MARK: the items

    /// The post's items, in the post's order. A run's items that could not be fetched are not offered.
    var items: [GalleryItem] {
        switch source {
        case .media: return mediaItems
        case .run(let pipeline):
            let failures = pipeline.galleryRun?.failures ?? [:]
            return pipeline.galleryItems.filter { failures[$0.id] == nil }
        }
    }

    func item(_ id: Int) -> GalleryItem? { items.first { $0.id == id } }

    /// The ids in the order shown: the owner's order, then any item that arrived later.
    var orderedIDs: [Int] {
        let have = items.map(\.id)
        let known = Set(have)
        let kept = order.filter { known.contains($0) }
        return kept + have.filter { !kept.contains($0) }
    }

    func isTicked(_ id: Int) -> Bool { !unticked.contains(id) }

    /// A video or gif is skipped by the gallery image (R4).
    func isSkipped(_ id: Int) -> Bool { output == .galleryImage && item(id)?.isPhoto == false }

    /// The ticked items in play order, every type.
    var tickedIDs: [Int] { orderedIDs.filter(isTicked) }

    func toggle(_ id: Int) {
        if unticked.contains(id) { unticked.remove(id) } else { unticked.insert(id) }
    }

    /// Moves `id` to where `target` is now (the board's splice: out of its place, into the target's).
    func move(_ id: Int, onto target: Int) {
        var ids = orderedIDs
        guard id != target, let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: target) else { return }
        ids.remove(at: from)
        ids.insert(id, at: to)
        order = ids
        selected = id
    }

    /// `move earlier` / `move later` of the selected item.
    func shift(by delta: Int) {
        guard let id = selected else { return }
        var ids = orderedIDs
        guard let from = ids.firstIndex(of: id), ids.indices.contains(from + delta) else { return }
        ids.swapAt(from, from + delta)
        order = ids
    }

    var canMoveEarlier: Bool { selected.flatMap { orderedIDs.firstIndex(of: $0) }.map { $0 > 0 } ?? false }
    var canMoveLater: Bool { selected.flatMap { orderedIDs.firstIndex(of: $0) }.map { $0 < orderedIDs.count - 1 } ?? false }

    func select(_ id: Int) { selected = selected == id ? nil : id }

    func name(_ id: Int) -> String {
        Copy.Gallery.itemLabel(item(id)?.type ?? .photo, index: id)
    }

    // MARK: pictures

    /// Where an item's picture comes from, in order: this device's copy, the server's poster, the picker's thumb.
    func pictureSources(_ id: Int) -> [LibraryPictureSource] {
        switch source {
        case .media:
            return mediaPictures[id] ?? []
        case .run(let pipeline):
            var out: [LibraryPictureSource] = []
            if let sid = pipeline.sessionID, let stored = app.store.videos.first(where: { $0.role == .item && $0.sessionID == sid && $0.itemIndex == id }) {
                if item(id)?.isPhoto == true, let url = stored.fileURL, FileManager.default.fileExists(atPath: url.path) { out.append(.file(url)) }
                if let url = stored.posterURL { out.append(.file(url)) }
            }
            if let url = item(id)?.thumb { out.append(.image(url)) }
            return out
        }
    }

    private static func pictures(of media: MediaItem) -> [Int: [LibraryPictureSource]] {
        var out: [Int: [LibraryPictureSource]] = [:]
        for rendition in media.items {
            guard let index = rendition.itemIndex else { continue }
            var sources: [LibraryPictureSource] = []
            func add(_ source: LibraryPictureSource) { if !sources.contains(source) { sources.append(source) } }
            if rendition.itemType == .photo, let url = rendition.local?.fileURL, FileManager.default.fileExists(atPath: url.path) {
                add(.file(url))
            }
            if let url = rendition.local?.posterURL { add(.file(url)) }
            if let url = rendition.posterURL { add(.image(url)) }
            if rendition.itemType == .photo, let url = rendition.publicURL { add(.image(url)) }
            out[index] = sources
        }
        return out
    }

    private static func session(of media: MediaItem) -> String? {
        media.post?.session?.id ?? media.post?.id ?? media.local?.sessionIDs.first
    }

    // MARK: the plans

    func slideshowPlan(_ format: SlideshowPlan.Format) -> SlideshowPlan {
        var plan = SlideshowPlan.standard(format, items: tickedIDs, settings: app.settings)
        plan.photoSeconds = SlideshowPlan.snapped(seconds)
        plan.fade = fade
        plan.frame = frame
        if format == .mp4, hasVideoTicked { plan.sound = sound }
        return plan
    }

    var imagePlan: GalleryImagePlan { GalleryImagePlan(items: tickedIDs, layout: layout) }

    /// What `make` would send.
    var currentMake: GalleryMake {
        output.isSlideshow ? .slideshow(slideshowPlan(output.format)) : .image(imagePlan)
    }

    /// A video (not a gif) is ticked: the mp4 can carry its sound.
    var hasVideoTicked: Bool { tickedIDs.contains { item($0)?.type == .video } }
    var showsSound: Bool { output == .slideshowMp4 && hasVideoTicked }

    // MARK: the numbers

    var chosenItems: [GalleryItem] { slideshowPlan(output.format).chosen(from: items) }
    var length: Double { slideshowPlan(output.format).length(of: items) }
    var motionItems: [GalleryItem] { chosenItems.filter(\.isMotion) }

    /// "12.4 s + gif 3.2 s".
    var motionList: String {
        motionItems.map { ($0.type == .gif ? "gif " : "video ") + Copy.Gallery.length($0.duration ?? 0) }.joined(separator: " + ")
    }

    var frameSize: CGSize { MakeEstimate.frame(for: slideshowPlan(output.format), items: items) }

    func webpBytes(fade: Bool) -> Int64 {
        var plan = slideshowPlan(.webp)
        plan.fade = fade
        return MakeEstimate.webpBytes(items, plan: plan, frame: MakeEstimate.frame(for: plan, items: items))
    }

    var estimatedBytes: Int64 {
        switch output {
        case .slideshowWebp: return webpBytes(fade: fade)
        case .slideshowMp4:
            let plan = slideshowPlan(.mp4)
            return MakeEstimate.mp4Bytes(items, plan: plan, frame: frameSize)
        case .galleryImage: return canvas.map(MakeEstimate.jpegBytes) ?? 0
        }
    }

    var canvas: GalleryCanvas? { MakeEstimate.canvas(for: imagePlan, items: items) }

    /// The photos of the gallery image, in drawing order, and how many videos and gifs it leaves out.
    var imagePhotos: (photos: [GalleryItem], skipped: Int) { imagePlan.photos(in: items) }

    var serverText: String {
        let s = MakeEstimate.serverSeconds(currentMake, items: items)
        return s < 90 ? "\(max(1, Int(s.rounded()))) s" : "\(Int((s / 60).rounded())) min"
    }

    /// `length 20.0 s · about 1.8 MB · about 25 s on the server` (the mp4 adds its frame; the gallery image its size).
    var summary: String {
        switch output {
        case .slideshowWebp, .slideshowMp4:
            guard tickedIDs.count >= 2 else { return "nothing to make yet" }
            let size = Copy.Gallery.size(estimatedBytes)
            if output == .slideshowMp4 {
                let f = frameSize
                return "length \(Copy.Gallery.length(length)) · \(Int(f.width))×\(Int(f.height)) · about \(size) · about \(serverText) on the server"
            }
            return Copy.Gallery.summary(length: Copy.Gallery.length(length), size: size, server: serverText)
        case .galleryImage:
            guard let canvas else { return "nothing to make yet" }
            return "\(Copy.Gallery.imageMeta(canvas.width, canvas.height, Copy.Gallery.size(estimatedBytes))) · about \(serverText) on the server"
        }
    }

    // MARK: the caps

    struct Gate: Equatable {
        var reason: String?
        var ways: [CombineWay] = []
        var allowed: Bool { reason == nil }
    }

    /// Whether the server will take the make, and if not why and what the owner can do (`SlideshowPlan.check`).
    var gate: Gate {
        switch output {
        case .galleryImage:
            let photos = imagePhotos.photos.count
            return photos >= 2 ? Gate() : Gate(reason: Copy.Combine.needsTwo(photos: photos))
        case .slideshowWebp, .slideshowMp4:
            let plan = slideshowPlan(output.format)
            switch plan.check(items) {
            case .ok:
                return Gate()
            case .tooFew:
                return Gate(reason: Copy.Gallery.tickAtLeastTwo + ".")
            case .tooMuchVideo(let motion):
                return Gate(reason: Copy.Gallery.videosTooLong(Copy.Gallery.length(motion)))
            case .tooLong(let total, _, let fit):
                let len = Copy.Gallery.length(total)
                var ways: [CombineWay] = []
                if let fit { ways.append(.perPhoto(fit)) }
                if plan.format == .webp {
                    if slideshowPlan(.mp4).check(items).isOK { ways.append(.makeMp4) }
                    return Gate(reason: Copy.Gallery.webpTooLong(len) + (fit == nil ? Copy.Combine.evenHalfDoesNotFit : ""), ways: ways)
                }
                return Gate(reason: Copy.Gallery.mp4TooLong(len) + (fit == nil ? Copy.Combine.evenHalfDoesNotFit : ""), ways: ways)
            }
        }
    }

    func take(_ way: CombineWay) {
        switch way {
        case .perPhoto(let s): seconds = s
        case .makeMp4: output = .slideshowMp4
        }
    }

    /// "this replaces the slideshow webp you made before." when the post already has this output (R8).
    var replacesNote: String? {
        let kind: MadeKind
        switch currentMake {
        case .slideshow(let plan): kind = .slideshow(plan.format)
        case .image(let plan): kind = .galleryImage(plan.layout)
        }
        return existing.union(madeHere).contains(kind) ? Copy.Gallery.replacesPrevious(currentMake.what) : nil
    }

    // MARK: sending and following

    /// The make this sheet asked for, in the state its run reports.
    var phase: CombinePhase {
        guard let asked = sentMake else { return .edit }
        if let failure = sendFailure { return .failed(asked, failure) }
        if sending { return .sending(asked) }
        guard shown, let run, let make = run.galleryRun?.make else { return .edit }
        switch make {
        case .none: return .edit
        case .waiting(let m): return .afterSave(m, done: run.galleryRun?.done ?? 0, of: run.galleryRun?.total ?? 0)
        case .sending(let m): return .sending(m)
        case .queued(let m, let ahead): return .queued(m, ahead: ahead)
        case .making(let m, let progress): return .making(m, fraction: progress.fraction)
        case .done(let m, let result): return .done(m, result)
        case .failed(let m, let failure): return .failed(m, failure)
        }
    }

    var canMake: Bool { phase.isEdit && gate.allowed && !sending }

    func make() {
        guard canMake else { return }
        perform(currentMake)
    }

    /// "try again": the same plan, the settings untouched.
    func retry() {
        guard let asked = sentMake else { return }
        perform(asked)
    }

    private func perform(_ m: GalleryMake) {
        sentMake = m
        sendFailure = nil
        sending = true
        shown = true
        run = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                switch self.source {
                case .media(let media):
                    try await self.app.make(m, from: media)
                    if let sid = Self.session(of: media) { self.run = self.app.queue.galleryJob(session: sid)?.pipeline }
                case .run(let pipeline):
                    await pipeline.make(m)
                    self.run = pipeline
                }
                if self.run == nil { self.sendFailure = .server(code: "error.app.unknown") }
            } catch {
                self.sendFailure = (error as? PipelineFailure) ?? .server(code: "error.app.unknown")
            }
            self.sending = false
        }
    }

    /// `change settings` / `make another`: back to the editor with every setting as it was. A finished make joins the
    /// kinds a remake would replace.
    func backToEditing() {
        if case .done(let m, _) = phase {
            madeHere.insert(Self.kind(of: m))
            let tab = Self.kind(of: m).tabName
            if !madeTabs.contains(tab) && !madeTabsAdded.contains(tab) { madeTabsAdded.append(tab) }
        }
        shown = false
        sentMake = nil
        sendFailure = nil
    }

    static func kind(of make: GalleryMake) -> MadeKind {
        switch make {
        case .slideshow(let plan): return .slideshow(plan.format)
        case .image(let plan): return .galleryImage(plan.layout)
        }
    }

    // MARK: the result's names

    /// The tab and the file a made `m` lands as (`FolderNaming`: `slideshow.webp`, `slideshow.mp4`, `gallery image · 3 across.jpg`).
    static func names(of make: GalleryMake) -> (tab: String, file: String) {
        let kind = Self.kind(of: make)
        switch make {
        case .slideshow(let plan): return (kind.tabName, "slideshow.\(plan.format.rawValue)")
        case .image: return (kind.tabName, "\(kind.tabName).jpg")
        }
    }

    /// The tabs of this post so far, `photos` first.
    func tabsSoFar(adding tab: String) -> [String] {
        var tabs = madeTabs + madeTabsAdded
        if !tabs.contains(tab) { tabs.append(tab) }
        return [Copy.Gallery.photosTab(items.filter(\.isPhoto).count)] + tabs
    }

    /// The made file is kept on this device, so its place in Files (or the Mac's folder) is worth a line.
    var keepsOnDevice: Bool { app.settings.keepVideosOnDevice }
}
