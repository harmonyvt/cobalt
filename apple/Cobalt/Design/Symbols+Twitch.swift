import SwiftUI

/// SF Symbols for the twitch tab (APP-API-CONTRACT 70). Its own file, compiled into the extensions too (`Cobalt/Design`).
extension Symbol {
    enum Twitch {
        static let tab = "play.tv"
        static let search = "magnifyingglass"
        static let live = "dot.radiowaves.left.and.right"
        static let viewers = "eye"
        static let clip = "scissors"
        static let send = "arrow.up"
        static let emotes = "face.smiling"
        static let locked = "lock.fill"
        static let keyboard = "keyboard"
        static let reply = "arrowshape.turn.up.left"
        static let copy = "doc.on.doc"
        static let close = "xmark"
        static let back = "chevron.left"
        static let down = "arrow.down"
        static let slow = "timer"
        static let warn = "exclamationmark.triangle"
        static let open = "arrow.up.forward.square"
        static let pin = "pin"
        static let recent = "clock"
        static let jumpToLive = "forward.end.fill"
        static let chat = "bubble.left.and.bubble.right"
        static let channels = "list.bullet"
        // the stream on a TV (70.5)
        static let tv = "tv"
        static let airPlay = "airplayvideo"
        static let dim = "moon"
        static let undim = "sun.max"
        static let chatOnTV = "text.bubble"
        static let mirror = "rectangle.on.rectangle"
        // low-latency native player & mode switch
        static let lowLatency = "bolt.fill"
        static let embed = "globe"
        static let quality = "slider.horizontal.3"
        static let muted = "speaker.slash.fill"
        static let unmuted = "speaker.wave.2.fill"
        static let audioOnly = "waveform"
    }
}
