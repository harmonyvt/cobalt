import CobaltKit
import Foundation

/// Copy for gallery share links (APP-API-CONTRACT section 24; all new, lowercase): the library's `make share link` bar
/// and the links tab. Plain values only (counts, dates, CobaltKit types), since `Cobalt/Design` is compiled into the
/// extensions too.
extension Copy {
    enum Links {
        static let title = "links"

        // MARK: the library's select bar

        static let make = "make share link"
        static let making = "making link…"
        static let makeA11yHint = "makes one link for the picked files and copies it"
        /// Shown while the pick is fine: "3 files · one link".
        static func ready(_ count: Int) -> String { "\(count) files · one link" }
        static let tooFew = "pick 2 or more"
        static func tooMany(_ max: Int) -> String { "\(max) at most" }
        /// "1 is private · make these public first".
        static func notPublic(_ count: Int) -> String {
            "\(count) \(count == 1 ? "is" : "are") private · make these public first"
        }
        /// The status when the server says a picked file is private now.
        static let makeThesePublic = "make these public first"
        /// Footer hint when tapping `make link` or `collection` can offer to make private picks public.
        static func notPublicPromptHint(_ count: Int) -> String {
            "\(count) \(count == 1 ? "isn't" : "aren't") public · tap make link or collection to make public"
        }
        /// Alert when tapping `make link` or `collection` with non-public items picked.
        static func makePublicAlertTitle(_ count: Int) -> String {
            count == 1 ? "make 1 item public?" : "make \(count) items public?"
        }
        static func makePublicForLinkMessage(_ count: Int) -> String {
            count == 1
                ? "1 selected item isn't public yet. make it public and create the link?"
                : "\(count) selected items aren't public yet. make them public and create the link?"
        }
        static func makePublicForCollectionMessage(_ count: Int) -> String {
            count == 1
                ? "1 selected item isn't public yet. make it public and choose a collection?"
                : "\(count) selected items aren't public yet. make them public and choose a collection?"
        }
        static let makePublicAndLink = "make public & make link"
        static let makePublicAndCollection = "make public & choose collection"
        static let usePrivateLinkInstead = "make private link instead"
        static let usePrivateCollectionInstead = "use private link instead"
        static let cancel = "cancel"

        /// The bar's line for a verdict (the picked count is for the ready line).
        static func line(for verdict: ShareSetVerdict, count: Int) -> String {
            switch verdict {
            case .ready: return ready(count)
            case .tooFew: return tooFew
            case .tooMany(let max): return tooMany(max)
            case .notPublic(let n): return notPublic(n)
            }
        }

        // MARK: the tab

        static let loading = "loading links…"
        static let emptyTitle = "no links yet"
        static let emptyBody = "select files in the library and make a share link"
        static let failedTitle = "can't load your links"
        static let retry = "try again"
        static let refresh = "refresh"
        /// Above the list when a refresh failed but the last list is still shown.
        static let staleLine = "can't reach the server · showing the last list"

        // MARK: a row

        static func fileCount(_ count: Int) -> String { "\(count) \(count == 1 ? "file" : "files")" }
        static func privateNow(_ count: Int) -> String {
            "\(count) \(count == 1 ? "file is" : "files are") private now"
        }
        static let allPrivate = "link is off until a file is public"
        static func rowA11y(title: String, files: Int, when: String) -> String {
            "\(title), \(fileCount(files)), made \(when)"
        }

        // MARK: actions

        static let copyLink = "copy link"
        /// The row's own button (iPhone, iPad): one word, so it fits beside the title.
        static let copy = "copy"
        static let share = "share"
        static let revoke = "revoke"
        static let revokeTitle = "revoke this link?"
        static let revokeMessage = "the link stops working at once. the files stay in your library."
        static let keep = "keep"
        static let revoked = "link revoked"
    }

    /// The link and collection pages of the screen pane (apple/CONTRACT-PANE.md section 5).
    enum LinksPane {
        /// The link is not in the list and the list could not be loaded.
        static let cantLoad = "can't load this link right now."
        /// The shelf card that puts the link in and out of collections.
        static let collectionsCard = "collections"
        static let collectionsHint = "tap to put it in or take it out"
        static let noCollectionsYet = "no collections yet"
        static let openCollection = "open"
        /// The collection page's subtitle: "3 links".
        static func linksLine(_ count: Int) -> String { Copy.Collections.linkCount(count) }
        /// A link's subtitle: "3 files · public · 2 days ago".
        static func subtitle(files: Int, privacy: String?, when: String) -> String {
            [Copy.Links.fileCount(files), privacy, when].compactMap { $0 }.joined(separator: " · ")
        }
        static let addressA11y = "link address"
    }

    /// Bulk audio loudness leveling & strictly gated `?audio=normal` share links.
    enum AudioBulk {
        static let segmentOriginal = "original audio"
        static let segmentLeveled = "leveled"
        static let queryTag = "?audio=normal"
        static let copyLeveledLink = "copy ?audio=normal"
        static let copiedNormal = "copied leveled link (?audio=normal)"
        static let lockedSuffix = "?audio=normal locked"
        static let normalActiveSuffix = "?audio=normal on"
        static let noAudibleVideos = "no audible videos · ?audio=normal n/a"
        static let leveling = "leveling…"
        static let alreadyLeveled = "all videos already leveled"
        static let unlockedAuto = "all leveled · ?audio=normal unlocked"
        static let levelAudio = "level audio"
        static let retryLeveling = "retry leveling"
        static let badgeLeveledFallback = "leveled"
        static let badgeLeveling = "leveling…"
        static let badgeFailed = "failed"
        static let badgeSilent = "silent"
        static let badgeUnmeasured = "unmeasured"

        static func levelRemaining(_ count: Int, target: AudioTargetLufs) -> String {
            let what = count == 1 ? "1 video" : "\(count) videos"
            return "level \(what) · \(target.rawValue) lufs"
        }

        static func retryRemaining(_ count: Int) -> String {
            count == 1 ? "retry 1 video" : "retry \(count) videos"
        }

        static func levelShort(_ count: Int) -> String {
            "level \(count)"
        }

        static func retryShort(_ count: Int) -> String {
            "retry \(count)"
        }

        static func levelingProgress(done: Int, total: Int) -> String {
            "leveling \(done)/\(total)…"
        }

        static func allLeveled(_ count: Int) -> String {
            count == 1
                ? "video leveled · ?audio=normal ready"
                : "all \(count) videos leveled · ?audio=normal ready"
        }

        static func allLeveledCompact(_ count: Int) -> String {
            count == 1 ? "1 video leveled" : "all \(count) videos leveled"
        }

        static func needsLevelCompact(audible: Int, remaining: Int) -> String {
            if audible == 1 { return "1 video · needs leveling" }
            let verb = remaining == 1 ? "needs" : "need"
            return "\(audible) videos · \(remaining) \(verb) leveling"
        }

        static func queuedToast(_ count: Int) -> String {
            count == 1 ? "leveling 1 video…" : "leveling \(count) videos…"
        }

        static func partialToast(queued: Int, failed: Int) -> String {
            "leveling \(queued) · \(failed) couldn't start"
        }

        static func failedToast(_ count: Int) -> String {
            count == 1 ? "couldn't start audio leveling" : "couldn't start leveling for \(count) videos"
        }
    }
}
