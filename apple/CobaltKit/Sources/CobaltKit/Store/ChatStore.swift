import Foundation
import Observation

// Chat (APP-API-CONTRACT 27): the threads the owner has with Claude about the library. `ChatThreadContent` is one open
// thread and the pure rules that apply a reply's events to it; `ChatStore` lists, creates, renames and deletes threads,
// sends a message and applies the reply as it streams, and follows a reply whose stream dropped by reading the thread
// again every 2 s (at most 3 minutes), then calls it interrupted.

// MARK: - one open thread

/// What the app holds of one thread: the thread, every message oldest first, and the library posts they reference.
/// `apply(_:)` is the whole of what a reply's events do to it.
public struct ChatThreadContent: Sendable, Equatable {
    public var thread: ChatThread
    public var messages: [ChatMessage]
    /// Keyed by the post's id. A post a message references that is not here was deleted: draw "removed".
    public var posts: [String: LibraryPost]

    public init(thread: ChatThread, messages: [ChatMessage] = [], posts: [String: LibraryPost] = [:]) {
        self.thread = thread
        self.messages = messages
        self.posts = posts
    }

    public init(_ detail: ChatThreadDetail) {
        self.init(thread: detail.thread, messages: detail.messages, posts: detail.posts)
    }

    /// The last message is still being written.
    public var isReplying: Bool { messages.last.map { $0.role == .assistant && $0.status == .running } ?? false }

    /// A job the chat handed to the server is still going (33.14): the server adds a reply by itself when it ends.
    public var isWaitingOnJob: Bool { messages.contains { $0.role == .assistant && $0.steps.contains(where: \.isWaitingJob) } }

    /// The posts of a message, in its order; ids with no post (deleted) are skipped.
    public func posts(of message: ChatMessage) -> [LibraryPost] { message.postIDs.compactMap { posts[$0] } }

    /// The text of the user message that came before `message` (what a "try again" sends), nil when there is none.
    public func prompt(before message: ChatMessage) -> ChatMessage? {
        guard let i = messages.firstIndex(where: { $0.id == message.id }) else { return nil }
        return messages[..<i].last { $0.role == .user }
    }

    // MARK: events

    /// Applies one event of the reply stream:
    /// - `user` replaces the app's stand-in for it (or is appended);
    /// - `assistant` is appended (a message already there is replaced);
    /// - `text` is appended to the running message, in order;
    /// - `step` replaces the step with the same id, or is appended;
    /// - `posts` appends the ids the message does not show yet, and merges the shapes;
    /// - `collage` sets the collage of the running message; `ranked` sets its scored list (and merges the shapes);
    /// - `confirm` sets the card on its message (or updates its status after an answer);
    /// - `title` and `done` carry the thread as it is now; `done` replaces the message;
    /// - `error` marks the message failed (with the saved one when the server sent it).
    public mutating func apply(_ event: ChatEvent) {
        switch event {
        case .user(let message):
            if let i = messages.firstIndex(where: { $0.isLocal && $0.role == .user }) {
                messages[i] = message
            } else {
                upsert(message)
            }
        case .assistant(let message):
            upsert(message)
        case .text(let delta):
            edit { $0.text += delta }
        case .step(let step):
            edit { message in
                if let i = message.steps.firstIndex(where: { $0.id == step.id }) {
                    message.steps[i] = step
                } else {
                    message.steps.append(step)
                }
            }
        case .posts(let ids, let shown):
            for post in shown { posts[post.id] = post }
            edit { message in
                for id in ids where !message.postIDs.contains(id) { message.postIDs.append(id) }
            }
        case .collage(let collage):
            edit { $0.collage = collage }
        case .ranked(let ranked, let shown):
            for post in shown { posts[post.id] = post }
            edit { $0.ranked = ranked }
        case .title(let renamed):
            thread = renamed
        case .confirm(let messageID, let card):
            if let messageID, let i = messages.firstIndex(where: { $0.id == messageID }) {
                messages[i].confirm = card
            } else if let i = messages.lastIndex(where: { $0.confirm?.id == card.id }) {
                messages[i].confirm = card
            } else {
                edit { $0.confirm = card }
            }
        case .done(let message, let current):
            replaceAssistant(with: message)
            thread = current
        case .error(let code, let saved):
            if var saved {
                saved.status = .error
                saved.error = saved.error ?? code
                replaceAssistant(with: saved)
            } else if assistantIndex() != nil {
                edit { $0.status = .error; $0.error = code }
            } else {
                messages.append(ChatMessage(
                    id: "\(ChatMessage.localPrefix)error", role: .assistant, status: .error, error: code,
                    createdAt: messages.last?.createdAt ?? Date()))
            }
        }
    }

