import CobaltKit
import Observation
import SwiftUI

// What the chat list and a thread's screen share (APP-API-CONTRACT section 27): making a thread, the rename sheet and the
// delete confirm. Each screen owns its own controller (a pushed screen leaves the one underneath mounted, so two screens
// must never present from one piece of state) and applies `.chatPresentations(_:)`.

/// The push to a thread's screen (the id; the screen reads the live thread from the store).
struct ChatRoute: Hashable, Identifiable {
    let id: String
}

@MainActor @Observable
final class ChatController {
    let model: AppModel

    /// The thread the owner chose `rename` for: the sheet is open on it.
    var renaming: ChatThread?
    /// The thread the owner chose `delete` for: the confirm is open on it.
    var deleting: ChatThread?
    /// A new thread is being made (the button is dimmed meanwhile).
    var making = false
    /// Threads whose DELETE is in flight.
    var deletingIDs: Set<String> = []
    /// +1 when a delete lands (success haptic) or a new chat or a delete fails (error haptic).
    var doneTick = 0
    var failTick = 0

    init(model: AppModel) {
        self.model = model
    }

    var store: ChatStore { model.chat }

    /// "new chat": makes an empty thread and opens it with the keyboard up.
    func newChat(shell: ShellActions) {
        guard !making else { return }
        making = true
        Task {
            defer { making = false }
            do {
                let made = try await store.create()
                store.openThreadID = made.id
                store.focusComposer()
            } catch {
                shell.showStatus(Copy.Chat.message(for: error))
                failTick += 1
            }
        }
    }

    /// Deletes a thread after the confirm. `done` runs once it is gone (a thread's own screen pops).
    func delete(_ thread: ChatThread, shell: ShellActions, done: @escaping () -> Void = {}) {
        guard !deletingIDs.contains(thread.id) else { return }
        deletingIDs.insert(thread.id)
        Task {
            defer { deletingIDs.remove(thread.id) }
            do {
                try await store.delete(thread.id)
                shell.showStatus(Copy.Chat.deleted)
                doneTick += 1
                done()
            } catch {
                shell.showStatus(Copy.Chat.message(for: error))
                failTick += 1
            }
        }
    }
}

private struct ChatPresentations: ViewModifier {
    @Bindable var controller: ChatController
    let deleted: () -> Void

    @Environment(\.shell) private var shell

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                Copy.Chat.deleteTitle, isPresented: deletingPresented, titleVisibility: .visible,
                presenting: controller.deleting
            ) { thread in
                Button(Copy.Chat.delete, role: .destructive) { controller.delete(thread, shell: shell, done: deleted) }
                Button(Copy.Chat.keep, role: .cancel) {}
            } message: { _ in
                Text(Copy.Chat.deleteMessage)
            }
            .sheet(item: $controller.renaming) { thread in
                ChatRenameSheet(model: controller.model, thread: thread)
            }
            .haptic(.success, trigger: controller.doneTick)
            .haptic(.error, trigger: controller.failTick)
    }

    private var deletingPresented: Binding<Bool> {
        Binding(get: { controller.deleting != nil }, set: { if !$0 { controller.deleting = nil } })
    }
}

extension View {
    /// The delete confirm and the rename sheet of `controller`; `deleted` runs after a delete the owner confirmed.
    func chatPresentations(_ controller: ChatController, deleted: @escaping () -> Void = {}) -> some View {
        modifier(ChatPresentations(controller: controller, deleted: deleted))
    }
}

// MARK: - the rename sheet

/// The rename sheet: one name field (save is enabled only when `ChatRule.cleanTitle` accepts it). A refusal shows inside
/// the sheet, which stays open.
struct ChatRenameSheet: View {
    let model: AppModel
    let thread: ChatThread

    @Environment(\.dismiss) private var dismiss
    @Environment(\.shell) private var shell
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var name: String
    @State private var saving = false
    @State private var problem: String?
    @FocusState private var focused: Bool

    init(model: AppModel, thread: ChatThread) {
        self.model = model
        self.thread = thread
        _name = State(initialValue: thread.title)
    }

    private var cleaned: String? { ChatRule.cleanTitle(name) }
    private var canSave: Bool { cleaned != nil && !saving }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Copy.Chat.renameTitle)
                .font(Font.cobalt(16, .semibold, relativeTo: .headline))
                .foregroundStyle(CobaltColor.text)
                .accessibilityAddTraits(.isHeader)
            field
            if let problem {
                Text(problem)
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.errorText)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            HStack(spacing: 8) {
                Button(Copy.Chat.cancel) { dismiss() }
                    .buttonStyle(.cobaltSecondary())
                    .keyboardShortcut(.cancelAction)
                    .disabled(saving)
                Button(Copy.Chat.save) { save() }
                    .buttonStyle(.cobaltPrimary())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 12)
        #if os(macOS)
        .frame(width: 420)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents(typeSize.isAccessibilitySize ? [.height(260), .large] : [.height(200)])
        .presentationDragIndicator(.visible)
        #endif
        .background(CobaltColor.bg)
        .interactiveDismissDisabled(saving)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Chat.renameTitle)
        .task {
            // after the sheet's rise has settled: focus asked for sooner is dropped
            try? await Task.sleep(for: .milliseconds(500))
            focused = true
        }
    }

    private var field: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                TextField(Copy.Chat.namePlaceholder, text: $name)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit { if canSave { save() } }
                    .font(CobaltType.body)
                    .foregroundStyle(CobaltColor.text)
                    .accessibilityLabel(Copy.Chat.nameField)
                if !name.isEmpty {
                    Button {
                        name = ""
                        focused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(CobaltColor.caption)
                            .frame(width: Metrics.hit, height: Metrics.hit)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Copy.Media.clearTitle)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, name.isEmpty ? 12 : 0)
            .frame(minHeight: Metrics.hit)
            .background(CobaltColor.elevated, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
            .onChange(of: name) { _, now in
                let cut = TitleText.capped(now, limit: ChatRule.titleLimit)
                if cut != now { name = cut }
                problem = nil
            }
            if name.unicodeScalars.count >= 50 {
                Text(Copy.Chat.nameCount(name.unicodeScalars.count))
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.caption)
                    .monospacedDigit()
            }
        }
    }

    private func save() {
        guard let cleaned, !saving else { return }
        saving = true
        problem = nil
        Task {
            defer { saving = false }
            do {
                if cleaned != thread.title {
                    try await model.chat.rename(thread.id, to: cleaned)
                    shell.showStatus(Copy.Chat.renamed)
                }
                dismiss()
            } catch {
                problem = Copy.Chat.message(for: error)
            }
        }
    }
}
