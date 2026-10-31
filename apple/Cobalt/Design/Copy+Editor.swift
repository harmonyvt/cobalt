import CobaltKit
import Foundation

/// Copy for the editor (apple/CONTRACT-EDITOR.md section 5, all lowercase; the app is "capystore"). The contract's table comes
/// first and is exact; the block after it holds the few words the screens needed that the table did not name (marked
/// "added"). Plain values and CobaltKit types only, since `Cobalt/Design` is compiled into the extensions too.
extension Copy {
    enum Editor {
        static let title = "editor", edit = "edit", edits = "edits", untitled = "untitled edit"

        // MARK: library entry

        static let editLine = "edit the picked videos together"
        static let editNoVideo = "pick at least one video to edit"
        static let creating = "making the edit…"
        static let previewFailed = "the preview can't play here. render still works."
        static let couldntCreate = "couldn't start the edit. try again."
        static func leftOut(_ n: Int) -> String {
            n == 1 ? "1 photo or gif left out · add it on the overlay" : "\(n) photos and gifs left out · add them on the overlay"
        }
        static func notOnServer(_ n: Int) -> String {
            n == 1 ? "1 pick isn't on the server, so it's left out" : "\(n) picks aren't on the server, so they're left out"
        }

        // MARK: shelf

        static func clipsLine(_ duration: String, _ clips: Int) -> String { "\(duration) · \(clips) clip\(clips == 1 ? "" : "s")" }
        static func editedAgo(_ ago: String) -> String { "edited \(ago)" }
        static let badgeWaiting = "waiting", badgeRendered = "rendered", badgeFailed = "render failed"
        static func badgeRendering(_ pct: Int) -> String { "rendering \(pct)%" }
        static let open = "open", rename = "rename…", delete = "delete…", deleteEdit = "delete edit…"
        static let deleteTitle = "delete this edit?"
        static let deleteBody = "videos you rendered from it stay in your library."
        static let deleteConfirm = "delete"
        static let renameTitle = "rename edit", renamePlaceholder = "name"

        // MARK: top bar

        static let close = "close", render = "render"
        static let toolSelect = "select", toolBlade = "blade", toolCrop = "crop"
        static let canvas = "canvas", quality = "quality"
        static func qualityLabel(_ p: Int, _ fps: Int) -> String { "\(p)p · \(fps)" }       // "1080p · 30"
        static func saveSaved(clips: Int, duration: String) -> String {
            "saved · \(clips) clip\(clips == 1 ? "" : "s") · \(duration)"
        }
        static let saveSaving = "saving…", saveRetrying = "not saved · retrying", saveConflict = "changed on another device"

        // MARK: bin

        static let library = "library", dragIn = "drag in", searchLibrary = "search the library"
        static let badgeGif = "gif", badgePhoto = "photo", cantEditBadge = "can't edit"
        static let cantEdit = "the editor takes mp4 and mov videos, gifs, jpgs and pngs."
        static let binEmpty = "nothing in your library yet. save something first."
        static let add = "add", addClip = "add a clip", addOverlay = "add an overlay", done = "done", cancel = "cancel"

        // MARK: preview and transport

        static let backOneFrame = "back one frame", forwardOneFrame = "forward one frame", play = "play", pause = "pause"
        static let pinchToZoom = "pinch to zoom"
        static func loadingSources(_ pct: Int) -> String { "getting your clips · \(pct)%" }
        static let missingClip = "this clip was deleted from your library"
        static let sourceFailed = "couldn't get this clip", tryAgain = "try again"
        static let removeMissing = "remove the missing clips to render"
        static let cropDone = "done", cropReset = "reset"

        // MARK: inspector

