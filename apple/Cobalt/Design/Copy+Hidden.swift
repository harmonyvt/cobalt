import CobaltKit
import Foundation

/// Copy for hidden posts and auto-hide rules (APP-API-CONTRACT 37; all new, lowercase, terse): a post's `hidden` link row
/// and its unhide, settings › hidden (the rules, the lock, open hidden) and the add-rule sheet. Plain values only
/// (counts, strings, CobaltKit types), since `Cobalt/Design` is compiled into the extensions too.
extension Copy {
    enum Hidden {
        // MARK: a post's link (the detail)

        static let row = "hidden"
        static let rowDetail = "out of the library · never shared"
        static let unhideFirst = "unhide first"
        static let note = "only in library › hidden. no link can be made and it can't go in a gallery link."
        static let hiddenBy = "hidden by"
        static let byYou = "you"
        static let byChat = "the chat"
        /// "rule: instagram.com/close.friends.acct"; "a rule" when the rule is gone or not read yet.
        static func byRule(_ rule: HideRule?) -> String {
            guard let rule else { return "a rule" }
            return "rule: \(ruleValue(rule))"
        }

        static let hidePost = "hide this post…"
        static let hideTitle = "hide this post?"
        static let hideMessage = "its public link and private link stop working for good, and it moves to library › hidden."
        static func hideMessage(inLinks n: Int) -> String {
            "\(hideMessage) it leaves \(n) public gallery \(n == 1 ? "link" : "links")."
        }
        static let hideConfirm = "hide"
        static let unhideTitle = "unhide it?"
        static let unhideMessage = "it comes back to the library as only you. no link comes back by itself. rules won't hide it again."
        static let unhide = "unhide"
        static let cancel = "cancel"
        static let done = "done"

        static let working = "working…"
        static let hideFailed = "couldn't hide it. try again."
        /// The server hid the post but could not take a public copy of a file off (`error.library.not_toggleable`, or a
        /// failed switch): it stays a hidden post, and a retry finishes the files.
        static let hiddenFileFailed = "hidden, but a public copy couldn't be taken off. try again."
        static let unhiddenFileFailed = "back in the library, but a file couldn't be changed. try again."
        static let unhideFailed = "couldn't unhide it. try again."
        static let hiddenStatus = "hidden"
        static let unhiddenStatus = "back in the library"

        // MARK: settings › hidden

        /// The reason the system sheet shows when the lock is turned off.
        static let lockOffReason = "turn off the lock on your hidden posts"

        static let settingsGroup = "hidden"
        static let settingsRow = "hidden"
        static let screenTitle = "hidden"
        static func posts(_ n: Int) -> String { n == 1 ? "1 post" : "\(n) posts" }
        static func rules(_ n: Int) -> String { n == 1 ? "1 rule" : "\(n) rules" }
        static let settingsFooter = "posts you hide, and rules that hide new saves."

        static let rulesGroup = "hide automatically"
        static let noRules = "no rules yet."
        static let loadingRules = "loading rules…"
        static let addRule = "add rule…"
        static let deleteRule = "delete rule"
        static let retry = "try again"
        static let loadFailed = "couldn't read the rules."
        static let rulesFooter = "a rule checks every new save before any link is made, so a matching post is never public. \"what it's about\" needs its words first, so while one is on, new saves wait as only you for a few minutes. unhiding a post by hand keeps it out of the rules."

        static func kindLabel(_ kind: HiddenRuleKind) -> String {
            switch kind {
            case .site: return "from a site or account"
            case .words: return "title or link has"
            case .about: return "what it's about mentions"
            case .upload: return "uploads"
            }
        }

        /// What the rule looks for: its value, or for uploads a line.
        static func ruleValue(_ rule: HideRule) -> String {
            rule.kind == .upload || rule.value.isEmpty ? "uploaded from photos or files" : rule.value
        }

        static func hits(_ rule: HideRule) -> String {
            rule.enabled ? "\(rule.hits) hidden by this rule" : "off · hides nothing new"
        }

