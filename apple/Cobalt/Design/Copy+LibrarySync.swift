import Foundation

/// Copy for settings › "library sync": the switch for the on-device library. All lowercase. Its own
/// file so this work never edits `Copy.swift`; compiled into the app, the share extension and the
/// widgets (`Cobalt/Design` is shared by all three).
extension Copy {
    enum LibrarySync {
        static let group = "library sync"
        static let toggle = "keep the library on this device"
        static var footer: String { "capystore keeps a copy of your library on this \(device), so it opens at once and your changes wait here while you are offline. the light along the bottom edge shows what it is doing. new, so it starts off." }
        static let turnsOnNextOpen = "quit and open capystore again to turn it on."
        static let turnsOffNextOpen = "quit and open capystore again to turn it off."
    }
}