        static func clipN(_ n: Int) -> String { "clip \(n)" }
        static func fileLine(_ name: String, _ w: Int, _ h: Int) -> String { "\(name) · \(w)×\(h)" }
        static let trim = "trim", trimIn = "in", trimOut = "out", speed = "speed", crop = "crop", fit = "fit", volume = "volume"
        static let cropFull = "full", cropFree = "free", fitFill = "fill", fitFit = "fit", editCrop = "edit crop"
        static func speedValue(_ s: Double) -> String { "\(trimmedNumber(s))×" }                  // "1.5×", "0.25×", "2×"
        static func becomes(_ seconds: Double) -> String { "clip becomes \(trimmedNumber(seconds, places: 1))s" }   // "clip becomes 4.5s"
        static let pitchKept = "pitch kept"
        static let pitch = "pitch", pitchHint = "changes the voice, not the speed", pitchReset = "reset"
        /// "+3", "-2.5", "0" (semitones, steps of a half).
        static func pitchValue(_ p: Double) -> String {
            if abs(p) < 0.001 { return "0" }
            return "\(p > 0 ? "+" : "-")\(trimmedNumber(abs(p)))"
        }
        static func pitchChip(_ p: Double) -> String { "pitch \(pitchValue(p))" }              // "pitch +3"
        static let mute = "mute", unmute = "unmute", muted = "muted", noSound = "no sound"
        static let splitAtPlayhead = "split at playhead", deleteClip = "delete clip", deleteOverlay = "delete overlay"
        static let overlay = "overlay", start = "start", length = "length", position = "position", size = "size", opacity = "opacity"
        static let nothingSelected = "select a clip to change it"
        static func summary(canvas: String, quality: String, duration: String, clips: Int) -> String {
            "\(canvas) · \(quality) · \(duration) · \(clips) clip\(clips == 1 ? "" : "s")"
        }

        // MARK: timeline

        static let trackOverlay = "overlay", trackMain = "main", trackAudio = "audio", zoomIn = "zoom in", zoomOut = "zoom out"

        // MARK: iPhone tools and sheets

        static let toolTrim = "trim", toolSplit = "split", toolSpeed = "speed", toolOverlay = "overlay", toolVolume = "volume"
        static let nothingToSplit = "move the playhead into a clip to split it"
        static let pinchAndDrag = "pinch and drag the frame"
        static func sheetTitle(_ name: String, _ n: Int) -> String { "\(name) · clip \(n)" }    // "surf · clip 2"
        static func inAt(_ t: String) -> String { "in \(t)" }
        static func outAt(_ t: String) -> String { "out \(t)" }

        // MARK: render

        static let renderTitle = "render this edit"
        static func renderSummary(w: Int, h: Int, fps: Int, duration: String) -> String { "\(w)×\(h) · \(fps) fps · \(duration)" }
        static let renderNote = "the finished video goes to your library as private."
        static let renderOffline = "can't reach the server"
        static func waitingAhead(_ n: Int) -> String { n == 0 ? "waiting · next" : "waiting · \(n) ahead" }
        static let preparing = "preparing", finishing = "finishing"
        static func rendering(_ pct: Int) -> String { "rendering \(pct)%" }
        static let cancelRender = "cancel render", cancelRenderTitle = "cancel this render?", keepRendering = "keep rendering"
        static let rendered = "rendered · it's in your library", openVideo = "open"
        static func renderFailed(_ reason: String) -> String { "couldn't render — \(reason)" }
        static let renderingOlder = "this render is of an earlier version"
        static let closeRendering = "it keeps rendering on the server. it shows up in your library when it's done."

        // MARK: open, save, close

        static let openingProject = "opening the edit…"
        static let couldntOpen = "couldn't open this edit", projectGone = "this edit was deleted"
        static let closeUnsavedTitle = "close without saving?"
        static let closeUnsavedBody = "your last changes aren't on the server yet."
        static let keepEditing = "keep editing", closeAnyway = "close anyway"
        static let conflictTitle = "this edit changed on another device"
        static let conflictBody = "keep yours to replace it, or use theirs to drop your changes since."
        static let useTheirs = "use theirs", keepMine = "keep mine"
        static let editorOff = "the editor is off on this server"
        static let tooManyProjects = "you have 200 edits. delete some to make another."
        static let queueFull = "the server has 20 renders waiting. try again when some finish."

        // MARK: queue

