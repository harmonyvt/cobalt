import CobaltKit
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// What a dragged tile carries: the item's index in the post. Only this strip takes it.
struct CombineDrag: Codable, Transferable {
    var id: Int

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

/// Every item of the post in play order, as a strip (apple/CONTRACT-GALLERY.md 1.15, board `Gallery-Combine`):
/// - touch and hold, then drag a tile to reorder it (the system's drag and drop, so it works the same with a pointer on
///   the Mac and iPad, and the strip scrolls itself near its edges);
/// - tap a tile to select it: `move earlier` / `move later` move it one place, for VoiceOver, a keyboard, and a far move;
/// - tap the circle under a tile to leave it out (all ticked by default).
/// What is shown here, in this order, with these ticks, is exactly what is sent.
struct CombineStrip: View {
    let combine: CombineModel

    var body: some View {
        let ids = combine.orderedIDs
        VStack(alignment: .leading, spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(Array(ids.enumerated()), id: \.element) { position, id in
                            CombineTile(combine: combine, id: id, position: position, count: ids.count)
                                .id(id)
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 3)
                    .animation(.snappy(duration: 0.25), value: ids)
                }
                .scrollClipDisabled()
                .onChange(of: ids) { _, _ in
                    if let selected = combine.selected { withAnimation { proxy.scrollTo(selected, anchor: .center) } }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Copy.Combine.itemsA11y)

            selection
            Text(tickLine)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    /// The selected item's name and its two move buttons; else the one-line hint. A fixed height, so ticking never moves
    /// what is below.
    private var selection: some View {
        Group {
            if let id = combine.selected, let position = combine.orderedIDs.firstIndex(of: id) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Copy.Combine.selected(combine.name(id), position: position + 1, of: combine.orderedIDs.count))
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Button { combine.shift(by: -1) } label: {
                            Label(Copy.Gallery.moveEarlier, systemImage: Symbol.Gallery.moveEarlier)
                        }
                        .buttonStyle(.cobaltSecondary(compact: true))
                        .disabled(!combine.canMoveEarlier)
                        .accessibilityLabel(Copy.Combine.moveA11y(combine.name(id), earlier: true))
                        Button { combine.shift(by: 1) } label: {
                            Label(Copy.Gallery.moveLater, systemImage: Symbol.Gallery.moveLater)
                                .labelStyle(TrailingIconLabelStyle())
                        }
                        .buttonStyle(.cobaltSecondary(compact: true))
                        .disabled(!combine.canMoveLater)
                        .accessibilityLabel(Copy.Combine.moveA11y(combine.name(id), earlier: false))
                    }
                }
            } else {
                Text(Copy.Combine.hint)
                    .font(CobaltType.badge)
                    .foregroundStyle(CobaltColor.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
    }

    private var tickLine: String {
        let ids = combine.orderedIDs
        let skipped = ids.filter { combine.isSkipped($0) && combine.isTicked($0) }.count
        if combine.output == .galleryImage {
            let photos = combine.imagePhotos.photos.count
            return Copy.Combine.tickLine(ticked: photos, of: ids.count, skipped: skipped)
        }
        let ticked = combine.tickedIDs.count
        return ticked < 2 ? Copy.Gallery.tickAtLeastTwo : Copy.Combine.tickLine(ticked: ticked, of: ids.count, skipped: 0)
    }
}

/// The text first, then the icon (the `move later` arrow points forward).
private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.title
            configuration.icon
        }
    }
}

/// One tile: the picture (a tap selects, a drag reorders) and the tick under it.
struct CombineTile: View {
    let combine: CombineModel
    let id: Int
    let position: Int
    let count: Int
    @State private var targeted = false

    static let width: CGFloat = 52
    static let height: CGFloat = 64

    var body: some View {
        let item = combine.item(id)
        let ticked = combine.isTicked(id)
        let skipped = combine.isSkipped(id)
        let selected = combine.selected == id
        let name = combine.name(id)
        VStack(spacing: 2) {
            Button { combine.select(id) } label: { face(item: item, selected: selected, ticked: ticked, skipped: skipped) }
                .buttonStyle(.plain)
                .draggable(CombineDrag(id: id)) {
                    picture(item: item).frame(width: Self.width, height: Self.height).clipShape(.rect(cornerRadius: 8))
                }
                .dropDestination(for: CombineDrag.self) { drops, _ in
                    guard let dragged = drops.first?.id else { return false }
                    combine.move(dragged, onto: id)
                    return true
                } isTargeted: { targeted = $0 }
                .accessibilityLabel(Copy.Combine.tileA11y(
                    name, length: item.flatMap { $0.isMotion ? $0.duration.map(Copy.Gallery.length) : nil },
                    position: position + 1, of: count, ticked: ticked, skipped: skipped))
                .accessibilityHint(Copy.Combine.tileHint)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction(named: Text(Copy.Gallery.moveEarlier)) { combine.selected = id; combine.shift(by: -1) }
                .accessibilityAction(named: Text(Copy.Gallery.moveLater)) { combine.selected = id; combine.shift(by: 1) }

            Button { combine.toggle(id) } label: { tick(ticked: ticked, skipped: skipped) }
                .buttonStyle(.plain)
                .disabled(skipped)
                .accessibilityLabel(skipped ? Copy.Combine.skippedA11y(name) : Copy.Combine.tickA11y(name, ticked: ticked))
                .accessibilityValue(ticked && !skipped ? "ticked" : "not ticked")
        }
        .frame(width: Self.width)
    }

    private func picture(item: GalleryItem?) -> some View {
        CombinePicture(sources: combine.pictureSources(id), maxPixel: 180, item: item, number: id)
    }

    private func face(item: GalleryItem?, selected: Bool, ticked: Bool, skipped: Bool) -> some View {
        picture(item: item)
            .frame(width: Self.width, height: Self.height)
            .clipShape(.rect(cornerRadius: 8))
            .overlay(alignment: .bottomLeading) {
                if let item, item.isMotion {
                    Text(item.duration.map(Copy.Gallery.length) ?? item.type.rawValue)
                        .font(.cobalt(9, .regular, relativeTo: .caption2))
                        .foregroundStyle(CobaltColor.badgeInk)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(CobaltColor.badgeBack, in: .capsule)
                        .padding(3)
                }
            }
            .overlay {
                if skipped {
                    Rectangle().fill(.black.opacity(0.45))
                    Image(systemName: Symbol.Gallery.video)
                        .font(.system(size: 13))
                        .foregroundStyle(CobaltColor.badgeInk)
                }
            }
            .opacity(ticked && !skipped ? 1 : 0.4)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? CobaltColor.text : (targeted ? CobaltColor.focus : .clear), lineWidth: 2)
            }
            .frame(width: Self.width, height: Self.height)
            .contentShape(.rect(cornerRadius: 8))
    }

    private func tick(ticked: Bool, skipped: Bool) -> some View {
        VStack(spacing: 2) {
            Image(systemName: ticked && !skipped ? Symbol.Gallery.ticked : Symbol.Gallery.unticked)
                .font(.system(size: 18))
                .foregroundStyle(ticked && !skipped ? CobaltColor.text : CobaltColor.caption)
            Text("\(id + 1)")
                .font(.cobalt(9.5, .regular, relativeTo: .caption2))
                .foregroundStyle(CobaltColor.caption)
        }
        .frame(width: Self.width, height: Metrics.hit)
        .contentShape(.rect)
    }
}
