import CobaltKit
import SwiftUI

/// The photos tab of a gallery (CONTRACT-GALLERY 1.19, owner decision 3, board `Gallery-Detail` B): one page at a time with
/// previous and next beside it, `3 / 10` over its corner, and a strip of thumbnails under it that scales to 20 items. A swipe,
/// the arrows, the strip and the left and right keys all move the same page. A page for an item that was never saved is the
/// photo's outline in red with `try photo 7 again` under it (the actions say it). One photo is the same page without arrows
/// or strip.
struct GalleryPager: View {
    let c: DetailContext
    var maxHeight: CGFloat = 340

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pages: [GalleryPage] { c.item.galleryPages }

    var body: some View {
        let pages = pages
        if let page = c.controller.currentPage(in: c.item) {
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    if pages.count > 1 { PagerArrow(direction: .previous, disabled: isFirst(page, in: pages)) { move(-1) } }
                    pageView(page, count: pages.count)
                    if pages.count > 1 { PagerArrow(direction: .next, disabled: isLast(page, in: pages)) { move(1) } }
                }
                if pages.count > 1 {
                    ThumbnailStrip(c: c, pages: pages, current: page.index)
                }
            }
            .background { arrowKeys }
            .onChange(of: c.item.missing) { _, missing in
                // a retried photo that now exists (or no longer fails) is no longer "fetching"
                c.controller.retrying.formIntersection(missing)
            }
        }
    }

    private func isFirst(_ page: GalleryPage, in pages: [GalleryPage]) -> Bool { pages.first?.index == page.index }
    private func isLast(_ page: GalleryPage, in pages: [GalleryPage]) -> Bool { pages.last?.index == page.index }

    private func move(_ delta: Int) {
        withAnimation(reduceMotion ? Motion.fade : Motion.card) { c.controller.movePage(delta, in: c.item) }
    }

    /// The aspect a missing page is drawn at: its neighbours' (a post's photos are almost always one shape).
    private var neighbourAspect: CGFloat {
        c.item.items.first(where: { $0.itemType == .photo })?.aspect ?? 4.0 / 5.0
    }

    @ViewBuilder
    private func pageView(_ page: GalleryPage, count: Int) -> some View {
        let position = (pages.firstIndex { $0.index == page.index } ?? 0) + 1
        Group {
            if let r = page.rendition {
                RenditionHero(rendition: r, item: c.item, maxHeight: maxHeight)
            } else {
                MissingHero(
                    index: page.index, aspect: neighbourAspect, maxHeight: maxHeight,
                    retrying: c.controller.retrying.contains(page.index))
            }
        }
        .id(page.index)
        .transition(.opacity)
        .overlay(alignment: .topLeading) {
            if count > 1 {
                DetailTypeBadge(label: "\(position) / \(count)").padding(8)
                    .accessibilityHidden(true)
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 28).onEnded { value in
                // a mostly horizontal swipe turns the page; a vertical drag is the form scrolling
                guard abs(value.translation.width) > abs(value.translation.height) * 1.6 else { return }
                move(value.translation.width < 0 ? 1 : -1)
            })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Gallery.itemName(
            page.rendition?.itemType.map { $0 == .photo ? "photo" : $0.rawValue } ?? "photo", page.index + 1, of: c.item.galleryTotal))
    }

    /// The left and right keys (the Mac, an iPad keyboard).
    private var arrowKeys: some View {
        VStack {
            Button("") { move(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { move(1) }.keyboardShortcut(.rightArrow, modifiers: [])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}

/// Previous and next: a small glass circle beside the page (the board's `ib sm`), 44 pt to hit.
struct PagerArrow: View {
    enum Direction { case previous, next }
    let direction: Direction
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: direction == .previous ? "chevron.left" : "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(CobaltColor.text)
                .frame(width: 30, height: 30)
                .modifier(PagerArrowSkin())
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .accessibilityLabel(direction == .previous ? "previous photo" : "next photo")
    }
}

private struct PagerArrowSkin: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content.background(.regularMaterial, in: Circle()).overlay(Circle().strokeBorder(CobaltColor.hairline, lineWidth: 1))
        #else
        content.glassEffect(.regular.interactive(), in: .circle)
        #endif
    }
}

