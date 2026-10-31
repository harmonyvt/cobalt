import CobaltKit
import Foundation

/// Copy for the library's server search and a post's place in the search index (apple/CONTRACT.md section 13;
/// APP-API-CONTRACT 21). Lowercase. Plain values only (counts, dates, CobaltKit enums), so it compiles into the share
/// extension and the widgets too (`Cobalt/Design` is shared).
extension Copy {
    enum Search {
        // the search field and the line under it
        /// The field's prompt while the server searches by meaning (`search titles` without it).
        static let prompt = "search titles and what's in them"
        /// The iPhone search field's clear button (VoiceOver).
        static let clearField = "clear search"
        static let searching = "searching…"
        static func results(_ n: Int) -> String { n == 1 ? "1 result" : "\(n) results" }
        static func stillIndexing(_ n: Int) -> String { n == 1 ? "still indexing 1 post" : "still indexing \(n) posts" }
        /// "12 results · still indexing 3 posts"; the count alone when the index is complete.
        static func resultsLine(count: Int, pending: Int) -> String {
            pending > 0 ? "\(results(count)) · \(stillIndexing(pending))" : results(count)
        }
        static let waking = "search is waking up…"
        static let failed = "couldn't search by meaning. showing name matches."
        static let off = "search by meaning is off on this server. showing name matches."

        /// The text of the line for `state`; nil draws no line.
        static func line(_ state: LibrarySearchState) -> String? {
            switch state {
            case .idle: return nil
            case .searching: return searching
            case .results(let count, let pending): return resultsLine(count: count, pending: pending)
            case .waking: return waking
            case .off: return off
            case .failed: return failed
            }
        }


        // the detail's "what it's about" section (APP-API-CONTRACT 34; with `features.about`)
        static let aboutSection = "what it's about"
        static let aboutLoading = "reading what it's about…"
        static let aboutUnavailable = "couldn't read what it's about."
        static let aboutPending = "cutting frames…"
        static let aboutNotDescribed = "not described yet. it is picked up in the next pass."
        static let aboutFailed = "couldn't describe it yet. it is tried again later."
        static let heard = "heard"
        static let noSound = "no sound"
        static let noSpeech = "no speech"
        static let tags = "tags"
        static let addTag = "add a tag"
        static let addTagA11y = "add a tag"
        static let tagsFull = "16 tags is the most."
        static let editedTags = "your tags"
        static let resetTags = "reset"
        static let resetTagsA11yHint = "goes back to the tags the server wrote"
        static let tagsNotSaved = "couldn't save the tags. they are back as they were."
        static let closestWords = "reads closest to"
        static let noWords = "no words yet. they show once the post is indexed."
        static let closestVideos = "closest videos"
        static func removeTag(_ tag: String) -> String { "remove \(tag)" }
        static func closestA11y(_ title: String, score: Double) -> String { "\(title), \(percent(score)) close" }
        static func wordA11y(_ word: String, score: Double) -> String { "\(word), \(scoreText(score))" }
        /// A score as the rows show it: two places ("0.42").
        static func scoreText(_ score: Double) -> String { String(format: "%.2f", score) }
        private static func percent(_ score: Double) -> String { "\(Int((max(0, min(1, score)) * 100).rounded())) %" }
        /// The language the speech was detected in, as the server's code ("en").
        static func language(_ code: String) -> String { "speech: \(code)" }

        // the detail's "search index" section
        static let section = "search index"
        static let loading = "checking the index…"
        static let unavailable = "couldn't check the index."
        static let notListed = "not in the index yet."
        static let indexed = "indexed"
        static let stale = "waiting to re-index"
        static let pending = "waiting"
        static let failedState = "failed"
        static let gaveUp = "gave up"
        static let unknown = "unknown"
        static let posterIncluded = "poster included"
        static let yes = "yes", no = "no"
        static let attempts = "tries"
        static let model = "model"
        static let whatWasEmbedded = "what it's searched by"
        static let titleLabel = "title"
        static let textLabel = "text"
        static let posterLabel = "poster"
        static let none = "none"
        static let changedSince = "the title or poster changed since: the next pass re-indexes it."
        static let searchOff = "search is off on this server."

        /// The badge's word for a state.
        static func state(_ state: LibrarySearchStatus.State) -> String {
            switch state {
            case .indexed: return indexed
            case .stale: return stale
            case .pending: return pending
            case .failed: return failedState
            case .gaveUp: return gaveUp
            case .unknown: return unknown
            }
        }

        /// The line under the badge: "indexed 2 h ago", "retries in 40 min", "gave up after 3 tries", or nil.
        static func detail(_ status: LibrarySearchStatus, now: Date) -> String? {
            switch status.state {
            case .indexed, .stale:
                return status.embeddedAt.map { "indexed \(ago($0, now: now))" }
            case .pending:
                return "the next index pass takes it."
            case .failed:
                if let retry = status.retryAt { return "retries \(until(retry, now: now))" }
                return status.failedAt.map { "failed \(ago($0, now: now))" }
            case .gaveUp:
                return status.attempts > 0 ? "gave up after \(status.attempts) \(status.attempts == 1 ? "try" : "tries"). renaming it tries again." : nil
            case .unknown:
                return nil
            }
        }

        /// "just now", "5 min ago", "2 h ago", "3 d ago".
        static func ago(_ date: Date, now: Date) -> String {
            let s = max(0, Int(now.timeIntervalSince(date)))
            if s < 60 { return "just now" }
            return "\(span(s)) ago"
        }

        /// "in 40 min", "in 2 h", "soon".
        static func until(_ date: Date, now: Date) -> String {
            let s = Int(date.timeIntervalSince(now))
            if s < 60 { return "soon" }
            return "in \(span(s))"
        }

        private static func span(_ s: Int) -> String {
            if s < 3_600 { return "\(s / 60) min" }
            if s < 86_400 { return "\(s / 3_600) h" }
            return "\(s / 86_400) d"
        }
    }
}
