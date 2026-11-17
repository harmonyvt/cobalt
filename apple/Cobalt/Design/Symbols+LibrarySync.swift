import SwiftUI

/// Symbols for settings › "library sync". In the system's `name_availability.plist` at iOS 18 or
/// earlier. An extension of `Symbol` in its own file so this work never edits `Symbols.swift`.
extension Symbol {
    enum LibrarySync {
        static let toggle = "arrow.triangle.2.circlepath"
        static let restart = "power"
    }
}
