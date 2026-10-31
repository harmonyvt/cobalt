import CobaltKit
import SwiftUI

/// The composer's + opens this: the loaded library as a grid, newest first, with a field that narrows it by title. Tap
/// tiles to pick them (up to what the next message still takes); "attach N" puts them on the composer as chips, the same
/// as "ask about this" does from a post. iPhone and iPad: a sheet; Mac: the same view, 520 pt wide.
struct ChatAttachSheet: View {
    let model: AppModel
    /// Already on the composer: not offered again.
    let already: [String]
    let attach: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var picked: [String] = []
    @State private var query = ""

    private var room: Int { max(0, ChatRule.attachmentLimit - already.count) }

    private var rows: [LibraryRow] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return model.library.posts
            .lazy
            .filter { !self.already.contains($0.id) && model.library.post(id: $0.id) != nil }
            .map { LibraryRow(item: model.mediaItem(for: $0)) }
            .filter { words.isEmpty || $0.title.lowercased().contains(words) }
            .prefix(240)
            .map { $0 }
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            TextField(Copy.ChatActivity.attachSearch, text: $query)
                .textFieldStyle(.plain)
                .font(CobaltType.body)
                .padding(.horizontal, 12)
                .frame(minHeight: 40)
                .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if rows.isEmpty {
                Text(Copy.ChatActivity.attachEmpty)
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.caption)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6) {
                        ForEach(rows) { row in tile(row) }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        #if os(macOS)
        .frame(width: 520, height: 560)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        .background(CobaltColor.bg)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.ChatActivity.attach)
    }

    private var header: some View {
        HStack(spacing: 8) {
            CloseButton(cancels: true) { dismiss() }
            Spacer(minLength: 8)
            Text(Copy.ChatActivity.attachTitle)
                .font(Font.cobalt(16, .semibold, relativeTo: .headline))
                .foregroundStyle(CobaltColor.text)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Button(Copy.ChatActivity.attachConfirm(picked.count)) {
                attach(picked)
                dismiss()
            }
            .buttonStyle(.cobaltPrimary(fullWidth: false))
            .disabled(picked.isEmpty)
        }
    }

    private func tile(_ row: LibraryRow) -> some View {
        let on = picked.contains(row.id)
        return Button {
            if on {
                picked.removeAll { $0 == row.id }
            } else if picked.count < room {
                picked.append(row.id)
            }
        } label: {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { FacePicture(item: row.item, maxPixel: 300, gradient: 0) }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(on ? CobaltColor.text : .clear, lineWidth: 2)
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: on ? Symbol.chatPicked : Symbol.chatUnpicked)
                        .font(.system(size: 18))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(on ? CobaltColor.onText : .white, on ? CobaltColor.text : .black.opacity(0.35))
                        .padding(6)
                        .accessibilityHidden(true)
                }
                .opacity(!on && picked.count >= room ? 0.4 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
