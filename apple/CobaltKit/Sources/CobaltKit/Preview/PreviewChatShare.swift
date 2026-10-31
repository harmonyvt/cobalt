import Foundation
import Synchronization

// Chats shared as web pages in previews (APP-API-CONTRACT 46): every chat starts not shared. Sharing gives a link up to
// the chat's latest message; rotating gives a new key; stopping forgets it.

/// What the preview "server" holds for `/chat/threads/<id>/share`, and every call made (`"PUT <id>"`, `"ROTATE <id>"`).
final class PreviewChatShareState: Sendable {
    private struct State {
        var shares: [String: ChatShare] = [:]
        var counter = 900
        var calls: [String] = []
    }

    private let state = Mutex(State())

    var calls: [String] { state.withLock { $0.calls } }
    func record(_ call: String) { state.withLock { $0.calls.append(call) } }
    func share(_ id: String) -> ChatShare? { state.withLock { $0.shares[id] } }

    func put(_ id: String, _ change: ChatShareChange, messages: [ChatMessage], now: Date) -> ChatShare {
        state.withLock { s in
            let shown = messages.filter { $0.status != .running }
            var share = s.shares[id] ?? {
                s.counter += 1
                return ChatShare(
                    url: Self.url(s.counter), threadID: id, uptoID: shown.last?.id ?? "0", uptoAt: shown.last?.createdAt,
                    messages: shown.count, behind: 0, files: Set(shown.flatMap(\.postIDs)).count, media: true, code: false,
                    createdAt: now, updatedAt: now)
            }()
            if change.toLatest {
                share.uptoID = shown.last?.id ?? share.uptoID
                share.uptoAt = shown.last?.createdAt
                share.files = Set(shown.flatMap(\.postIDs)).count
            }
            if let media = change.media { share.media = media }
            if let code = change.code { share.code = code }
            let upto = messages.firstIndex { $0.id == share.uptoID }.map { $0 + 1 } ?? messages.count
            share.messages = upto
            share.behind = max(0, messages.count - upto)
            share.updatedAt = now
            s.shares[id] = share
            return share
        }
    }

    func rotate(_ id: String, now: Date) -> ChatShare? {
        state.withLock { s in
            guard var share = s.shares[id] else { return nil }
            s.counter += 1
            share.url = Self.url(s.counter)
            share.createdAt = now
            share.opened = 0
            share.lastOpenedAt = nil
            s.shares[id] = share
            return share
        }
    }

    func stop(_ id: String) -> Bool { state.withLock { $0.shares.removeValue(forKey: id) != nil } }

    static func url(_ n: Int) -> URL {
        URL(string: "https://share.capybaraharmony.com/c/\(PreviewPrivateState.key(n))")!
    }
}

extension PreviewClient {
    public func chatShare(threadID: String) async throws -> ChatShare? {
        chatShareState.record("GET " + threadID)
        try await clock.sleep(seconds: 0.2 * timeScale)
        guard scenario.hasChat else { throw PipelineFailure.unsupported }
        guard chatState.thread(threadID) != nil else { throw ChatError.notFound }
        return chatShareState.share(threadID)
    }

    public func shareChat(threadID: String, _ change: ChatShareChange) async throws -> ChatShare {
        chatShareState.record("PUT " + threadID)
        try await clock.sleep(seconds: 0.4 * timeScale)
        guard scenario.hasChat else { throw PipelineFailure.unsupported }
        guard chatState.thread(threadID) != nil else { throw ChatError.notFound }
        let messages = chatState.messages(threadID)
        if messages.isEmpty, chatShareState.share(threadID) == nil {
            throw CobaltError.api(code: "error.chat_share.empty", httpStatus: 409)
        }
        return chatShareState.put(threadID, change, messages: messages, now: clock.now())
    }

    public func rotateChatShare(threadID: String) async throws -> ChatShare {
        chatShareState.record("ROTATE " + threadID)
        try await clock.sleep(seconds: 0.3 * timeScale)
        guard scenario.hasChat else { throw PipelineFailure.unsupported }
        guard let share = chatShareState.rotate(threadID, now: clock.now()) else {
            throw CobaltError.api(code: "error.chat_share.not_found", httpStatus: 404)
        }
        return share
    }

    public func stopChatShare(threadID: String) async throws {
        chatShareState.record("DELETE " + threadID)
        try await clock.sleep(seconds: 0.3 * timeScale)
        guard scenario.hasChat else { throw PipelineFailure.unsupported }
        guard chatShareState.stop(threadID) else { throw CobaltError.api(code: "error.chat_share.not_found", httpStatus: 404) }
    }
}
