import CobaltKit
import Foundation
import SwiftUI

/// Copy for the emote editor (APP-API-CONTRACT 71, apple/CONTRACT.md "emote editor"): make an emote from a picture, webp, gif
/// or video, with crop, squash, format, compress and frames. All lowercase. Plain values and CobaltKit types only, since
/// `Cobalt/Design` is compiled into the extensions too.
extension Copy {
    enum EmoteEditor {
        static let makeAnEmote = "make an emote"
        static let title = "new emote"
        static let pickToMake = "pick a picture to make an emote from"
        static let pickToMakeHint = "tap a picture to start from it"
        static let cancelPick = "cancel"
        static let unavailable = "this server can't make emotes"
        static let loadingSource = "opening the picture…"
        static let cantOpen = "couldn't open this one"

        // MARK: tabs
        static let crop = "crop"
        static let squash = "squash"
        static let format = "format"
        static let compress = "compress"
        static let frames = "frames"

        static func tab(_ tab: EmoteEditorModel.Tab) -> String {
            switch tab {
            case .crop: return crop
            case .squash: return squash
            case .format: return format
            case .compress: return compress
            case .frames: return frames
            }
        }

        // MARK: header
        static let undo = "undo"
        static let redo = "redo"
        static let close = "close"

        // MARK: preview
        static let source = "source"
        static let atRealSize = "at real size, in chat"
        static let inChat = "in chat"
        static let darkAndLight = "dark and light"
        static let chatName = "harmony"
        static let chatLine = "she is in the box again"
        static let chatLight = "light mode check"
        static let compareHint = "drag the line to compare"
        static let remaking = "making it…"
        static let result = "result"
        static let loop = "loop"
        static let bounce = "bounce"
        static func sizeLabel(_ x: Int) -> String { "\(x)x" }
        static func cropBadge(_ ratio: String, _ w: Int, _ h: Int) -> String { "\(ratio) · \(w) × \(h)" }
        static func compareTag(_ format: EmoteFormat, quality: Int?) -> String {
            quality.map { "\(format.rawValue) · q \($0)" } ?? format.rawValue
        }
        static func playing(frames: Int, seconds: Double) -> String {
            String(format: "playing · %d frames · %.1f s", frames, seconds)
        }
        static func still(_ w: Int, _ h: Int) -> String { "one still frame · \(w) × \(h)" }

        // MARK: crop tab
        static let cropTitle = "crop"
        static let cropNote = "drag the box over the picture, or pick a shape"
        static let cropReset = "whole picture"
        static func cropSize(_ w: Int, _ h: Int) -> String { "\(w) × \(h) px of the source" }

        // MARK: squash tab
        static let squashNote = "stretch or squash, each way on its own"
        static let wide = "wide"
        static let tall = "tall"
        static let linked = "linked"
        static let unlinked = "unlinked"
        static let presetSquish = "squish"
        static let presetTall = "tall boi"
        static let presetWide = "wide 3:1"
        static let reset = "reset"
        static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

        // MARK: format tab
        static let formatTitle = "format"
        static let webp = "webp"
        static let webpNote = "animated, alpha, small. what 7tv keeps"
        static let gif = "gif"
        static let gifNote = "plays anywhere. 256 colours"
        static let png = "png"
        static let pngNote = "one still frame, lossless"
        static let pngStillAt = "still at"
        static func formatName(_ f: EmoteFormat) -> String {
            switch f {
            case .webp: return webp
            case .gif: return gif
            case .png: return png
            }
        }
        static func formatNote(_ f: EmoteFormat) -> String {
            switch f {
            case .webp: return webpNote
            case .gif: return gifNote
            case .png: return pngNote
            }
        }

        // MARK: compress tab
        static let compressTitle = "compress"
        static let auto = "auto"
        static let autoNote = "auto keeps it under 7 mb"
        static let fixedNote = "held at the quality and size you set"
        static let quality = "quality"
        static let longestSide = "longest side"
        static let frameRate = "frame rate"
        static let remake = "remake"
        static func pixels(_ n: Int) -> String { "\(n) px" }
        static func fps(_ n: Int) -> String { "\(n) fps" }

        // MARK: frames tab
        static let framesTitle = "moment"
        static let momentNote = "drag the window over the moment"
        static func momentRange(_ from: Double, _ to: Double, of total: Double?) -> String {
            let base = String(format: "%.1f - %.1f s", from, to)
            return total.map { base + String(format: " of %.1f s", $0) } ?? base
        }
        static let fpsNote = "7tv plays up to 50"
        static let noSound = "no sound"

        // MARK: checks
        static let shape = "shape"
        static let frameCount = "frames"
        static func framesValue(_ n: Int) -> String { "\(n) frames" }

        // MARK: meter
        static let sizeMeter = "size"
        static func cap(_ text: String) -> String { "\(text) cap" }
        static let overCap = "over the cap · switch to auto"

        // MARK: actions
        static let upload = "upload to 7tv"
        static let uploadNeedsLink = "link 7tv in the 7tv tab to upload"
        static let saveToLibrary = "save to library"
        static let saving = "saving…"
        static let saved = "saved to the library."
        static let share = "share"
        static let waitForDraft = "wait for the made file"

        // MARK: blockers and errors
        static let shapeBlocked = "the shape is outside 1:32 to 3:1 · crop or squash it back"
        static let momentBlocked = "a moment is 0.2 to 10 seconds"

        static func message(for error: SevenTvError) -> String {
            switch error {
            case .tooLarge: return shapeBlocked
            case .busy: return "the server is making another emote · try again in a moment"
            case .fitFailed(let words): return words.map { "couldn't make it · \($0)" } ?? "couldn't make it · try again"
            case .fileType: return "emotes can't be made from this kind of file"
            default: return Copy.SevenTv.message(for: error)
            }
        }

        // MARK: accessibility
        static let stageA11y = "the picture with its crop box"
        static let resultA11y = "the emote as it will look"
        static func tickA11y(_ name: String, value: String?, ok: Bool) -> String {
            "\(name) \(value ?? "unknown") · \(ok ? "fine" : "check this")"
        }
    }
}

/// Symbols for the emote editor.
extension Symbol {
    enum EmoteEditor {
        static let make = "face.smiling"
        static let crop = "crop"
        static let squash = "arrow.up.and.down.and.arrow.left.and.right"
        static let format = "photo.on.rectangle"
        static let compress = "arrow.down.right.and.arrow.up.left"
        static let frames = "film"
        static let undo = "arrow.uturn.backward"
        static let redo = "arrow.uturn.forward"
        static let linked = "link"
        static let unlinked = "link.badge.plus"
        static let wide = "arrow.left.and.right"
        static let tall = "arrow.up.and.down"
        static let squish = "arrow.down.to.line"
        static let tallBoi = "arrow.up.to.line"
        static let wideThree = "arrow.left.and.right.square"
        static let auto = "wand.and.sparkles"
        static let remake = "arrow.clockwise"
        static let upload = "square.and.arrow.up"
        static let library = "square.stack"
        static let share = "square.and.arrow.up.on.square"
        static let tickOK = "checkmark.circle.fill"
        static let tickWarn = "exclamationmark.triangle.fill"
        static let tickBad = "xmark.circle.fill"
        static let tickUnknown = "circle.dotted"
        static let loop = "repeat"
        static let bounce = "arrow.left.arrow.right"
        static let muted = "speaker.slash"
        static let play = "play.fill"
    }
}
