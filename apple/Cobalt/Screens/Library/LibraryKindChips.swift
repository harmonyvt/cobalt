import CobaltKit
import SwiftUI

/// The kind chips (apple/CONTRACT-GALLERY.md 1.21, board `Library-Mixed`): `all · videos · photos · galleries · webps`,
/// each its icon with how many there are (a video with webps counts under videos and webps; icon-first controls: the
/// kind's word is the chip's name, for VoiceOver and the Mac's hover). Its own row, so it combines with `show` (public, kept on this device) and with the sort;
/// the same state the `kind` list of the sort and show menu sets (`LibraryModel.kindFilter`). Only on a server that has
/// photos and galleries (`features.gallery`).
///
/// The `hidden` chip is last, only on a server that has hidden posts (`capabilities.hidden`, APP-API-CONTRACT 37.7), and
/// black when on. It is the hidden album's switch (`LibraryModel.showingHidden`), not a case of `LibraryKindFilter`: the
/// kind chips are off while it is on, and a kind chip turns it off.
///
/// A view of its own: a download tick or a scroll in the tiles must not redraw it.
///
/// `Equatable` on its plain inputs (not `pickAll`): the body reads the model itself, so a parent pass that changed
/// neither does not recount.
struct LibraryKindChips: View, Equatable {
    let model: AppModel
    /// Synthetic rows a preview adds (DEBUG); empty in the app.
    var extra: [LibraryRow] = []
    /// Softens the trailing edge when pinned controls sit to the right (replaces a hard vertical divider pipe).
    var trailingFade = false
    /// A chip's long press: tick every post of that kind (`false`), or tick them and share (`true`). Nil offers neither.
    var pickAll: (@MainActor (LibraryKindFilter, Bool) -> Void)?

    nonisolated static func == (a: LibraryKindChips, b: LibraryKindChips) -> Bool {
        a.model === b.model && a.extra == b.extra && a.trailingFade == b.trailingFade
            && (a.pickAll == nil) == (b.pickAll == nil)
    }

    private var library: LibraryModel { model.library }

    /// `nil` while the library is not all here: a count of the first page would grow as the owner scrolls. The posts are
    /// counted off the main thread with the rows (`AppModel.libraryKindCounts`); this only adds a preview's extra rows.
    private var counts: [LibraryKindFilter: Int]? {
        // in the album the chips count the album's posts (the filter applies there too)
        let album = library.showingHidden
        guard !(album ? library.hiddenHasMore : library.hasMore) else { return nil }
        var out = model.libraryKindCounts
        for row in extra {
            if row.emote { out[.emotes, default: 0] += 1; continue }
            out[.all, default: 0] += 1
            for chip in LibraryKindFilter.chips(kind: row.kind, hasWebp: row.hasWebp) { out[chip, default: 0] += 1 }
        }
        return out
    }

    var body: some View {
        let counts = counts
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    if model.capabilities.gallery {
                        ForEach(LibraryKindFilter.allCases, id: \.self) { kind in
                            chip(kind, count: counts.map { $0[kind] ?? 0 })
                        }
                    }
                    if model.capabilities.hidden { hiddenChip }
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, trailingFade ? 18 : 12)
            .padding(.vertical, 6)
        }
        .scrollBounceBehavior(.basedOnSize)
        .mask {
            if trailingFade {
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 22)
                }
            } else {
                Rectangle()
            }
        }
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
            // icon-first controls: the kind's icon and its count; the word is the chip's name (VoiceOver, Mac hover)
            HStack(spacing: 5) {
                Image(systemName: Symbol.Library.kind(kind))
                    .font(.system(size: 12, weight: .semibold))
                if let count {
                    Text("\(count)")
                        .font(Font.cobalt(11.5, selected ? .semibold : .medium, relativeTo: .caption))
                        .monospacedDigit()
                        .opacity(selected ? 0.94 : 0.72)
                        .transition(.opacity)
                } else if countsLoading {
                    // the count's room, held while the library loads: the chip does not grow when the number lands
                    countPlaceholder(selected: selected)
                }
            }
            .foregroundStyle(selected ? CobaltColor.onText : Color.primary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 12)
            .frame(minWidth: 40, minHeight: 30)
            .contentShape(Capsule())
            .libraryGlassPill(selected: selected)
        }
        .buttonStyle(.plain)
        .help(Copy.Library2.name(kind))
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

    // MARK: loading

    /// Whether the counts are on their way (the first page, the whole library paging in, or the album loading): only
    /// then do the chips hold a shimmering placeholder where the number goes. A library that is simply not all here
    /// (more pages on scroll) shows no count and no placeholder, as before.
    private var countsLoading: Bool {
        library.showingHidden ? library.hiddenLoading || library.loadingAll != nil
            : library.isLoading || library.loadingAll != nil
    }

    private func countPlaceholder(selected: Bool) -> some View {
        Capsule()
            .fill(selected ? CobaltColor.onText.opacity(0.32) : Color.primary.opacity(0.14))
            .frame(width: 22, height: 8)
            .skeletonShimmer()
            .accessibilityHidden(true)
            .transition(.opacity)
    }

    // MARK: hidden

    /// How many posts are hidden, once the library has said (a count read before the first page would be a 0 that lies).
    private var hiddenCount: Int? {
        library.posts.isEmpty && (library.isLoading || library.loadingAll != nil) ? nil : library.hiddenCount
    }

    /// Deep obsidian glass with white ink when on.
    private var hiddenChip: some View {
        @Bindable var library = model.library
        let selected = library.showingHidden
        return Button {
            library.showingHidden.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: Symbol.HiddenRules.hidden)
                    .font(.system(size: 12, weight: .semibold))
                if let hiddenCount {
                    Text("\(hiddenCount)")
                        .font(Font.cobalt(11.5, selected ? .semibold : .medium, relativeTo: .caption))
                        .monospacedDigit()
                        .opacity(selected ? 0.94 : 0.72)
                        .transition(.opacity)
                } else if countsLoading {
                    countPlaceholder(selected: selected)
                }
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 12)
            .frame(minWidth: 40, minHeight: 30)
            .contentShape(Capsule())
            .libraryGlassPill(selected: selected, tint: selected ? .black : nil)
        }
        .buttonStyle(.plain)
        .help(Copy.HiddenAlbum.chipName)
        .accessibilityLabel(Copy.HiddenAlbum.chipName)
        .accessibilityValue(hiddenCount.map { "\($0)" } ?? "")
        .accessibilityHint(Copy.HiddenAlbum.chipHint)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
