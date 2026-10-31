import CobaltKit
import SwiftUI

// One thread (APP-API-CONTRACT section 27.4): its messages in a list anchored to the bottom, the reply streaming into it
// (code steps collapsed, the shown files as thumbnails that open the post), and the composer. The list follows the reply
// while the owner is at the bottom and lets go the moment they scroll up. A shown file opens the way the library opens
// one: on iPhone the detail is pushed here; on iPad and Mac the library tab reveals the post. A thread whose chat started
// helpers (APP-API-CONTRACT 43.6) shows them as a strip under the header; a helper's own thread opens in a sheet with this
// same screen, read-only: its mail with the chat on top and a footer instead of the composer.

struct ChatThreadScreen: View {
    let model: AppModel
    let threadID: String
    let tier: Tier
    /// Set when this is a helper's own thread opened from its parent (the parent's id): read-only, in a sheet.
    var helperOf: String? = nil

    @Environment(\.shell) private var shell
    @Environment(\.dismiss) private var dismiss
    @Environment(\.hapticsEnabled) private var haptics
    @State private var controller: ChatController
    /// The phone's pushed detail of a shown file.
    @State private var opened: OpenedMedia?
    @State private var atBottom = true
    @State private var sent = 0
    /// Counts the confirm cards answered yes / no, for their haptics.
    @State private var confirmedYes = 0
    @State private var confirmedNo = 0
    @FocusState private var composerFocused: Bool

    init(model: AppModel, threadID: String, tier: Tier, helperOf: String? = nil) {
        self.model = model
        self.threadID = threadID
        self.tier = tier
        self.helperOf = helperOf
        _controller = State(initialValue: ChatController(model: model))
    }

    private var store: ChatStore { model.chat }
    private var content: ChatThreadContent? { store.content(of: threadID) }
    private var busy: Bool { store.isBusy(threadID) }
    private var title: String { content?.thread.title ?? store.thread(threadID)?.title ?? Copy.Chat.title }
    /// A helper's thread (43.1): only its parent writes to it.
    private var readOnly: Bool { helperOf != nil || content?.isAgentThread == true }
    /// "make video" (APP-API-CONTRACT 45): the server makes chat videos and the thread has something to show.
    private var canMakeVideo: Bool { model.canMakeChatVideos && !readOnly && content?.messages.isEmpty == false }

    var body: some View {
        Group {
            if let content {
                messages(content)
            } else {
                placeholder
            }
        }
        .background(CobaltColor.bg)
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(iOS)
            QueueToolbarItem(model: model)
            #endif
            ToolbarItem(placement: .primaryAction) { menu }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let content, readOnly {
                ChatHelperFooter(model: model, content: content, parentID: helperOf ?? content.agent?.parent)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            } else if content != nil {
                ChatComposer(
                    model: model, threadID: threadID, content: content, busy: busy, focus: $composerFocused
                ) { send($0) }
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
        }
        .modifier(ChatHelperChrome(model: model, threadID: threadID, shows: !readOnly && content != nil))
        .task(id: threadID) {
            await store.load(threadID)
            if !readOnly { await focusIfAsked() }
        }
        .onChange(of: store.composerFocus) { if !readOnly { Task { await focusIfAsked() } } }
        .navigationDestination(item: $opened) { target in
            MediaDetail(model: model, item: target.item, initial: target.initial)
        }
        .chatPresentations(controller) {
            store.openThreadID = nil
            dismiss()
        }
        .haptic(.impact(weight: .light), trigger: sent, enabled: haptics)
        .modifier(ReplyHaptics(status: content?.messages.last?.status))
        .modifier(ConfirmHaptics(yes: confirmedYes, no: confirmedNo))
    }

    // MARK: the messages

    private func scrollToken(_ content: ChatThreadContent) -> String {
        guard let last = content.messages.last else { return "empty" }
        return "\(content.messages.count)|\(last.id)|\(last.text.count)|\(last.steps.count)|\(last.steps.last?.status.rawValue ?? "")|\(last.postIDs.count)|\(last.ranked?.hits.count ?? 0)|\(last.status.rawValue)|\(content.messages.compactMap(\.confirm?.status.rawValue).joined())"
    }

