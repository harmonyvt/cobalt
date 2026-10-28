import Foundation

// "Ask chat" (CONTRACT-PARALLEL.md 15.10): sends a message to the chat AI (APP-API-CONTRACT 27) and waits for the reply,
// which the action returns. It goes through `ChatStore.send` like the chat tab, so the reply shows in the tab and gets the
// same Live Activity (thinking, tool calls, writing, done), marked as coming from a Shortcut.

/// A finished reply, as the action hands it on.
public struct ShortcutChatReply: Sendable, Equatable {
    /// The reply as the AI wrote it (markdown).
    public var text: String
    /// The same, plain: what Siri reads out.
    public var plain: String
    public var threadID: String
    public var threadTitle: String
    /// Library files the reply shows (thumbnails, collage).
    public var shownPostIDs: [String]
    public var collageTotal: Int?

    public init(text: String, plain: String, threadID: String, threadTitle: String, shownPostIDs: [String], collageTotal: Int?) {
        self.text = text
        self.plain = plain
        self.threadID = threadID
        self.threadTitle = threadTitle
        self.shownPostIDs = shownPostIDs
        self.collageTotal = collageTotal
    }

    /// Opens the thread in the chat tab.
    public var openURL: URL { ChatLiveAttributes.openURL(thread: threadID) }
}

/// The reply's progress for the system's own Live Activity of a long-running action: the words of the chat activity's
/// headline, and a fraction that creeps towards 95% with every event (a reply has no known length) and is 100% at the end.
public typealias ShortcutChatProgress = @MainActor (_ completed: Int64, _ total: Int64, _ words: String) -> Void

extension ShortcutActions {
    /// The threads for the action's "Chat" picker, newest first (`GET /chat/threads`); empty when chat is off or unreachable.
    public func chatThreads() async -> [ChatThread] {
        guard ctx.capabilities.chat || ctx.capabilities.kind == .unreachable else { return [] }
        await model.chat.refresh()
        return model.chat.threads
    }

    /// The threads with these ids, as far as the list knows them.
    public func chatThreads(for ids: [String]) async -> [ChatThread] {
        if ids.contains(where: { model.chat.thread($0) == nil }) { await model.chat.refresh() }
        return ids.compactMap { model.chat.thread($0) }
    }

    /// "Ask chat". `threadID` nil starts a new chat (the AI names it after its first reply); `postIDs` are library posts to
    /// ask about (at most 20). Throws `ShortcutError` for the readiness checks, `ChatError` for a refusal (`.off`, `.busy`,
    /// `.full`, `.notFound`, `.badRequest` for an empty or long message) and for a reply that failed (`.model`,
    /// `.interrupted`), and `CancellationError` when stopped.
    public func askChat(
        _ message: String, threadID: String? = nil, postIDs: [String] = [], cancel: ShortcutCancel = ShortcutCancel(),
        progress: ShortcutChatProgress? = nil
    ) async throws -> ShortcutChatReply {
        guard ChatRule.cleanMessage(message) != nil else { throw ChatError.badRequest }
        _ = try await prepare()
        guard ctx.capabilities.chat else { throw ChatError.off }
        if cancel.isCancelled { throw CancellationError() }

        let chat = model.chat
        let id: String
        if let threadID {
            if chat.thread(threadID) == nil, chat.content(of: threadID) == nil { await chat.load(threadID) }
            if chat.loadStates[threadID] == .gone { throw ChatError.notFound }
            guard chat.thread(threadID) != nil || chat.content(of: threadID) != nil else { throw ChatError.notFound }
            id = threadID
        } else {
            id = try await chat.create().id
        }

        let reporter = ChatProgressReporter(since: ctx.clock.now(), progress: progress)
        let send = Task { @MainActor in
            try await chat.send(text: message, postIDs: postIDs, in: id, source: .shortcut) { event in reporter.feed(event) }
        }
        // the stop button: `cancel` is a flag, so look at it while the reply runs
        let watch = Task { @MainActor in
            while !send.isCancelled {
                if cancel.isCancelled { send.cancel(); return }
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
            }
        }
        defer { watch.cancel() }
        try await withTaskCancellationHandler {
            try await send.value
        } onCancel: {
            send.cancel()
        }
        if cancel.isCancelled || Task.isCancelled { throw CancellationError() }

        guard let content = chat.content(of: id), let last = content.messages.last, last.role == .assistant else {
            throw ChatError.interrupted
        }
        switch last.status {
        case .error:
            throw ChatError(code: last.error ?? "") ?? .model
        case .running:
            throw ChatError.interrupted
        case .done:
            break
        }
        progress?(100, 100, "replied")
        return ShortcutChatReply(
            text: last.text, plain: ChatLiveCopy.plain(last.text), threadID: id, threadTitle: content.thread.title,
            shownPostIDs: last.postIDs, collageTotal: last.collage?.total)
    }

    /// 2% at the start, then towards 95% as events arrive (half way after 40).
    static func chatProgress(events: Int) -> Int64 {
        let x = Double(max(0, events))
        return Int64((2 + 93 * x / (x + 40)).rounded())
    }
}

/// Folds the reply's events into the words and fraction the Shortcut reports.
@MainActor
final class ChatProgressReporter {
    private var tracker: ChatLiveTracker
    private let progress: ShortcutChatProgress?

    init(since: Date, progress: ShortcutChatProgress?) {
        tracker = ChatLiveTracker(since: since)
        self.progress = progress
        progress?(2, 100, ChatLiveCopy.headline(tracker.state))
    }

    func feed(_ event: ChatEvent) {
        _ = tracker.apply(event)
        progress?(ShortcutActions.chatProgress(events: tracker.events), 100, ChatLiveCopy.headline(tracker.state))
    }
}
