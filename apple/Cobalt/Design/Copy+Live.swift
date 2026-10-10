import CobaltKit
import Foundation

/// Copy for the Live Activity (CONTRACT-LIVE.md 2.7, 2.8) and the base of the offline-storage settings (4.3) and
/// the detail's offline copy (CONTRACT-OFFLINE retired "download again", "clear offline copies" and the keep-off
/// confirm; the new words are in `Copy+Offline.swift`). All lowercase. Nested namespaces in their own file so this lane never
/// edits `Copy.swift`; compiled into the widget extension too. Marked **new** unless the app
/// already said it (`Copy.fetching`, `Copy.waking`, `Copy.uploading`, `Copy.savingPrivately`,
/// `Copy.reading`, `Copy.decoding`, `Copy.packing`, `Copy.makingWebp`, `Copy.webpReady`,
/// `Copy.failure`, `Copy.keepVideos`, `Copy.remove`, `Copy.keep`).
extension Copy {
    enum Live {
        /// The stage line of the expanded island and the lock screen card.
        static func stage(_ s: LiveContentState, service: String?) -> String {
            switch s.stage {
            case .fetching:
                return Copy.fetching(from: service.flatMap { $0 == "file" || $0.isEmpty ? nil : $0 })
            case .uploading: return Copy.uploading
            case .saving: return Copy.savingPrivately
            case .reading: return Copy.reading
            case .ready: return ready
            case .rendering:
                if s.packing { return Copy.packing }
                return s.framesTotal != nil ? Copy.decoding : Copy.makingWebp
            case .done: return s.resultURL == nil ? savedLocal : Copy.webpReady
            case .failed: return failure(s)
            }
        }

        static let ready = "ready to trim"                                                    // new
        /// Plain cobalt, local mode: the clip was saved on this device and there is no link.
        static var savedLocal: String { "saved on this \(Copy.device)" }                       // new
        static let waitingForCobalt = "waiting for cobalt…"                                   // new
        static let open = "open"                                                              // new
        static let copyLink = "copy link"
        static let linkCopied = "link copied"

        /// The existing failure text for the case the activity carries (it holds the case name and the
        /// server's code, not the enum). Two lines at most in the widget.
        static func failure(_ s: LiveContentState) -> String {
            let code = s.code ?? ""
            switch s.failure {
            case "noLink": return Copy.failure(.noLink)
            case "tooLarge": return "that file is over the size limit."                       // new (the limit is not in the state)
            case "fetchFailed": return Copy.failure(.fetchFailed(code: code))
            case "linkUnreadable": return Copy.failure(.linkUnreadable(code: code))
            case "unsupported": return Copy.failure(.unsupported)
            case "serverBusy": return Copy.failure(.serverBusy)
            case "renderBusy": return Copy.failure(.renderBusy)
            case "renderLost": return Copy.failure(.renderLost)
            case "expired": return Copy.failure(.expired)
            case "keyMissing": return Copy.failure(.keyMissing)
            case "keyInvalid": return Copy.failure(.keyInvalid)
            case "unreachable": return Copy.failure(.unreachable)
            default: return Copy.failure(.server(code: code))
            }
        }

        /// "instagram · Dd7P496wolG", or the file's name for a file.
        static func source(service: String, ref: String, input: String) -> String {
            if input == "file" || service == "file" || service.isEmpty { return ref }
            return ref.isEmpty ? service : "\(service) · \(ref)"
        }

        /// "480×854 · 10.1 s · 4.5 MB": the finished webp.
        static func result(_ s: LiveContentState) -> String? {
            var parts: [String] = []
            if let w = s.resultWidth, let h = s.resultHeight { parts.append(Format.size(w, h)) }
            if let t = s.resultSeconds { parts.append(Format.seconds(t)) }
            if let b = s.resultBytes { parts.append(Format.bytes(b)) }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }

        /// The link without its scheme: "media.capybaraharmony.com/PrEvIeW001.webp".
        static func link(_ url: String) -> String {
            for scheme in ["https://", "http://"] where url.hasPrefix(scheme) { return String(url.dropFirst(scheme.count)) }
            return url
        }

        /// Spoken summary of the whole activity (VoiceOver on the Lock Screen).
        static func a11y(_ s: LiveContentState, service: String?, metric: String?) -> String {
            [stage(s, service: service), metric].compactMap { $0 }.joined(separator: ", ")
        }

        // settings row (2.8)
        static let row = "live activity"                                                      // new
        static let rowPushed = "on"                                                           // new
        static let rowLocal = "only while cobalt is open"                                     // new
        static let rowOff = "off in ios settings"                                             // new
        static let rowFooter = "every save and webp shows in the dynamic island and on the lock screen."   // new
        static func status(_ s: LiveStatus) -> String? {
            switch s {
            case .pushed: return rowPushed
            case .localOnly: return rowLocal
            case .off: return rowOff
            case .unavailable: return nil
            }
        }
    }

    enum Storage {
        /// Section header: "on this iphone".
        static var group: String { "on this \(Copy.device)" }                                // new
        static let noLimit = "no limit"                                                       // new
        static func limitName(_ l: StorageLimit) -> String {
            switch l {
            case .gb1: return "1 GB"
            case .gb2: return "2 GB"
            case .gb5: return "5 GB"
            case .gb10: return "10 GB"
            case .gb20: return "20 GB"
            case .unlimited: return noLimit
            }
        }

        /// "54 MB", "2.1 GB", "5 GB": the storage lines drop a trailing ".0" (MB and GB alike).
        static func size(_ bytes: Int64) -> String {
            Format.bytes(bytes)
                .replacingOccurrences(of: ".0 MB", with: " MB")
                .replacingOccurrences(of: ".0 GB", with: " GB")
        }

        /// "13 videos · 54 MB of 5 GB"; with no limit "13 videos · 2.1 GB".
        static func usage(count: Int, bytes: Int64, limit: Int64?) -> String {
            let head = "\(count) \(count == 1 ? "video" : "videos") · \(size(bytes))"
            guard let limit else { return head }
            return "\(head) of \(size(limit))"
        }

        /// The cache limit's picker row. Offline (kept) videos never count against it (CONTRACT-OFFLINE decision 4).
        static let limit = "cache limit"
        /// The confirm of a lower cache limit: only cached videos go; the kept ones stay.
        static func lowerTitle(freeing bytes: Int64) -> String {
            "this clears about \(size(bytes)) of the oldest cached videos from this \(Copy.device)."   // new
        }
        // The rest of the settings section (the toggle, the rows, clear cache, the footer) is in `Copy+Offline.swift`.
    }

    enum Offline {
        static var onDevice: String { "on this \(Copy.device)" }                              // new
        static var missing: String { "not on this \(Copy.device)" }                           // new
        static let removeCopy = "remove offline copy"                                         // new
        static let downloading = "downloading…"                                               // new
        static let downloadFailed = "couldn't download that. try again."                      // new
        static let gone = "the server no longer has this video."                              // new
        /// Why a download failed: the server lost it, it can't be reached, or anything else.
        static func failure(_ f: PipelineFailure) -> String {
            switch f {
            case .expired: return gone
            case .unreachable: return Copy.failure(.unreachable)
            default: return downloadFailed
            }
        }
        static func bytes(_ n: Int64) -> String { Copy.Storage.size(n) }
        // Keep offline, stop downloading, the confirms, the status lines and the settings rows are in `Copy+Offline.swift`.
    }
}
