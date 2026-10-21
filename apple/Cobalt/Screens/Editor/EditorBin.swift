import CobaltKit
import SwiftUI

/// The library bin (apple/CONTRACT-EDITOR.md 4.3, left column, 236 pt): `library` and `drag in`, a search field, and a
/// two-column grid of the library's videos, GIFs and photos. Drag a video onto the main track or any file onto the overlay
/// lane; double-click (Mac) or `+` (iPad) appends a video to the main track and puts a GIF or photo on the overlay at the
/// playhead. Files the editor cannot use are dimmed with `can't edit`.
struct EditorBin: View {
    let model: AppModel
    let session: EditSession

    @Environment(EditorHost.self) private var host
    @State private var entries: [EditorBinEntry] = []
    @State private var query = ""

    private var shown: [EditorBinEntry] {
        let folded = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !folded.isEmpty else { return entries }
        return entries.filter {
            "\($0.source.name)\n\($0.postTitle)".folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .contains(folded)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(Copy.Editor.library)
                    .font(Font.cobalt(12.5, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(CobaltColor.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                Text(Copy.Editor.dragIn)
                    .font(Font.cobalt(11, .regular, relativeTo: .caption2))
                    .foregroundStyle(CobaltColor.caption)
            }
            searchField
            if shown.isEmpty {
                Text(Copy.Editor.binEmpty)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                    .padding(.top, 8)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(shown) { entry in
                            EditorBinTile(entry: entry, add: add)
                        }
                        if model.library.hasMore, query.isEmpty {
                            Color.clear.frame(height: 1)
                                .onAppear { Task { await model.library.loadMore() } }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(EditorColor.panel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Editor.binA11y)
        .task(id: model.library.posts.map(\.id)) { entries = EditorBinEntry.entries(model) }
        .task { if model.library.posts.isEmpty { await model.library.refresh() } }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CobaltColor.caption)
            TextField(Copy.Editor.searchLibrary, text: $query)
                .textFieldStyle(.plain)
                .font(Font.cobalt(11.5, .regular, relativeTo: .caption))
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
        }
        .padding(.horizontal, 10)
        .frame(height: Platform.isMac ? 30 : 38)
        .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(CobaltColor.border, lineWidth: 1) }
    }

    /// Double-click, `+`: a video to the end of the main track, a GIF or photo onto the overlay at the playhead.
    private func add(_ entry: EditorBinEntry) {
        switch entry.source.kind {
        case .video:
            session.add([entry.source], at: nil)
        case .gif, .photo:
            if !session.addOverlay(entry.source, atFrame: nil) { host.show(Copy.Editor.dropIntoOverlayRefused) }
        case .unsupported:
            host.show(Copy.Editor.cantEdit)
        }
    }
}

/// One tile: the poster at 9:12 with its badge (`0:12`, `gif`, `photo`), draggable; dimmed with `can't edit` when the editor
/// cannot take the file.
private struct EditorBinTile: View {
    let entry: EditorBinEntry
    let add: (EditorBinEntry) -> Void

    var body: some View {
        EditorPoster(url: entry.source.posterURL, fallback: EditorColor.clip(for: entry.id), maxPixel: 240)
            .opacity(entry.isEditable ? 1 : 0.4)
            .aspectRatio(9.0 / 12.0, contentMode: .fit)
            .overlay(alignment: .bottomLeading) { badge.padding(6) }
            .overlay(alignment: .topTrailing) { plus.padding(4) }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onTapGesture(count: 2) { if Platform.isMac { add(entry) } }
            .draggable(EditorDragPayload(entry.source).text) {
                EditorPoster(url: entry.source.posterURL, fallback: EditorColor.clip(for: entry.id), maxPixel: 160)
                    .frame(width: 64, height: 86)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .help("\(entry.source.name) · \(Copy.Editor.hintDoubleClick)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(a11yLabel)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: Copy.Editor.add) { add(entry) }
    }

    private var badgeText: String {
        if !entry.isEditable { return Copy.Editor.cantEditBadge }
        switch entry.source.kind {
        case .video: return entry.source.duration.map(Copy.Editor.clock) ?? ""
        case .gif: return Copy.Editor.badgeGif
        case .photo: return Copy.Editor.badgePhoto
        case .unsupported: return Copy.Editor.cantEditBadge
        }
    }

    private var badge: some View {
        Text(badgeText)
            .font(Font.cobalt(10, .regular, relativeTo: .caption2))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    /// `+` for a finger or a pointer without a double-click (iPad).
    @ViewBuilder
    private var plus: some View {
        if !Platform.isMac, entry.isEditable {
            Button { add(entry) } label: {
                Image(systemName: Symbol.Editor.add)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(.black.opacity(0.6), in: Circle())
                    .frame(width: Metrics.hit, height: Metrics.hit)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(Copy.Editor.add) \(entry.source.name)")
        }
    }

    private var a11yLabel: String {
        let kind: String
        switch entry.source.kind {
        case .video: kind = entry.source.duration.map { Copy.Editor.clock($0) } ?? ""
        case .gif: kind = Copy.Editor.badgeGif
        case .photo: kind = Copy.Editor.badgePhoto
        case .unsupported: kind = Copy.Editor.cantEditBadge
        }
        return [entry.source.name, kind].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
