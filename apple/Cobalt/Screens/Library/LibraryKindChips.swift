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

    private var library: LibraryModel { model.library }

    /// `nil` while the library is not all here: a count of the first page would grow as the owner scrolls.
    private var counts: [LibraryKindFilter: Int]? {
        guard !library.hasMore else { return nil }
        var out: [LibraryKindFilter: Int] = [:]
        func add(_ kind: MediaKind) {
            out[.all, default: 0] += 1
            out[Self.filter(for: kind), default: 0] += 1
        }
        for post in library.posts { add(model.mediaItem(for: post).kind) }
        for row in extra { add(row.kind) }
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(LibraryKindFilter.allCases, id: \.self) { kind in
                    chip(kind, count: counts.map { $0[kind] ?? 0 })
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Library2.kindFilter)
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
        .accessibilityLabel(Copy.Library2.name(kind))
        .accessibilityValue(count.map { "\($0)" } ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
