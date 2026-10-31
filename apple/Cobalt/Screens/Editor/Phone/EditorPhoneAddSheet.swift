#if os(iOS)
import CobaltKit
import SwiftUI

/// The bin as a sheet (apple/CONTRACT-EDITOR.md 4.4, 12): the library's files in a grid with `add` on each tile, a search field
/// and `done`. For the main track (`+` on the timeline) it offers videos and appends the pick; for the overlay (the `overlay`
/// tool) it offers videos, images (photos, gifs, webps, cutouts) and 7TV emotes on three shelves and puts the pick at the
/// playhead on the lowest free layer. A picture's menu has `remove background`.
struct EditorPhoneAddSheet: View {
    let model: AppModel
    let session: EditSession
    let mode: EditorPhoneAddMode

    @Environment(EditorHost.self) private var host
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [EditorBinEntry] = []
    @State private var query = ""
    @State private var added: Set<String> = []
    @State private var addedTick = 0
    @State private var shelf: EditorBinEntry.Shelf = .images
    @State private var cutoutOf: EditSource?

    /// Shelves show once the server takes webps and layers; before that the overlay takes everything in one grid.
    private var hasShelves: Bool { mode == .overlay && session.overlayTrackLimit > 1 }

    private var shown: [EditorBinEntry] {
        let wanted = entries.filter {
            mode == .main ? $0.source.kind == .video : (!hasShelves || $0.shelf == shelf)
        }
        let folded = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !folded.isEmpty else { return wanted }
        return wanted.filter {
            "\($0.source.name)\n\($0.postTitle)".folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .contains(folded)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if hasShelves { shelfPicker }
            searchField
            content
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 14)
        .background(CobaltColor.surface.ignoresSafeArea())
        .task(id: model.library.posts.map(\.id)) { entries = EditorBinEntry.entries(model) }
        .task { if model.library.posts.isEmpty { await model.library.refresh() } }
        .modifier(EditorPhoneAddedHaptic(tick: addedTick))
        .sheet(item: $cutoutOf) { picture in
            EditorCutoutSheet(session: session, source: picture, made: { dismiss() }) { cutoutOf = nil }
                .presentationDetents([.large])
        }
    }

    private var shelfPicker: some View {
        Picker(Copy.Editor.addOverlay, selection: $shelf) {
            Text(Copy.Editor.shelfVideos).tag(EditorBinEntry.Shelf.videos)
            Text(Copy.Editor.shelfImages).tag(EditorBinEntry.Shelf.images)
            Text(Copy.Editor.shelfEmotes).tag(EditorBinEntry.Shelf.emotes)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(mode == .main ? Copy.Editor.addClip : Copy.Editor.addOverlay)
                .font(CobaltType.sheetTitle)
                .foregroundStyle(CobaltColor.text)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Button(Copy.Editor.done) { dismiss() }
                .buttonStyle(.cobaltPrimary(fullWidth: false, compact: true))
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(CobaltColor.caption)
                .accessibilityHidden(true)
            TextField(Copy.Editor.searchLibrary, text: $query)
                .textFieldStyle(.plain)
                .font(Font.cobalt(12, .regular, relativeTo: .caption))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(CobaltColor.border, lineWidth: 1) }
    }

    @ViewBuilder
    private var content: some View {
        if shown.isEmpty {
            Text(hasShelves && shelf == .emotes ? Copy.Editor.emotesEmpty : Copy.Editor.binEmpty)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
                .padding(.top, 8)
            Spacer(minLength: 0)
        } else {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(shown) { entry in
                        EditorPhoneAddTile(entry: entry, isAdded: added.contains(entry.id)) { add(entry) }
                            .contextMenu {
                                if mode == .overlay, session.canCutout, entry.canCutout {
                                    Button { cutoutOf = entry.source } label: {
                                        Label(Copy.Editor.removeBackground, systemImage: Symbol.Editor.cutout)
                                    }
                                }
                            }
                    }
                    if model.library.hasMore, query.isEmpty {
                        Color.clear.frame(height: 1)
                            .onAppear { Task { await model.library.loadMore() } }
                    }
                }
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// A video joins the main track's end (or the overlay at the playhead); a GIF or photo only goes on the overlay.
    private func add(_ entry: EditorBinEntry) {
        switch entry.source.kind {
        case .video where mode == .main:
            session.add([entry.source], at: nil)
            added.insert(entry.id)
            addedTick += 1
        case .video, .gif, .photo:
            guard mode == .overlay else {
                host.show(Copy.Editor.leftOut(1))
                return
            }
            if session.addOverlay(entry.source, atFrame: nil) {
                dismiss()
            } else {
                host.show(session.overlayTrackLimit > 1 ? Copy.Editor.allLayersBusy : Copy.Editor.dropIntoOverlayRefused)
            }
        case .unsupported:
            host.show(Copy.Editor.cantEdit)
        }
    }
}

private struct EditorPhoneAddedHaptic: ViewModifier {
    let tick: Int

    func body(content: Content) -> some View {
        content.haptic(.success, trigger: tick)
    }
}

/// One tile: the poster at 9:12 with its badge (`0:12`, `gif`, `photo`) and a `+` (a tick once it was added); dimmed with
/// `can't edit` when the editor cannot take the file.
private struct EditorPhoneAddTile: View {
    let entry: EditorBinEntry
    let isAdded: Bool
    let add: () -> Void

    var body: some View {
        Button(action: add) {
            EditorPoster(url: entry.source.posterURL, fallback: EditorColor.clip(for: entry.id), maxPixel: 240)
                .opacity(entry.isEditable ? 1 : 0.4)
                .aspectRatio(9.0 / 12.0, contentMode: .fit)
                .overlay(alignment: .bottomLeading) { badge.padding(6) }
                .overlay(alignment: .topTrailing) { mark.padding(6) }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Copy.Editor.add) \(a11yName)")
    }

    private var kindText: String {
        if !entry.isEditable { return Copy.Editor.cantEditBadge }
        if entry.isEmote { return Copy.Editor.badgeEmote }
        switch entry.source.kind {
        case .video: return entry.source.duration.map(Copy.Editor.clock) ?? ""
        case .gif: return Copy.Editor.badgeGif
        case .photo: return Copy.Editor.badgePhoto
        case .unsupported: return Copy.Editor.cantEditBadge
        }
    }

    private var a11yName: String {
        [entry.source.name, kindText].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private var badge: some View {
        Text(kindText)
            .font(Font.cobalt(10, .regular, relativeTo: .caption2))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    @ViewBuilder
    private var mark: some View {
        if entry.isEditable {
            Image(systemName: isAdded ? Symbol.keep : Symbol.Editor.add)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(.black.opacity(0.6), in: Circle())
        }
    }
}

// MARK: - render

/// The render sheet (apple/CONTRACT-EDITOR.md 4.6): the confirm card (`renderTitle`, the summary, `renderNote`, `render` /
/// `cancel`) and, once a render runs, its progress with `cancel render`.
struct EditorPhoneRenderSheet: View {
    let model: AppModel
    let session: EditSession
    let close: () -> Void

    var body: some View {
        ScrollView {
            EditorRenderCard(model: model, session: session, close: close)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(CobaltColor.surface.ignoresSafeArea())
    }
}
#endif
