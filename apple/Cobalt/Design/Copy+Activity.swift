import CobaltKit
import Foundation

/// Copy for the activity pill and the activity and health sheet (apple 03-PHASE3 3.4; all lowercase). Plain values only
/// (counts, names, dates, CobaltKit value types such as `JobStatus` and `ActivityPillState`; never a model or a store), so it
/// compiles into the share extension and the widgets too (`Cobalt/Design` is shared). The failure sentences, the engine names and
/// the device-copy reasons are the ones the work card already says (`Copy.failure`, `Copy.Save`); everything the pill and the
/// sheet add is here.
extension Copy {
    enum Activity {
        // MARK: the sheet

        static let title = "activity"
        static let segmentActivity = "activity"
        static let segmentSystem = "system"
        static let segmentsA11y = "activity or system health"
        static let sheetA11y = "activity and system health"

        /// The sheet's header: the one count, said once ("3 active · 1 needs attention"); nothing in motion: "all quiet".
        static func header(active: Int, attention: Int) -> String {
            var parts: [String] = []
            if active > 0 { parts.append("\(active) active") }
            if attention > 0 { parts.append("\(attention) \(attention == 1 ? "needs" : "need") attention") }
            return parts.isEmpty ? "all quiet" : parts.joined(separator: " · ")
        }

        /// Under a button that needs the server while it can't be reached (`OfflineReasonModifier`).
        static let needsNetwork = "needs network"

        static let running = "running"
        static let attention = "needs attention"
        static let recent = "recent"
        static func sectionA11y(_ name: String, count: Int) -> String { "\(name), \(count)" }

        static let emptyTitle = "nothing running"
        static let emptyBody = "saves, webps, downloads and renders show up here while they run, and the last ten stay under recent."
        static let recentEmpty = "nothing finished yet."

        // MARK: row actions

        static let retry = "retry"
        static let dismiss = "dismiss"
        static let cancel = "cancel"
        static let open = "open"
        static let showSteps = "show steps"
        static let hideSteps = "hide steps"
        static let stepsA11y = "steps"

        // MARK: the pill

        static let pillA11yLabel = "activity"
        static let pillHint = "opens what capystore is doing and how it is connected"
        static let pillIdleValue = "nothing running, everything connected"

        /// What the pill says; nil for the quiet dot (it draws no words).
        static func pill(_ state: ActivityPillState) -> String? {
            switch state {
            case .attention(let retries, _):
                return retries > 0 ? "\(retries) retry" : "sync"
            case .offline(let pending):
                return pending > 0 ? "offline · \(pending)" : "offline"
            case .active(let count, let fraction):
                if let fraction { return percent(fraction) }
                return "\(count) active"
            case .syncing(let pending):
                return pending > 0 ? "syncing \(pending)" : "syncing"
            case .waking:
                return "waking"
            case .idle:
                return nil
            }
        }

        /// "42%".
        static func percent(_ fraction: Double) -> String { "\(Int((min(1, max(0, fraction)) * 100).rounded()))%" }

        /// What VoiceOver reads as the pill's value.
        static func pillValue(_ state: ActivityPillState) -> String {
            switch state {
            case .attention(let retries, let sync):
                var parts: [String] = []
                if retries > 0 { parts.append(retries == 1 ? "1 needs a retry" : "\(retries) need a retry") }
                if sync { parts.append("library sync hit a problem") }
                return parts.joined(separator: ", ")
            case .offline(let pending):
                return pending > 0 ? "offline, \(Copy.LibrarySync.waiting(pending))" : "offline"
            case .active(let count, let fraction):
                if count == 1, let fraction { return "1 in progress, \(percent(fraction))" }
                return Copy.Queue.inProgressA11y(count)
            case .syncing(let pending):
                return pending > 0 ? "syncing the library, \(Copy.LibrarySync.waiting(pending))" : "syncing the library"
            case .waking:
                return "waking the server"
            case .idle:
                return pillIdleValue
            }
        }

        // MARK: a row's words

        /// What the owner (or the link) calls the work; a foreign server row with no link is worded here ("a save from your mac").
        static func title(_ s: JobStatus) -> String {
            if !s.title.isEmpty { return s.title }
            let what: String
            switch s.kind {
            case .save: what = "a save"
            case .gallery: what = "a post"
            case .upload: what = "an upload"
            case .webpRender: what = "a webp"
            case .editorRender: what = "an edit render"
            case .deviceDownload: what = "a download"
            case .photosExport: what = "photos"
            case .swarm: what = "a swarm"
            }
            if let name = s.remote?.keyName, !name.isEmpty { return "\(what) from your \(name)" }
            if s.remote != nil { return "\(what) that isn't in this list" }
            return what
        }

