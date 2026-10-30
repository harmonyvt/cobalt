import CobaltKit
import Foundation

/// Copy for private share links (APP-API-CONTRACT 36; all new, lowercase): a post's three-way link, the links tab's
/// badges and actions, a collection's `privacy…` menu, the select panel's public/private choice and settings › sharing.
/// Plain values only (counts, dates, CobaltKit types), since `Cobalt/Design` is compiled into the extensions too.
extension Copy {
    enum PrivateLinks {
        // MARK: a post's link (the detail)

        static let section = "link"
        static let off = "off"
        static let offDetail = "only you"
        static let publicLink = "public link"
        static let publicDetail = "anyone with the link"
        static let privateLink = "private link"
        static let privateDetail = "a key in the link · rotate any time"

        static let link = "link"
        static let copy = "copy private link"
        static let copied = "copied"
        static let opened = "opened"
        static func openedCount(_ n: Int) -> String { n == 1 ? "1 time" : "\(n) times" }
        static let keyMade = "key made"
        static let rotate = "rotate key…"
        static let working = "working…"
        static let footnote = "rotating stops the old link at once. discord can keep showing a preview it already saved."

        static let turnOnTitle = "turn on a private link?"
        static let turnOnMessage = "the public link stops working and the file leaves the public media address. only people with the new link can open it."
        /// The same question when the file is in public gallery links, which it drops out of.
        static func turnOnMessage(inLinks n: Int) -> String {
            "\(turnOnMessage) it's in \(n) public gallery \(n == 1 ? "link" : "links"), which a private file drops out of."
        }
        static let turnOn = "turn on private link"
        static let alsoLinks = "make those links private too"
        static let leaveOut = "leave it out of them"

        static let rotateTitle = "rotate the key?"
        static let rotateMessage = "the old link stops working right away. the new one is copied for you."
        static let rotateConfirm = "rotate key"

        static let offTitle = "turn the link off?"
        static let offMessage = "the link stops working for everyone. only you can see the file."
        static let offConfirm = "turn off"
        static let toPublicTitle = "make it public?"
        static let toPublicMessage = "the private link stops working right away, and anyone with the public link can open the file."
        static let toPublicConfirm = "make public"

        /// The status after a private link was turned on or rotated and copied.
        static let copiedPrivate = "private link copied"
        static let copiedNewKey = "new key copied"
        static let turnOnFailed = "couldn't make the private link. try again."
        static let rotateFailed = "couldn't rotate the key. try again."
        static let changeFailed = "that didn't work. try again."
        static let notToggleable = "this file can't have a private link."
        static let gone = "the private link was already gone."
        static let unavailable = "the server can't make private links right now."

        /// A status line for a failed private-link change in the links tab and settings.
        static func message(for error: Error) -> String {
            switch error {
            case PrivateLinkError.unavailable: return unavailable
            case PrivateLinkError.notFound: return gone
            case PrivateLinkError.notToggleable: return notToggleable
            default: return Copy.actionFailed
            }
        }

        // MARK: the links tab

        static let badgePublic = "public"
        static let badgePrivate = "private"
        static let makePrivate = "make private"
        static let makePublic = "make public…"
        static let rotateKey = "rotate key…"
        static let makePublicTitle = "make this link public?"
        static let makePublicMessage = "the private link stops working right away, and the public address opens again."
        static let makePublicConfirm = "make public"
        static let madePublic = "the link is public"
        static func openedLine(_ n: Int) -> String { "opened \(openedCount(n))" }
        static func rowA11y(isPrivate: Bool) -> String { isPrivate ? "private link" : "public link" }

        // a collection's `privacy…` menu
        static let privacy = "privacy…"
        static let everyPrivate = "make every link private"
        static let everyRotate = "rotate every key…"
        static let everyPublic = "make every link public…"
        static let everyRotateTitle = "rotate every key in this collection?"
        static let everyRotateMessage = "every old private link here stops working right away. copy all to get the new ones."
        static let everyRotateConfirm = "rotate every key"
        static let everyPublicTitle = "make every link public?"
        static let everyPublicMessage = "the private links here stop working right away, and the public addresses open again."
        static let everyPublicConfirm = "make every link public"
        static func madeEveryPrivate(_ n: Int) -> String { "\(n) private \(n == 1 ? "link" : "links")" }
        static func rotatedEvery(_ n: Int) -> String { "rotated \(n) \(n == 1 ? "key" : "keys")" }
        static let madeEveryPublic = "every link is public"
        /// The collection line: "2 of 5 private".
        static func privateOf(_ n: Int, _ total: Int) -> String { "\(n) of \(total) private" }

        // MARK: making a gallery link (the library's select panel)

        static let choice = "link"
        static let choicePublic = "public"
        static let choicePrivate = "private"
        /// The panel's line while the pick is fine, for a private link.
        static func readyPrivate(_ count: Int) -> String { "\(count) files · one private link" }
        /// A pick with posts that have no file on the server (a private link takes any file the server has).
        static func notOnServer(_ count: Int) -> String {
            "\(count) \(count == 1 ? "isn't" : "aren't") on the server"
        }
        static func line(for verdict: ShareSetVerdict, count: Int, isPrivate: Bool) -> String {
            guard isPrivate else { return Copy.Links.line(for: verdict, count: count) }
            switch verdict {
            case .ready: return readyPrivate(count)
            case .notPublic(let n): return notOnServer(n)
            default: return Copy.Links.line(for: verdict, count: count)
            }
        }

        // MARK: settings › sharing

        static let settingsGroup = "sharing"
        static let newLinksStart = "new links start"
        static let privateCount = "private links"
        static let rotateAll = "rotate every key…"
        static let rotateAllTitle = "rotate every key?"
        static let rotateAllMessage = "every private link you've shared stops working right away. copy the new ones from the links tab."
        static let rotateAllConfirm = "rotate every key"
        static let settingsFooter = "a private link has a key in it, and the public address of the same thing stops working while it's on. new gallery links start the way you pick here."
        static let loadFailed = "couldn't load the private links."
        static let retry = "try again"
        static let cancel = "cancel"
    }
}