// MARK: - the strip

/// Every page as a small picture, the shown one ringed; a missing one outlined in red with `!`. In `select photos` a tap
/// ticks instead of turning the page. It keeps the shown tile in view.
struct ThumbnailStrip: View {
    let c: DetailContext
    let pages: [GalleryPage]
    let current: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(pages) { page in
                        tile(page).id(page.index)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 3)
            }
            .scrollClipDisabled()
            .defaultScrollAnchor(.center)
            .onAppear { proxy.scrollTo(current, anchor: .center) }
            .onChange(of: current) { _, index in
                withAnimation(reduceMotion ? nil : Motion.chip) { proxy.scrollTo(index, anchor: .center) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("photos")
    }

    private func tile(_ page: GalleryPage) -> some View {
        let selecting = c.controller.selecting
        let ticked = c.controller.picked.contains(page.index)
        let isCurrent = page.index == current && !selecting
        return Button {
            if selecting {
                if !page.isMissing { c.controller.toggle(page.index) }
            } else {
                withAnimation(reduceMotion ? Motion.fade : Motion.card) { c.controller.selectPage(page.index, in: c.item) }
            }
        } label: {
            ThumbnailTile(page: page, total: c.item.galleryTotal)
                .frame(width: 44, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(isCurrent ? CobaltColor.text : Color.clear, lineWidth: 2)
                }
                .overlay(alignment: .topTrailing) {
                    if selecting, !page.isMissing {
                        Image(systemName: ticked ? Symbol.Gallery.ticked : Symbol.Gallery.unticked)
                            .font(.system(size: 17, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(ticked ? CobaltColor.onText : Color.white, ticked ? CobaltColor.text : Color.black.opacity(0.3))
                            .padding(2)
                    }
                }
                .opacity(selecting && !ticked && !page.isMissing ? 0.7 : 1)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label(page))
        .accessibilityAddTraits(isCurrent || (selecting && ticked) ? .isSelected : [])
    }

    private func label(_ page: GalleryPage) -> String {
        let name = Copy.Gallery.itemName(
            page.rendition?.itemType.map { $0 == .photo ? "photo" : $0.rawValue } ?? "photo", page.index + 1, of: c.item.galleryTotal)
        return page.isMissing ? "\(name), not saved" : name
    }
}

/// One thumbnail: the device's poster or the photo itself, else the server's poster, else a placeholder; a video or a gif has
/// its capsule; a page that was never saved is a red outline with `!`.
struct ThumbnailTile: View {
    let page: GalleryPage
    let total: Int

    var body: some View {
        ZStack {
            if let r = page.rendition {
                Rectangle().fill(FrameGradient.fill(FrameGradient.variant(forIndex: page.index)))
                picture(r)
                if r.isMotionItem {
                    HStack(spacing: 2) {
                        if r.itemType != .gif { Image(systemName: "play.fill").font(.system(size: 6)) }
                        Text(r.itemType == .gif ? "gif" : (r.duration.map { Format.seconds($0).replacingOccurrences(of: " ", with: "") } ?? ""))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                        .fixedSize()
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(CobaltColor.badgeInk)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(CobaltColor.badgeBack, in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(3)
                }
            } else {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(CobaltColor.errorText, lineWidth: 1.5)
                    .overlay {
                        Image(systemName: Symbol.Gallery.missing)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(CobaltColor.errorText)
                    }
            }
        }
    }

    @ViewBuilder
    private func picture(_ r: Rendition) -> some View {
        let fm = FileManager.default
        if let poster = r.local?.posterURL, fm.fileExists(atPath: poster.path) {
            StillImage(url: poster)
        } else if let file = r.local?.fileURL, r.isStillPicture, fm.fileExists(atPath: file.path) {
            StillImage(url: file)
        } else if let url = r.posterURL ?? (r.isStillPicture ? (r.publicURL ?? r.file?.url) : nil) {
            RemoteStill(poster: RemotePoster(url: HeroSource.resolve(url), isVideo: false), maxPixel: 200)
        }
    }
}