        /// The one line under a row's title: what the stage is doing, with its real numbers.
        static func stage(_ s: JobStatus) -> String {
            switch s.stage {
            case .queued(let ahead):
                return queued(ahead)
            case .waking(let engine):
                return Copy.Save.waking(engine)
            case .fetching(let engine, let fallbackFrom):
                if let fallbackFrom { return Copy.Save.switched(from: fallbackFrom, to: engine ?? .ytdlp, code: nil) }
                return Copy.fetching(from: s.sourceHost)
            case .downloading(let bytes, let total):
                let head = s.kind == .upload ? Copy.uploading : Copy.fetching(from: s.sourceHost)
                return joined(head, ofBytes(bytes, total))
            case .storing(let bytes, let total):
                return joined(Copy.Save.storing, ofBytes(bytes, total))
            case .galleryProgress(let done, let total, _, _):
                return "saving \(done) of \(total)"
            case .readingFrames(let done, let total):
                return joined(Copy.reading, total > 0 ? "\(done) of \(total)" : nil)
            case .rendering(let phase, let done, let total):
                return joined(rendering(s.kind, phase), ofCount(done, total))
            case .deviceCopy(let bytes, let total):
                let head = s.kind == .deviceDownload ? "downloading to this \(Copy.device)" : Copy.Save.localCopying
                return joined(head, ofBytes(bytes, total))
            case .completed(let cloudSaved, let receipt):
                if case .failed = receipt { return Copy.Save.localCopyFailed }
                return cloudSaved ? Copy.Save.inLibrary : "saved"
            case .failed(let failure, _):
                return Copy.failure(failure)
            case .awaitingChoice:
                return "waiting for your pick"
            }
        }

        private static func queued(_ ahead: Int?) -> String {
            guard let ahead else { return "waiting in line" }
            return ahead <= 0 ? "next in line" : Copy.Jobs.line(ahead + 1)
        }

        private static func rendering(_ kind: JobStatus.Kind, _ phase: RenderPhase?) -> String {
            if kind == .editorRender { return "rendering your edit" }
            switch phase {
            case .pack?: return Copy.packing
            case .fetching?: return "fetching the video"
            case .queued?: return "waiting to render"
            case .decode?, nil: return Copy.makingWebp
            }
        }

        private static func joined(_ head: String, _ tail: String?) -> String {
            guard let tail, !tail.isEmpty else { return head }
            return "\(head) · \(tail)"
        }

        /// "12 MB of 40 MB"; "12 MB" with no total; nil with no number.
        static func ofBytes(_ bytes: Int64?, _ total: Int64?) -> String? {
            guard let bytes else { return nil }
            guard let total, total > 0 else { return Copy.Storage.size(bytes) }
            return "\(Copy.Storage.size(bytes)) of \(Copy.Storage.size(total))"
        }

        /// "12 of 150"; nil when the server did not say.
        static func ofCount(_ done: Int?, _ total: Int?) -> String? {
            guard let done else { return nil }
            guard let total, total > 0 else { return "\(done)" }
            return "\(done) of \(total)"
        }

        // MARK: the receipts (a finished save)

        static let cloudOK = "cloud ✓"
        static let deviceOK = "device ✓"
        static let deviceFailed = "device ⚠"
        static let deviceCopying = "device …"
        static let cloudOKA11y = "saved to your library"
        static var deviceOKA11y: String { "saved on this \(Copy.device)" }
        static var deviceFailedA11y: String { "the copy on this \(Copy.device) did not arrive" }
        static var deviceCopyingA11y: String { "copying to this \(Copy.device)" }

        /// The device receipt chip; nil when this kind keeps no copy on the device.
        static func deviceReceipt(_ receipt: JobStatus.LocalCopyReceipt) -> String? {
            switch receipt {
            case .notNeeded: return nil
            case .savedOnDevice: return deviceOK
            case .inProgress: return deviceCopying
            case .failed: return deviceFailed
            }
        }

        static func deviceReceiptA11y(_ receipt: JobStatus.LocalCopyReceipt) -> String? {
            switch receipt {
            case .notNeeded: return nil
            case .savedOnDevice: return deviceOKA11y
            case .inProgress: return deviceCopyingA11y
            case .failed: return deviceFailedA11y
            }
        }

        // MARK: the stepper

        static func stepName(_ id: JobStep.ID) -> String {
            switch id {
            case .queued: return "queued"
            case .wake: return "wake"
            case .source: return "source"
            case .store: return "library"
            case .device: return "device"
            }
        }

        static func stepStateA11y(_ state: JobStep.State) -> String {
            switch state {
            case .done: return "done"
            case .active: return "now"
            case .warning: return "needs a look"
            case .pending: return "waiting"
            case .failed: return "stopped"
            }
        }