        static func queueTitle(_ title: String) -> String { "render · \(title)" }
        static func queueDone(_ duration: String, _ size: String) -> String { "video · \(duration) · \(size) · private" }
        static let openEdit = "open edit"

        // MARK: accessibility

        /// "clip 2, surf, 4.5 seconds, 1.5 times speed, cropped, muted, selected" (a part is left out when it is the default).
        static func a11yClip(n: Int, name: String, seconds: Double, speed: Double, cropped: Bool, muted: Bool, selected: Bool) -> String {
            var parts = ["clip \(n)", name, "\(trimmedNumber(seconds, places: 1)) seconds"]
            if abs(speed - 1) > 0.001 { parts.append("\(trimmedNumber(speed)) times speed") }
            if cropped { parts.append("cropped") }
            if muted { parts.append("muted") }
            if selected { parts.append("selected") }
            return parts.joined(separator: ", ")
        }
        /// "overlay, dance, from 3 seconds for 3 seconds, selected"
        static func a11yOverlay(name: String, start: Double, seconds: Double, selected: Bool) -> String {
            var parts = ["overlay", name, "from \(trimmedNumber(start, places: 1)) seconds for \(trimmedNumber(seconds, places: 1)) seconds"]
            if selected { parts.append("selected") }
            return parts.joined(separator: ", ")
        }
        static let a11yMoveEarlier = "move earlier", a11yMoveLater = "move later"
        static let a11yTrimStart = "start", a11yTrimEnd = "end", a11yPlayhead = "playhead"
        static func a11yPlayheadValue(_ t: String, of total: String) -> String { "\(t) of \(total)" }

        // MARK: added (undo and redo, decided in section 10)

        static let undo = "undo", redo = "redo"

        // MARK: added (words the screens needed that the table did not name)

        static let selectAction = "select"
        static let trimAction = "trim"
        static let moveLeft = "move left", moveRight = "move right", moveUp = "move up", moveDown = "move down"
        static let overlaySize = "overlay size"
        static let positionX = "x", positionY = "y"
        static let sourceFrame = "source"
        static let loadingProject = "loading"
        static let renameField = "rename"
        static let timelineA11y = "timeline"
        static let binA11y = "library"
        static let inspectorA11y = "inspector"
        static let previewA11y = "preview"
        static let canvasA11y = "preview canvas"
        static let renderPopoverA11y = "render"
        static let dropCantEdit = cantEdit
        static let dropIntoOverlayRefused = "there's no room for it there"
        static let seeAll = "see all"
        static let longTimeline = "long edit"
        static let transportTime = "time"
        static let renderPercentA11y = "render progress"
        static let hintDoubleClick = "double-click to add"
        static let hintTapPlus = "tap plus to add"
        static let moreOptions = "more"
        static let zoom = "zoom"
        static let tooLongBar = "too long"

        // MARK: errors, in words

        /// What a refusal from the editor's routes says.
        static func errorLine(_ error: EditError) -> String {
            switch error {
            case .off: return editorOff
            case .notFound: return projectGone
            case .conflict: return conflictTitle
            case .tooMany: return tooManyProjects
            case .queueFull: return queueFull
            case .finished: return "that render already ended"
            case .tooLarge: return renderReason("too_large")
            case .invalid(let problem): return Self.problem(problem)
            case .offline: return renderOffline
            case .unavailable: return "the server can't do that right now"
            case .other: return "something went wrong"
            }
        }

        // MARK: problems (EditProblem to words)

        /// `duration` is the edit's length in seconds, for `tooLong`.
        static func problem(_ p: EditProblem, duration: Double? = nil) -> String {
            switch p {
            case .canvas: return "pick a canvas: 9:16, 1:1 or 16:9"
            case .empty: return "add at least one video"
            case .tooManyClips: return "50 clips at most · remove some"
            case .tooLong:
                if let duration { return "10 minutes at most · it's \(clock(duration))" }
                return "10 minutes at most"
            case .range(let path):
                let (who, field) = subject(of: path)
                if let field { return "\(who): \(field) is out of range" }
                return "\(who): a setting is out of range"
            case .overlayOverlap: return "two overlays overlap · move one"
            case .overlayPastEnd: return "an overlay runs past the end"
            case .sourceMissing: return "a clip was deleted from your library"
            case .notVideo: return "only videos go on the main track"
            case .unsupportedSource: return "the editor can't use one of these files"
            case .pastSourceEnd(let path): return "\(subject(of: path).who) ends after its video does"
            }
        }

