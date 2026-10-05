import CobaltKit
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Every user-facing string (CONTRACT section 5). All lowercase, exactly as the contract gives
/// them; strings the boards did not have are marked **new** there and here. CobaltKit exposes enums
/// and numbers, never copy (the one exception is the share notification, which CobaltKit posts).
enum Copy {
    // MARK: device

    /// "iphone" / "ipad" / "mac"
    static var device: String {
        #if os(macOS)
        return "mac"
        #else
        // Copy is read while building views, always on the main actor.
        return MainActor.assumeIsolated { UIDevice.current.userInterfaceIdiom == .pad } ? "ipad" : "iphone"
        #endif
    }

    // MARK: tabs and shell

    static let appName = "cobalt"
    static func tab(_ tab: AppTab) -> String {
        switch tab {
        case .save: return "save"
        case .library: return "library"
        case .settings: return "settings"
        }
    }

    // MARK: home

    /// The home subtitle: "13 videos · 54 MB on this iphone".
    static func offline(count: Int, bytes: Int64) -> String {
        "\(count) \(count == 1 ? "video" : "videos") · \(storage(bytes)) on this \(device)"
    }
    static let emptyOrbit = "your videos show up here"            // new
    static let orbitA11y = "your latest videos"
    static let paste = "paste"
    static let file = "file"
    static let pasteA11y = "paste a link"
    static let fileA11y = "add a file"
    /// The file circle's menu: where the file comes from.
    static let sourcePhotos = "photos"
    static let sourceFiles = "files"
    static let cancel = "cancel"
    /// The card's detail line while a picked photo or video is copied out of the library.
    static let copyingFromPhotos = "copying from photos"
    static func copyingFromPhotos(percent: Int) -> String { "copying from photos · \(percent)%" }
    static let closeA11y = "close"
    static let progressA11y = "progress"

    /// "54 MB" (the storage lines drop the ".0" the work card keeps).
    static func storage(_ bytes: Int64) -> String {
        let text = Format.bytes(bytes)
        return text.replacingOccurrences(of: ".0 MB", with: " MB")
    }

    static func step(_ step: Rail.Step) -> String {
        switch step {
        case .fetch: return "fetch"
        case .upload: return "upload"
        case .save: return "save"
        case .read: return "read"
        case .webp: return "webp"
        case .host: return "publish"
        }
    }

    // MARK: progress card (CONTRACT-ORBIT 2c): what is happening now, in plain words

    /// The headline while the link is fetched ("downloading from instagram").
    static func fetching(from service: String?) -> String {
        service.map { "downloading from \($0)" } ?? "downloading the video"
    }
    static let waking = "waking the server"
    /// Footnote under the waking line, shown while the server wakes.
    static let wakingNote = "it sleeps when idle."
    static let uploading = "uploading your file"
    static let savingPrivately = "saving to your library"
    static let saving = "saving to your library"
    static var savingLocally: String { "saving to this \(device)" }
    static let reading = "reading the video"
    static let decoding = "making your webp"
    static let packing = "packing the webp"
    static let makingWebp = "making your webp"
    static let hostingOriginal = "publishing the video"

    /// "step 2 of 4".
    static func stepOf(_ step: Int, _ count: Int) -> String { "step \(step) of \(count)" }
    /// Steps 1...3 finished and the run is waiting for the owner (the trim): "3 of 4 done".
    static func stepsDone(_ done: Int, _ count: Int) -> String { "\(done) of \(count) done" }
    static let stepDone = "done"
    static let stepFailed = "stopped"
    /// "frame 42 of 150".
    static func frameOf(_ done: Int, _ total: Int) -> String { "frame \(done) of \(total)" }
    /// "2.1 of 4.3 MB": the unit is said once when both numbers share it.
    static func bytesOf(_ done: Int64, _ total: Int64) -> String {
        let all = Format.bytes(total)
        let part = Format.bytes(done)
        if let unit = all.split(separator: " ").last, part.hasSuffix(" \(unit)") {
            return "\(part.dropLast(unit.count + 1)) of \(all)"
        }
        return "\(part) of \(all)"
    }
    /// "waking the server · 4 s", or just "4 s".
    static func elapsedLine(_ prefix: String?, seconds: Int) -> String {
        prefix.map { "\($0) · \(seconds) s" } ?? "\(seconds) s"
    }

    // MARK: trim and result