    private mutating func upsert(_ message: ChatMessage) {
        if let i = messages.firstIndex(where: { $0.id == message.id }) { messages[i] = message } else { messages.append(message) }
    }

    /// The assistant message events act on: the running one, else the last.
    private func assistantIndex() -> Int? {
        messages.lastIndex { $0.role == .assistant && $0.status == .running }
            ?? messages.lastIndex { $0.role == .assistant }
    }

    private mutating func edit(_ change: (inout ChatMessage) -> Void) {
        guard let i = assistantIndex() else { return }
        change(&messages[i])
    }

    /// The final (or failed) message takes the place of the same id, else of the running assistant message, else the end.
    private mutating func replaceAssistant(with message: ChatMessage) {
        if let i = messages.firstIndex(where: { $0.id == message.id }) {
            messages[i] = message
        } else if let i = assistantIndex(), messages[i].status == .running {
            messages[i] = message
        } else {
            messages.append(message)
        }
    }
}

/// How far one collage has been read (27.5): the post ids loaded so far in order, their shapes, where the next page
/// starts, and whether a page is on its way or failed. Held by `ChatStore.collagePages`, per message.
public struct ChatCollageState: Sendable, Equatable {
    /// Post ids in the order the server listed them, no duplicates, only posts the server sent a shape for.
    public var postIDs: [String] = []
    public var posts: [String: LibraryPost] = [:]
    /// The offset of the next page; 0 before the first, nil once the last has been read.
    public var next: Int? = 0
    /// At least one page has been read.
    public var loaded = false
    public var loading = false
    /// The last request failed (the pages already read stay).
    public var failed = false
    /// The collage's size as the last page said it.
    public var total: Int?
    /// Which read this state belongs to: an answer for another one (the collage was replaced) is dropped.
    var token = 0

    public init() {}

    /// Takes a page that was asked for at `offset`: its posts and shapes are added after the ones read, an id already
    /// there or one with no shape is skipped, and `next` follows the page. A `next` that does not move past `offset` would
    /// be asked for again forever, so it ends the collage instead.
    mutating func absorb(_ page: ChatCollagePage, asked offset: Int) {
        posts.merge(page.posts) { _, new in new }
        var seen = Set(postIDs)
        for id in page.postIDs where page.posts[id] != nil && seen.insert(id).inserted { postIDs.append(id) }
        next = page.next.flatMap { $0 > offset ? $0 : nil }
        total = page.total
        loaded = true
        loading = false
        failed = false
    }

    /// The loaded posts, in order.
    public var loadedPosts: [LibraryPost] { postIDs.compactMap { posts[$0] } }

    /// More pages can be asked for (also the retry after a failure).
    public var hasMore: Bool { next != nil }

    /// How many posts the next page brings, at most `page`, given the collage's `total`.
    public func nextCount(total: Int, page: Int = ChatRule.collagePage) -> Int {
        guard let next else { return 0 }
        return max(1, min(page, total - next))
    }
}

/// What is typed and attached for a thread but not sent: "ask about this" leaves the post here until the first message.
public struct ChatDraft: Sendable, Equatable {
    public var text: String
    public var postIDs: [String]

    public init(text: String = "", postIDs: [String] = []) {
        self.text = text
        self.postIDs = postIDs
    }

    public var isEmpty: Bool { text.isEmpty && postIDs.isEmpty }
}

// MARK: - the store

@MainActor @Observable
public final class ChatStore {
    public enum State: Equatable, Sendable {
        case idle
        /// A `refresh()` is running. `threads` still holds what was listed before, if anything.
        case loading
        case loaded
        /// The last `refresh()` failed, with the error to word. `threads` still holds what was listed before.
        case failed(ChatFailure)
    }

    /// Why a list or a read failed (the UI words it; the store only classifies).
    public enum ChatFailure: Equatable, Sendable {
        case off, unavailable, offline, other
    }

