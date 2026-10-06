import CobaltKit
import SwiftUI

// The focus for a pasted gallery (apple/CONTRACT-GALLERY.md 1.10, 1.11 and 5; board `Gallery-Paste`). A gallery saves
// everything the moment it is recognised, so the focus shows the hero at once: the cover with two card edges and the
// count badge, the title, `saving 4 of 10` with its bar, and under it a `make from it` row (slideshow webp, slideshow
// mp4, gallery image: each opens the combine sheet with that output chosen). When it is saved the card says where it
// went and that Photos has nothing; a partial save keeps what it got and offers `try photo 7 again`. A single photo is
// the same screen without the stack, the count and the make row.
//
// FocusView.swift decides when to use these (`FocusLayer.isGallery`); this file draws them.

// MARK: - the card edges

/// The two card edges behind a gallery's planet and hero: the same rounded rectangle, stepped up and to the right.
/// Drawn in the planet's own coordinates; the orbit's planets and the focus hero use the same step rule, so the hero
/// that lands in its slot and the planet that takes over wear the same stack.
struct CardEdges: View {
    let size: CGSize
    let radius: CGFloat
    let step: CGFloat

    /// How far the first edge sits from the planet, from the planet's short side (3 pt on a small planet, 8 on the hero).
    static func step(forShort short: CGFloat) -> CGFloat { min(8, max(3, short * 0.05)) }

    var body: some View {
        ZStack {
            edge(2, fill: GalleryTone.edgeBack)
            edge(1, fill: GalleryTone.edgeFront)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func edge(_ k: CGFloat, fill: Color) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(fill)
            .frame(width: size.width, height: size.height)
            .offset(x: step * k, y: -step * k)
    }
}

enum GalleryTone {
    static let edgeBack = Color(light: 0xd4d4da, dark: 0x3a3a40)
    static let edgeFront = Color(light: 0x9c9ca4, dark: 0x62626a)
}

// MARK: - the cover

/// Where a gallery's cover picture comes from: this device's copy of the first item, else the server's thumb of it.
struct GalleryCoverSource: Equatable {
    var file: URL?
    var remote: URL?
}

/// What the hero planet is told about a gallery.
struct GalleryHero: Equatable {
    /// The post's items; 2 or more draws the stack and the count.
    var count: Int
    var cover: GalleryCoverSource
}

/// The cover picture: the server's thumb underneath, this device's file over it once it decodes.
struct GalleryPicture: View {
    let source: GalleryCoverSource

    var body: some View {
        ZStack {
            if let remote = source.remote {
                AsyncImage(url: remote) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill().transition(.opacity)
                    } else {
                        Color.clear
                    }
                }
            }
            if let file = source.file { StillImage(url: file) }
        }
    }
}

// MARK: - what the focus knows about the run

/// The three things a gallery can be made into, in the order of the board's row.
enum GalleryMakeKind: String, Identifiable, CaseIterable {
    case webp, mp4, image

    var id: String { rawValue }

    var label: String {
        switch self {
        case .webp: return Copy.Gallery.slideshowWebp
        case .mp4: return Copy.Gallery.slideshowMp4
        case .image: return Copy.Gallery.galleryImage
        }
    }

    var symbol: String {
        switch self {
        case .webp: return Symbol.Gallery.slideshowWebp
        case .mp4: return Symbol.Gallery.slideshowMp4
        case .image: return Symbol.Gallery.galleryImage
        }
    }

    init(_ make: GalleryMake) {
        switch make {
        case .slideshow(let plan): self = plan.format == .webp ? .webp : .mp4
        case .image: self = .image
        }
    }
}

/// The words of a make in `making the …` and `couldn't make the …` (the board says `video` for the mp4).
private extension GalleryMake {
    var focusWhat: String {
        switch self {
        case .slideshow(let plan): return plan.format == .webp ? Copy.Gallery.slideshowWebp : "video"
        case .image: return Copy.Gallery.galleryImage
        }
    }

    /// The tab it becomes (CONTRACT-GALLERY 1.19): `slideshow webp`, `slideshow`, `gallery image · 3 across`.
    var focusTab: String {
        switch self {
        case .slideshow(let plan): return plan.format == .webp ? "slideshow webp" : "slideshow"
        case .image(let plan): return Copy.Gallery.galleryImageTab(plan.layout.label)
        }
    }

