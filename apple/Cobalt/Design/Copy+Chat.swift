import CobaltKit
import Foundation

/// Copy for chat (APP-API-CONTRACT section 27; all new, lowercase): the chat tab's thread list, a thread's screen, the
/// composer, the code steps and the refusals. Plain values only (counts, dates, CobaltKit types), since `Cobalt/Design`
/// is compiled into the extensions too.
extension Copy {
    enum Chat {
        static let title = "chat"

        // MARK: the thread list

        static let newChat = "new chat"
        static let refresh = "refresh"
        static let loading = "loading chats…"
        static let emptyTitle = "no chats yet"
        static let emptyBody = "ask about your library: what you saved, find a clip, roast your taste"
        static let failedTitle = "can't load your chats"
        static let retry = "try again"
        /// Above the list when a refresh failed but the last list is still shown.
        static let staleLine = "can't reach the server · showing the last list"
        static func failedBody(_ failure: ChatStore.ChatFailure) -> String {
            switch failure {
            case .off: return "chat is off on this server"
            case .unavailable: return "the server can't chat right now"
            case .offline: return "can't reach the server"
            case .other: return "something went wrong"
            }
        }
        static let noMessages = "no messages yet"
        static func messageCount(_ count: Int) -> String { "\(count) \(count == 1 ? "message" : "messages")" }
        static func rowA11y(title: String, preview: String, when: String) -> String {
            preview.isEmpty ? "\(title), \(when)" : "\(title), \(preview), \(when)"
        }

        // MARK: rename and delete

        static let rename = "rename"
        static let renameTitle = "rename chat"
        static let namePlaceholder = "chat name"
        static let nameField = "name"
        static let save = "save"
        static let cancel = "cancel"
        static func nameCount(_ count: Int) -> String { "\(count) of \(ChatRule.titleLimit)" }
        static let delete = "delete"
        static let deleteTitle = "delete this chat?"
        static let deleteMessage = "its messages are deleted too."
        static let keep = "keep"
        static let renamed = "chat renamed"
        static let deleted = "chat deleted"
        static let menu = "chat"

        // MARK: a thread

        static let threadLoading = "loading chat…"
        static let threadFailed = "can't load this chat"
        static let threadGone = "this chat is gone"
        static let threadEmptyTitle = "ask about your library"
        static let threadEmptyBody = "what you saved, a clip you half remember, or what your taste says about you"
        static let working = "thinking…"
        static let latest = "latest"
        static let copyText = "copy text"
        static let you = "you"
        static let claude = "claude"
        static func messageA11y(role: ChatMessage.Role, text: String) -> String {
            "\(role == .user ? you : claude): \(text)"
        }

        // MARK: the composer

        static let placeholder = "ask about your library"
        static let send = "send"
        static let sendA11yHint = "sends the message"
        static let sending = "waiting for the reply"
        static let attached = "asking about"
        static func removeAttachment(_ title: String) -> String { "remove \(title)" }
        static func characterCount(_ count: Int) -> String { "\(count) of \(ChatRule.messageLimit)" }

        // MARK: code steps

        static func ran(seconds: Double?) -> String {
            guard let seconds else { return "ran code" }
            return "ran code · \(duration(seconds))"
        }
        static let running = "running code…"
        // a job the chat handed to the server (APP-API-CONTRACT 33.14)
        static let jobWaiting = "making it… the chat carries on when it's ready"
        static let jobDone = "made it"
        static func jobFailed(_ status: String?) -> String {
            switch status {
            case "timeout": return "it took too long"
            case "cancelled": return "it was cancelled"
            default: return "it didn't finish"
            }
        }
        static let failedStep = "code failed"
        static let code = "code"
        static let logs = "logs"
        static let result = "result"
        static let error = "error"
        static func duration(_ seconds: Double) -> String {
            seconds >= 10 ? "\(Int(seconds.rounded())) s" : String(format: "%.1f s", seconds)
        }
        static func stepA11y(_ title: String, expanded: Bool) -> String { "\(title), \(expanded ? "shown" : "hidden")" }

        // MARK: shown posts

        static let removed = "removed"
        static let removedA11y = "removed from your library"
        static let shownA11y = "files from your library"
        static let openPostA11yHint = "opens it in the library"

