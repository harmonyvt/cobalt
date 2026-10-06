import Foundation
import Synchronization

// The vocabulary of the Shortcuts actions (CONTRACT-PARALLEL.md section 15). Plain Swift: the App Intents structs in
// the app target (`Cobalt/Intents/`) are thin wrappers that turn these into `AppEntity`s, `AppEnum`s and dialogs, and
// the words live in `Design/Copy+Shortcuts.swift`. Everything here is testable with `swift test`.

/// What the owner asked for as the save's visibility (15.4). `appDefault` follows Settings "make new saves public".
public enum ShortcutVisibility: String, Sendable, CaseIterable {
    case appDefault, `public`, `private`

    /// `JobOptions.makePublic`: nil follows the app's setting.
    public var makePublic: Bool? {
        switch self {
        case .appDefault: return nil
        case .public: return true
        case .private: return false
        }
    }
}

/// What "Save links" does with a post that holds several items (CONTRACT-GALLERY 1.13, the `Galleries` parameter):
/// `everything` is the default (a post is saved whole, into cobalt, never into Photos); the two makes save everything
/// first and then make one thing from it.
public enum ShortcutGalleries: String, Sendable, CaseIterable {
    /// Save every item (the default).
    case everything
    /// Today's rule: the post's first video only. A photo-only post then fails (the server says `error.webp.no_video`).
    case firstVideo
    /// Save everything, then make a slideshow webp of all of it (the app's standard plan: 2 s a photo, crossfade).
    case slideshowWebp
    /// Save everything, then make a gallery image of its photos (the `Layout` parameter picks the arrangement).
    case galleryImage

    /// What the job does behind the save. nil = `JobOptions`' own default (`.saveAll`).
    public func handling(layout: GalleryLayout) -> GalleryHandling? {
        switch self {
        case .everything: return nil
        case .firstVideo: return .firstVideo
        case .slideshowWebp: return .slideshowWebp
        case .galleryImage: return .galleryImage(layout)
        }
    }

    /// A make follows the save.
    public var makes: Bool { self == .slideshowWebp || self == .galleryImage }

    /// What the make is called in words ("slideshow webp", "gallery image"); nil for the two that make nothing.
    public var what: String? {
        switch self {
        case .slideshowWebp: return "slideshow webp"
        case .galleryImage: return "gallery image"
        case .everything, .firstVideo: return nil
        }
    }
}

/// "Get latest saves" filter (15.4; the chips of the library, CONTRACT-GALLERY 1.21). `videos`, `photos` and `galleries`
/// are the post's kind; `webps` is a post that holds a webp (one made of a video, or a slideshow webp).
public enum ShortcutSaveKind: String, Sendable, CaseIterable { case anything, videos, photos, galleries, webps }

/// What a save is (`CobaltSave.kind`; the library's `MediaKind`, with a post that is only webps counted as a video).
public enum ShortcutMediaKind: String, Sendable, CaseIterable { case video, photo, gallery }

/// A save's state as Shortcuts shows it (15.4 `CobaltSaveState`).
public enum ShortcutSaveState: String, Sendable, CaseIterable { case queued, saving, saved, failed }

/// "Make webp" size (15.4): the two widths the server renders, or the app's setting.
public enum ShortcutWebpSize: Int, Sendable, CaseIterable {
    case appDefault = 0, small = 320, large = 480
}

