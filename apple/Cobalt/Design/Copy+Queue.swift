import CobaltKit
import Foundation

/// Copy for the queue tab (apple/CONTRACT.md section 12; all new, lowercase). Plain values only (counts, names,
/// dates, CobaltKit enums), so it compiles into the share extension and the widgets too (`Cobalt/Design` is shared). The job rows reuse
/// the tray's words (`Copy.Jobs`, `TrayCopy`); everything else the tab says is here.
extension Copy {
    enum Queue {
        static let title = "queue"

        // MARK: header

        /// "3 running · 2 waiting · 1 failed"; nothing in motion but finished lines: "all done"; the empty state has
        /// its own words.
        static func header(running: Int, waiting: Int, failed: Int) -> String {
            var parts: [String] = []
            if running > 0 { parts.append("\(running) running") }
            if waiting > 0 { parts.append("\(waiting) waiting") }
            if failed > 0 { parts.append("\(failed) failed") }
            return parts.isEmpty ? allDone : parts.joined(separator: " · ")
        }
        static let allDone = "all done"
        /// Nothing of the owner's runs, but the server is still indexing the library.
        static let onlyIndexing = "only library indexing is running"
        /// Under the header when the last poll did not reach the server.
        static let serverProblem = "can't reach the server · showing what it said last"
        /// "updated 12:46" (the snapshot's time, `Format.when`).
        static func updated(_ when: String) -> String { "updated \(when)" }

        // MARK: sections

        static let now = "now"
        static let waiting = "waiting"
        static let indexing = "library indexing"
        static let downloads = "downloads"
        static let photos = "photos"
        static let finished = "recently finished"
        static let failed = "failed"

        // MARK: empty

        static let emptyTitle = "nothing in the queue"
        static let emptyBody = "saves, webps, downloads and library indexing show up here while they run."

        // MARK: the server's own work

        /// "a share from your iphone", "a save from your mac", "a webp from your mac", "a save that isn't in this list".
        static func serverTitle(kind: String, share: Bool, keyName: String?, mine: Bool) -> String {
            let what: String
            switch kind {
            case "render", "webp": what = "a webp"
            case "poster": what = "a poster"
            default: what = share ? "a share" : "a save"
            }
            if let keyName, !keyName.isEmpty { return "\(what) from your \(keyName)" }
            if mine { return "\(what) from this key" }
            return "\(what) that isn't in this list"
        }
        static let serverRunning = "running on the server"
        /// "3rd in line".
        static func serverWaiting(_ place: Int) -> String { Copy.Jobs.line(place) }
        static let serverNote = "the server runs it whether or not capystore is open."

        // MARK: the index

        static let indexTitle = "library search"
        /// "32 of 284 posts indexed".
        static func indexProgress(indexed: Int, posts: Int) -> String {
            "\(indexed) of \(posts) \(posts == 1 ? "post" : "posts") indexed"
        }
        /// "252 to go · about 180 an hour"; no rate: "252 to go · every 15 minutes".
        static func indexDetail(pending: Int, ratePerHour: Double?) -> String {
            let rate = ratePerHour.map { $0 >= 1 ? "about \(Int($0.rounded())) an hour" : "less than 1 an hour" }
            return "\(pending) to go · \(rate ?? "every 15 minutes")"
        }
        static let indexRunning = "indexing now"
        static let indexWaiting = "next pass within 15 minutes"
        /// "2 couldn't be indexed".
        static func indexFailed(_ n: Int) -> String { "\(n) couldn't be indexed" }
        static let indexNext = "next"
        /// "last pass 12:46".
        static func indexLastRun(_ when: String) -> String { "last pass \(when)" }

        static let postersTitle = "posters"
        static func postersPending(_ n: Int) -> String { "\(n) \(n == 1 ? "poster" : "posters") to make" }

        // MARK: downloads

        static let downloadWaiting = "waiting for the network"
        static func downloadFailed(_ failure: OfflineFailure) -> String {
            switch failure {
            case .gone: return "the file is gone from the server."
            case .unreachable: return "the network never let it finish."
            case .auth: return "the server refused the key."
            case .full: return "this device is full."
            case .other(let status): return "the server said \(status)."
            }
        }

        // MARK: photos

        static let photosTitle = "adding to the cobalt album"
        /// "3 of 7".
        static func photosProgress(done: Int, total: Int) -> String { "\(done) of \(total)" }

        // MARK: finished

        static let saved = "saved"
        static let webpReady = "webp ready"
        /// "saved · 12:46".
        static func finishedAt(_ outcome: String, when: String) -> String { "\(outcome) · \(when)" }

        // MARK: actions and VoiceOver

        static let cancel = "cancel"
        static let stop = "stop downloading"
        /// A job the server is already doing: the app stops following it (CONTRACT-PARALLEL 3.4).
        static let stopFollowing = "stop"
        static let tryAgain = "try again"
        static let dismiss = "dismiss"
        static let open = "open"
        static let refresh = "refresh"
        static let openLibrary = "open library"
        static let openSettings = "open settings"
        /// The JobTray's header, as a button: "open the queue".
        static let openQueueA11y = "open the queue"
        /// The toolbar button's value while work runs on this device (the badge): "2 in progress".
        static func inProgressA11y(_ count: Int) -> String { "\(count) in progress" }
        static func sectionA11y(_ name: String, count: Int) -> String { "\(name), \(count) \(count == 1 ? "item" : "items")" }
    }
}
