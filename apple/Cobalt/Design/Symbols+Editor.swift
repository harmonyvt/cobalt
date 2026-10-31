import SwiftUI

/// SF Symbols for the editor (apple/CONTRACT-EDITOR.md section 7), one name per meaning. An extension of `Symbol` in its own
/// file, compiled into the extensions too (`Cobalt/Design`). The names are the contract's; `redo`, `delete` and `done` are
/// added. All exist in SF Symbols 5 (iOS 17 / macOS 14) or earlier, so they resolve on iOS 26 and macOS 26.
/// Not checked in the SF Symbols app (no Mac in this lane): the first build's screenshots are the check.
extension Symbol {
    enum Editor {
        static let edit = "film.stack"
        static let render = "sparkles.rectangle.stack"
        static let toolSelect = "cursorarrow"
        static let toolBlade = "scissors"
        static let toolCrop = "crop"
        static let trim = "arrow.left.and.right"
        static let split = "scissors"
        static let speed = "gauge.with.dots.needle.67percent"
        static let overlay = "square.on.square"
        static let volume = "speaker.wave.2"
        static let muted = "speaker.slash"
        static let add = "plus"
        static let play = "play.fill"
        static let pause = "pause.fill"
        static let back = "backward.frame"
        static let forward = "forward.frame"
        static let zoomIn = "plus.magnifyingglass"
        static let zoomOut = "minus.magnifyingglass"
        static let canvas = "aspectratio"
        static let quality = "rectangle.badge.checkmark"
        static let missing = "exclamationmark.triangle"
        static let fit = "arrow.down.right.and.arrow.up.left"
        static let fill = "arrow.up.left.and.arrow.down.right"

        // added
        static let undo = "arrow.uturn.backward"
        static let redo = "arrow.uturn.forward"
        static let delete = "trash"
        static let gif = "livephoto"
        static let photo = "photo"
        static let video = "film"
        static let retry = "arrow.clockwise"
        static let cutout = "wand.and.stars"                         // remove background
        static let layers = "square.3.layers.3d"
        static let layerUp = "arrow.up.square"
        static let layerDown = "arrow.down.square"
        static let emote = "face.smiling"
        static let close = "xmark"
        static let more = "ellipsis.circle"
        static let imageCrop = "crop"                                // crop a picture (CONTRACT-EDITOR 13)
        static let cropRotateLeft = "rotate.left"
        static let cropFlip = "arrow.left.and.right.righttriangle.left.righttriangle.right"
        static let cropReset = "arrow.counterclockwise"
        static let cropSaveCopy = "square.and.arrow.down"
        static let cropPlace = "square.on.square"
    }
}
