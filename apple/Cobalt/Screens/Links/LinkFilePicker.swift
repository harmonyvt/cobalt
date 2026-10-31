import CobaltKit
import SwiftUI

// "add files" from a link's edit mode (APP-API-CONTRACT 41.4, mockup step 4): the library as a grid with search and the
// kind chips. Posts already in the link are ticked and locked ("in link"); in a public link a post with no public file is
// dimmed ("private: only in private links"); hidden posts and galleries are not listed. Picks are numbered with their
// future place (8, 9, 10) and stop at the room left; the rest dim. "add N files" puts them at the end of the draft. Each
// post stands for one file: `ShareSetRule.fileID(for:)` in a public link, `privateFileID(for:)` in a private one.

/// The kind chips of the picker.
enum LinkPickKind: CaseIterable, Hashable {
    case all, videos, photos, webps

    var title: String {
        switch self {
        case .all: return Copy.LinkEdit.kindAll
        case .videos: return Copy.LinkEdit.kindVideos
        case .photos: return Copy.LinkEdit.kindPhotos
        case .webps: return Copy.LinkEdit.kindWebps
        }
    }

    func admits(_ item: MediaItem) -> Bool {
        switch self {
        case .all: return true
        case .videos: return item.kind == .video
        case .photos: return item.kind == .photo
        case .webps: return item.kind == .webp || item.hasMadeWebp
        }
    }
}

/// One post the picker lists.
struct LinkPickCandidate: Identifiable {
    enum Status: Equatable {
        /// Can be picked; this file goes in.
        case available(fileID: String)
        /// A file of the post is in the link already.
        case inLink
        /// A public link and the post has no public file.
        case privateOnly
    }

    let id: String                  // post id
    let item: MediaItem
    let state: Status

    var fileID: String? {
        if case .available(let id) = state { return id }
        return nil
    }

    /// The library's posts for a link: not hidden, not galleries, with a file that could go in (or one in it already).
    @MainActor
    static func list(model: AppModel, isPrivate: Bool, inLink: Set<String>) -> [LinkPickCandidate] {
        let hidden = model.settings.hiddenIndex
        var out: [LinkPickCandidate] = []
        for post in model.library.posts where !post.hidden && !hidden.contains(post: post.id) {
            let item = model.mediaItem(for: post)
            guard item.kind != .gallery else { continue }
            let publicID = ShareSetRule.fileID(for: item)
            let anyID = ShareSetRule.privateFileID(for: item)
            var ids = ShareSetIndex.fileIDs(of: item)
            if let publicID { ids.insert(publicID) }
            if let anyID { ids.insert(anyID) }
            let state: Status
            if !ids.isDisjoint(with: inLink) {
                state = .inLink
            } else if let id = isPrivate ? anyID : publicID {
                state = .available(fileID: id)
            } else if anyID != nil {
                state = .privateOnly
            } else {
                continue
            }
            out.append(LinkPickCandidate(id: post.id, item: item, state: state))
        }
        return out
    }
}

struct LinkFilePicker: View {
    let model: AppModel
    let isPrivate: Bool
    /// The draft's files: their posts are ticked and locked.
    let inLink: [String]
    /// How many more fit.
    let room: Int
    let add: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var kind: LinkPickKind = .all
    /// File ids in the order picked.
    @State private var picks: [String] = []

    private var candidates: [LinkPickCandidate] {
        let all = LinkPickCandidate.list(model: model, isPrivate: isPrivate, inLink: Set(inLink))
        let folded = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return all.filter { candidate in
            guard kind.admits(candidate.item) else { return false }
            guard !folded.isEmpty else { return true }
            return candidate.item.titleText.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .contains(folded)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LinkPickerHeader(picked: picks.count, room: room) { dismiss() }
            LinkPickerSearch(query: $query, kind: $kind)
            grid
            LinkPickerFoot(isPrivate: isPrivate, picked: picks.count) {
                let chosen = picks
                dismiss()
                add(chosen)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 12)
        #if os(macOS)
        .frame(width: 560, height: 620)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
        .background(CobaltColor.bg)
        .haptic(.selection, trigger: picks.count)
        .task { if model.library.posts.isEmpty { await model.library.refresh() } }
    }

    @ViewBuilder
    private var grid: some View {
        let list = candidates
        if list.isEmpty {
            Text(Copy.LinkEdit.pickerEmpty)
                .font(CobaltType.caption)
                .foregroundStyle(CobaltColor.caption)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 24)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 160), spacing: 6)], spacing: 6) {
                    ForEach(list) { candidate in
                        LinkPickTile(
                            candidate: candidate, number: number(of: candidate), full: picks.count >= room
                        ) { toggle(candidate) }
                    }
                }
                .padding(.bottom, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// The pick's future place in the link (8, 9, 10), nil when not picked.
    private func number(of candidate: LinkPickCandidate) -> Int? {
        guard let id = candidate.fileID, let index = picks.firstIndex(of: id) else { return nil }
        return inLink.count + index + 1
    }

    private func toggle(_ candidate: LinkPickCandidate) {
        guard let id = candidate.fileID else { return }
        if let index = picks.firstIndex(of: id) {
            picks.remove(at: index)
        } else if picks.count < room {
            picks.append(id)
        }
    }
}