/// One save as Shortcuts hands it from action to action (15.4 `CobaltSave`). `id` is the post key: the session id for a
/// saved link, the item id for an upload; both equal `GET /library`'s post `id`. A save the server never answered for
/// (`stillLocal`) has no post key yet: its id is the job's UUID and nothing can look it up until it lands.
public struct ShortcutSave: Sendable, Equatable, Identifiable {
    public var id: String
    /// The custom title, else the file's or the post's own (`service · ref`).
    public var title: String
    /// The page it came from (a saved link).
    public var link: URL?
    public var service: String?
    public var state: ShortcutSaveState
    /// The original's public link, when it is public.
    public var publicLink: URL?
    /// Public links of its webps, newest first.
    public var webpLinks: [URL]
    public var duration: Double?
    public var created: Date
    /// A video original exists (what "Make webp" needs). A gallery has one when one of its items is a video.
    public var hasVideo: Bool
    /// What the save is. nil while it is not known: a save the server has only just taken (or has not finished) may turn
    /// out to be a photo post or a gallery; once it is saved the library says.
    public var kind: ShortcutMediaKind?
    /// The items the post holds (1 for a video or a photo, the live items of a gallery); nil with `kind`.
    public var itemCount: Int?
    /// Public links of its items, in the post's order (a gallery's photos; a single video's or photo's own link). Empty
    /// while the save is private or not finished.
    public var itemLinks: [URL]
    /// Public links of what was made from it (slideshow webp and mp4, gallery images, crops), newest first.
    public var madeLinks: [URL]
    /// Items the save could not fetch ("photo 7 couldn't be fetched"); the others are saved.
    public var itemsFailed: Int

    public init(
        id: String, title: String, link: URL? = nil, service: String? = nil, state: ShortcutSaveState,
        publicLink: URL? = nil, webpLinks: [URL] = [], duration: Double? = nil, created: Date, hasVideo: Bool = false,
        kind: ShortcutMediaKind? = nil, itemCount: Int? = nil, itemLinks: [URL] = [], madeLinks: [URL] = [], itemsFailed: Int = 0
    ) {
        self.id = id
        self.title = title
        self.link = link
        self.service = service
        self.state = state
        self.publicLink = publicLink
        self.webpLinks = webpLinks
        self.duration = duration
        self.created = created
        self.hasVideo = hasVideo
        self.kind = kind
        self.itemCount = itemCount
        self.itemLinks = itemLinks
        self.madeLinks = madeLinks
        self.itemsFailed = itemsFailed
    }
}

/// Why an action stopped (15.6). The words are the app's (`Copy.Shortcuts`).
public enum ShortcutError: Error, Sendable, Equatable {
    /// No server or key in the app.
    case notSignedIn
    /// The server answered and refused the key.
    case keyRefused
    /// The server did not answer (nothing was queued).
    case serverUnreachable
    /// No server line (an old server) and the owner declined to continue in the foreground.
    case oldServer
    case noLink
    /// The server's line holds its limit (`error.studio.line_full`); the number is `limits.line_max`.
    case lineFull(max: Int)
    /// A file over the upload limit, before a byte was sent.
    case fileTooLarge(limit: Int64)
    /// Nothing to upload.
    case noFile
    /// "Make webp" on a save with no video.
    case noVideo
    /// The save is not on the server (any more).
    case saveNotFound
    /// Anything the pipeline or the server said, in the words of CONTRACT 5.1.
    case failed(PipelineFailure)

    /// The pipeline's failure as the action reports it: the ones with their own words first.
    static func from(_ failure: PipelineFailure, lineMax: Int) -> ShortcutError {
        switch failure {
        case .lineFull: return .lineFull(max: lineMax)
        case .keyMissing: return .notSignedIn
        case .keyInvalid: return .keyRefused
        case .unreachable: return .serverUnreachable
        case .noLink: return .noLink
        case .tooLarge(let limit): return .fileTooLarge(limit: limit)
        default: return .failed(failure)
        }
    }
}

/// One link or file that could not be handed over, with its label (`service · ref` or the file's name) and why.
public struct ShortcutFailure: Sendable, Equatable {
    public var label: String
    public var error: ShortcutError
    /// The server had it and then failed it (while waiting); false = it could not be handed over at all.
    public var afterHandOver: Bool

    public init(label: String, error: ShortcutError, afterHandOver: Bool = false) {
        self.label = label
        self.error = error
        self.afterHandOver = afterHandOver
    }
}

