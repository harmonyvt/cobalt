import CobaltKit
import Foundation

/// The words the combine sheet needs beyond `Copy.Gallery` (apple/CONTRACT-GALLERY.md section 3), taken from the approved
/// boards `Gallery-Combine` and `Gallery-Image`. All lowercase, like the rest. Its own file (lane A2) so nobody else's
/// copy file changes.
extension Copy {
    enum Combine {
        // MARK: the sheet

        static let title = "make from this post"
        static let closeA11y = "close"
        static let outputsA11y = "what to make"
        static let itemsA11y = "items, in the order they will be used"

        // MARK: the items strip

        static var hint: String {
            Platform.isMac
                ? "drag a thumbnail to reorder · click one to select it · click the circle under it to leave it out"
                : "drag a thumbnail to reorder · tap one to select it · tap the circle under it to leave it out"
        }

        /// "7 of 10 ticked" / "7 of 10 ticked · 2 skipped (videos)"; `image` is the gallery image's line.
        static func tickLine(ticked: Int, of n: Int, skipped: Int) -> String {
            skipped > 0 ? "\(ticked) of \(n) ticked · \(skipped) skipped (videos)" : "\(ticked) of \(n) ticked"
        }

        /// "photo 3 · 3rd of 10" (`position` is 1-based).
        static func selected(_ name: String, position: Int, of n: Int) -> String { "\(name) · \(Jobs.ordinal(position)) of \(n)" }

        /// VoiceOver for a tile: "photo 3, position 3 of 10, left out".
        static func tileA11y(_ name: String, length: String?, position: Int, of n: Int, ticked: Bool, skipped: Bool) -> String {
            var parts = [name]
            if let length { parts.append(length) }
            parts.append("position \(position) of \(n)")
            if skipped { parts.append("not in the image") } else if !ticked { parts.append("left out") }
            return parts.joined(separator: ", ")
        }
        static let tileHint = "select it to move it with the buttons below. or touch and hold, then drag to reorder."
        static func tickA11y(_ name: String, ticked: Bool) -> String { ticked ? "leave out \(name)" : "use \(name)" }
        static func skippedA11y(_ name: String) -> String { "\(name) is skipped: videos are not in the image" }
        static func moveA11y(_ name: String, earlier: Bool) -> String { "move \(name) \(earlier ? "earlier" : "later")" }

        // MARK: the slideshow

        static let playA11y = "play the preview", pauseA11y = "pause the preview"
        static func slide(_ i: Int, of n: Int) -> String { "slide \(i) of \(n)" }
        static let nothingTicked = "nothing ticked"
        static func frameSize(_ size: CGSize) -> String { "frame \(Int(size.width))×\(Int(size.height))" }
        static func previewA11y(_ slide: String) -> String { "preview, \(slide)" }
        static func timelineA11y(_ parts: [String]) -> String { "timeline: \(parts.joined(separator: "; "))" }
        static func segmentA11y(_ name: String, seconds: String) -> String { "\(name), \(seconds)" }
        static let secondsNoteWebp = "the slider changes the length, not the webp's size (a still costs the same however long it is held)."
        static let secondsNoteMp4 = "one value for every photo. videos and gifs keep their own length (a gif plays once)."
        static func secondsA11y(_ s: String) -> String { "\(s) a photo" }
        /// `size`: what the crossfades add to the webp, "1.4 MB".
        static func fadeNoteWebp(on: Bool, adds size: String) -> String {
            on ? "0.3 s · adds about \(size) to the webp" : "off · cuts: a much smaller webp"
        }
        static func fadeNoteMp4(on: Bool) -> String { on ? "0.3 s · no size cost in the mp4" : "off · no size cost in the mp4" }
        static func webpSettings(quality: String, width: Int) -> String {
            "webp quality and width come from your webp settings: \(quality), \(width) px wide."
        }
        static let frameLabel = "frame"
        static let frameShortStory = "9:16", frameShortSquare = "1:1"

        // MARK: the gallery image

        static let layoutLabel = "layout (you pick one each time)"
        static let layoutA11y = "gallery image layout"
        static let imagePreviewA11y = "preview of the gallery image, drawn to scale; scroll inside it"
        static let scaledNote = " · scaled to fit 30,000 px / 40 MP"
        /// "needs 2 photos: none ticked." / "needs 2 photos: only 1 ticked."
        static func needsTwo(photos: Int) -> String {
            "\(Gallery.needsTwoPhotos): \(photos == 0 ? "none" : "only \(photos)") ticked."
        }
        /// A photo whose cell is cropped from another shape and drawn larger than its own pixels.
        static func drawnLargerCropped(_ name: String, _ x: String) -> String {
            "\(name) is drawn \(x) its own pixels: its cell is cropped from another shape"
        }
        static func layoutNameA11y(_ layout: String) -> String { "layout \(layout)" }

        // MARK: ways out and the reasons that need more than the contract's line

        static let evenHalfDoesNotFit = " even 0.5 s a photo does not fit."

        // MARK: making

        static let sendingHead = "sending to the server"
        static let sendingSub = "you can close this; it carries on."
        static let afterSaveSub = "it runs when the save is ready. you can close this; it carries on."
        static let waitingForTheServer = "waiting for the server"
        static func lineDetail(place: Int, webpNext: Bool) -> String { Jobs.lineDetail(place: place, webpNext: webpNext) }
        static let queuedSub = "focused: it goes ahead of saves still waiting. you can close this; it carries on."
        /// `server`: "25 s" / "2 min".
        static func makingSub(server: String) -> String {
            "about \(server) on the server. you can close this; it lands in the same media."
        }
        static let closingNote = "closing never stops a make; the tray shows it."

        // MARK: done

        /// iPhone and iPad: the file's place in Files; the Mac: in the cobalt folder.
        static func inFolder(title: String, file: String) -> String {
            Platform.isMac ? "in Finder: ~/Movies/cobalt/\(title)/\(file)" : Gallery.inFiles("\(title)/\(file)")
        }
        static let oneSwitch = "public or private with the post's one switch, like the photos."
        static func tabsSoFar(_ tabs: [String]) -> String { "tabs made from this post so far: \(tabs.joined(separator: " · "))" }
        static let changeSettings = "change settings"

        // MARK: failures

        /// The line under a failed make: the encoder's words for a server failure while making, else the app's own, and
        /// always "your settings are kept".
        static func failed(_ failure: PipelineFailure, what: String) -> String {
            switch failure {
            case .unsupported:
                return "\(Gallery.serverCantMake). the photos are untouched and your settings are kept."
            case .expired:
                return "the server no longer holds this post's originals. the photos here are untouched and your settings are kept."
            case .keyMissing, .keyInvalid, .unreachable:
                return "\(Copy.failure(failure)) your settings are kept."
            case .server(let code) where code == "error.webp.too_long":
                return "too long for a webp. webps stop at 60 s; the mp4 can be up to 3:00. your settings are kept."
            case .server(let code) where code == "error.studio.too_few_photos" || code == "error.studio.not_gallery":
                return "\(Gallery.needsTwoPhotos). your settings are kept."
            case .server(let code) where code == PipelineFailure.lineFullCode:
                return "\(Copy.Jobs.lineFull()) your settings are kept."
            default:
                return Gallery.makeFailed(what)
            }
        }
    }
}
