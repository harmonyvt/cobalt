import SwiftUI

/// Symbols for "diagnostics" (crash reports and logs). In the system's `name_availability.plist` at
/// iOS 18 or earlier. An extension of `Symbol` in its own file so the telemetry work never edits `Symbols.swift`.
extension Symbol {
    enum Telemetry {
        static let toggle = "stethoscope"
        static let sendNow = "paperplane"
        static let waiting = "tray.full"
    }
}