        // MARK: a collage (27.5)

        static let collageResults = "results"
        static func collageCount(_ count: Int) -> String { "\(count) \(count == 1 ? "result" : "results")" }
        static func showMore(_ count: Int) -> String { "show \(count) more" }
        static let openInLibrary = "open in library"
        static let collageOpen = "open"
        static let collageShare = "share"
        static let collageFailed = "couldn't load these · try again"
        static func collageA11y(title: String, count: Int) -> String { "\(title), \(collageCount(count))" }
        static func collageShown(_ shown: Int, of total: Int) -> String { "showing \(shown) of \(total)" }

        // MARK: a ranked list (APP-API-CONTRACT 34.6)

        static let rankedResults = "ranked"
        static func rankedCount(_ count: Int) -> String { "\(count) ranked" }
        static func rankedWithin(_ label: String) -> String { "within \(label)" }
        static func rankedA11y(title: String, count: Int) -> String { "\(title), \(rankedCount(count))" }
        static func rankedRowA11y(_ title: String, score: Double?) -> String {
            score.map { "\(title), score \(String(format: "%.2f", $0))" } ?? title
        }

        // MARK: a failed reply

        static let replyFailed = "the reply failed · try again"
        static let replyInterrupted = "the reply was cut off · try again"
        static let tryAgain = "try again"

        // MARK: "ask about this"

        static let askAbout = "ask about this"
        static let askAboutA11yHint = "starts a new chat with this post"

        // MARK: a confirm card (33.7)

        /// The red button of a delete card: "delete 3" / "delete 1".
        static func confirmDelete(_ files: Int) -> String { "delete \(files)" }
        static let confirmMakePrivate = "make private"
        static let confirmYes = "yes"
        static let confirmCancel = "cancel"
        static func confirmButton(_ action: ChatConfirm.Action) -> String {
            switch action {
            case .delete(let files): return confirmDelete(files)
            case .makePrivate: return confirmMakePrivate
            case .other: return confirmYes
            }
        }
        /// "3 posts · 3 files · 18.4 MB · 1 public link stops working · 1 share link shows them": the parts that are there.
        static func confirmEffect(_ effect: ChatConfirmEffect) -> String {
            var parts: [String] = []
            if let posts = effect.posts, posts > 1 { parts.append("\(posts) posts") }
            if let files = effect.files, files > 0 { parts.append("\(files) \(files == 1 ? "file" : "files")") }
            if let bytes = effect.bytes, bytes > 0 { parts.append(Format.bytes(bytes)) }
            if let links = effect.publicLinks, links > 0 {
                parts.append(links == 1 ? "1 public link stops working" : "\(links) public links stop working")
            }
            if let links = effect.shareLinks, links > 0 {
                parts.append(links == 1 ? "1 share link shows them" : "\(links) share links show them")
            }
            return parts.joined(separator: " · ")
        }
        /// The titles the card covers, the first few: "“cat jumps”, “timer 2”".
        static func confirmTitles(_ titles: [String]) -> String {
            titles.prefix(5).map { "“\($0)”" }.joined(separator: ", ")
        }
        static let confirmDone = "done"
        static let confirmKept = "kept · nothing changed"
        static let confirmExpired = "this ask timed out · nothing changed"
        static let confirmAnswering = "on it…"
        static func confirmA11y(summary: String, effect: String) -> String {
            effect.isEmpty ? "asks first: \(summary)" : "asks first: \(summary), \(effect)"
        }
        static let confirmGone = "that ask is gone · nothing changed"

        // MARK: refusals

        static let busy = "wait for the reply to finish"
        static let full = "this chat is full · start a new one"
        static let tooMany = "200 chats at most · delete one first"
        static let off = "chat is off on this server"
        static let tooLong = "that message is too long"
        static let gone = "that chat is gone"

        /// The status line for a refused or failed chat call.
        static func message(for error: Error) -> String {
            switch error {
            case ChatError.busy: return busy
            case ChatError.full: return full
            case ChatError.tooMany: return tooMany
            case ChatError.off: return off
            case ChatError.notFound: return gone
            case ChatError.badRequest: return tooLong
            case ChatError.confirmGone: return confirmGone
            default: return Copy.actionFailed
            }
        }
    }
}