        /// "clip 3" / "overlay" and the field a server path names: `main[2].speed` is ("clip 3", "speed").
        private static func subject(of path: String) -> (who: String, field: String?) {
            var who = "clip"
            if path.hasPrefix("overlay") { who = "overlay" }
            else if let open = path.firstIndex(of: "["), let close = path.firstIndex(of: "]"), open < close,
                    let index = Int(path[path.index(after: open)..<close]) {
                who = "clip \(index + 1)"
            }
            let tail = path.split(separator: ".").dropFirst().joined(separator: ".")
            let field: String?
            switch tail {
            case "speed": field = "speed"
            case "in", "out": field = "trim"
            case let t where t.hasPrefix("crop"): field = "crop"
            case "volume": field = "volume"
            case "at": field = "position"
            case "frame.x", "frame.y": field = "position"
            case "frame.w", "frame.h": field = "size"
            case "opacity": field = "opacity"
            default: field = nil
            }
            return (who, field)
        }

        // MARK: render outcomes

        /// The words for a failed render's `error` code ("error.edit.render_failed" and friends).
        static func renderReason(_ code: String?) -> String {
            let key = (code ?? "").replacingOccurrences(of: "error.edit.", with: "")
            switch key {
            case "render_failed": return "the video couldn't be made"
            case "timeout": return "it took too long"
            case "source_missing": return "a clip was deleted from the library"
            case "lost": return "the server restarted"
            case "too_large": return "the video was too big"
            case "storage": return "the server couldn't store it"
            default: return "something went wrong"
            }
        }

        /// The line for a render that is still going: "waiting · 1 ahead", "preparing", "rendering 40%", "finishing".
        static func renderLine(_ r: EditRender) -> String {
            switch r.status {
            case .queued: return waitingAhead(r.queueAhead ?? 0)
            case .preparing: return preparing
            case .rendering: return rendering(percent(r.progress))
            case .finishing: return finishing
            case .done: return badgeRendered
            case .error: return badgeFailed
            case .cancelled: return cancel
            }
        }

        /// The shelf card's badge for a project's newest render; nil when it never rendered or was cancelled.
        static func badge(_ r: EditRender?) -> String? {
            guard let r else { return nil }
            switch r.status {
            case .queued: return badgeWaiting
            case .preparing, .finishing: return badgeWaiting
            case .rendering: return badgeRendering(percent(r.progress))
            case .done: return badgeRendered
            case .error: return badgeFailed
            case .cancelled: return nil
            }
        }

        static func percent(_ progress: Double?) -> Int { Int(((progress ?? 0) * 100).rounded(.down).clamped(to: 0...100)) }

        // MARK: time

        /// "0:26" (whole seconds, rounded).
        static func clock(_ seconds: Double) -> String {
            let total = max(0, Int(seconds.isFinite ? seconds.rounded() : 0))
            return "\(total / 60):" + twoDigits(total % 60)
        }

        /// "0:09.0": tenths (the transport and the playhead).
        static func clockTenths(_ seconds: Double) -> String {
            let tenths = max(0, Int(seconds.isFinite ? (seconds * 10).rounded() : 0))
            let whole = tenths / 10
            return "\(whole / 60):" + twoDigits(whole % 60) + ".\(tenths % 10)"
        }

        /// "0:08.75": hundredths (the trim fields).
        static func clockCentis(_ seconds: Double) -> String {
            let centis = max(0, Int(seconds.isFinite ? (seconds * 100).rounded() : 0))
            let whole = centis / 100
            return "\(whole / 60):" + twoDigits(whole % 60) + "." + twoDigits(centis % 100)
        }

