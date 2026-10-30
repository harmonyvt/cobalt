import Foundation
import Synchronization

// Chat in previews (APP-API-CONTRACT 27): a server with `features.chat`, three sample threads (one with code steps and
// shown posts, one with a failed step, one with a deleted post), and a canned reply that streams the way the real one does:
// the user message, a running code step that finishes, the text word by word, the shown posts, a new title, the end.
// A fourth thread ("every cat i saved") ends in a collage (27.5): 95 generated posts, served 30 at a time, with one of them
// deleted since; the replies in that thread (and any message that says "collage") stream a `collage` event too.
// `PreviewScenario.chatEmpty` has no threads, `.chatFail` cannot list them, `.chatReplyFails` ends every reply in
// `error.chat.model`. `.happy` and `.renditions` have the three samples. `.chatConfirm` adds a fifth thread whose last reply
// waits on a confirm card (33.5): answering it streams the card's new status and a short reply.

extension PreviewScenario {
    /// The preview server has `features.chat`.
    var hasChat: Bool {
        switch self {
        case .happy, .renditions, .chatEmpty, .chatFail, .chatReplyFails, .chatConfirm, .hidden: return true
        default: return false
        }
    }
}

extension PreviewData {
    /// The post ids the canned reply shows (the first three of the preview library), in order.
    static func chatShownPostIDs(now: Date) -> [String] { Array(libraryPage(now: now).posts.prefix(3).map(\.id)) }

    static let chatThreadIDs = ["PrEvIeWchat00001", "PrEvIeWchat00002", "PrEvIeWchat00003", "PrEvIeWchat00004"]
    /// The sample thread that ends in a collage, and the id of that message.
    static let collageThreadID = chatThreadIDs[3]
    static let collageMessageID = "132"
    /// What the preview collage says it holds, and what it is called.
    static let collageTotal = 95
    static let collage = ChatCollage(title: "every cat", query: "cats", total: collageTotal)
    /// The position of the collage post that "was deleted since": its page comes back one post short.
    static let collageGoneIndex = 41

    /// The collage's `collageTotal` posts, in order: the preview library's posts again under new ids, at mixed aspects.
    static func collagePosts(now: Date) -> [LibraryPost] {
        let base = libraryPage(now: now).posts
        guard !base.isEmpty else { return [] }
        let shapes: [(Int, Int)] = [(720, 1280), (1080, 1080), (1920, 1080), (480, 600), (1080, 1350), (1280, 720), (720, 1280)]
        let names = [
            "sleepy cat", "cat versus cucumber", "the cat on the stairs", "loaf", "window cat", "kitten, first day", "zoomies at 3 am",
            "cat and the printer", "cat in a box", "slow blink",
        ]
        return (0..<collageTotal).map { i in
            var post = base[i % base.count]
            let shape = shapes[i % shapes.count]
            post.id = String(format: "PrEvIeWcat%04d", i)
            post.link = nil
            post.session = nil
            post.title = i < names.count ? names[i] : "\(names[i % names.count]) \(i / names.count + 1)"
            post.customTitle = nil
            post.width = shape.0
            post.height = shape.1
            post.files = post.files.enumerated().map { n, file in
                var file = file
                file.id = "PrEvIeWcatfile\(i)-\(n)"
                if file.width != nil { file.width = shape.0 }
                if file.height != nil { file.height = shape.1 }
                return file
            }
            return post
        }
    }
    /// The `.chatConfirm` thread, the message that asks, and its card.
    static let confirmThreadID = "PrEvIeWchat00005"
    static let confirmMessageID = "142"
    static let confirmCardID = "PrEvIeWcard00001"