    /// Where reading one thread is.
    public enum LoadState: Equatable, Sendable {
        case loading, loaded, failed
        /// The server does not know the thread (deleted elsewhere).
        case gone
    }

    /// The threads, most recently updated first.
    public private(set) var threads: [ChatThread] = []
    public private(set) var state: State = .idle
    /// The threads read so far (and the ones just made).
    public private(set) var contents: [String: ChatThreadContent] = [:]
    public private(set) var loadStates: [String: LoadState] = [:]
    /// Threads with a reply on its way from this device (streaming or being followed).
    public private(set) var sendingIDs: Set<String> = []
    /// Confirm cards whose answer is on its way (33.5): their buttons wait.
    public private(set) var answeringConfirms: Set<String> = []
    /// What is typed and attached per thread.
    public private(set) var drafts: [String: ChatDraft] = [:]
    /// The thread the chat tab shows (its screen is pushed); nil shows the list.
    public var openThreadID: String?
    /// Bumped when the composer should take the keyboard ("ask about this" or "new chat" opened a thread).
    public private(set) var composerFocus = 0
    @ObservationIgnored private var composerFocusTaken = 0

    /// How often a reply that lost its stream is read again, and for how long (27.2: every 2 s, at most 3 minutes).
    public static let pollInterval = 2.0
    public static let pollLimit = Int(180.0 / pollInterval)
    /// How often an open thread whose chat handed a job to the server is read again, and for how long (33.14: the server
    /// continues the chat when the job ends; it gives up on a job after an hour).
    public static let jobPollInterval = 4.0
    public static let jobPollLimit = Int(3600.0 / jobPollInterval)

    /// The collages read so far, by the message that carries them (27.5).
    public private(set) var collagePages: [String: ChatCollageState] = [:]
    public static let collagePageSize = ChatRule.collagePage
    @ObservationIgnored private var collageTokens = 0

    @ObservationIgnored private let ctx: PipelineContext
    /// Bumped by `reset()`: an answer from the old server arriving later is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var followers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var jobWatchers: [String: Task<Void, Never>] = [:]
    /// The reply activities (iOS only; nil on the Mac, in previews and in tests unless one is injected).
    @ObservationIgnored var live: ChatLiveManager?

    init(context: PipelineContext) {
        self.ctx = context
    }

    // MARK: the list

    /// Lists the threads again (`GET /chat/threads`). A refresh that is already running is not doubled. A failure keeps
    /// what was listed before.
    public func refresh() async {
        guard state != .loading else { return }
        let started = generation
        state = .loading
        do {
            let listed = try await ctx.client.chatThreads()
            guard started == generation else { return }
            threads = listed.sorted { $0.updatedAt > $1.updatedAt }
            for thread in listed where contents[thread.id] != nil { contents[thread.id]?.thread = thread }
            state = .loaded
        } catch {
            guard started == generation else { return }
            state = .failed(Self.failure(for: error))
        }
    }

    /// The thread with this id, as the list or the open thread has it.
    public func thread(_ id: String) -> ChatThread? {
        threads.first { $0.id == id } ?? contents[id]?.thread
    }

    /// Makes a thread (`POST /chat/threads`) and puts it first, read and empty. Throws `ChatError` (`.tooMany` at 200) or
    /// whatever the transport threw; nothing is inserted then. `title` is cleaned with `ChatRule.cleanTitle` (a title
    /// that does not clean is not sent, so the thread is "new chat").
    @discardableResult
    public func create(title: String? = nil) async throws -> ChatThread {
        let started = generation
        let made = try await ctx.client.createChatThread(title: title.flatMap(ChatRule.cleanTitle))
        if started == generation {
            put(made)
            if contents[made.id] == nil { contents[made.id] = ChatThreadContent(thread: made) }
            loadStates[made.id] = .loaded
        }
        return made
    }

    /// Renames a thread (`PATCH`). The answer replaces the local one. A title `ChatRule.cleanTitle` refuses is
    /// `ChatError.badRequest`, and nothing is sent. A thread the server no longer knows is dropped locally.
    @discardableResult
    public func rename(_ id: String, to raw: String) async throws -> ChatThread {
        guard let title = ChatRule.cleanTitle(raw) else { throw ChatError.badRequest }
        let started = generation
        do {
            let renamed = try await ctx.client.renameChatThread(id: id, title: title)
            if started == generation {
                put(renamed)
                contents[id]?.thread = renamed
            }
            return renamed
        } catch ChatError.notFound {
            if started == generation { forget(id) }
            throw ChatError.notFound
        }
    }