/// What "Save links" and "Upload files" return: the saves the server has (or, for `stillLocal`, still the app's),
/// the ones that could not be sent, and how many were asked for.
public struct ShortcutSaveOutcome: Sendable, Equatable {
    /// In the order asked; failures are not in here.
    public var saves: [ShortcutSave]
    public var failures: [ShortcutFailure]
    /// Distinct links or files asked for.
    public var total: Int
    /// Saves whose gallery was saved but whose make (slideshow webp, gallery image) could not be made: the save stands,
    /// nothing was made. Only after a wait (`waitUntilSaved` is what follows the make).
    public var makeFailures: [ShortcutMakeFailure] = []
    /// The jobs behind `saves`, same order (`nil` for none); the wait and the stop button act on them.
    var jobIDs: [UUID] = []
    /// The server session of each save, same order, to follow it with: nil for a save the server has not answered for
    /// and for an image upload (an image has no session).
    var sessions: [String?] = []
    /// The links were saved with a make behind the save (`ShortcutGalleries.what`: "slideshow webp" or "gallery image"):
    /// the wait follows it too.
    var makeWhat: String?
    var asksMake: Bool { makeWhat != nil }

    public init(saves: [ShortcutSave], failures: [ShortcutFailure], total: Int) {
        self.saves = saves
        self.failures = failures
        self.total = total
    }

    /// Some were sent, some were not (the dialog of 15.3 step 5).
    public var isPartial: Bool { !saves.isEmpty && !failures.isEmpty }
}

/// A gallery that was saved but whose make could not be made (the photos are saved and untouched).
public struct ShortcutMakeFailure: Sendable, Equatable {
    /// The save's title.
    public var title: String
    /// "slideshow webp" or "gallery image".
    public var what: String
    public var failure: PipelineFailure

    public init(title: String, what: String, failure: PipelineFailure) {
        self.title = title
        self.what = what
        self.failure = failure
    }
}

/// A file as the action hands it over: the system's file URL (copied before the action returns, the temporary file
/// may go as soon as it does), its bytes already in memory, or a reader that produces the bytes only when the file's
/// turn comes (`IntentFile.data` for a file with no URL: a big Photos video must never sit in memory next to the other
/// files, or before the size limit has had its say).
public struct ShortcutFile: Sendable {
    public enum Source: Sendable {
        case url(URL)
        case data(Data)
        /// Read when this file is staged, one file at a time, off the main thread; released as soon as it is written to
        /// the inbox. Its size is checked after the read (there is nothing to ask before), and a file over the limit is
        /// never written.
        case deferred(@Sendable () -> Data)
    }

    public var name: String
    public var source: Source

    public init(name: String, source: Source) {
        self.name = name
        self.source = source
    }
}

/// What `prepare()` found out about the server: whether it keeps the line (`features.line`).
public struct ShortcutReadiness: Sendable, Equatable {
    /// False: an old server. A job then waits in this device's line and needs the app in the foreground.
    public var hasLine: Bool
    /// `limits.line_max`.
    public var lineMax: Int
}

/// "Stop" on a waiting action (the Shortcuts stop button or the 30 s timeout) and the Task's own cancellation both
/// land here, so an action cleans up whichever it hears first.
public final class ShortcutCancel: Sendable {
    private let flag = Mutex(false)

    public init() {}

    public func cancel() { flag.withLock { $0 = true } }
    public var isCancelled: Bool { flag.withLock { $0 } }
}

/// Progress for the system's own Live Activity (`ProgressReportingIntent.progress`): units done of a total, the unit
/// being bytes for an upload, finished saves for a wait, and a hundred steps for a webp.
public typealias ShortcutProgress = @MainActor (_ completed: Int64, _ total: Int64) -> Void

/// What an action reads the clipboard through (the Siri phrase "Save my copied link" has no input).
@MainActor
public protocol ShortcutClipboard {
    func text() -> String?
}
