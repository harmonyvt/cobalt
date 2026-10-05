import CobaltKit
import Foundation

/// Copy for "diagnostics": crash reports and logs sent to the owner's own server. All lowercase. Its own
/// file so the telemetry work never edits `Copy.swift`; compiled into the app, the share extension and the
/// widgets (`Cobalt/Design` is shared by all three).
extension Copy {
    enum Telemetry {
        static let group = "diagnostics"
        static let toggle = "send crash reports and logs to your server"
        static let sendNow = "send logs now"
        static let sending = "sending…"

        static func footer(host: String) -> String {
            "sent: the app version, this \(device)'s model and os, the steps cobalt took (states, file sizes and types, error codes, the sites you saved from) and crash reports. never sent: your api key, what's on your clipboard, or the contents of your files. it goes only to \(host); with this off the log stays on this \(device)."
        }

        static func waiting(events: Int, crashes: Int) -> String {
            var parts = [events == 1 ? "1 event" : "\(events) events"]
            if crashes > 0 { parts.append(crashes == 1 ? "1 crash report" : "\(crashes) crash reports") }
            return parts.joined(separator: " and ") + " waiting"
        }

        /// What "send logs now" answered.
        static func result(_ r: TelemetrySendResult) -> String {
            switch r.outcome {
            case .done:
                var parts = [r.events == 1 ? "1 event" : "\(r.events) events"]
                if r.crashes > 0 { parts.append(r.crashes == 1 ? "1 crash report" : "\(r.crashes) crash reports") }
                return "sent " + parts.joined(separator: " and ")
            case .nothingToSend: return "nothing new to send"
            case .disabled: return "turn on sending first"
            case .unsupported: return "this server doesn't take logs yet"
            case .noKey: return "paste your api key first"
            case .backingOff: return "waiting before the next try"
            case .failed(let code): return code == "network" ? "couldn't reach the server" : "couldn't send: \(code)"
            }
        }

        /// A result that is a problem (drawn in the error colour).
        static func isProblem(_ r: TelemetrySendResult) -> Bool {
            switch r.outcome {
            case .failed, .unsupported, .noKey: return true
            default: return false
            }
        }
    }
}
