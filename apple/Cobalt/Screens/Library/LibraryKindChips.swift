import CobaltKit
import SwiftUI

/// The kind chips (apple/CONTRACT-GALLERY.md 1.21, board `Library-Mixed`): `all · videos · photos · galleries · webps`,
/// each with how many there are (a video with webps counts under videos and webps). Its own row, so it combines with `show` (public, kept on this device) and with the sort;
/// the same state the `kind` list of the sort and show menu sets (`LibraryModel.kindFilter`). Only on a server that has
/// photos and galleries (`features.gallery`).
///
/// The `hidden` chip is last, only on a server that has hidden posts (`capabilities.hidden`, APP-API-CONTRACT 37.7), and
/// black when on. It is the hidden album's switch (`LibraryModel.showingHidden`), not a case of `LibraryKindFilter`: the
/// kind chips are off while it is on, and a kind chip turns it off.
///
/// A view of its own: it counts the loaded posts, and a download tick or a scroll in the tiles must not redo that.
///
/// `Equatable` on its plain inputs (not `pickAll`): the body reads the model itself, so a parent pass that changed
/// neither does not recount.
struct LibraryKindChips: View, Equatable {
    let model: AppModel
    /// Synthetic rows a preview adds (DEBUG); empty in the app.
    var extra: [LibraryRow] = []
    /// A chip's long press: tick every post of that kind (`false`), or tick them and share (`true`). Nil offers neither.
    var pickAll: ((LibraryKindFilter, Bool) -> Void)?

    nonisolated static func == (a: LibraryKindChips, b: LibraryKindChips) -> Bool {
        a.model === b.model && a.extra == b.extra && (a.pickAll == nil) == (b.pickAll == nil)
    }

    private var library: LibraryModel { model.library }

    /// `nil` while the library is not all here: a count of the first page would grow as the owner scrolls.
    private var counts: [LibraryKindFilter: Int]? {
        // in the album the chips count the album's posts (the filter applies there too)
        let album = library.showingHidden
        guard !(album ? library.hiddenHasMore : library.hasMore) else { return nil }
        var out: [LibraryKindFilter: Int] = [:]
        func add(_ kind: MediaKind, hasWebp: Bool) {
            out[.all, default: 0] += 1
            for chip in LibraryKindFilter.chips(kind: kind, hasWebp: hasWebp) { out[chip, default: 0] += 1 }
        }
        for post in (album ? library.hiddenPosts : library.posts) {
            if post.isEmote { out[.emotes, default: 0] += 1 }
            else {
                let item = model.mediaItem(for: post)
                add(item.kind, hasWebp: item.hasMadeWebp)
            }
        }
        for row in extra {
            if row.emote { out[.emotes, default: 0] += 1 }
            else { add(row.kind, hasWebp: row.hasWebp) }
        }
        return out
    }

    var body: some View {
        let counts = counts
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if model.capabilities.gallery {
                    ForEach(LibraryKindFilter.allCases, id: \.self) { kind in
                        chip(kind, count: counts.map { $0[kind] ?? 0 })
                    }
                }
                if model.capabilities.hidden { hiddenChip }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Library2.kindFilter)
        .haptic(.selection, trigger: model.library.kindFilter)
        .haptic(.selection, trigger: model.library.showingHidden)
    }

    private func chip(_ kind: LibraryKindFilter, count: Int?) -> some View {
        @Bindable var library = model.library
        // off while the hidden album is open: the album is its own chip
        let selected = !library.showingHidden && library.kindFilter == kind
        return Button {
            library.showingHidden = false
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

    // MARK: hidden

    /// How many posts are hidden, once the library has said (a count read before the first page would be a 0 that lies).
    private var hiddenCount: Int? {
        library.posts.isEmpty && (library.isLoading || library.loadingAll != nil) ? nil : library.hiddenCount
    }

    /// Black fill, white text when on (in the dark theme a thin light ring keeps the black chip on the dark bar).
    private var hiddenChip: some View {
        @Bindable var library = model.library
        let selected = library.showingHidden
        return Button {
            library.showingHidden.toggle()
        } label: {
            Text(Copy.HiddenAlbum.chip(count: hiddenCount))
                .font(Font.cobalt(11.5, selected ? .semibold : .regular, relativeTo: .caption))
                .monospacedDigit()
                .foregroundStyle(selected ? Color.white : Color.primary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 12)
                .frame(minHeight: 30)
                .background(Capsule().fill(selected ? Color.black : CobaltColor.elevated))
                .overlay(Capsule().strokeBorder(Color.white.opacity(selected ? 0.28 : 0), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Copy.HiddenAlbum.chipName)
        .accessibilityValue(hiddenCount.map { "\($0)" } ?? "")
        .accessibilityHint(Copy.HiddenAlbum.chipHint)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