    /// The file it is kept as (CONTRACT-GALLERY 1.8): `slideshow.webp`, `gallery image · 3 across.jpg`.
    var focusFile: String {
        switch self {
        case .slideshow(let plan): return plan.format == .webp ? "slideshow.webp" : "slideshow.mp4"
        case .image(let plan): return "\(Copy.Gallery.galleryImageTab(plan.layout.label)).jpg"
        }
    }
}

/// Everything the gallery focus says, derived once per update from the pipeline and the store; plain values so the
/// rules can be read in one place.
@MainActor
struct GalleryFacts {
    let items: [GalleryItem]
    let run: GalleryRun
    let title: String
    let line: LinePosition?
    /// Where it was kept, when it was kept on this device ("Files › On My iPhone › cobalt › <title>").
    let place: String?
    /// The media is in this device's store, so its detail can open.
    let canOpen: Bool
    /// The server can make a slideshow or a gallery image (`features.gallery_make`).
    let canMake: Bool
    /// This run was started by `try photo 7 again`: its failures are being fetched anew, not left over from a save.
    let isRetry: Bool

    init(model: AppModel, pipeline: Pipeline, title: String) {
        self.isRetry = GalleryRetry.isMarked(pipeline)
        let items = pipeline.galleryItems
        let run = pipeline.galleryRun ?? GalleryRun(total: max(items.count, 1))
        self.items = items
        self.run = run
        self.title = title
        self.line = pipeline.line
        let stored = pipeline.mediaID.flatMap { model.store.media(id: $0) }
        self.canOpen = stored != nil
        self.canMake = model.capabilities.gallery && model.capabilities.galleryMake
        let kept = stored.map { !$0.items.isEmpty } ?? false
        self.place = kept ? Self.place(title: title, single: max(run.total, items.count) <= 1, model: model) : nil
    }

    /// "Files › On My iPhone › cobalt › instagram · Ddy0-gpGg5U" / "~/Movies/cobalt/instagram · Ddy0-gpGg5U".
    private static func place(title: String, single: Bool, model: AppModel) -> String? {
        #if os(macOS)
        let status = model.folderSync.status
        guard status.available, status.enabled else { return nil }
        return single ? status.path : "\(status.path)/\(title)"
        #else
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        let base = "Files › On My \(device) › cobalt"
        return single ? base : "\(base) › \(title)"
        #endif
    }

    var total: Int { max(run.total, items.count, 1) }
    var isSingle: Bool { total <= 1 }
    var isSaving: Bool { if case .saving = run.phase { return true } else { return false } }
    var isSaved: Bool { run.isSaved }
    var failed: [Int] { run.failures.keys.sorted() }
    var kept: Int { max(0, total - failed.count) }

    /// The items that were saved (the ones a make is built from).
    var savedItems: [GalleryItem] { items.filter { run.failures[$0.id] == nil } }
    private var photos: Int { items.filter(\.isPhoto).count }

    /// "10 photos", "2 photos + 2 videos"; a single photo reads "photo · jpg · 1200×1500".
    var countText: String {
        if isSingle {
            let item = items.first
            var parts = [item.map { $0.isPhoto ? "photo" : $0.type.rawValue } ?? "photo"]
            if let w = item?.width, let h = item?.height, w > 0, h > 0 { parts.append(Format.size(w, h)) }
            return parts.joined(separator: " · ")
        }
        return Copy.Gallery.count(photos: photos, videos: items.count - photos)
    }

    /// The step the save is on, as the owner counts it: the one being fetched ("saving 4 of 10").
    var savingStep: Int { min(total, run.done + 1) }
    var fraction: Double? { run.done > 0 ? min(1, Double(run.done) / Double(max(1, total))) : nil }

    /// "photo 7", "photos 2 and 7", "video 3, photo 7": the items that could not be fetched.
    var failedName: String {
        let indices = failed
        let types = Dictionary(items.map { ($0.id, $0.type) }, uniquingKeysWith: { first, _ in first })
        if indices.allSatisfy({ (types[$0] ?? .photo) == .photo }) { return Copy.Gallery.photoNames(indices) }
        return indices.map { Copy.Gallery.itemLabel(types[$0] ?? .photo, index: $0) }.joined(separator: ", ")
    }

    // MARK: make

    var makeIsActive: Bool { run.make.isActive }