    static let scaleStart = "0 s"
    static let scaleUnknown = "…"
    static let trimOverLimit = "webps stop at 10 s, so the first 10 s are picked. drag to choose."
    static let wholeClipFits = "the whole clip fits in a webp."
    static let makeWebp = "make webp"
    static let savePhotos = "save to photos"
    static let savedPhotos = "saved to photos"
    static let hostOriginal = "host original"
    static let hostAsIs = "host as-is"
    static let linkCopied = "link copied"
    static let webpReady = "webp ready"
    static let backToTrim = "back to trim"
    static let copyLink = "copy link"
    static let copied = "copied"
    static let share = "share"
    static let imageNote = "this is an image, so there is nothing to trim. it can be hosted as it is."
    static var savedLocally: String { "saved on this \(device)." }   // new
    static let inPoint = "in point"
    static let outPoint = "out point"
    static let selection = "selection"
    static let trimAdjustHint = "arrow keys move 0.1 s"
    static let bracketA11y = "trim bracket"
    static let previewA11y = "preview of the selection"
    static let framesA11y = "frames of the video"
    static let resultA11y = "your webp"

    // MARK: focus (the planet after the morph)

    static let publicShare = "public share"
    static let convertToWebp = "convert to webp"
    static let anotherWebp = "another webp"
    static let cancelTrim = "cancel"
    static let webpLink = "webp link"
    static let videoLink = "video link"
    static let copyWebpLink = "copy webp link"
    static let copyVideoLink = "copy video link"
    static let shareWebpLink = "share webp link"
    static let shareVideoLink = "share video link"
    static let linkBadgeA11y = "hosted: has a public link"
    static let webpBadgeA11y = "made into a webp"
    static let tapForSound = "tap the video for sound"
    static let soundOn = "sound on"
    static let soundOff = "sound off"
    static let focusA11y = "your new video"
    static let closeFocusHint = "swipe down to put it back in the orbit"
    static func focusTitle(service: String, ref: String) -> String { "\(service) · \(ref)" }
    static func focusMeta(seconds: Double?, width: Int?, height: Int?, bytes: Int64?) -> String {
        var parts: [String] = []
        if let seconds { parts.append(Format.seconds(seconds)) }
        if let width, let height { parts.append(Format.size(width, height)) }
        if let bytes { parts.append(Format.bytes(bytes)) }
        return parts.joined(separator: " · ")
    }
    static func renderTicksA11y(done: Int, total: Int) -> String { "\(done) of \(total) frames decoded" }

    static func trimNote(duration: Double?, limit: Double) -> String {
        if let duration, duration <= limit { return wholeClipFits }
        return trimOverLimit
    }

    // MARK: failures

    /// "100 MB" / "200 MB". The server's limits are 100 000 000 bytes (upload) and 200 MiB (source):
    /// a whole number of MiB reads as that many MB, anything else in decimal MB.
    static func megabytes(_ bytes: Int64) -> String {
        let mib: Int64 = 1_048_576
        if bytes > 0, bytes % mib == 0 { return "\(bytes / mib) MB" }
        return "\(bytes / 1_000_000) MB"
    }

    static func failure(_ failure: PipelineFailure) -> String {
        switch failure {
        case .noLink: return "no link found in that text."
        case .tooLarge(let limit): return "that file is over the \(megabytes(limit)) limit."
        case .fetchFailed: return "cobalt couldn't fetch this link. the post may be private or removed."
        case .unsupported: return "cobalt for apple can't save this kind of post yet."          // new
        case .serverBusy: return "cobalt is busy with another video. try again in a minute."     // new
        case .renderBusy: return "another webp is being made right now."
        case .renderLost: return "the webp was lost while cobalt was in the background. your trim is kept."
        case .expired: return "this video's studio has expired."                                  // new
        case .keyMissing: return "add your api key in settings first."                            // new
        case .keyInvalid: return "this key was revoked"
        case .unreachable: return "can't reach the server."                                       // new
        case .server(let code):
            // A failure while making the webp carries CobaltKit's "render." prefix: say it in words,
            // never show the raw code.
            if code.hasPrefix(PipelineFailure.renderPhasePrefix) { return "cobalt couldn't make the webp. your trim is kept." }
            if code == "error.app.file_unreadable" { return "couldn't read that file. if it's in icloud, check your connection and try again." }
            if let line = appFailure(code) { return line }
            return "something went wrong (\(code))."                                              // new
        }
    }

    /// The on-device errors (`error.app.*`: made by the app, never by the server), each in plain
    /// words: a raw code is for the server's own surprises, not for a refused permission or a failed
    /// save to photos.
    static func appFailure(_ code: String) -> String? {
        guard code.hasPrefix("error.app.") else { return nil }
        switch code {
        case "error.app.photos_denied": return "allow cobalt to add to photos in settings, then try again."
        case "error.app.no_original": return "cobalt couldn't get the original video. try again."
        case "error.app.job_lost": return "cobalt lost track of that video. save it again."
        case "error.app.not_cobalt": return "that server doesn't look like cobalt."
        case "error.app.photos", "error.app.photos_failed": return "couldn't save to photos. try again."
        default: return "something went wrong. try again."                                        // error.app.unknown and the rest
        }
    }

