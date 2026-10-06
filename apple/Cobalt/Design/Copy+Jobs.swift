import Foundation

/// Copy for pasting anywhere and running several at once (CONTRACT-PARALLEL section 9). All lowercase. Plain values
/// only (counts, names, dates), so it compiles into the share extension and the widgets too (`Cobalt/Design` is
/// shared). The tray and its cards, the review sheet, the status lines, cancel and stop, the relaunch note and the
/// Live Activity summary read their words from here.
extension Copy {
    enum Jobs {
        // MARK: waiting for the server

        static let checking = "checking the link"
        static let waiting = "waiting for the server"

        /// "1st in line" ... "2nd in line" ... "11th in line" (the job running on the server is 1st).
        static func line(_ place: Int) -> String { "\(ordinal(place)) in line" }

        /// A focused webp right behind the job on the server.
        static let lineNext = "your webp goes next"

        /// Who is directly ahead: `label` is the line's own words ("a share from your iphone", "a save from your mac",
        /// "a save that isn't in this list").
        static func behind(_ label: String) -> String { "after \(label)" }

        /// The detail under "waiting for the server": "2nd in line", "3rd in line · after a share from your iphone",
        /// "2nd in line · your webp goes next".
        static func lineDetail(place: Int, behind label: String? = nil, webpNext: Bool = false) -> String {
            var parts = [line(place)]
            if let label, !label.isEmpty { parts.append(behind(label)) }
            if webpNext { parts.append(lineNext) }
            return parts.joined(separator: " · ")
        }

        /// Device line only: a `429` for something that is not in this line, for `seconds` so far.
        static func busyElsewhere(label: String?, seconds: Int) -> String {
            let what = label.flatMap { $0.isEmpty ? nil : $0 } ?? "a save that isn't in this list"
            return "it's busy with \(what) · \(seconds) s"
        }

        static func lineFull(max: Int = 50) -> String {
            "cobalt's line is full (\(max)). try again when a few have finished."
        }

        // MARK: the tray

        /// "2 running · 1 waiting", "1 finished", "1 failed"; `waiting` is part of what is live, so running is
        /// `live - waiting` (`JobSummary`).
        static func trayHeader(live: Int, waiting: Int, finished: Int, failed: Int) -> String {
            var parts: [String] = []
            let running = max(0, live - waiting)
            if running > 0 { parts.append("\(running) running") }
            if waiting > 0 { parts.append("\(waiting) waiting") }
            if failed > 0 { parts.append("\(failed) failed") }
            if parts.isEmpty, finished > 0 { parts.append("\(finished) finished") }
            return parts.joined(separator: " · ")
        }

        static let trayA11y = "jobs running alongside"
        static let trayHide = "hide the jobs"
        static let trayShow = "show the jobs"
        static let savedCard = "saved · in the orbit and your library"
        static let open = "open"
        static let clearFinished = "clear"
        static let pickerJob = "pick what to save"

        // MARK: what a paste or a drop says

        static let noLink = "no link found in that text."
        static let nothingDropped = "nothing cobalt can save was dropped."
        static let duplicate = "already saving that one."

        /// "saving 3 links alongside." (a job added while another has the screen, or from a review).
        static func savingAlongside(_ count: Int) -> String {
            "saving \(count) \(count == 1 ? "link" : "links") alongside."
        }

        /// Several files dropped or pasted: "uploading 3 files alongside."
        static func uploadingAlongside(_ count: Int) -> String {
            "uploading \(count) \(count == 1 ? "file" : "files") alongside."
        }

        static func keepsGoing(_ title: String) -> String { "\(title) keeps going alongside." }

        // MARK: the review sheet (several links)

        /// "3 links on your clipboard" / "3 links dropped".
        static func reviewTitle(count: Int, dropped: Bool) -> String {
            "\(count) \(count == 1 ? "link" : "links") \(dropped ? "dropped" : "on your clipboard")"
        }

        /// "the first 20 of 34 links": more links than one review takes.
        static func reviewCap(shown: Int, found: Int) -> String { "the first \(shown) of \(found) links" }

        static let reviewNote = "links already saved are left out; tick them to save again."
        static let reviewNew = "new"
        static let reviewLive = "saving now"
        static func reviewSaved(when: String) -> String { "already saved · \(when)" }
        static let reviewCancel = "cancel"
        static func reviewSave(_ count: Int) -> String { count > 0 ? "save \(count)" : "nothing picked" }
        static let reviewA11yTicked = "ticked"
        static let reviewA11yUnticked = "not ticked"

        // MARK: cancel, stop (3.4)

        static func cancelled(_ title: String) -> String { "cancelled \(title). nothing was saved." }
        static let cancelledWebp = "cancelled the webp."
        static func stoppedFollowing(_ title: String) -> String {
            "stopped following \(title). the server finishes what it started, so it still shows up in your library."
        }
        static func stoppedReading(_ title: String) -> String { "stopped. \(title) is saved in your library." }
        static let couldntCancel = "couldn't cancel: the server didn't answer."
        static func cancelA11y(_ title: String) -> String { "cancel \(title)" }
        static func stopA11y(_ title: String) -> String { "stop \(title)" }

        // MARK: coming back

        /// "3 links from last time are back in line."
        static func relaunch(_ count: Int) -> String {
            count == 1 ? "1 link from last time is back in line." : "\(count) links from last time are back in line."
        }
        static func fileGone(_ name: String) -> String { "the file for \(name) is gone" }

        // MARK: leaving cobalt with work that has no session yet (device line, an upload mid-way)

        static func leavingLinks(_ count: Int) -> (title: String, body: String) {
            count == 1
                ? ("1 link is waiting for cobalt", "open cobalt to finish it.")
                : ("\(count) links are waiting for cobalt", "open cobalt to finish them.")
        }

        static func leavingUploads(_ count: Int) -> (title: String, body: String) {
            count == 1
                ? ("1 upload is waiting for cobalt", "open cobalt to finish it.")
                : ("\(count) uploads are waiting for cobalt", "open cobalt to finish them.")
        }

        // MARK: the Live Activity summary (two or more jobs)

        /// "+2 more · 1 waiting for the server"
        static func liveMore(extra: Int, waiting: Int) -> String {
            var text = "+\(extra) more"
            if waiting > 0 { text += " · \(waiting) waiting for the server" }
            return text
        }

        /// "3 saved · 1 webp", "2 saved · 1 couldn't be saved"
        static func liveDone(saved: Int, webps: Int, failed: Int) -> String {
            var parts: [String] = []
            if saved > 0 { parts.append("\(saved) saved") }
            if webps > 0 { parts.append("\(webps) webp") }
            if failed > 0 { parts.append("\(failed) couldn't be saved") }
            return parts.joined(separator: " · ")
        }

        // MARK: ordinals

        /// 1st, 2nd, 3rd, 4th ... 11th, 12th, 13th ... 21st (English, as everything here).
        static func ordinal(_ n: Int) -> String {
            let tens = n % 100
            let suffix: String
            if (11...13).contains(tens) {
                suffix = "th"
            } else {
                switch n % 10 {
                case 1: suffix = "st"
                case 2: suffix = "nd"
                case 3: suffix = "rd"
                default: suffix = "th"
                }
            }
            return "\(n)\(suffix)"
        }
    }
}