    private func messages(_ content: ChatThreadContent) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let parent = helperOf ?? content.agent?.parent {
                        ChatHelperMail(mail: store.agents(of: parent).mail(with: threadID))
                    }
                    if content.messages.isEmpty, !readOnly { emptyHint }
                    ForEach(content.messages) { message in
                        ChatMessageView(
                            model: model, message: message, content: content, tier: tier, open: open,
                            retry: { send($0, attaching: false) }, canRetry: !busy,
                            answer: { answer($0, yes: $1) },
                            answering: message.confirm.map { store.answeringConfirms.contains($0.id) } ?? false,
                            canMakeVideo: canMakeVideo && !busy,
                            makeVideo: { controller.video = ChatVideoRequest(threadID: threadID, from: $0) })
                            .equatable()
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            // Short threads sit at the bottom. The start at the newest message is a `scrollTo` below, not an anchor: an
            // initial-offset anchor keeps re-applying until the first drag, so a collage loading more pinned the list to
            // its new bottom instead of leaving it where "show 30 more" was.
            .defaultScrollAnchor(.bottom, for: .alignment)
            .defaultScrollAnchor(.top, for: .sizeChanges)
            .defaultScrollAnchor(.top, for: .initialOffset)
            .onAppear { DispatchQueue.main.async { proxy.scrollTo(Self.bottom, anchor: .bottom) } }
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 72
            } action: { _, now in
                atBottom = now
            }
            .onChange(of: scrollToken(content)) {
                if atBottom { proxy.scrollTo(Self.bottom, anchor: .bottom) }
            }
            .onChange(of: sent) {
                atBottom = true
                withAnimation(Motion.card) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !atBottom, busy {
                    Button {
                        withAnimation(Motion.card) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                    } label: {
                        Image(systemName: Symbol.chatLatest)
                            .font(.system(size: 30))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(CobaltColor.onText, CobaltColor.text)
                    }
                    .buttonStyle(.plain)
                    .padding(14)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel(Copy.Chat.latest)
                }
            }
            .motion(Motion.card, value: atBottom)
        }
    }

    private static let bottom = "chat-bottom"

    private var emptyHint: some View {
        VStack(spacing: 6) {
            Image(systemName: Symbol.chatEmpty)
                .font(.system(size: 28))
                .foregroundStyle(CobaltColor.caption)
                .accessibilityHidden(true)
            Text(Copy.Chat.threadEmptyTitle).font(CobaltType.bodySemibold).foregroundStyle(CobaltColor.text)
            Text(Copy.Chat.threadEmptyBody)
                .font(CobaltType.caption)
                .foregroundStyle(CobaltColor.caption)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var placeholder: some View {
        switch store.loadStates[threadID] {
        case .failed:
            ContentUnavailableView {
                Label(Copy.Chat.threadFailed, systemImage: Symbol.error).font(CobaltType.body)
            } actions: {
                Button(Copy.Chat.retry, systemImage: Symbol.retry) { Task { await store.load(threadID) } }
                    .buttonStyle(.cobaltSecondary(fullWidth: false))
            }
        case .gone:
            ContentUnavailableView {
                Label(Copy.Chat.threadGone, systemImage: Symbol.chatEmpty).font(CobaltType.body)
            }
        default:
            VStack(spacing: 10) {
                ProgressView()
                Text(Copy.Chat.threadLoading).font(CobaltType.caption).foregroundStyle(CobaltColor.caption)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: the menu

    @ViewBuilder
    private var menu: some View {
        if !readOnly, let thread = content?.thread ?? store.thread(threadID) {
            Menu {
                Button(Copy.Chat.rename, systemImage: Symbol.chatRename) { controller.renaming = thread }
                if canMakeVideo {
                    Button(Copy.Chat.makeVideo, systemImage: Symbol.chatVideo) {
                        controller.video = ChatVideoRequest(threadID: thread.id, from: nil)
                    }
                    .disabled(busy)
                }
                Divider()
                Button(Copy.Chat.delete, systemImage: Symbol.chatDelete, role: .destructive) { controller.deleting = thread }
            } label: {
                Label(Copy.Chat.menu, systemImage: Symbol.chatMenu)
                    .labelStyle(.iconOnly)
            }
            .iconName(Copy.Chat.menu)
        }
    }

    // MARK: actions

    /// Sends the composer's text (with the attached posts) or, for "try again", the text a failed reply answered (nothing
    /// attached). A refusal before the stream shows as a status line; the composer keeps what was typed.
    private func send(_ text: String, attaching: Bool = true) {
        let ids = attaching ? store.draft(threadID).postIDs : []
        sent += 1
        Task {
            do {
                try await store.send(text: text, postIDs: ids, in: threadID)
            } catch {
                shell.showStatus(Copy.Chat.message(for: error))
            }
        }
    }

    /// A confirm card's "delete 3" / "make private" (yes) or "cancel" (no). The answer streams the reply on into the
    /// thread like a send; a card the server no longer has shows as a status line and the thread reloads.
    private func answer(_ card: ChatConfirm, yes: Bool) {
        if yes { confirmedYes += 1 } else { confirmedNo += 1 }
        atBottom = true
        Task {
            do {
                try await store.answer(card, yes: yes, in: threadID)
            } catch {
                shell.showStatus(Copy.Chat.message(for: error))
            }
        }
    }

    /// A shown file: the phone pushes its detail, the iPad and Mac show it in the library tab (the inspector).
    private func open(_ post: LibraryPost) {
        if tier == .compact {
            let item = model.mediaItem(for: post)
            opened = OpenedMedia(item: item, initial: item.face.id)
        } else {
            model.revealInLibrary(postID: post.id)
        }
    }

    private func focusIfAsked() async {
        guard store.takeComposerFocus() else { return }
        // after the push has settled: focus asked for sooner is dropped
        try? await Task.sleep(for: .milliseconds(600))
        composerFocused = true
    }
}

/// A confirm card answered: a firm thud for the yes that changes the library, a soft tick for "cancel".
private struct ConfirmHaptics: ViewModifier {
    let yes: Int
    let no: Int

    func body(content: Content) -> some View {
        content
            .haptic(.impact(weight: .heavy), trigger: yes)
            .haptic(.impact(weight: .light), trigger: no)
    }
}

/// The reply finishing, or failing: felt as well as seen. Its own modifier so the screen's chain stays small enough
/// for the type checker.
private struct ReplyHaptics: ViewModifier {
    let status: ChatMessage.Status?

    func body(content: Content) -> some View {
        content
            .hapticChange(.success, trigger: status) { (old: ChatMessage.Status?, new: ChatMessage.Status?) in
                old == .running && new == .done
            }
            .hapticChange(.error, trigger: status) { (old: ChatMessage.Status?, new: ChatMessage.Status?) in
                old == .running && new == .error
            }
    }
}