    /// Deletes a thread and its messages (`DELETE`). A thread the server no longer knows is gone already, so it goes
    /// locally too; any other error leaves it and is thrown.
    public func delete(_ id: String) async throws {
        let started = generation
        do {
            try await ctx.client.deleteChatThread(id: id)
        } catch ChatError.notFound {
            // already gone
        }
        if started == generation { forget(id) }
    }

    // MARK: one thread

    /// Reads a thread (`GET /chat/threads/<id>`): its messages and posts. While a reply is on its way from this device the
    /// messages are left alone (the stream is the newer truth); a reply the server is still writing (another device, a
    /// relaunch) is followed.
    public func load(_ id: String) async {
        let started = generation
        if contents[id] == nil || loadStates[id] == nil { loadStates[id] = .loading }
        do {
            let detail = try await ctx.client.chatThread(id: id)
            guard started == generation else { return }
            if sendingIDs.contains(id) {
                contents[id]?.posts.merge(detail.posts) { _, new in new }
            } else {
                adopt(detail)
            }
            loadStates[id] = .loaded
            if contents[id]?.isReplying == true, !sendingIDs.contains(id) { follow(id) }
        } catch ChatError.notFound {
            guard started == generation else { return }
            forget(id)
            loadStates[id] = .gone
        } catch {
            guard started == generation else { return }
            if contents[id] == nil { loadStates[id] = .failed }
        }
    }

    public func content(of id: String) -> ChatThreadContent? { contents[id] }

    /// A reply is on its way: sent from this device (streaming or followed), or the server is still writing the last one.
    public func isBusy(_ id: String) -> Bool {
        sendingIDs.contains(id) || contents[id]?.isReplying == true
    }

    // MARK: collages

    /// Reads the first page of a message's collage (`GET .../collage?offset=0&limit=30`). Nothing happens when the collage
    /// has been asked for already (loading, loaded, or failed: `loadMoreCollage` retries).
    public func loadCollage(threadID: String, messageID: String) async {
        guard collagePages[messageID] == nil else { return }
        collageTokens += 1
        var state = ChatCollageState()
        state.token = collageTokens
        collagePages[messageID] = state
        await fetchCollage(threadID: threadID, messageID: messageID)
    }

    /// Reads the next page and appends it (also the retry of a page that failed, the first included). Nothing happens
    /// while a page is on its way or after the last one.
    public func loadMoreCollage(threadID: String, messageID: String) async {
        guard let state = collagePages[messageID], !state.loading, state.next != nil else { return }
        await fetchCollage(threadID: threadID, messageID: messageID)
    }

    private func fetchCollage(threadID: String, messageID: String) async {
        guard var state = collagePages[messageID], !state.loading, let offset = state.next else { return }
        let token = state.token
        let started = generation
        state.loading = true
        state.failed = false
        collagePages[messageID] = state
        do {
            let page = try await ctx.client.chatCollage(
                threadID: threadID, messageID: messageID, offset: offset, limit: Self.collagePageSize)
            guard started == generation, collagePages[messageID]?.token == token else { return }
            var now = collagePages[messageID] ?? state
            now.absorb(page, asked: offset)
            collagePages[messageID] = now
        } catch {
            guard started == generation, collagePages[messageID]?.token == token else { return }
            collagePages[messageID]?.loading = false
            collagePages[messageID]?.failed = true
        }
    }

    /// Forgets the collages that are no longer what their message says: the message lost its collage, or the collage
    /// has a different size (a later call replaced it), so the next read starts from the first page.
    private func pruneCollagePages(of id: String) {
        guard let content = contents[id] else { return }
        for message in content.messages {
            guard let state = collagePages[message.id] else { continue }
            if message.collage == nil || (state.total != nil && state.total != message.collage?.total) {
                collagePages[message.id] = nil
            }
        }
    }

    // MARK: the draft

    public func draft(_ id: String) -> ChatDraft { drafts[id] ?? ChatDraft() }

    public func setDraftText(_ text: String, for id: String) {
        var draft = drafts[id] ?? ChatDraft()
        draft.text = text
        drafts[id] = draft.isEmpty ? nil : draft
    }

