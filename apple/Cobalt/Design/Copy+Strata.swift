import CobaltKit
import Foundation

// All lowercase house copy for the Strata home layout ("core sample").

extension Copy {
    enum Strata {
        static let today = "today"
        static let yesterday = "yesterday"
        static let thisWeek = "this week"
        static let older = "older"

        static let rulerFooter = "MB down the side · height = size"
        static let emptyHint = "paste a link or add a file from the bar above."
        static let newest = "newest"
        static let tapToOpen = "tap any thumbnail to inspect"
        static let openDetail = "open detail"
        static let open = "open"
        static let stop = "stop"
        static let publicBadge = "public"
        static let webpBadge = "webp"
        static let inPhotosBadge = "in photos"
        static let savedPrefix = "saved"
        static let waiting = "waiting"

        static func sampleFrom(_ layer: String) -> String { "sample · from \(layer)" }
        static func layerMeta(count: Int, bytes: Int64) -> String { "\(count) · \(Copy.storage(bytes))" }
        static func waitingSummary(count: Int, title: String) -> String {
            "\(count) waiting · \(title)"
        }
        static func seeAll(_ count: Int) -> String { "see all \(count)" }

        /// Lowercase stratum title (`today`, `yesterday`, `this week`, `november`, `oct 2025`, `older`).
        static func bucketTitle(_ bucket: StrataBucket, now: Date = Date(), calendar: Calendar = .current) -> String {
            switch bucket {
            case .today: return today
            case .yesterday: return yesterday
            case .thisWeek: return thisWeek
            case .older: return older
            case .month(let year, let month):
                let symbols = calendar.monthSymbols
                let shortSymbols = calendar.shortMonthSymbols
                let currentYear = calendar.component(.year, from: now)
                let index = max(0, min(symbols.count - 1, month - 1))
                if year == currentYear {
                    return symbols[index].lowercased()
                }
                let short = shortSymbols[max(0, min(shortSymbols.count - 1, month - 1))].lowercased()
                return "\(short) \(year)"
            }
        }

        /// Compact relative age for the sample peek card ("just now", "4 m ago", "3 h ago", "yesterday", "5 d ago").
        static func relativeSaved(_ date: Date, now: Date = Date()) -> String {
            let delta = max(0, now.timeIntervalSince(date))
            if delta < 60 { return "just now" }
            if delta < 3_600 { return "\(Int(delta / 60)) m ago" }
            if delta < 86_400 { return "\(Int(delta / 3_600)) h ago" }
            let days = Int(delta / 86_400)
            if days == 1 { return "yesterday" }
            if days < 30 { return "\(days) d ago" }
            let months = max(1, days / 30)
            return "\(months) mo ago"
        }
    }
}