        /// The right-hand words of a step: the real number it has, nothing invented. nil: the step has nothing to add.
        static func stepDetail(_ step: JobStep) -> String? {
            switch step.detail {
            case .none:
                return nil
            case .queue(let ahead):
                return ahead.map { $0 <= 0 ? "next" : Copy.Jobs.line($0 + 1) }
            case .wake(let engine):
                return engine.map { Copy.Save.engine($0) }
            case .source(let engine, let fallbackFrom, let bytes, let total):
                var parts: [String] = []
                if let engine { parts.append(Copy.Save.engine(engine)) }
                if let ofBytes = ofBytes(bytes, total) { parts.append(ofBytes) }
                if let fallbackFrom { parts.append("switched from \(Copy.Save.engine(fallbackFrom))") }
                return parts.isEmpty ? nil : parts.joined(separator: " · ")
            case .items(let done, let total, _, _):
                return "\(done) of \(total)"
            case .frames(let done, let total):
                return total > 0 ? "\(done) of \(total) frames" : nil
            case .bytes(let bytes, let total):
                return ofBytes(bytes, total)
            case .render(_, let done, let total):
                return ofCount(done, total)
            case .failure(let failure):
                return Copy.failure(failure)
            case .receipt(let receipt):
                switch receipt {
                case .notNeeded: return nil
                case .savedOnDevice: return "on this \(Copy.device)"
                case .inProgress: return "copying…"
                case .failed(let code): return code.map(Copy.Save.localCopyReason) ?? Copy.Save.localCopyFailed
                }
            }
        }

        /// One step, for VoiceOver: "source, now, yt-dlp, 12 MB of 40 MB".
        static func stepA11y(_ step: JobStep) -> String {
            var parts = [stepName(step.id), stepStateA11y(step.state)]
            if let detail = stepDetail(step) { parts.append(detail) }
            if step.state == .active, let fraction = step.fraction { parts.append(percent(fraction)) }
            return parts.joined(separator: ", ")
        }

        /// One row, for VoiceOver.
        static func rowA11y(_ s: JobStatus) -> String {
            var parts = [title(s), stage(s)]
            if let fraction = s.fraction, s.isActive { parts.append(percent(fraction)) }
            return parts.joined(separator: ", ")
        }

        // MARK: the system segment

        static let edgeGroup = "api edge"
        static let containersGroup = "containers"
        static let syncGroup = "library sync"
        static let storageGroup = "offline storage"
        static let stageGroup = "live stage"

        // api edge
        static let edgeChecking = "checking…"
        static let edgeNotChecked = "not checked yet"
        static func edgeReachable(rtt: Int) -> String { "reachable · \(rtt) ms" }
        static let edgeUnreachable = "can't reach the server"
        static let edgeNotCobalt = "answers, but it isn't a capystore server"
        static func edgeChecked(_ when: String) -> String { "checked \(when)" }
        static let retryNow = "retry now"

        // containers
        static func containerName(_ name: SystemHealth.ContainerName) -> String {
            switch name {
            case .cobalt: return "cobalt"
            case .ytdlp: return "yt-dlp"
            case .editRenderer: return "editor renderer"
            }
        }
        static let containerWarm = "warm"
        static let containerWaking = "waking…"
        static let containerUnknown = "not seen yet"
        static func containerSeen(_ when: String) -> String { "seen \(when)" }
        static let containersFooter = "last observed while your saves and renders ran. capystore does not wake a container just to look."

        // library sync
        static let syncOff = "the library sync is off."
        static let syncToggle = "keep the library on this device"
        static func syncCursor(_ seq: Int64) -> String { "synced up to #\(seq)" }
        static func syncLast(_ when: String) -> String { "last synced \(when)" }
        static let syncNever = "not synced yet"
        static let syncNow = "sync now"
        static func syncNextTry(seconds: Int) -> String { seconds <= 0 ? "trying again now" : "trying again in \(seconds) s" }
        static let syncPendingNone = "no changes waiting"
        static let syncPendingTitle = "waiting on this device"

        /// One waiting edit, as the sheet lists it: `rename "harbour.mov"`, `visibility → public`. `postTitle` is the post's own name
        /// when the library has it.
        static func pendingEdit(_ edit: PendingSyncEdit, postTitle: String?) -> String {
            let name = postTitle.map { " · \($0)" } ?? ""
            switch edit.kind {
            case .rename(let title):
                return title.map { "rename \u{201C}\($0)\u{201D}" } ?? "clear the name\(name)"
            case .delete: return "delete\(name)"
            case .hide: return "hide\(name)"
            case .unhide: return "unhide\(name)"
            case .visibility(let makePublic): return "visibility → \(makePublic ? "public" : "private")\(name)"
            }
        }
        static let pendingSending = "sending"
        static func pendingTries(_ n: Int) -> String { n == 1 ? "tried once" : "tried \(n) times" }

        // offline storage
        static func storageUsage(items: Int, bytes: Int64) -> String {
            "\(items) \(items == 1 ? "item" : "items") · \(Copy.Storage.size(bytes))"
        }
        static let storageEmpty = "nothing kept on this device"
        static let manageStorage = "manage storage"

        // live stage (obs)
        static func obsOnAir(_ count: Int) -> String { "● on air · \(count) obs connected" }
        static let obsOnAirNone = "● on air · no obs connected"
        static let obsOnAirUnknown = "● on air"
        static let obsOffAir = "○ off air"
        static let obsOpen = "open the live stage"
    }
}
