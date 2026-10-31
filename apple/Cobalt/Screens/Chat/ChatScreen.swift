import CobaltKit
import SwiftUI

// The chat tab (APP-API-CONTRACT section 27): the threads with Claude about the library, newest first, each with its title,
// the start of the last message and when it changed. "new chat" makes an empty thread and opens it; a row opens its thread
// (a push, `ChatThreadScreen`); swipe or the context menu rename and delete (delete asks first). The list is
// `model.chat` (a refresh on appear and a pull keep it honest).

struct ChatScreen: View {
    let model: AppModel
    let tier: Tier

    @Environment(\.shell) private var shell
    @State private var controller: ChatController

    init(model: AppModel, tier: Tier) {
        self.model = model
        self.tier = tier
        _controller = State(initialValue: ChatController(model: model))
    }

    private var store: ChatStore { model.chat }

    private enum Phase { case loading, failed(ChatStore.ChatFailure), empty, list }

    private var phase: Phase {
        if !store.threads.isEmpty { return .list }
        switch store.state {
        case .idle, .loading: return .loading
        case .failed(let failure): return .failed(failure)
        case .loaded: return .empty
        }
    }

    var body: some View {
        content
            .background(CobaltColor.bg)
            .navigationTitle(Copy.Chat.title)
            .toolbar {
                #if os(iOS)
                QueueToolbarItem(model: model)
                #endif
                ToolbarItem(placement: .primaryAction) {
                    Button(Copy.Chat.newChat, systemImage: Symbol.chatNew) { controller.newChat(shell: shell) }
                        .labelStyle(.iconOnly)
                        .disabled(controller.making)
                        #if os(macOS)
                        .keyboardShortcut("n", modifiers: .command)
                        .help(Copy.Chat.newChat)
                        #endif
                }
                #if os(macOS)
                ToolbarItem(placement: .primaryAction) {
                    Button(Copy.Chat.refresh, systemImage: Symbol.retry) { Task { await store.refresh() } }
                        .labelStyle(.iconOnly)
                        .disabled(store.state == .loading)
                        .keyboardShortcut("r", modifiers: .command)
                        .help(Copy.Chat.refresh)
                }
                #endif
            }
            .task { await store.refresh() }
            .navigationDestination(item: openedThread) { route in
                ChatThreadScreen(model: model, threadID: route.id, tier: tier)
            }
            .chatPresentations(controller)
    }

    private var openedThread: Binding<ChatRoute?> {
        Binding(get: { store.openThreadID.map(ChatRoute.init) }, set: { store.openThreadID = $0?.id })
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text(Copy.Chat.loading).font(CobaltType.caption).foregroundStyle(CobaltColor.caption)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        case .failed(let failure):
            ContentUnavailableView {
                Label(Copy.Chat.failedTitle, systemImage: Symbol.error).font(CobaltType.body)
            } description: {
                Text(Copy.Chat.failedBody(failure)).font(CobaltType.caption)
            } actions: {
                Button(Copy.Chat.retry, systemImage: Symbol.retry) { Task { await store.refresh() } }
                    .buttonStyle(.cobaltSecondary(fullWidth: false))
            }
        case .empty:
            ScrollView {
                ContentUnavailableView {
                    Label(Copy.Chat.emptyTitle, systemImage: Symbol.chatEmpty).font(CobaltType.body)
                } description: {
                    Text(Copy.Chat.emptyBody).font(CobaltType.caption)
                } actions: {
                    Button(Copy.Chat.newChat, systemImage: Symbol.chatNew) { controller.newChat(shell: shell) }
                        .buttonStyle(.cobaltSecondary(fullWidth: false))
                        .disabled(controller.making)
                }
                .padding(.top, 60)
                .frame(maxWidth: .infinity)
            }
            .refreshable { await store.refresh() }
        case .list:
            list
        }
    }

    private var list: some View {
        List {
            if case .failed = store.state {
                Text(Copy.Chat.staleLine)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.errorText)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(store.threads) { thread in
                ChatThreadRow(thread: thread, controller: controller)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .motion(Motion.rows, value: store.threads.map(\.id))
        .refreshable { await store.refresh() }
    }
}

// MARK: - a row

/// A thread's row with everything a list gives it: rename and delete by swipe (iPhone, iPad) and by the context menu.
struct ChatThreadRow: View {
    let thread: ChatThread
    let controller: ChatController

    @Environment(\.dynamicTypeSize) private var typeSize

    private var busy: Bool { controller.deletingIDs.contains(thread.id) }

    var body: some View {
        let when = Format.when(thread.updatedAt, now: Date())
        Button {
            controller.store.openThreadID = thread.id
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(thread.title)
                        .font(CobaltType.bodySemibold)
                        .foregroundStyle(CobaltColor.text)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    Text(thread.preview.isEmpty ? Copy.Chat.noMessages : thread.preview)
                        .font(CobaltType.caption)
                        .foregroundStyle(CobaltColor.caption)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                Text(when)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                    .lineLimit(1)
            }
            .padding(.vertical, 6)
            .frame(minHeight: Metrics.hit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .opacity(busy ? 0.4 : 1)
        .disabled(busy)
        .animation(Motion.fade, value: busy)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.Chat.rowA11y(title: thread.title, preview: thread.preview, when: when))
        .accessibilityAddTraits(.isButton)
        #if os(iOS)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(Copy.Chat.delete, systemImage: Symbol.chatDelete, role: .destructive) { controller.deleting = thread }
            Button(Copy.Chat.rename, systemImage: Symbol.chatRename) { controller.renaming = thread }
                .tint(CobaltColor.focus)
        }
        #endif
        .contextMenu {
            Button(Copy.Chat.rename, systemImage: Symbol.chatRename) { controller.renaming = thread }
            Divider()
            Button(Copy.Chat.delete, systemImage: Symbol.chatDelete, role: .destructive) { controller.deleting = thread }
        }
    }
}
