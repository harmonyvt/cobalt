import AppIntents
import CobaltKit
import Foundation

/// A chat thread, for the "Ask chat" action's "Chat" parameter (CONTRACT-PARALLEL.md 15.10).
struct CobaltChat: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "capystore chat")
    static let defaultQuery = CobaltChatQuery()

    var id: String

    @Property(title: "Title")
    var title: String

    @Property(title: "Updated")
    var updated: Date

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(Copy.Shortcuts.chatSubtitle(updated: updated))")
    }

    init(_ thread: ChatThread) {
        id = thread.id
        title = thread.title.isEmpty ? ChatRule.defaultTitle : thread.title
        updated = thread.updatedAt
    }
}

/// `suggestedEntities()` is the chat list (`GET /chat/threads`), newest first.
struct CobaltChatQuery: EntityQuery {
    @Dependency var actions: ShortcutActions

    func entities(for identifiers: [String]) async throws -> [CobaltChat] {
        await actions.chatThreads(for: identifiers).map(CobaltChat.init)
    }

    func suggestedEntities() async throws -> [CobaltChat] {
        await actions.chatThreads().map(CobaltChat.init)
    }
}

/// "Ask chat" (CONTRACT-PARALLEL.md 15.10): iOS and macOS 27. Sends a message to the chat AI and returns its reply as text,
/// waiting for it in the background. While the AI works, its Live Activity shows what it is doing (thinking, the tool it
/// is using, writing) and the start of the reply once it is done; a tap opens the chat. The reply is in the chat tab too.
@available(iOS 27, macOS 27, *)
struct AskChatIntent: AppIntent, LongRunningIntent, CancellableIntent {
    static let title: LocalizedStringResource = "Ask chat"
    static let description = IntentDescription(
        "Sends a message to capystore's chat AI and returns its reply. With no chat given it starts a new one.",
        categoryName: "capystore")
    static var supportedModes: IntentModes { .background }
    // the reply can read out titles and links from the library
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Message", requestValueDialog: "what do you want to ask?")
    var message: String

    @Parameter(title: "Chat", description: "Empty starts a new chat.")
    var chat: CobaltChat?

    @Parameter(title: "Saves", description: "Saves to ask about (at most 20).", default: [])
    var saves: [CobaltSave]

    @Dependency var actions: ShortcutActions

    static var parameterSummary: some ParameterSummary {
        Summary("Ask chat \(\.$message)") {
            \.$chat
            \.$saves
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        do {
            let cancel = ShortcutCancel()
            progress.totalUnitCount = 100
            let progress = progress
            let report: ShortcutChatProgress = { done, total, words in
                progress.totalUnitCount = total
                progress.completedUnitCount = done
                progress.localizedDescription = words
            }
            let text = message
            let threadID = chat?.id
            let postIDs = Array(saves.map(\.id).prefix(ChatRule.attachmentLimit))
            let actions = actions
            let reply = try await performBackgroundTask(
                operation: { @Sendable in
                    try await actions.askChat(text, threadID: threadID, postIDs: postIDs, cancel: cancel, progress: report)
                },
                onCancel: { _ in cancel.cancel() })
            return .result(value: reply.text, dialog: IntentErrors.dialog(Copy.Shortcuts.chatDialog(reply)))
        } catch {
            throw IntentErrors.map(error)
        }
    }
}

#if os(iOS)
// Lets the action start the reply's Live Activity while capystore is in the background.
@available(iOS 27, *)
extension AskChatIntent: LiveActivityIntent {}
#endif
