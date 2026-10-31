import CobaltKit
import SwiftUI

// The composer at the foot of a thread (APP-API-CONTRACT section 27.4): chips for the posts attached to the next message
// ("ask about this" leaves one there), a multi-line field (1 to 4000 characters) and the send button. Send is off while the
// text is empty or a reply is on its way. Return sends on the Mac (shift-Return is a new line); ⌘Return sends from an iPad's
// keyboard; on an iPhone the keyboard's Return is a new line and the button sends. The text and the chips live in the
// store (`ChatStore.draft`), so they survive leaving the screen.

struct ChatComposer: View {
    let model: AppModel
    let threadID: String
    let content: ChatThreadContent?
    let busy: Bool
    var focus: FocusState<Bool>.Binding
    let send: (String) -> Void

    @State private var attaching = false

    private var store: ChatStore { model.chat }
    private var draft: ChatDraft { store.draft(threadID) }
    private var cleaned: String? { ChatRule.cleanMessage(draft.text) }
    private var canSend: Bool { cleaned != nil && !busy }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !draft.postIDs.isEmpty { chips.padding(.top, 6).padding(.horizontal, 8) }
            HStack(alignment: .bottom, spacing: 4) {
                attachButton
                field
                sendButton
            }
            if draft.text.count >= 3_500 {
                Text(Copy.Chat.characterCount(draft.text.count))
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(draft.text.count > ChatRule.messageLimit ? CobaltColor.errorText : CobaltColor.caption)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        // the send button's 44-point hit area sets the row's height; the field matches it (below) so one line of text sits
        // level with the button instead of at the bottom of a taller row with a gap above it
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        // one floating glass pill, like the tab bar it replaces in a thread
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .animation(Motion.card, value: draft.postIDs)
    }

    // MARK: the field

    private var field: some View {
        TextField(Copy.Chat.placeholder, text: text, axis: .vertical)
            .lineLimit(1...6)
            .font(CobaltType.body)
            .foregroundStyle(CobaltColor.text)
            .focused(focus)
            .textFieldStyle(.plain)
            .padding(.vertical, 6)
            .frame(minHeight: Metrics.hit)
            #if os(macOS)
            .onKeyPress(keys: [.return], phases: .down) { press in
                if press.modifiers.contains(.shift) {
                    store.setDraftText(draft.text + "\n", for: threadID)
                } else if canSend {
                    submit()
                }
                return .handled
            }
            #endif
            .accessibilityLabel(Copy.Chat.placeholder)
    }

    private var text: Binding<String> {
        Binding(
            get: { store.draft(threadID).text },
            set: { store.setDraftText(TitleText.capped($0, limit: ChatRule.messageLimit), for: threadID) })
    }

    private var attachButton: some View {
        Button { attaching = true } label: {
            Label(Copy.ChatActivity.attach, systemImage: Symbol.chatAttach)
        }
        .buttonStyle(.cobaltIcon(.small))
        .disabled(draft.postIDs.count >= ChatRule.attachmentLimit)
        .sheet(isPresented: $attaching) {
            ChatAttachSheet(model: model, already: draft.postIDs) { ids in
                store.attach(ids, to: threadID)
            }
        }
    }

    private var sendButton: some View {
        // the composer's one filled icon: an arrow in a solid circle; while a reply comes it pulses and stays off
        Button(action: submit) {
            Label(Copy.Chat.send, systemImage: Symbol.chatSendArrow)
        }
        .buttonStyle(.cobaltIcon(.small, prominent: true, state: busy ? .working : .idle))
        .disabled(!canSend)
        .keyboardShortcut(.return, modifiers: .command)
        .accessibilityLabel(busy ? Copy.Chat.sending : Copy.Chat.send)
        .accessibilityHint(Copy.Chat.sendA11yHint)
    }

    private func submit() {
        guard let cleaned, !busy else { return }
        send(cleaned)
    }

    // MARK: the attached posts

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(draft.postIDs, id: \.self) { id in
                    AttachmentChip(model: model, post: content?.posts[id] ?? model.library.post(id: id)) {
                        store.detach(id, from: threadID)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Chat.attached)
    }
}

/// A post attached to the next message: its picture, its title, and an x that takes it off.
private struct AttachmentChip: View {
    let model: AppModel
    let post: LibraryPost?
    let remove: () -> Void

    var body: some View {
        let row = post.map { LibraryRow(item: model.mediaItem(for: $0)) }
        HStack(spacing: 6) {
            if let row {
                FacePicture(item: row.item, maxPixel: 96)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .accessibilityHidden(true)
            } else {
                Image(systemName: Symbol.chatRemoved)
                    .font(.system(size: 14))
                    .foregroundStyle(CobaltColor.caption)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
            }
            Text(row?.title ?? Copy.Chat.removed)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.text)
                .lineLimit(1)
                .frame(maxWidth: 150, alignment: .leading)
            Button(action: remove) {
                Image(systemName: Symbol.chatDetach)
                    .font(.system(size: 16))
                    .foregroundStyle(CobaltColor.caption)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Copy.Chat.removeAttachment(row?.title ?? Copy.Chat.removed))
        }
        .padding(.leading, 4)
        .padding(.trailing, 2)
        .padding(.vertical, 3)
        .background(CobaltColor.surface, in: Capsule())
    }
}