    /// Attaches posts to the next message (at most `ChatRule.attachmentLimit`, no duplicates).
    public func attach(_ postIDs: [String], to id: String) {
        var draft = drafts[id] ?? ChatDraft()
        for postID in postIDs where !draft.postIDs.contains(postID) && draft.postIDs.count < ChatRule.attachmentLimit {
            draft.postIDs.append(postID)
        }
        drafts[id] = draft.isEmpty ? nil : draft
    }

    public func detach(_ postID: String, from id: String) {
        guard var draft = drafts[id] else { return }
        draft.postIDs.removeAll { $0 == postID }
        drafts[id] = draft.isEmpty ? nil : draft
    }

    /// Asks for the composer's keyboard once the thread's screen is up.
    public func focusComposer() { composerFocus += 1 }

    /// True once per `focusComposer()`: the screen that takes it focuses its composer.
    public func takeComposerFocus() -> Bool {
        guard composerFocus > composerFocusTaken else { return false }
        composerFocusTaken = composerFocus
        return true
    }

    /// "ask about this": makes a thread (`POST /chat/threads`) with these posts attached to its draft, so they go with the
    /// first message the owner sends. The thread opens (`openThreadID`) and the composer asks for the keyboard. The posts
    /// are kept with the thread so the chips can draw them. Throws what `create` throws.
    @discardableResult
    public func startThread(with postIDs: [String], posts: [LibraryPost] = []) async throws -> ChatThread {
        let made = try await create()
        for post in posts { contents[made.id]?.posts[post.id] = post }
        attach(postIDs, to: made.id)
        openThreadID = made.id
        focusComposer()
        return made
    }

    // MARK: sending

    /// Sends a message and applies the reply as it streams (`POST /chat/threads/<id>/messages`): the user message
    /// appears at once, then the assistant's text, steps and shown posts as their events arrive, the title, and the final
    /// message. Returns when the reply is done, failed (the message says so), or could not be followed.
    ///
    /// Throws, with nothing changed (the draft is put back), when the server refuses before the stream: `ChatError.busy`,
    /// `.full`, `.notFound`, `.off`, `.badRequest`, `.unavailable`, or the transport's error when the message never
    /// reached it. A stream that drops after the reply began is followed by reading the thread every 2 s while its last
    /// message is running (3 minutes at most, then it is marked `error.chat.interrupted`).
    ///
    /// `source` is what the reply's Live Activity says it came from; `onEvent` sees every event of the reply as it is
    /// applied (the "Ask chat" Shortcut's progress).
    public func send(
        text: String, postIDs: [String] = [], in id: String, source: ChatLiveSource = .app,
        onEvent: (@MainActor (ChatEvent) -> Void)? = nil
    ) async throws {
        guard let cleaned = ChatRule.cleanMessage(text) else { throw ChatError.badRequest }
        guard !isBusy(id) else { throw ChatError.busy }
        var attached: [String] = []
        for postID in postIDs where !attached.contains(postID) && attached.count < ChatRule.attachmentLimit { attached.append(postID) }
        let started = generation
        sendingIDs.insert(id)
        defer { sendingIDs.remove(id) }

        if contents[id] == nil, let thread = thread(id) { contents[id] = ChatThreadContent(thread: thread) }
        guard contents[id] != nil else { throw ChatError.notFound }
        let baseCount = contents[id]?.messages.count ?? 0
        let stand = ChatMessage(
            id: "\(ChatMessage.localPrefix)\(UUID().uuidString)", role: .user, text: cleaned, postIDs: attached,
            createdAt: ctx.clock.now())
        contents[id]?.messages.append(stand)
        let kept = drafts[id]
        drafts[id] = nil
        live?.began(thread: id, prompt: cleaned, source: source)
        var refusal: ChatError?
        defer {
            // only a message after this send's own (a rollback leaves the thread's earlier reply last)
            let messages = contents[id]?.messages ?? []
            let last = messages.count > baseCount + 1 ? messages.last : nil
            live?.ended(thread: id, final: last?.role == .assistant ? last : nil, code: refusal?.code ?? ChatError.interrupted.code)
        }

        var received = 0
        var finished = false
        var failure: Error?
        do {
            for try await event in ctx.client.sendChatMessage(threadID: id, text: cleaned, postIDs: attached) {
                guard started == generation else { return }
                received += 1
                apply(event, to: id)
                onEvent?(event)
                if event.isFinal { finished = true }
            }
        } catch {
            failure = error
        }
        guard started == generation else { return }
        if finished { return }

        if received == 0 {
            // Nothing came back. A refusal is final; a dropped connection may still have reached the server.
            if let refused = failure as? ChatError {
                refusal = refused
                rollback(id, stand: stand.id, draft: kept)
                throw refused
            }
            if await !serverHasMessages(beyond: baseCount, in: id, started: started) {
                rollback(id, stand: stand.id, draft: kept)
                throw failure ?? CobaltError.network(.networkConnectionLost)
            }
        }
        await poll(id, started: started)
    }

