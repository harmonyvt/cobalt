import CobaltKit
import SwiftUI

/// The kind chips (apple/CONTRACT-GALLERY.md 1.21, board `Library-Mixed`): `all · videos · photos · galleries · webps`,
/// each with how many there are. Its own row, so it combines with `show` (public, kept on this device) and with the sort;
/// the same state the `kind` list of the sort and show menu sets (`LibraryModel.kindFilter`). Only on a server that has
/// photos and galleries (`features.gallery`).
///
/// A view of its own: it counts the loaded posts, and a download tick or a scroll in the tiles must not redo that.
struct LibraryKindChips: View {
    let model: AppModel
    /// Synthetic rows a preview adds (DEBUG); empty in the app.
    var extra: [LibraryRow] = []
    /// A chip's long press: tick every post of that kind (`false`), or tick them and share (`true`). Nil offers neither.
    var pickAll: ((LibraryKindFilter, Bool) -> Void)?
    /// The iPhone's way into select mode: a `select` / `done` chip pinned at the start of the row (the top bar has no
    /// room left for it). Nil leaves it in the top bar.
    var selectChip: SelectChip?

    struct SelectChip {
        let selecting: Bool
        let toggle: () -> Void
    }

    private var library: LibraryModel { model.library }

    /// `nil` while the library is not all here: a count of the first page would grow as the owner scrolls.
    private var counts: [LibraryKindFilter: Int]? {
        guard !library.hasMore else { return nil }
        var out: [LibraryKindFilter: Int] = [:]
        func add(_ kind: MediaKind) {
            out[.all, default: 0] += 1
            out[Self.filter(for: kind), default: 0] += 1
        }
        for post in library.posts {
            if post.isEmote { out[.emotes, default: 0] += 1 }
            else { add(model.mediaItem(for: post).kind) }
        }
        for row in extra {
            if row.emote { out[.emotes, default: 0] += 1 }
            else { add(row.kind) }
        }
        return out
    }

    /// The chip a media of this kind is counted under.
    nonisolated static func filter(for kind: MediaKind) -> LibraryKindFilter {
        switch kind {
        case .video: return .videos
        case .photo: return .photos
        case .gallery: return .galleries
        case .webp: return .webps
        }
    }

    var body: some View {
        let counts = counts
        chips(counts)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Library2.kindFilter)
        .haptic(.selection, trigger: model.library.kindFilter)
    }

    /// First in the row: an outlined `select`, a filled `done`. Inside the scroll view with the kind chips: pinned beside
    /// it, outside the scroll view, the button drew but never received the tap on iOS 27.
    private func selectButton(_ chip: SelectChip) -> some View {
        Button(action: chip.toggle) {
            Text(chip.selecting ? Copy.Library2.doneSelecting : Copy.Library2.select)
                .font(Font.cobalt(11.5, .semibold, relativeTo: .caption))
                .foregroundStyle(chip.selecting ? CobaltColor.onText : Color.primary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 12)
                .frame(minHeight: 30)
                .background(Capsule().fill(chip.selecting ? CobaltColor.text : Color.clear))
                .overlay(Capsule().strokeBorder(CobaltColor.text, lineWidth: 1.25))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chip.selecting ? .isSelected : [])
    }

    private func chips(_ counts: [LibraryKindFilter: Int]?) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if let selectChip {
                    selectButton(selectChip)
                        .padding(.trailing, 4)
                }
                ForEach(LibraryKindFilter.allCases, id: \.self) { kind in
                    chip(kind, count: counts.map { $0[kind] ?? 0 })
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func chip(_ kind: LibraryKindFilter, count: Int?) -> some View {
        @Bindable var library = model.library
        let selected = library.kindFilter == kind
        return Button {
            library.kindFilter = kind
        } label: {
            Text(Copy.Library2.chip(kind, count: count))
                .font(Font.cobalt(11.5, selected ? .semibold : .regular, relativeTo: .caption))
                .monospacedDigit()
                .foregroundStyle(selected ? CobaltColor.onText : Color.primary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 12)
                .frame(minHeight: 30)
                .background(Capsule().fill(selected ? CobaltColor.text : CobaltColor.elevated))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu {
            // galleries are not shared, so their chip offers neither
            if let pickAll, count != 0, kind != .galleries {
                Button(Copy.Library2.selectAllKind(kind), systemImage: Symbol.Gallery.selectPhotos) { pickAll(kind, false) }
                Button(Copy.Library2.shareAllKind(kind), systemImage: Symbol.Library.share) { pickAll(kind, true) }
            }
        }
        .accessibilityLabel(Copy.Library2.name(kind))
        .accessibilityValue(count.map { "\($0)" } ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