    /// "tidy up the timer clips": the chat found three timer clips and asks before deleting them.
    static func chatConfirmSeed(now: Date) -> (thread: ChatThread, messages: [ChatMessage]) {
        func t(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let shown = chatShownPostIDs(now: now)
        let card = ChatConfirm(
            id: confirmCardID, op: "library.delete", summary: "delete 3 posts",
            effect: ChatConfirmEffect(
                titles: ["the timer one", "the timer, again", "timer (final)"], posts: 3, files: 3, bytes: 18_400_000,
                publicLinks: 1, shareLinks: 1),
            status: .waiting, expiresAt: now.addingTimeInterval(14 * 60))
        let code = """
        const timers = (await cobalt.library.list({ query: "timer" })).map(p => p.id);
        await cobalt.show(timers);
        return await cobalt.library.delete(timers);
        """
        let thread = ChatThread(
            id: confirmThreadID, title: "tidy up the timer clips", createdAt: t(2), updatedAt: t(1),
            preview: "found 3 timer clips. tap delete if you're sure (=^･ω･^=)", messageCount: 2)
        let messages = [
            ChatMessage(id: "141", role: .user, text: "delete all the kitchen timer clips, i'm over them", createdAt: t(2)),
            ChatMessage(
                id: confirmMessageID, role: .assistant, text: "found 3 timer clips. tap delete if you're sure (=^･ω･^=)",
                postIDs: shown,
                steps: [
                    ChatStep(id: "toolu_31", status: .done, code: code, logs: [], result: #"{"pending_confirm":{"id":"PrEvIeWcard00001"}}"#, durationMS: 380),
                    ChatStep(id: confirmCardID, kind: "confirm", status: .done, result: card.summary),
                ],
                confirm: card, createdAt: t(1)),
        ]
        return (thread, messages)
    }

    /// A post a sample message shows that the library no longer has (the "removed" tile).
    static let chatGonePostID = "PrEvIeWgone000001"

    /// Every kind of tool card (APP-API-CONTRACT 38), drawn from the preview library: a search, a look, trending 7TV
    /// emotes, an edit with an emote and a cutout on overlay layers, a render, a box command, a box save, a share link and
    /// a collection. The canned reply's code step carries them.
    static func chatToolCalls(now: Date) -> [ChatToolCall] {
        let ids = Array(libraryPage(now: now).posts.prefix(4).map(\.id))
        guard ids.count == 4 else { return [] }
        func emote(_ id: String, _ name: String) -> ChatToolCard.Emotes.Emote {
            .init(id: id, name: name, url: URL(string: "https://cdn.7tv.app/emote/\(id)/2x.webp")!)
        }
        let emotes = [
            emote("01F6MQ33FG000FFJ97ZB8MWV52", "catJAM"), emote("01F6ME9FRG0005TFYTWP1H8R42", "catJam"),
            emote("01GDGFJEWG000BMR7QE2FQC25Z", "catJAM"), emote("01FSJ3RPM00000JPZ36BHMF681", "catJAM"),
            emote("01FBFM0TZR0006C5E1Y5NP9ZTA", "catJAM"), emote("01G3NZ2G0G000E830Z7JV4DWB2", "catJAM"),
        ]
        let edit = ChatToolCard.Edit(
            projectID: "PrEvIeWedit00001", title: "harbour then the timer", revision: 4, duration: 34.4, width: 720, height: 1280,
            change: .updated,
            tracks: [
                .init(isMain: true, clips: [
                    .init(id: "m1", postID: ids[0], title: "the harbour clip", at: 0, length: 18, sourceIn: 0, sourceOut: 18),
                    .init(id: "m2", postID: ids[1], title: "the timer one", at: 18, length: 16.4, sourceIn: 4, sourceOut: 24.5, speed: 1.25, pitch: 3),
                ]),
                .init(isMain: false, index: 0, clips: [
                    .init(id: "o1", kind: .emote, title: "catJAM", picture: emotes[0].url, at: 3, length: 6, sourceOut: 6, isNew: true),
                ]),
                .init(isMain: false, index: 1, clips: [
                    .init(id: "o2", postID: ids[2], kind: .cutout, title: "capy cutout", at: 20, length: 9, sourceOut: 9),
                ]),
            ])
        return [
            ChatToolCall(op: "library.search", ms: 640, card: .search(.init(
                query: "harbour dog", total: 38, hits: zip(ids, [0.62, 0.58, 0.51, 0.44]).map { .init(postID: $0, score: $1) }))),
            ChatToolCall(op: "look", ms: 12, card: .look(postIDs: Array(ids.prefix(3)))),
            ChatToolCall(op: "emotes.find", ms: 410, card: .emotes(.init(query: "catJAM", sort: "trending_weekly", emotes: emotes))),
            ChatToolCall(op: "box.run", ms: 6_200, card: .box(.init(
                cmd: #"ffmpeg -hide_banner -loglevel error -y -i capy.png -vf "colorkey=0xFFFFFF:0.18:0.05" out/capy_cutout.png"#,
                code: 0, stdout: "capy_cutout.png  412 KB"))),
            ChatToolCall(op: "box.save", ms: 900, card: .files(.init(isIn: false, files: [.init(name: "capy_cutout.png", bytes: 412_000)], postID: ids[2]))),
            ChatToolCall(op: "edits.update", ms: 80, card: .edit(edit)),
            ChatToolCall(op: "edits.render", ms: 300, card: .job(.init(
                op: "edits.render", job: "PrEvIeWjob000001", status: "done", progress: 1, postID: ids[3], kind: "video", seconds: 34.4,
                width: 720, height: 1280, bytes: 10_400_000))),
            ChatToolCall(op: "stage.get", ms: 30, status: .error, error: "cobalt.stage.get: the studio is off"),
            ChatToolCall(op: "links.create", ms: 220, card: .link(.init(
                id: "3301894276177155739", url: URL(string: "https://share.capybaraharmony.com/g/3301894276177155739")!,
                title: "harbour + catJAM", files: 3))),
            ChatToolCall(op: "collections.add", ms: 90, card: .collection(.init(id: "PrEvIeWcoll00001", name: "Lia Share 12", count: 11, change: .added))),
        ]
    }

    /// The three sample threads, newest first, with their messages.
    static func chatSeed(now: Date) -> (threads: [ChatThread], messages: [String: [ChatMessage]]) {
        func t(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let shown = chatShownPostIDs(now: now)

        let code1 = """
        const yesterday = await cobalt.library({ since: "2026-10-17", until: "2026-10-18", limit: 50 });
        const funny = await cobalt.search("funny", 10);
        const ids = new Set(yesterday.map(p => p.id));
        const hits = funny.filter(p => ids.has(p.id)).slice(0, 3);
        await cobalt.show(hits.map(p => p.id));
        return hits.map(p => ({ id: p.id, title: p.title, source: p.source }));
        """
        let result1 = """
        [{"id":"Dd7P496wolG","title":"the dog at the harbour","source":"instagram.com"},
         {"id":"2105435404002562056","title":"the timer one","source":"x.com"},
         {"id":"Dd5JFkMDt4N","title":"coffee and the city","source":"instagram.com"}]
        """
        let reply1 = """
        you saved **12 posts** yesterday. the three funniest:

        1. the dog at the harbour, 14 s. the dog gives up halfway
        2. the timer one, 5 s
        3. coffee and the city, 10 s

        want only the videos, or should i look at the day before too?
        """
        let broken = """
        const longest = await cobalt.library({ limit: 200 }).sort((a, b) => b.duration - a.duration)[0];
        return longest;
        """
        let fixed = """
        const all = await cobalt.library({ limit: 200 });
        all.sort((a, b) => (b.duration ?? 0) - (a.duration ?? 0));
        return { id: all[0].id, duration: all[0].duration, title: all[0].title };
        """

        let thread1 = ChatThread(
            id: chatThreadIDs[0], title: "funny things from yesterday", createdAt: t(40), updatedAt: t(12),
            preview: "the longest one is the harbour clip at 37 s. it is also the one with the dog.", messageCount: 4)
        let messages1 = [
            ChatMessage(id: "101", role: .user, text: "what did i save yesterday? show me the funniest", createdAt: t(40)),
            ChatMessage(
                id: "102", role: .assistant, text: reply1, postIDs: shown,
                steps: [ChatStep(
                    id: "toolu_01", status: .done, code: code1, logs: ["12 posts yesterday", "3 funny ones"],
                    result: result1, durationMS: 820,
                    calls: [
                        ChatToolCall(op: "library.list", ms: 40, card: .search(.init(query: "newest", total: 12, hits: shown.map { .init(postID: $0) }))),
                        ChatToolCall(op: "library.search", ms: 610, card: .search(.init(
                            query: "funny", total: 10, hits: zip(shown, [0.62, 0.58, 0.51]).map { .init(postID: $0, score: $1) }))),
                        ChatToolCall(op: "show", ms: 3),
                    ])],
                createdAt: t(39)),
            ChatMessage(id: "103", role: .user, text: "which one is the longest?", createdAt: t(13)),
            ChatMessage(
                id: "104", role: .assistant,
                text: "the longest one is the harbour clip at 37 s. it is also the one with the dog.",
                postIDs: [shown[0]],
                steps: [
                    ChatStep(
                        id: "toolu_02", status: .error, code: broken, error: "TypeError: cobalt.library(...).sort is not a function",
                        durationMS: 40),
                    ChatStep(
                        id: "toolu_03", status: .done, code: fixed, logs: ["scanned 15 posts"],
                        result: #"{"id":"Dd55fEyN1Yy","duration":37.43,"title":"harbour and the dog"}"#, durationMS: 310),
                ],
                createdAt: t(12)),
        ]

        let thread2 = ChatThread(
            id: chatThreadIDs[1], title: "roast my taste", createdAt: t(200), updatedAt: t(180),
            preview: "mostly dogs, coffee and one very specific obsession with kitchen timers.", messageCount: 2)
        let messages2 = [
            ChatMessage(id: "111", role: .user, text: "roast my taste", createdAt: t(200)),
            ChatMessage(
                id: "112", role: .assistant,
                text: "mostly dogs, coffee and one very specific obsession with kitchen timers.\n\nthree of your last ten saves are the same timer. you are fine. it is fine.",
                steps: [ChatStep(
                    id: "toolu_11", status: .done, code: "return (await cobalt.library({ limit: 10 })).map(p => p.title);",
                    logs: [], result: #"["the dog at the harbour","the timer one","the timer, again"]"#, durationMS: 450)],
                createdAt: t(199)),
        ]

        let thread3 = ChatThread(
            id: chatThreadIDs[2], title: "what is this twitter webp", createdAt: t(2 * 1_440), updatedAt: t(2 * 1_440 - 3),
            preview: "it is a kitchen timer counting down to a pasta joke. the other file is gone from your library.", messageCount: 2)
        let messages3 = [
            ChatMessage(
                id: "121", role: .user, text: "what is this one about?", postIDs: [shown[1]], createdAt: t(2 * 1_440)),
            ChatMessage(
                id: "122", role: .assistant,
                text: "it is a kitchen timer counting down to a pasta joke. the other file is gone from your library.",
                postIDs: [shown[1], chatGonePostID], createdAt: t(2 * 1_440 - 3)),
        ]

        let thread4 = ChatThread(
            id: collageThreadID, title: "every cat i saved", createdAt: t(5 * 1_440), updatedAt: t(5 * 1_440 - 2),
            preview: "found 95 posts with a cat in them. all of them are below, newest first.", messageCount: 2)
        let messages4 = [
            ChatMessage(id: "131", role: .user, text: "show me every cat i saved", createdAt: t(5 * 1_440)),
            ChatMessage(
                id: collageMessageID, role: .assistant,
                text: "found **95 posts** with a cat in them. all of them are below, newest first. the three i would start with are up here:",
                postIDs: shown,
                steps: [ChatStep(
                    id: "toolu_21", status: .done,
                    code: "const cats = await cobalt.search(\"cats\", 500);\nawait cobalt.show(cats.slice(0, 3).map(p => p.id));\nawait cobalt.collage(cats.map(p => p.id), { title: \"every cat\", query: \"cats\" });\nreturn cats.length;",
                    logs: ["95 cats"], result: "95", durationMS: 940)],
                collage: collage, createdAt: t(5 * 1_440 - 2)),
        ]
        return (
            [thread1, thread2, thread3, thread4],
            [thread1.id: messages1, thread2.id: messages2, thread3.id: messages3, thread4.id: messages4])
    }
}

/// What the preview "server" holds for `/chat`, and every call made (`"GET"`, `"POST"`, `"GET <id>"`, `"SEND <id> <text>"`).
final class PreviewChatState: Sendable {
    private struct State {
        var threads: [ChatThread] = []
        var messages: [String: [ChatMessage]] = [:]
        var counter = 300
        var threadCounter = 0
        var calls: [String] = []
        var listFails = false
        var replyFails = false
        var readFails = false
        var collageFails = false
        /// The sends in flight (one reply at a time per thread).
        var replying: Set<String> = []
    }

    private let state = Mutex(State())

    var threads: [ChatThread] { state.withLock { $0.threads } }
    var calls: [String] { state.withLock { $0.calls } }
    func messages(_ id: String) -> [ChatMessage] { state.withLock { $0.messages[id] ?? [] } }

    func seed(_ threads: [ChatThread], messages: [String: [ChatMessage]], listFails: Bool, replyFails: Bool) {
        state.withLock {
            $0.threads = threads
            $0.messages = messages
            $0.listFails = listFails
            $0.replyFails = replyFails
        }
    }

    /// Tests: `GET /chat/threads` answers 503 while this is true.
    var listFails: Bool {
        get { state.withLock { $0.listFails } }
        set { state.withLock { $0.listFails = newValue } }
    }

    /// Tests: every collage page answers 503 while this is true.
    var collageFails: Bool {
        get { state.withLock { $0.collageFails } }
        set { state.withLock { $0.collageFails = newValue } }
    }

    /// The card's message and the card, while it can be answered; marks it answered (the card runs once).
    func takeConfirm(_ cardID: String, in id: String, yes: Bool, at now: Date) throws -> (messageID: String, card: ChatConfirm) {
        try state.withLock { s in
            guard s.threads.contains(where: { $0.id == id }) else { throw ChatError.notFound }
            guard !s.replying.contains(id) else { throw ChatError.busy }
            guard let i = s.messages[id]?.firstIndex(where: { $0.confirm?.id == cardID }),
                  let card = s.messages[id]?[i].confirm, card.isOpen(at: now)
            else { throw ChatError.confirmGone }
            s.messages[id]![i].confirm?.status = yes ? .yes : .no
            return (s.messages[id]![i].id, s.messages[id]![i].confirm!)
        }
    }

    /// Tests: every reply ends in `error.chat.model` while this is true.
    var replyFails: Bool {
        get { state.withLock { $0.replyFails } }
        set { state.withLock { $0.replyFails = newValue } }
    }

    func record(_ call: String) { state.withLock { $0.calls.append(call) } }

    func list() -> [ChatThread]? {
        state.withLock { $0.listFails ? nil : $0.threads.sorted { $0.updatedAt > $1.updatedAt } }
    }

    func thread(_ id: String) -> ChatThread? { state.withLock { s in s.threads.first { $0.id == id } } }

    func nextMessageID() -> String {
        state.withLock { s in
            s.counter += 1
            return String(s.counter)
        }
    }

    func add(title: String?, at now: Date) throws -> ChatThread {
        try state.withLock { s in
            guard s.threads.count < ChatRule.threadCap else { throw ChatError.tooMany }
            s.threadCounter += 1
            let id = "PrEvIeWnew" + String(format: "%06d", s.threadCounter)
            let made = ChatThread(id: id, title: title ?? ChatRule.defaultTitle, createdAt: now, updatedAt: now)
            s.threads.insert(made, at: 0)
            s.messages[id] = []
            return made
        }
    }

    func rename(_ id: String, to title: String, at now: Date) throws -> ChatThread {
        try state.withLock { s in
            guard let i = s.threads.firstIndex(where: { $0.id == id }) else { throw ChatError.notFound }
            s.threads[i].title = title
            s.threads[i].updatedAt = now
            return s.threads[i]
        }
    }

    func remove(_ id: String) -> Bool {
        state.withLock { s in
            guard s.threads.contains(where: { $0.id == id }) else { return false }
            s.threads.removeAll { $0.id == id }
            s.messages[id] = nil
            return true
        }
    }

    /// Takes the thread's one reply slot: `busy` while a reply is running, `full` at 200 messages.
    func beginReply(_ id: String) throws {
        try state.withLock { s in
            guard s.threads.contains(where: { $0.id == id }) else { throw ChatError.notFound }
            guard !s.replying.contains(id) else { throw ChatError.busy }
            guard (s.messages[id]?.count ?? 0) + 2 <= ChatRule.messageCap else { throw ChatError.full }
            s.replying.insert(id)
        }
    }

    func endReply(_ id: String) { state.withLock { _ = $0.replying.remove(id) } }

    func append(_ message: ChatMessage, to id: String) {
        state.withLock { s in
            s.messages[id, default: []].append(message)
            if let i = s.threads.firstIndex(where: { $0.id == id }) {
                s.threads[i].messageCount = s.messages[id]?.count ?? 0
                s.threads[i].updatedAt = message.createdAt
                if !message.text.isEmpty { s.threads[i].preview = String(message.text.prefix(120)) }
            }
        }
    }

    func update(_ messageID: String, in id: String, _ change: (inout ChatMessage) -> Void) {
        state.withLock { s in
            guard let i = s.messages[id]?.firstIndex(where: { $0.id == messageID }) else { return }
            change(&s.messages[id]![i])
            if let t = s.threads.firstIndex(where: { $0.id == id }), !(s.messages[id]![i].text.isEmpty), s.messages[id]![i].role == .assistant {
                s.threads[t].preview = String(s.messages[id]![i].text.prefix(120))
            }
        }
    }

    func setTitle(_ title: String, of id: String) -> ChatThread? {
        state.withLock { s in
            guard let i = s.threads.firstIndex(where: { $0.id == id }) else { return nil }
            s.threads[i].title = title
            return s.threads[i]
        }
    }
}

extension PreviewClient {
    /// `GET /chat/threads`; `.chatFail` answers `503`.
    public func chatThreads() async throws -> [ChatThread] {
        chatState.record("GET")
        try await clock.sleep(seconds: 0.3 * timeScale)
        guard scenario.hasChat else { throw PipelineFailure.unsupported }
        guard let list = chatState.list() else { throw ChatError.unavailable }
        return list
    }

    /// `POST /chat/threads`: "new chat" until the first message; `tooMany` at 200.
    public func createChatThread(title: String?) async throws -> ChatThread {
        chatState.record("POST")
        try await clock.sleep(seconds: 0.3 * timeScale)
        guard scenario.hasChat else { throw PipelineFailure.unsupported }
        var cleaned: String?
        if let title {
            guard let c = ChatRule.cleanTitle(title) else { throw ChatError.badRequest }
            cleaned = c
        }
        return try chatState.add(title: cleaned, at: clock.now())
    }

    /// `GET /chat/threads/<id>`: the messages oldest first and the `posts` the preview library has.
    public func chatThread(id: String) async throws -> ChatThreadDetail {
        chatState.record("GET " + id)
        try await clock.sleep(seconds: 0.25 * timeScale)
        guard scenario.hasChat else { throw PipelineFailure.unsupported }
        guard let thread = chatState.thread(id) else { throw ChatError.notFound }
        let messages = chatState.messages(id)
        let library = PreviewData.libraryPage(now: startedAt).posts
        var posts: [String: LibraryPost] = [:]
        let cardIDs = messages.flatMap { $0.steps.flatMap { $0.calls.compactMap(\.card).flatMap(\.postIDs) } }
        for postID in Set(messages.flatMap { $0.postIDs + ($0.ranked?.hits.map(\.postID) ?? []) } + cardIDs) {
            if let post = library.first(where: { $0.id == postID }) { posts[postID] = post }
        }
        return ChatThreadDetail(thread: thread, messages: messages, posts: posts)
    }

    /// `GET /chat/threads/<id>/messages/<message id>/collage?offset=&limit=` (27.5): a page of the collage, from the
    /// generated posts; the one "deleted since" is left out of its page (so that page is a post short). `notFound` for a
    /// message with no collage, `badRequest` for an offset below 0 or a limit outside 1...60.
    public func chatCollage(threadID: String, messageID: String, offset: Int, limit: Int) async throws -> ChatCollagePage {
        chatState.record("COLLAGE \(threadID) \(messageID) \(offset) \(limit)")
        try await clock.sleep(seconds: 0.35 * timeScale)
        guard scenario.hasChat else { throw PipelineFailure.unsupported }
        guard offset >= 0, (1...60).contains(limit) else { throw ChatError.badRequest }
        guard chatState.thread(threadID) != nil,
              let collage = chatState.messages(threadID).first(where: { $0.id == messageID })?.collage
        else { throw ChatError.notFound }
        if chatState.collageFails { throw ChatError.unavailable }
        let all = PreviewData.collagePosts(now: startedAt)
        let end = min(collage.total, all.count, offset + limit)
        let slice = offset < end ? Array(all[offset..<end]) : []
        let kept = slice.enumerated().filter { offset + $0.offset != PreviewData.collageGoneIndex }.map(\.element)
        return ChatCollagePage(
            title: collage.title, query: collage.query, total: collage.total, offset: offset,
            next: end < collage.total ? end : nil, postIDs: kept.map(\.id),
            posts: Dictionary(uniqueKeysWithValues: kept.map { ($0.id, $0) }))
    }

    /// `PATCH /chat/threads/<id>`: `badRequest` unless the title cleans to 1..60 code points.
    public func renameChatThread(id: String, title: String) async throws -> ChatThread {
        chatState.record("PATCH " + id)
        try await clock.sleep(seconds: 0.3 * timeScale)
        guard scenario.hasChat else { throw PipelineFailure.unsupported }
        guard let cleaned = ChatRule.cleanTitle(title) else { throw ChatError.badRequest }
        return try chatState.rename(id, to: cleaned, at: clock.now())
    }

    /// `DELETE /chat/threads/<id>`: an unknown id is `.notFound`.
    public func deleteChatThread(id: String) async throws {
        chatState.record("DELETE " + id)
        try await clock.sleep(seconds: 0.3 * timeScale)
        guard scenario.hasChat else { throw PipelineFailure.unsupported }
        guard chatState.remove(id) else { throw ChatError.notFound }
    }

    /// `POST /chat/threads/<id>/messages`: the real reply's shape, event by event, with small delays. A refusal
    /// (`busy`, `full`, `notFound`, `badRequest`) finishes the stream before any event.
    public func sendChatMessage(threadID: String, text: String, postIDs: [String]) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard scenario.hasChat else { throw PipelineFailure.unsupported }
                    chatState.record("SEND \(threadID) \(text)")
                    guard let cleaned = ChatRule.cleanMessage(text), postIDs.count <= ChatRule.attachmentLimit else { throw ChatError.badRequest }
                    try chatState.beginReply(threadID)
                    defer { chatState.endReply(threadID) }
                    try await streamReply(threadID: threadID, text: cleaned, postIDs: postIDs) { continuation.yield($0) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `POST /chat/threads/<id>/confirm/<card id>` (33.5): the card's new status, then a short reply that says what
    /// happened. `confirmGone` for a card that was answered or has expired.
    public func answerChatConfirm(threadID: String, confirmID: String, yes: Bool) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard scenario.hasChat else { throw PipelineFailure.unsupported }
                    chatState.record("CONFIRM \(threadID) \(confirmID) \(yes ? "yes" : "no")")
                    try await pause(0.3)
                    let taken = try chatState.takeConfirm(confirmID, in: threadID, yes: yes, at: clock.now())
                    try chatState.beginReply(threadID)
                    defer { chatState.endReply(threadID) }
                    continuation.yield(.confirm(messageID: taken.messageID, taken.card))
                    try await pause(yes ? 0.8 : 0.2)
                    var reply = ChatMessage(id: chatState.nextMessageID(), role: .assistant, status: .running, createdAt: clock.now())
                    chatState.append(reply, to: threadID)
                    continuation.yield(.assistant(reply))
                    let text = yes ? "done, all 3 timer clips are gone. your library feels lighter already ฅ^•ﻌ•^ฅ" : "okay, kept them all. the timers live on (=^･ω･^=)"
                    var streamed = ""
                    for word in Self.words(text) {
                        try await pause(0.045)
                        streamed += word
                        continuation.yield(.text(word))
                    }
                    reply.text = streamed
                    reply.status = .done
                    chatState.update(reply.id, in: threadID) { $0 = reply }
                    guard let thread = chatState.thread(threadID) else { throw ChatError.notFound }
                    continuation.yield(.done(reply, thread))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func pause(_ seconds: Double) async throws { try await clock.sleep(seconds: seconds * timeScale) }

    private func streamReply(threadID: String, text: String, postIDs: [String], emit: @Sendable (ChatEvent) -> Void) async throws {
        let now = clock.now()
        let isFirst = chatState.messages(threadID).isEmpty
        let library = PreviewData.libraryPage(now: startedAt).posts
        let attached = postIDs.filter { id in library.contains { $0.id == id } }

        // the saved user message; a new thread is titled from it (trimmed to 60 code points)
        let user = ChatMessage(id: chatState.nextMessageID(), role: .user, text: text, postIDs: attached, createdAt: now)
        chatState.append(user, to: threadID)
        if isFirst, chatState.thread(threadID)?.title == ChatRule.defaultTitle {
            _ = chatState.setTitle(String(text.unicodeScalars.prefix(ChatRule.titleLimit).map(Character.init)), of: threadID)
        }
        emit(.user(user))
        try await pause(0.25)

        var reply = ChatMessage(id: chatState.nextMessageID(), role: .assistant, status: .running, createdAt: clock.now())
        chatState.append(reply, to: threadID)
        emit(.assistant(reply))
        try await pause(0.35)

        // a code step: running, then done with its logs and result
        let code = """
        const posts = await cobalt.search(\(Self.jsString(text)), 12);
        const top = posts.slice(0, 3);
        console.log(`found ${posts.length}, showing ${top.length}`);
        await cobalt.show(top.map(p => p.id));
        return top.map(p => ({ id: p.id, title: p.title, score: p.score }));
        """
        var step = ChatStep(id: "toolu_\(reply.id)", status: .running, code: code)
        reply.steps = [step]
        chatState.update(reply.id, in: threadID) { $0.steps = [step] }
        emit(.step(step))
        try await pause(1.4)

        if chatState.replyFails {
            step.status = .error
            step.error = "the search is waking up"
            step.durationMS = 1_400
            emit(.step(step))
            let partial = "let me look at that"
            for word in Self.words(partial) {
                try await pause(0.05)
                emit(.text(word))
            }
            reply.text = partial
            reply.steps = [step]
            reply.status = .error
            reply.error = ChatError.model.code
            chatState.update(reply.id, in: threadID) { $0 = reply }
            emit(.error(code: ChatError.model.code, message: reply))
            return
        }

        step.status = .done
        step.logs = ["found 12, showing 3"]
        step.result = #"[{"id":"Dd55fEyN1Yy","score":0.62},{"id":"Dd7P496wolG","score":0.58},{"id":"2105435404002562056","score":0.51}]"#
        step.durationMS = 820
        step.calls = PreviewData.chatToolCalls(now: startedAt)
        reply.steps = [step]
        chatState.update(reply.id, in: threadID) { $0.steps = [step] }
        let cardIDs = Set(step.calls.compactMap(\.card).flatMap(\.postIDs))
        emit(.cardPosts(library.filter { cardIDs.contains($0.id) }))
        emit(.step(step))
        try await pause(0.3)

        // the text, a word or two at a time
        let body = """
        found **12 posts** that fit. these three are the closest:

        1. the harbour clip, 37 s
        2. the dog at the harbour, 14 s
        3. the timer one, 5 s

        say the word and i will narrow it to the videos only.
        """
        var streamed = ""
        for word in Self.words(body) {
            try await pause(0.045)
            streamed += word
            emit(.text(word))
        }
        reply.text = streamed
        chatState.update(reply.id, in: threadID) { $0.text = streamed }
        try await pause(0.2)

        let shown = PreviewData.chatShownPostIDs(now: startedAt)
        let shownPosts = shown.compactMap { id in library.first { $0.id == id } }
        reply.postIDs = shown
        chatState.update(reply.id, in: threadID) { $0.postIDs = shown }
        emit(.posts(ids: shown, posts: shownPosts))
        try await pause(0.3)

        // the collage thread (and a message that says "collage") also attaches the 95-post collage
        if threadID == PreviewData.collageThreadID || text.localizedCaseInsensitiveContains("collage") {
            reply.collage = PreviewData.collage
            chatState.update(reply.id, in: threadID) { $0.collage = PreviewData.collage }
            emit(.collage(PreviewData.collage))
            try await pause(0.3)
        }

        // a message that says "furry" or "rank" also attaches the scored list (34.6) under the text
        if text.localizedCaseInsensitiveContains("furry") || text.localizedCaseInsensitiveContains("rank") {
            let ranked = PreviewData.chatRanked(posts: library)
            reply.ranked = ranked
            chatState.update(reply.id, in: threadID) { $0.ranked = ranked }
            emit(.ranked(ranked, posts: library))
            try await pause(0.3)
        }

        if isFirst, let thread = chatState.setTitle("the harbour clips", of: threadID) {
            emit(.title(thread))
        }
        reply.status = .done
        chatState.update(reply.id, in: threadID) { $0.status = .done }
        guard let thread = chatState.thread(threadID) else { throw ChatError.notFound }
        emit(.done(reply, thread))
    }

    /// Text in pieces that keep their trailing space or newline, so joining them gives the text back.
    static func words(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == " " || ch == "\n" { out.append(current); current = "" }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private static func jsString(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped.prefix(60))\""
    }
}