        /// What a time field accepts: "8.75", "0:08.75", "1:02", ".5". Nil when it is not a time.
        static func parseClock(_ text: String) -> Double? {
            let clean = text.trimmingCharacters(in: .whitespaces)
            guard !clean.isEmpty else { return nil }
            let parts = clean.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { return nil }
            if parts.count == 2 {
                guard let m = Int(parts[0]), m >= 0, let s = Double(parts[1]), s >= 0, s < 60 else { return nil }
                return Double(m) * 60 + s
            }
            guard let s = Double(parts[0]), s >= 0, s.isFinite else { return nil }
            return s
        }

        /// "just now", "5 min ago", "2 h ago", "3 d ago", else the date as "3 oct".
        static func ago(_ date: Date, now: Date) -> String {
            let seconds = max(0, now.timeIntervalSince(date))
            if seconds < 60 { return "just now" }
            if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
            if seconds < 86_400 { return "\(Int(seconds / 3600)) h ago" }
            if seconds < 86_400 * 14 { return "\(Int(seconds / 86_400)) d ago" }
            return Format.when(date, now: now).split(separator: " ").dropLast().joined(separator: " ")
        }

        // MARK: layers, images, emotes and cutouts (CONTRACT-EDITOR 12)

        static let shelfAll = "all", shelfVideos = "videos", shelfImages = "images", shelfEmotes = "emotes"
        static let badgeEmote = "emote"
        static let layer = "layer", layers = "layers"
        static func layerN(_ track: Int) -> String { "L\(track + 1)" }                  // layer 0 is "L1"
        static func layerName(_ track: Int) -> String { "layer \(track + 1)" }
        static func moreLayers(_ n: Int) -> String { "+\(n) more" }
        static let fewerLayers = "fewer layers"
        static let layerUp = "up a layer", layerDown = "down a layer"
        static let layerBusy = "that layer is busy then"
        static let allLayersBusy = "all layers are busy there"
        static let emotesEmpty = "no emotes yet. save some from 7tv in the chat or the mcp."
        static let removeBackground = "remove background", cutOut = "cut out", cutOutAndPlace = "cut out and place"
        static let cutoutAuto = "auto", cutoutWhite = "white", cutoutColour = "colour"
        static let cutoutTolerance = "tolerance", cutoutEdgesOnly = "only from the edges", cutoutEdgesHint = "keeps white eyes"
        static let cutoutSoften = "soften edges", cutoutTrim = "trim to the subject"
        static let cutoutPickColour = "tap the picture to pick a colour"
        static let cutoutMaking = "cutting out…", cutoutBefore = "before", cutoutAfter = "after"
        static let cutoutLoading = "getting the picture…"
        static let cutoutNoPreview = "no preview here · the server will cut it out"
        static let cutoutHoldBefore = "hold to see the original"
        static func cutoutError(_ e: CutoutError) -> String {
            switch e {
            case .empty: return "nothing was left · lower the tolerance or try another mode"
            case .notImage: return "that isn't a picture"
            case .tooLarge: return "that picture is too big"
            case .offline: return "you're offline · try again"
            case .off: return "this server can't make cutouts yet"
            case .notFound: return "that picture is gone from your library"
            default: return "couldn't cut it out · try again"
            }
        }

        // MARK: icon names (added for the icon-first controls: what a long press shows and VoiceOver reads)

        static let lengthShorter = "a tenth shorter", lengthLonger = "a tenth longer"

        // MARK: numbers

        private static func twoDigits(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

        /// At most `places` decimals, no trailing zeros: 1.5, 0.25, 2, 4.5.
        static func trimmedNumber(_ value: Double, places: Int = 2) -> String {
            guard value.isFinite else { return "0" }
            var text = String(format: "%.\(places)f", value)
            if text.contains(".") {
                while text.hasSuffix("0") { text.removeLast() }
                if text.hasSuffix(".") { text.removeLast() }
            }
            return text == "-0" ? "0" : text
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
