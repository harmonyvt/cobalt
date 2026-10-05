import SwiftUI

/// Symbols for the Live Activity, the offline-storage rows and the detail's offline copy. An
/// extension of `Symbol` in its own file so the Live and storage lane never edits `Symbols.swift`;
/// compiled into the widget extension too (`Cobalt/Design` is shared with it).
extension Symbol {
    // live activity
    /// The Dynamic Island's own shape: the settings row for the live activity.
    static let liveActivity = "capsule"
    /// Failed, in the island's compact slot and the lock screen card.
    static let liveFailed = "exclamationmark"
    /// A done activity's small mark.
    static let liveDone = "checkmark"
    /// "waiting for cobalt…": the activity is stale.
    static let liveStale = "ellipsis"
    static let liveWaking = "bolt.horizontal"

    // offline storage
    static let clearOffline = "trash"
    static let removeOffline = "xmark.bin"
    static let downloadAgain = "arrow.down.to.line"
    static let offlineMissing = "icloud"
    static let offlineOn = "internaldrive"
}
