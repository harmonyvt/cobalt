import CobaltKit
import Foundation

/// What the Shortcuts actions say (CONTRACT-PARALLEL.md 15.6). Dialogs and errors are lowercase like the rest of cobalt.
/// The action names, parameter labels and Siri phrases are Apple's surface (Shortcuts, Siri, Spotlight) and read the way
/// Apple's own do; they stay literals in `Cobalt/Intents/` because App Intents metadata is extracted from static
/// strings. Its own file so the lane never edits `Copy.swift`; compiled into the share extension and widgets too
/// (`Cobalt/Design`), so it holds plain strings and CobaltKit types only.
extension Copy {
    enum Shortcuts {
        // MARK: errors (15.6)

        static let notSignedIn = "open capystore and add your server and key first."
        static let keyRefused = "capystore's key was refused. check it in capystore's settings."
        static let serverUnreachable = "capystore's server didn't answer."
        static let oldServer = "this server can't keep a line. open capystore to save."
        static let noLink = "no link found in that text."                                  // existing copy (`Copy.failure(.noLink)`)
        static let noFile = "no file to upload."
        static let noVideo = "that save has no video to make a webp from."
        static let saveNotFound = "capystore couldn't find that save."

        static func lineFull(max: Int) -> String { "capystore's line is full (\(max)). try again when a few have finished." }
        static func fileTooLarge(limit: Int64) -> String { Copy.failure(.tooLarge(limit: limit)) }     // "that file is over the 100 MB limit."

        /// The words of any `ShortcutError`.
        static func message(_ error: ShortcutError) -> String {
            switch error {
            case .notSignedIn: return notSignedIn
            case .keyRefused: return keyRefused
            case .serverUnreachable: return serverUnreachable
            case .oldServer: return oldServer
            case .noLink: return noLink
            case .lineFull(let max): return lineFull(max: max)
            case .fileTooLarge(let limit): return fileTooLarge(limit: limit)
            case .noFile: return noFile
            case .noVideo: return noVideo
            case .saveNotFound: return saveNotFound
            case .failed(let failure): return Copy.failure(failure)
            }
        }

        // MARK: ask chat (15.10)

        /// A refused message or a failed reply.
        static func chatMessage(_ error: ChatError) -> String {
            switch error {
            case .off: return "chat is off on capystore's server."
            case .busy: return "that chat is still replying. try again when it's done."
            case .full: return "that chat is full. leave the chat empty to start a new one."
            case .tooMany: return "capystore has 200 chats. delete one first."
            case .notFound: return "capystore couldn't find that chat."
            case .badRequest: return "the message is empty or over \(ChatRule.messageLimit) characters."
            case .interrupted: return "the reply was cut off. it may still be in the chat tab."
            case .confirmGone: return "that ask is gone. nothing changed."
            case .model, .unavailable: return "the reply failed. try again."
            }
        }

        /// What Siri says after the reply: the reply itself, plain, cut at 1,000 characters.
        static func chatDialog(_ reply: ShortcutChatReply) -> String {
            let text = reply.plain.isEmpty ? "done." : reply.plain
            return ChatLiveCopy.clip(text, to: 1_000)
        }

        static func chatSubtitle(updated: Date) -> String {
            updated.formatted(.relative(presentation: .named))
        }

        // MARK: dialogs

        /// "saved 2 of 3 links; 1 couldn't be sent: <reason>." (15.3 step 5). `noun`: "link" / "file". After a wait the
        /// ones that failed were saved by the server and then ended in an error: "couldn't be saved".
        static func partial(_ outcome: ShortcutSaveOutcome, noun: String) -> String {
            let failed = outcome.failures.count
            let reason = outcome.failures.first.map { message($0.error) }.map { " \($0)" } ?? ""
            let afterHandOver = outcome.failures.allSatisfy(\.afterHandOver)
            let word = afterHandOver ? "saved" : "sent"
            let nouns = outcome.total == 1 ? noun : "\(noun)s"
            return "saved \(outcome.saves.count) of \(outcome.total) \(nouns); \(failed) couldn't be \(word):\(reason)"
        }

        /// What the system asks the owner when an action must continue in the foreground: a server with no line (an old
        /// one) holds nothing for cobalt, so this device keeps the line and cobalt has to stay open.
        static let continueForOldServer = "this server can't keep a line, so capystore has to stay open to save."

        static let noSaves = "nothing saved yet."
        static func latest(_ saves: [ShortcutSave]) -> String {
            guard let first = saves.first else { return noSaves }
            if saves.count == 1 { return "your latest save is \(first.title)." }
            return "found \(saves.count) saves. the latest is \(first.title)."
        }
    }
}