// MARK: - the parts

private struct LinkPickerHeader: View {
    let picked: Int
    let room: Int
    let cancel: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(Copy.LinkEdit.pickerTitle)
                .font(Font.cobalt(16, .semibold, relativeTo: .headline))
                .foregroundStyle(CobaltColor.text)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Text(Copy.LinkEdit.pickedOfRoom(picked, room: room))
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
                .monospacedDigit()
                .contentTransition(.numericText())
            CloseButton(cancels: true, action: cancel)  // cancel is the sheet's close, top right
        }
    }
}

private struct LinkPickerSearch: View {
    @Binding var query: String
    @Binding var kind: LinkPickKind

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: Symbol.LinkEdit.search)
                    .foregroundStyle(CobaltColor.caption)
                    .accessibilityHidden(true)
                TextField(Copy.LinkEdit.searchPrompt, text: $query)
                    .font(CobaltType.body)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            .background(CobaltColor.elevated, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(LinkPickKind.allCases, id: \.self) { chip in
                        LinkPickChip(title: chip.title, on: kind == chip) { kind = chip }
                    }
                }
            }
        }
    }
}

private struct LinkPickChip: View {
    let title: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Font.cobalt(11.5, on ? .semibold : .regular, relativeTo: .caption))
                .foregroundStyle(on ? CobaltColor.onText : Color.primary)
                .padding(.horizontal, 12)
                .frame(minHeight: 30)
                .background(Capsule().fill(on ? CobaltColor.text : CobaltColor.elevated))
                .contentShape(Capsule())
        }
        .buttonStyle(.borderless)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

private struct LinkPickerFoot: View {
    let isPrivate: Bool
    let picked: Int
    let add: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isPrivate ? Copy.LinkEdit.privateLinkHint : Copy.LinkEdit.publicLinkHint)
                .font(CobaltType.badge)
                .foregroundStyle(CobaltColor.caption)
            Button(picked > 0 ? Copy.LinkEdit.addPicked(picked) : Copy.LinkEdit.pickSome, action: add)
                .buttonStyle(.cobaltPrimary())
                .disabled(picked == 0)
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// One post in the picker: its face, square; a tick and "in link" when it is there already, its number when picked,
/// dimmed with the reason when it cannot go in (or when the room is used up).
private struct LinkPickTile: View {
    let candidate: LinkPickCandidate
    let number: Int?
    /// The room is used up: tiles not picked dim.
    let full: Bool
    let toggle: () -> Void

    private var reason: String? {
        switch candidate.state {
        case .inLink: return Copy.LinkEdit.inLink
        case .privateOnly: return Copy.LinkEdit.privateOnly
        case .available: return nil
        }
    }

    private var enabled: Bool { candidate.fileID != nil && (number != nil || !full) }

    private var dimming: Double {
        if candidate.state == .inLink { return 0.55 }
        return enabled ? 1 : 0.35
    }

    var body: some View {
        Button(action: toggle) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { FacePicture(item: candidate.item, maxPixel: 240, showsGlyph: false) }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topTrailing) { badge }
                .overlay(alignment: .bottomLeading) { why }
                .overlay {
                    if number != nil {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(CobaltColor.text, lineWidth: 2)
                    }
                }
                .opacity(dimming)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(Copy.LinkEdit.pickA11y(name: candidate.item.titleText, number: number, why: reason))
        .accessibilityAddTraits(number != nil ? .isSelected : [])
    }

    @ViewBuilder
    private var badge: some View {
        if candidate.state == .inLink {
            Image(systemName: Symbol.LinkEdit.ticked)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(CobaltColor.badgeInk, CobaltColor.badgeBack)
                .padding(5)
        } else if let number {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(CobaltColor.onText)
                .frame(minWidth: 22, minHeight: 22)
                .background(CobaltColor.text, in: Circle())
                .padding(5)
        }
    }

    @ViewBuilder
    private var why: some View {
        if let reason {
            Text(reason)
                .font(Font.cobalt(9.5, .medium, relativeTo: .caption2))
                .foregroundStyle(CobaltColor.badgeInk)
                .lineLimit(2)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(CobaltColor.badgeBack, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(5)
        }
    }
}
