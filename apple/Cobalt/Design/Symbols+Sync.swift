import SwiftUI

/// Symbols for the automatic continue and the photos album (CONTRACT-SYNC.md section 3). All are in
/// the system's `name_availability.plist` at iOS 18 or earlier. An extension of `Symbol` in its own
/// file so this lane never edits `Symbols.swift`.
extension Symbol {
    enum Sync {
        static let album = "photo.badge.plus"
        static let albumStatus = "photo.stack"
        static let inPhotos = "photo.badge.checkmark"
        static let problem = "photo.badge.exclamationmark"
        static let webps = "sparkles"
        static let openSettings = "gearshape"
        static let autoContinue = "moon.zzz"
        static let wait = "timer"
    }
}