    /// What a make tile says under its name, and whether it can be pressed at all.
    func tile(_ kind: GalleryMakeKind) -> (sub: String, warns: Bool, enabled: Bool) {
        let saved = savedItems
        let ids = saved.map(\.id)
        if let request = run.make.request, run.make.isActive, GalleryMakeKind(request) == kind {
            if case .waiting = run.make { return (GalleryFocusCopy.afterTheSave, false, false) }
            return (GalleryFocusCopy.makingNow, false, false)
        }
        switch kind {
        case .webp, .mp4:
            let plan = SlideshowPlan(format: kind == .webp ? .webp : .mp4, items: ids)
            switch plan.check(saved) {
            case .ok: return (Copy.Gallery.length(plan.length(of: saved)), false, !makeIsActive)
            case .tooFew: return (GalleryFocusCopy.needsTwo, false, false)
            case .tooLong(let length, _, _): return (Copy.Gallery.length(length), true, !makeIsActive)
            case .tooMuchVideo(let length): return (Copy.Gallery.length(length), true, !makeIsActive)
            }
        case .image:
            let plan = GalleryImagePlan(items: ids)
            guard plan.isPossible(in: saved) else { return (Copy.Gallery.needsTwoPhotos, false, false) }
            return (plan.layout.label, false, !makeIsActive)
        }
    }

    // MARK: the lines of the card

    enum Line: Equatable, Identifiable {
        case saving(String, fraction: Double?)
        case waiting(String, String)
        case retrying(String, String)
        case saved(String, String?)
        case partial(String, retry: String)
        case failed(String)
        case makeWaiting(String)
        case making(String, fraction: Double)
        case makeQueued(String, String)
        case madeDone(String, String?)
        case makeFailed(String)

        var id: String {
            switch self {
            case .saving, .waiting, .retrying, .saved, .partial, .failed: return "save"
            case .makeWaiting, .making, .makeQueued, .madeDone, .makeFailed: return "make"
            }
        }
    }

    /// The save's line, then the make's.
    func lines(lineMax: Int) -> [Line] {
        var out: [Line] = []
        switch run.phase {
        case .saving:
            if isRetry, !failed.isEmpty {
                out.append(.retrying(GalleryFocusCopy.fetchingAgain(failedName), GalleryFocusCopy.resolvesAnew))
            } else if let line, case .inLine(let place, let behind) = line {
                out.append(.waiting(Copy.Jobs.waiting, Copy.Jobs.lineDetail(place: place, behind: behind)))
            } else if let line, case .serverBusy(_, let label) = line {
                let what = label.flatMap { $0.isEmpty ? nil : $0 } ?? "a save that isn't in this list"
                out.append(.waiting(Copy.Jobs.waiting, "it's busy with \(what)"))
            } else {
                out.append(.saving(Copy.Gallery.saving(savingStep, of: total), fraction: fraction))
            }
        case .saved:
            let l1 = place.map { Copy.Gallery.savedTo($0) } ?? GalleryFocusCopy.savedToCobalt
            if failed.isEmpty {
                out.append(.saved(l1, Copy.Gallery.notInPhotos))
            } else {
                out.append(.partial(
                    Copy.Gallery.notFetched(failedName, kept: kept), retry: Copy.Gallery.tryItemAgain(failedName)))
            }
        case .failed(let f):
            out.append(.failed(TrayCopy.failure(f, lineMax: lineMax)))
        }
        switch run.make {
        case .none:
            break
        case .waiting(let m):
            out.append(.makeWaiting("\(m.focusWhat) · \(Copy.Gallery.afterTheSave(run.done, of: total))"))
        case .sending(let m):
            out.append(.making(Copy.Gallery.making(m.focusWhat, 0), fraction: 0))
        case .queued(let m, let ahead):
            out.append(.makeQueued("\(m.focusWhat) · \(Copy.Jobs.waiting)", Copy.Jobs.lineDetail(place: ahead + 1)))
        case .making(let m, let progress):
            let f = progress.fraction
            out.append(.making(Copy.Gallery.making(m.focusWhat, Int((f * 100).rounded())), fraction: f))
        case .done(let m, _):
            let file = place == nil ? nil : Copy.Gallery.inFiles("\(title)/\(m.focusFile)")
            out.append(.madeDone(Copy.Gallery.addedAsTab(m.focusTab), file))
        case .failed(let m, _):
            out.append(.makeFailed(Copy.Gallery.makeFailed(m.focusWhat)))
        }
        return out
    }
}

/// The runs that `try photo 7 again` started: their `failures` are what is being fetched anew.
@MainActor
enum GalleryRetry {
    private static var runs: Set<UUID> = []
    static func mark(_ pipeline: Pipeline) { runs.insert(pipeline.runID) }
    static func isMarked(_ pipeline: Pipeline) -> Bool { runs.contains(pipeline.runID) }
}