    // MARK: confirm cards

    /// Answers a confirm card (`POST /chat/threads/<id>/confirm/<card id>`, APP-API-CONTRACT 33.5): yes runs the call the
    /// chat asked for, no drops it, and either way the reply goes on and is applied as it streams (the card's new status
    /// first, then a new assistant message). A second tap while the answer is on its way does nothing.
    ///
    /// Throws, with nothing changed, when the server refuses before the stream: `ChatError.confirmGone` (answered elsewhere,
    /// expired or replaced; the thread is read again so the card shows what became of it), `.busy`, `.notFound`, `.off`,
    /// `.unavailable`, or the transport's error. A stream that drops later is followed like a send's.
    public func answer(_ card: ChatConfirm, yes: Bool, in id: String) async throws {
        guard !answeringConfirms.contains(card.id) else { return }
        guard !isBusy(id) else { throw ChatError.busy }
        let started = generation
        sendingIDs.insert(id)
        answeringConfirms.insert(card.id)
        defer {
            sendingIDs.remove(id)
            answeringConfirms.remove(card.id)
        }
        let baseCount = contents[id]?.messages.count ?? 0

        var received = 0
        var finished = false
        var failure: Error?
        do {
            for try await event in ctx.client.answerChatConfirm(threadID: id, confirmID: card.id, yes: yes) {
                guard started == generation else { return }
                received += 1
                apply(event, to: id)
                if event.isFinal { finished = true }
            }
        } catch {
            failure = error
        }
        guard started == generation else { return }
        if finished { return }

        if received == 0 {
            if let refused = failure as? ChatError {
                if refused == .confirmGone {
                    // what became of the card is the server's: read the thread again
                    sendingIDs.remove(id)
                    await load(id)
                }
                throw refused
            }
            if await !serverHasMessages(beyond: baseCount, in: id, started: started) {
                throw failure ?? CobaltError.network(.networkConnectionLost)
            }
        }
        await poll(id, started: started)
    }

    private func rollback(_ id: String, stand: String, draft: ChatDraft?) {
        contents[id]?.messages.removeAll { $0.id == stand }
        if let draft, drafts[id] == nil { drafts[id] = draft }
    }

    /// One read after a stream that said nothing: did the server save the message? If so the thread is adopted.
    private func serverHasMessages(beyond count: Int, in id: String, started: Int) async -> Bool {
        guard let detail = try? await ctx.client.chatThread(id: id), started == generation, detail.messages.count > count else {
            return false
        }
        adopt(detail)
        return true
    }

    // MARK: following a reply

    /// Reads the thread every 2 s while its last message is running (the first read at once), up to 3 minutes. A reply
    /// still running then is marked interrupted. Used after a dropped stream and for a reply another device started.
    private func poll(_ id: String, started: Int) async {
        for attempt in 0..<Self.pollLimit {
            if attempt > 0 {
                do { try await ctx.clock.sleep(seconds: Self.pollInterval) } catch { return }
            }
            guard started == generation else { return }
            do {
                let detail = try await ctx.client.chatThread(id: id)
                guard started == generation else { return }
                adopt(detail)
                if !(contents[id]?.isReplying ?? false) { return }
            } catch ChatError.notFound {
                guard started == generation else { return }
                forget(id)
                loadStates[id] = .gone
                return
            } catch {
                continue                                         // a bad read; the next one may work
            }
        }
        guard started == generation else { return }
        markInterrupted(id)
    }

    private func follow(_ id: String) {
        guard followers[id] == nil else { return }
        let started = generation
        sendingIDs.insert(id)
        followers[id] = Task { [weak self] in
            guard let self else { return }
            await self.poll(id, started: started)
            guard started == self.generation else { return }
            self.followers[id] = nil
            self.sendingIDs.remove(id)
        }
    }