    static let ok = "ok"
    static let tryAgain = "try again"
    static let makeItAgain = "make it again"
    static let openSettings = "settings"

    // MARK: picker

    static let pickerTitle = "select what to save"
    static let pickerNote = "this post has more than one thing in it. press an item to save it, or turn a video into a webp."
    static let save = "save"
    static let webp = "webp"
    static func badge(_ type: MediaType) -> String {
        switch type {
        case .video: return "video"
        case .photo: return "photo"
        case .gif: return "gif"
        }
    }
    static func saveAll(_ count: Int) -> String {
        count == 2 ? "save both to photos" : "save all \(count) to photos"     // "all n" is new
    }
    static let pickerFooter = "webp only appears on videos and gifs. photos stay photos."
    static let saved = "saved"

    // MARK: library

    static let library = "library"
    static func libraryCounts(posts: Int, files: Int) -> String {
        "\(posts) \(posts == 1 ? "post" : "posts") · \(files) \(files == 1 ? "file" : "files")"
    }
    static let libraryFailed = "can't load the library."                                          // new
    static let libraryEmpty = "nothing here yet."                                                 // new
    static let webpFile = "webp"
    static let mp4Link = "mp4 link"
    static let privateCopy = "private copy"
    static let privatePill = "private"
    static let copy = "copy"
    static let delete = "delete"
    static let deleteOnWeb = "delete on web"
    static let keep = "keep"
    static let deleteAsk = "delete for everyone? discord embeds stop working."
    static let trimNewWebp = "trim a new webp"
    static let makeAWebp = "make a webp"
    static let close = "close"
    static let hostIt = "host it"
    static let saveAs = "save as…"
    static let whatExists = "what exists for this post"
    static let madeFromThisVideo = "made from this video"
    static let deleteFailed = "couldn't delete that. it is still there."                         // new
    static let actionFailed = "that didn't work. try again."                                      // new
    static let postsA11y = "posts"

    static func libraryPostTitle(service: String?, ref: String?) -> (String, String?) {
        (service ?? "cobalt", ref)
    }

    static func fileName(_ file: LibraryFile) -> String {
        switch file.role {
        case .webp: return file.duration.map { "webp \(Format.seconds($0))" } ?? "webp"
        case .hostedLink: return mp4Link
        case .privateCopy: return privateCopy
        }
    }

    static func fileMeta(_ file: LibraryFile) -> String {
        var parts: [String] = []
        if let bytes = file.bytes { parts.append(Format.bytes(bytes)) }
        switch file.role {
        case .webp:
            if let w = file.width, let h = file.height { parts.append(Format.size(w, h)) }
            parts.append("public")
        case .hostedLink: parts.append("public")
        case .privateCopy: parts.append("mp4")
        }
        return parts.joined(separator: " · ")
    }

    static func fileMetaWide(_ file: LibraryFile) -> String {
        switch file.role {
        case .webp: return fileMeta(file).replacingOccurrences(of: "public", with: "public link")
        case .hostedLink: return fileMeta(file).replacingOccurrences(of: "public", with: "public link")
        case .privateCopy: return fileMeta(file) + " · only you"
        }
    }

    static func postMeta(_ post: LibraryPost, now: Date) -> String {
        var parts: [String] = []
        if let d = post.duration { parts.append(Format.seconds(d)) }
        if let w = post.width, let h = post.height { parts.append(Format.size(w, h)) }
        parts.append(Format.when(post.createdAt, now: now))
        return parts.joined(separator: " · ")
    }

    static func postMetaWide(_ post: LibraryPost, now: Date) -> String {
        var parts: [String] = []
        if let d = post.duration { parts.append(Format.seconds(d)) }
        if let w = post.width, let h = post.height { parts.append(Format.size(w, h)) }
        parts.append("saved \(Format.when(post.createdAt, now: now))")
        if let session = post.session, session.status == .ready {
            let days = Int((session.expiresAt.timeIntervalSince(now) / 86_400).rounded(.down))
            if days >= 1 { parts.append("studio open \(days) more \(days == 1 ? "day" : "days")") }
        }
        return parts.joined(separator: " · ")
    }

    static let pasteHint = "paste"
    static let dropHint = "or drop a file anywhere"

    // MARK: inspector (wide)

