import SwiftUI

/// Symbols for timed subtitles (APP-API-CONTRACT 47). Its own file so `Symbols.swift` stays untouched.
extension Symbol {
    enum Subtitles {
        static let on = "captions.bubble.fill"
        static let off = "captions.bubble"
        static let under = "text.below.photo"
        static let onPicture = "text.bubble"
        static let said = "quote.bubble"
        static let copy = "doc.on.doc"
    }
}