/// The few words the board has that `Copy.Gallery` does not (lowercase, as the board).
enum GalleryFocusCopy {
    static let savedToCobalt = "saved to cobalt · in your library"
    static let afterTheSave = "after the save"
    static let makingNow = "making"
    static let needsTwo = "needs 2"
    static let done = "done"
    static let makeAgainHint = "try again"
    static func fetchingAgain(_ name: String) -> String { "fetching \(name) again" }
    static let resolvesAnew = "cobalt resolves the post anew"
    static func openA11y(_ title: String) -> String { "open \(title)" }
    static func heroA11y(_ countText: String) -> String { countText }
}

// MARK: - the card under the hero

/// ONE grouped glass card under the gallery hero: the title and what is in it, then a line for the save and a line for
/// what is being made (the board's `saving 4 of 10` / `saved to cobalt · …` / the partial error / `making the slideshow webp`).
struct GalleryInfoCard: View {
    let facts: GalleryFacts
    let meta: String
    let lineMax: Int
    let lifted: Bool
    let retryItems: () -> Void
    let tryAgain: () -> Void
    let makeAgain: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let lines = facts.lines(lineMax: lineMax)
        VStack(spacing: 0) {
            VStack(spacing: 3) {
                Text(facts.title)
                    .font(CobaltType.bodySemibold)
                    .foregroundStyle(CobaltColor.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(meta)
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.caption)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .accessibilityElement(children: .combine)
            ForEach(lines) { line in
                Rectangle()
                    .fill(CobaltColor.hairline)
                    .frame(height: 1)
                    .padding(.horizontal, 14)
                    .accessibilityHidden(true)
                row(line)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: FocusLayer.columnWidth)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .opacity(lifted ? 1 : 0)
        .offset(y: lifted ? 0 : 14)
        .animation(reduceMotion ? Motion.fade : FocusMotion.content.delay(lifted ? 0.2 : 0), value: lifted)
        .animation(reduceMotion ? Motion.fade : Motion.rows, value: lines)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func row(_ line: GalleryFacts.Line) -> some View {
        switch line {
        case .saving(let text, let fraction):
            VStack(alignment: .leading, spacing: 8) {
                status(text)
                StoryBar(fraction: fraction, height: 4)
            }
            .accessibilityElement(children: .combine)
        case .waiting(let head, let detail):
            VStack(alignment: .leading, spacing: 6) {
                status(head)
                sub(detail)
                StoryBar(fraction: 0, height: 4)
            }
            .accessibilityElement(children: .combine)
        case .retrying(let text, let note):
            VStack(alignment: .leading, spacing: 6) {
                status(text)
                sub(note)
                StoryBar(fraction: nil, height: 4)
            }
            .accessibilityElement(children: .combine)
        case .saved(let text, let note), .madeDone(let text, let note):
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: Symbol.checkmark)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CobaltColor.success)
                        .accessibilityHidden(true)
                    Text(text)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let note { sub(note).padding(.leading, 20) }
            }
            .accessibilityElement(children: .combine)
        case .partial(let message, let retry):
            VStack(alignment: .leading, spacing: 8) {
                InlineStatus(message: message)
                Button(retry, systemImage: Symbol.Gallery.retry, action: retryItems)
                    .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                InlineStatus(message: message)
                Button(Copy.tryAgain, systemImage: Symbol.retry, action: tryAgain)
                    .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
            }
        case .makeWaiting(let text):
            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CobaltColor.caption)
                    .accessibilityHidden(true)
                status(text)
            }
            .accessibilityElement(children: .combine)
        case .making(let text, let fraction):
            VStack(alignment: .leading, spacing: 8) {
                status(text)
                StoryBar(fraction: fraction, height: 4)
            }
            .accessibilityElement(children: .combine)
        case .makeQueued(let head, let detail):
            VStack(alignment: .leading, spacing: 6) {
                status(head)
                sub(detail)
                StoryBar(fraction: 0, height: 4)
            }
            .accessibilityElement(children: .combine)
        case .makeFailed(let message):
            VStack(alignment: .leading, spacing: 8) {
                InlineStatus(message: message)
                Button(Copy.tryAgain, systemImage: Symbol.retry, action: makeAgain)
                    .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
            }
        }
    }

    private func status(_ text: String) -> some View {
        Text(text)
            .font(CobaltType.bodyMedium)
            .foregroundStyle(CobaltColor.text)
            .monospacedDigit()
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentTransition(reduceMotion ? .identity : .numericText())
    }

    private func sub(_ text: String) -> some View {
        Text(text)
            .font(CobaltType.captionSmall)
            .foregroundStyle(CobaltColor.caption)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - the make row and the buttons

/// `make from it`: the three outputs as glass tiles, each with its default length or layout under it; then `open`
/// (prominent once it is saved) and `done`.
struct GalleryControls: View {
    let facts: GalleryFacts
    let lifted: Bool
    let choose: (GalleryMakeKind) -> Void
    let open: () -> Void
    let done: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var offersMake: Bool { !facts.isSingle && !facts.run.isFailedPhase }

    var body: some View {
        VStack(spacing: FocusLayer.gap) {
            if offersMake { makeRow }
            buttons
        }
        .frame(maxWidth: FocusLayer.columnWidth)
        .opacity(lifted ? 1 : 0)
        .allowsHitTesting(lifted)
        .offset(y: lifted ? 0 : 20)
        .animation(reduceMotion ? Motion.fade : FocusMotion.content.delay(lifted ? 0.28 : 0), value: lifted)
    }

    private var caption: String {
        if case .done = facts.run.make { return Copy.Gallery.makeAnother }
        return Copy.Gallery.makeFromIt
    }

    private var makeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: Symbol.Gallery.make)
                    .font(.system(size: 11, weight: .medium))
                    .accessibilityHidden(true)
                Text(caption)
                    .font(CobaltType.captionSmall)
            }
            .foregroundStyle(CobaltColor.caption)
            .padding(.leading, 6)
            .accessibilityAddTraits(.isHeader)
            if facts.canMake {
                GlassEffectContainer(spacing: 8) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { ForEach(GalleryMakeKind.allCases) { tile($0, stacked: true) } }
                        VStack(spacing: 8) { ForEach(GalleryMakeKind.allCases) { tile($0, stacked: false) } }
                    }
                }
            } else {
                Text(Copy.Gallery.serverCantMake)
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.caption)
                    .padding(.leading, 6)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Gallery.makeFromIt)
    }

    private func tile(_ kind: GalleryMakeKind, stacked: Bool) -> some View {
        let t = facts.tile(kind)
        return Button { choose(kind) } label: {
            Group {
                if stacked {
                    VStack(spacing: 2) {
                        Image(systemName: kind.symbol).font(.system(size: 17, weight: .medium)).frame(height: 22)
                        label(kind, t.sub, warns: t.warns)
                    }
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: kind.symbol).font(.system(size: 17, weight: .medium)).frame(width: 26)
                        label(kind, t.sub, warns: t.warns, leading: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                }
            }
            .foregroundStyle(CobaltColor.text)
            .padding(.vertical, stacked ? 9 : 0)
            .frame(maxWidth: .infinity, minHeight: stacked ? 64 : 48)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!t.enabled)
        .opacity(t.enabled || kind == facts.run.make.request.map({ GalleryMakeKind($0) }) ? 1 : 0.5)
        .glassEffect(t.enabled ? .regular.interactive() : .regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityLabel("\(kind.label), \(t.sub)")
    }

    private func label(_ kind: GalleryMakeKind, _ sub: String, warns: Bool, leading: Bool = false) -> some View {
        VStack(alignment: leading ? .leading : .center, spacing: 1) {
            Text(kind.label)
                .font(Font.cobalt(11.5, .medium, relativeTo: .caption))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(sub)
                .font(Font.cobalt(10.5, .regular, relativeTo: .caption2))
                .foregroundStyle(warns ? CobaltColor.errorText : CobaltColor.caption)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var buttons: some View {
        // `open` is there from the start (the row does not jump when the first item lands), disabled until the media is
        // saved on this device; with nothing kept here (keep new saves offline is off) it has nowhere to open and goes.
        let ready = facts.isSaved && facts.canOpen
        return ButtonRow {
            if facts.canOpen || !facts.isSaved {
                if ready {
                    Button(Copy.Jobs.open, systemImage: "arrow.up.forward.square", action: open)
                        .buttonStyle(.cobaltPrimary())
                } else {
                    Button(Copy.Jobs.open, systemImage: "arrow.up.forward.square", action: open)
                        .buttonStyle(.cobaltSecondary())
                        .disabled(true)
                }
            }
            Button(GalleryFocusCopy.done, systemImage: Symbol.checkmark, action: done)
                .buttonStyle(.cobaltSecondary())
        }
    }
}

private extension GalleryRun {
    var isFailedPhase: Bool { if case .failed = phase { return true } else { return false } }
}