    static let quality = "quality"
    static let width = "width"
    static let inspectorA11y = "inspector"
    static func qualityName(_ q: WebpQuality) -> String {
        switch q {
        case .low: return "low"
        case .med: return "medium"
        case .high: return "high"
        }
    }
    static func widthName(_ w: Int) -> String { "\(w) px" }
    static func timecodeRange(_ range: TrimRange) -> String {
        "\(Format.timecode(range.start)) → \(Format.timecode(range.end))"
    }
    static func timecodeOf(_ range: TrimRange, duration: Double) -> String {
        "\(timecodeRange(range)) of \(Format.timecode(duration))"
    }
    static let publicLink = "public link"

    // MARK: settings

    static let settings = "settings"
    static let groupServer = "server"
    static let groupMaking = "making"
    static let groupFeel = "feel"
    static let api = "api"
    static let thisServer = "this server"
    static let apiKey = "api key"
    static let pasteServerURL = "paste server url"                // new
    static let reset = "reset"                                    // new
    static let pasteKey = "paste key"                             // new
    static let pasteNewKey = "paste new key"
    static let noKey = "no key"                                   // new
    static let keyRevoked = "this key was revoked"
    static let notAKey = "that isn't a cobalt api key."           // new
    static var keyNotSaved: String { "couldn't save the key on this \(device). try again." }   // new
    static let notAURL = "that isn't a url."                      // new
    static let checking = "checking…"                             // new
    static let keyFootnote = "make keys on the web: cobalt → settings → api keys. the app keeps it in the keychain and sends it as \"Authorization: Api-Key …\". revoking it on the web locks this \(device) out at once."
    static let webpQuality = "webp quality"
    static var keepVideos: String { "keep videos on this \(device)" }
    static let storedHere = "stored here"
    static let haptics = "haptics"
    static let motion = "motion"
    static let motionFollows = "follows reduce motion"
    static let settingsFooter = "on a plain cobalt server (no studio routes) the same circles still save through cobalt's normal api; webp, studio and library just hide. your two shortcuts keep working."
    static var removeVideosTitle: String { "remove saved videos?" }                       // new
    static var removeVideosMessage: String { "the videos stored on this \(device) are deleted. their posters stay." }   // new
    static let remove = "remove"                                                          // new

    static func storageLine(count: Int, bytes: Int64) -> String {
        "\(count) \(count == 1 ? "video" : "videos") · \(storage(bytes))"
    }

    /// "cobalt 11.7.1 · your server" (what it can do is the disclosure under it, `serverFeatures`).
    static func serverKind(_ s: ServerSummary, checking: Bool) -> String {
        switch s.kind {
        case .unreachable: return checking ? Copy.checking : "can't reach this server"          // new
        case .notCobalt: return "this isn't a cobalt server"                                    // new
        case .plainCobalt: return ["cobalt", s.version].compactMap { $0 }.joined(separator: " ")
        case .legacyFork, .fork: return ["cobalt", s.version].compactMap { $0 }.joined(separator: " ") + " · your server"
        }
    }

    static let serverFeaturesTitle = "what it can do"
    static let featureOn = "on"
    static let featureOff = "off"

    /// One line of the server's capabilities: what it is, what it means here, and whether it is on.
    struct ServerFeature: Identifiable {
        let name: String
        let detail: String
        let on: Bool
        var id: String { name }
    }

    /// Every capability the server reported, on or off, in the order the owner meets them.
    static func serverFeatures(_ c: Capabilities) -> [ServerFeature] {
        [
            ServerFeature(name: "studio", detail: "makes webps and hosts originals", on: c.studio),
            ServerFeature(name: "upload", detail: "takes files from this \(device)", on: c.upload),
            ServerFeature(name: "library", detail: "keeps every post you've made", on: c.library),
            ServerFeature(name: "progress", detail: "real numbers while it saves and makes", on: c.saveProgress || c.renderProgress),
            ServerFeature(name: "finishes on its own", detail: "keeps going if you close the share sheet", on: c.finishesUnpolled),
            ServerFeature(name: "live activity push", detail: "updates the island when closed", on: c.livePush),
        ]
    }

    static func keyLine(name: String) -> String { "\(name) · ••••••••" }
    static let keySet = "set"

    // MARK: share sheet

    static let shareSheetA11y = "cobalt"
    static func overLimit(_ seconds: Double, limit: Double) -> String {
        "\(Format.seconds(seconds)) is over the \(Int(limit)) s webp limit. it's saved, so cobalt opens right on the trim."
    }
    static let trimInCobalt = "trim in cobalt"
    static let done = "done"
    static let stillMakingInApp = "still making the webp you started in the share sheet…"
    static let makingWebpDots = "making webp…"
    /// The app followed a webp the share sheet started, and it finished while the sheet was closed.
    static func finishedWhileClosed(bytes: Int64) -> String {
        "finished while the sheet was closed. \(Format.bytes(bytes)), link ready."
    }
    static let inspectorToggle = "trim settings"
}
