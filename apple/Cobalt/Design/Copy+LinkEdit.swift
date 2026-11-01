import CobaltKit
import Foundation

/// Copy for a gallery link's own screen and editing its files (APP-API-CONTRACT section 41; all new, lowercase): the
/// link screen, edit mode and its save bar, the add-files picker, and the library's "add to link". Plain values only
/// (counts, CobaltKit types), since `Cobalt/Design` is compiled into the extensions too.
extension Copy {
    enum LinkEdit {
        // MARK: the link screen

        static let screenTitle = "link"
        static let editTitle = "edit link"
        static let edit = "edit"
        static let done = "done"
        static let openA11yHint = "opens the link to see and edit its files"
        static let copyShare = "copy share"
        static let discordSection = "how discord shows it"
        static let filesSection = "files · in order"
        /// "6 of 10".
        static func countOf(_ count: Int, max: Int) -> String { "\(count) of \(max)" }
        static let readHint = "tap a file to open its post. edit to move, remove or add files."
        static let nothingShown = "nothing shows: every file is private, deleted or hidden"
        /// The discord preview's heading when the link has no title.
        static let captionTitle = "the ai caption"
        static func inCollections(_ names: [String]) -> String { "in " + names.joined(separator: " · ") }

        // MARK: a file

        static let kindVideo = "video", kindImage = "image", kindWebp = "webp", kindFile = "file"
        static let isNew = "new"
        static let notShownPrivate = "not shown: private"
        static let notShownDeleted = "not shown: deleted"
        static let notShownHidden = "not shown: hidden"
        static let notShown = "not shown"
        /// "0:14" for a video, "4s" for a webp.
        static func length(_ seconds: Double, video: Bool) -> String {
            let s = max(0, seconds)
            if !video { return "\(max(1, Int(s.rounded())))s" }
            let total = Int(s.rounded())
            return "\(total / 60):" + String(format: "%02d", total % 60)
        }
        static func fileA11y(number: Int, name: String, meta: String, warning: String?) -> String {
            [String(number), name, meta, warning].compactMap { $0 }.joined(separator: ", ")
        }
        static let openPostHint = "opens its post"

        // MARK: edit mode

        static let titlePlaceholder = "no title: the ai caption is used"
        static let titleHint = "shown on the link's preview · leave empty for the ai caption"
        static let titleField = "title"
        static let remove = "take out"
        static let removeOff = "a link needs 2 files. revoke it instead to take it down."
        static let addFiles = "add files"
        static func room(_ n: Int) -> String { "room for \(n)" }
        static func full(_ max: Int) -> String { "full: \(max) is the most a link holds" }
        static let moveHint = "drag to move"
        static let noChanges = "no changes yet. drag to move, − to take out."
        static let cancel = "cancel"
        static let save = "save"
        static let saving = "saving…"
        static let titleTooLong = "the title is over 80 characters"

        /// One change on the save bar.
        static func change(_ change: ShareSetChange) -> String {
            switch change {
            case .added(let n): return "\(n) added"
            case .removed(let n): return "\(n) out"
            case .reordered: return "new order"
            case .retitled: return "new title"
            }
        }

        /// "2 added · 1 out · new order", or the no-changes line.
        static func summary(_ changes: [ShareSetChange]) -> String {
            changes.isEmpty ? noChanges : changes.map(change).joined(separator: " · ")
        }

        // MARK: leaving with changes

        static let discardTitle = "discard changes to this link?"
        static let discard = "discard"
        static let keepEditing = "keep editing"

        // MARK: after a save

        static let updated = "link updated"
        static let discordKeeps = "messages already posted in discord keep their old preview."
        static let undo = "undo"
        static let putBack = "put back"
        static let changedElsewhere = "this link changed on another device. reloaded"
        static let gone = "this link was revoked"

        /// What a failed save (or undo, or add) says.
        static func message(for error: Error) -> String {
            switch error {
            case ShareSetError.changed: return changedElsewhere
            case ShareSetError.notFound: return gone
            case ShareSetError.hidden: return "a hidden post can't go in a link"
            case ShareSetError.notPublic: return "some files aren't public any more"
            case ShareSetError.badRequest: return "a link holds 2 to 10 files and a title of 80 characters at most"
            case ShareSetError.unavailable: return "the server can't change links right now"
            default: return "couldn't save the link"
            }
        }

        // MARK: the add-files picker

        static let pickerTitle = "add files"
        static let searchPrompt = "search the library"
        static func pickedOfRoom(_ picked: Int, room: Int) -> String { "\(picked) / room for \(room)" }
        static let inLink = "in link"
        static let privateOnly = "private: only in private links"
        static let publicLinkHint = "public link: only public files. make the link private to add private ones."
        static let privateLinkHint = "private link: any file can go in."
        static func addPicked(_ n: Int) -> String { n == 1 ? "add 1 file" : "add \(n) files" }
        static let pickSome = "pick files"
        static let pickerEmpty = "nothing in the library matches"
        static let kindAll = "all", kindVideos = "videos", kindPhotos = "photos", kindWebps = "webps"
        static func pickA11y(name: String, number: Int?, why: String?) -> String {
            [name, number.map { "number \($0)" }, why].compactMap { $0 }.joined(separator: ", ")
        }

        // MARK: the library's "add to link"

        static let addToLink = "add to link"
        static let addToLinkHint = "adds the picked files to one of your links"
        /// The context menu's item: one post, or the table's selection when the row is part of it.
        static let addToLinkMenu = "add to link…"
        static let addToLinkMenuHint = "adds this to one of your share links"
        static let loadingLinks = "loading your links…"
        static func pickLinkTitle(_ n: Int) -> String { "add \(n) to a link" }
        static let pickLinkFoot = "a link holds up to 10 files. public links take public files only."
        static let noLinksYet = "no links yet: make one with make share link"
        static let alreadyIn = "already in it"
        static let hasPrivate = "has a private file"
        /// "6 → 8 files".
        static func grows(_ from: Int, _ to: Int) -> String { "\(from) → \(to) files" }
        static func verdict(_ verdict: ShareSetAddVerdict, count: Int) -> String {
            switch verdict {
            case .ready(let n): return grows(count, count + n)
            case .alreadyIn: return alreadyIn
            case .noRoom(let r): return room(r)
            case .hasPrivate: return hasPrivate
            }
        }
        static func addedTo(_ n: Int, _ title: String) -> String { "added \(n) to \u{201C}\(title)\u{201D}" }
        static let openAction = "open"
    }
}