    /// While the open thread waits on a job its chat handed to the server (33.14), reads it every 4 s (at most an hour)
    /// until the server's new reply shows up; a reply it is still writing is then followed like any other. Stops when the
    /// thread is no longer open (opening it again reads it, which starts this again).
    private func watchJobs(_ id: String) {
        guard jobWatchers[id] == nil, contents[id]?.isWaitingOnJob == true else { return }
        let started = generation
        jobWatchers[id] = Task { [weak self] in
            guard let self else { return }
            defer { if started == self.generation { self.jobWatchers[id] = nil } }
            for _ in 0..<Self.jobPollLimit {
                do { try await self.ctx.clock.sleep(seconds: Self.jobPollInterval) } catch { return }
                guard started == self.generation, self.openThreadID == id, self.contents[id]?.isWaitingOnJob == true else { return }
                // a reply streaming from this device is the newer truth
                if self.sendingIDs.contains(id) { continue }
                guard let detail = try? await self.ctx.client.chatThread(id: id), started == self.generation else { continue }
                if self.sendingIDs.contains(id) { continue }
                self.adopt(detail)
                if self.contents[id]?.isReplying == true {
                    self.follow(id)
                    return
                }
            }
        }
    }

    private func markInterrupted(_ id: String) {
        guard var content = contents[id], content.isReplying else { return }
        content.apply(.error(code: ChatError.interrupted.code, message: nil))
        contents[id] = content
    }

    // MARK: state

    private func apply(_ event: ChatEvent, to id: String) {
        contents[id]?.apply(event)
        live?.observe(event, thread: id)
        switch event {
        case .collage:
            // a later collage of the same reply replaces the earlier one: start the pages over
            if let message = contents[id]?.messages.last(where: { $0.role == .assistant }) { collagePages[message.id] = nil }
        case .title(let thread): put(thread)
        case .done(let message, let thread):
            put(thread)
            pruneCollagePages(of: id)
            watchJobs(id)
            // the ranked list names posts the stream may not have shipped: read the thread for their shapes
            if let ranked = message.ranked, let have = contents[id]?.posts, ranked.hits.contains(where: { have[$0.postID] == nil }) {
                Task { await load(id) }
            }
        default: break
        }
    }

    private func adopt(_ detail: ChatThreadDetail) {
        let id = detail.thread.id
        var merged = contents[id]?.posts ?? [:]
        merged.merge(detail.posts) { _, new in new }
        contents[id] = ChatThreadContent(thread: detail.thread, messages: detail.messages, posts: merged)
        put(detail.thread)
        pruneCollagePages(of: id)
        watchJobs(id)
    }

    /// A thread as the server just answered it: in the list, ordered by when it changed.
    private func put(_ thread: ChatThread) {
        threads.removeAll { $0.id == thread.id }
        threads.append(thread)
        threads.sort { $0.updatedAt > $1.updatedAt }
    }

    private func forget(_ id: String) {
        threads.removeAll { $0.id == id }
        for message in contents[id]?.messages ?? [] { collagePages[message.id] = nil }
        contents[id] = nil
        drafts[id] = nil
        followers[id]?.cancel()
        followers[id] = nil
        jobWatchers[id]?.cancel()
        jobWatchers[id] = nil
        if openThreadID == id { openThreadID = nil }
    }

    /// Tests: an open thread the store did not read.
    func seed(_ content: ChatThreadContent) {
        contents[content.thread.id] = content
        loadStates[content.thread.id] = .loaded
        put(content.thread)
    }

    /// Another server or key: nothing from the old one is kept.
    func reset() {
        generation += 1
        live?.reset()
        for task in followers.values { task.cancel() }
        followers = [:]
        for task in jobWatchers.values { task.cancel() }
        jobWatchers = [:]
        threads = []
        contents = [:]
        collagePages = [:]
        loadStates = [:]
        sendingIDs = []
        answeringConfirms = []
        drafts = [:]
        openThreadID = nil
        state = .idle
    }

    /// What kind of failure an error is, for the failed state.
    static func failure(for error: Error) -> ChatFailure {
        switch error {
        case ChatError.off: return .off
        case ChatError.unavailable: return .unavailable
        case CobaltError.network: return .offline
        default: return .other
        }
    }
}