        static func ruleA11y(_ rule: HideRule) -> String { "\(kindLabel(rule.kind)) \(ruleValue(rule))" }

        static let privacyGroup = "privacy"
        static let lock = "lock with face id"
        static let lockDetail = "library › hidden asks every time"
        static let openHidden = "open hidden"
        static let openHiddenFooter = "the hidden album is in the library, under the hidden chip."

        // MARK: the add-rule sheet

        static let newRule = "new rule"
        static let add = "add"
        static let adding = "adding…"
        static let hidePostWhen = "hide a post when"

        static func kindTitle(_ kind: HiddenRuleKind) -> String {
            switch kind {
            case .site: return "it comes from a site or account"
            case .words: return "its title or link has a word"
            case .about: return "what it's about mentions"
            case .upload: return "i uploaded it"
            }
        }

        static func kindDetail(_ kind: HiddenRuleKind) -> String {
            switch kind {
            case .site: return "instagram.com · tiktok.com/@name · x.com/name"
            case .words: return "checks the title you gave it, the caption and the link"
            case .about: return "the words the library wrote from its frames and sound"
            case .upload: return "from photos, files or the share sheet, not a link"
            }
        }

        static func fieldTitle(_ kind: HiddenRuleKind) -> String {
            switch kind {
            case .site: return "site or account"
            case .words: return "word or phrase"
            case .about: return "word"
            case .upload: return ""
            }
        }

        static func placeholder(_ kind: HiddenRuleKind) -> String {
            switch kind {
            case .site: return "tiktok.com/@name"
            case .words: return "private"
            case .about: return "selfie"
            case .upload: return ""
            }
        }

        static let alsoHide = "also hide what's saved"

        /// "9 saved posts match now · their links stop working": the tail only when the rule will hide them now.
        static func matches(_ n: Int, applying: Bool) -> String {
            let base = n == 1 ? "1 saved post matches now" : "\(n) saved posts match now"
            guard n > 0 else { return base }
            return applying ? "\(base) · their links stop working" : "\(base) · they stay as they are"
        }

        static let counting = "checking what matches…"
        static let alsoHideFooterOff = "only new saves are checked."

        static let badSite = "that doesn't look like a site or account"
        static let badRule = "that rule can't be used"
        static let tooMany = "50 rules is the most"
        static let addFailed = "couldn't add the rule. try again."

        /// A refusal or failure of `POST /hidden/rules` in words.
        static func addFailure(_ error: Error, kind: HiddenRuleKind) -> String {
            if let failure = error as? PipelineFailure {
                switch failure {
                case .server(let code):
                    if code == "error.hidden.too_many" { return tooMany }
                    if code == "error.hidden.bad_rule" { return kind == .site ? badSite : badRule }
                    return addFailed
                case .keyInvalid, .keyMissing, .unreachable:
                    return Copy.failure(failure)
                default:
                    return addFailed
                }
            }
            return addFailed
        }

        static func hiddenNow(_ n: Int) -> String { n == 1 ? "1 post hidden" : "\(n) posts hidden" }
        static let ruleAdded = "rule added"
    }
}

/// Symbols for hidden posts and rules (APP-API-CONTRACT 37), compiled into the extensions too (`Cobalt/Design`).
extension Symbol {
    enum HiddenRules {
        static let hidden = "archivebox"
        static let unhide = "arrow.uturn.backward"
        static let by = "person"
        static let rule = "line.3.horizontal.decrease"
        static let lock = "faceid"
        static let open = "rectangle.stack"
        static let add = "plus"
        static let delete = "trash"
        static let retry = "arrow.clockwise"
        static let site = "globe"
        static let words = "textformat"
        static let about = "sparkles"
        static let upload = "square.and.arrow.up"

        static func kind(_ kind: HiddenRuleKind) -> String {
            switch kind {
            case .site: return site
            case .words: return words
            case .about: return about
            case .upload: return upload
            }
        }
    }
}
