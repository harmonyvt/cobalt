import AppIntents
import CobaltKit
import Foundation

/// A save's visibility in Shortcuts (CONTRACT-PARALLEL.md 15.4): the app's own setting, or this one save's.
enum CobaltVisibility: String, AppEnum {
    case appDefault, `public`, `private`

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Visibility")
    static let caseDisplayRepresentations: [CobaltVisibility: DisplayRepresentation] = [
        .appDefault: "App default",
        .public: "Public",
        .private: "Private",
    ]

    var shortcut: ShortcutVisibility {
        switch self {
        case .appDefault: return .appDefault
        case .public: return .public
        case .private: return .private
        }
    }
}

/// What "Save links" does with a post that holds several photos or videos (CONTRACT-GALLERY.md 1.13): a gallery is saved
/// whole into cobalt by default, never into Photos; the other two choices save it and then make one thing from it.
enum CobaltGalleries: String, AppEnum {
    case everything, firstVideo, webp, image

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Galleries")
    static let caseDisplayRepresentations: [CobaltGalleries: DisplayRepresentation] = [
        .everything: "Save everything",
        .firstVideo: "First video only",
        .webp: "Save + slideshow webp",
        .image: "Save + gallery image",
    ]

    var shortcut: ShortcutGalleries {
        switch self {
        case .everything: return .everything
        case .firstVideo: return .firstVideo
        case .webp: return .slideshowWebp
        case .image: return .galleryImage
        }
    }
}

/// How "Save + gallery image" arranges the photos (CONTRACT-GALLERY.md 1.13, 6.4): no gaps, no borders.
enum CobaltGalleryLayout: String, AppEnum {
    case strip, grid2, grid3, row

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Layout")
    static let caseDisplayRepresentations: [CobaltGalleryLayout: DisplayRepresentation] = [
        .strip: "Strip",
        .grid2: "2 across",
        .grid3: "3 across",
        .row: "Side by side",
    ]

    var layout: GalleryLayout {
        switch self {
        case .strip: return .strip
        case .grid2: return .grid2
        case .grid3: return .grid3
        case .row: return .row
        }
    }
}

/// "Save links" (CONTRACT-PARALLEL.md 15.4): hands links to cobalt's server, which holds the line and saves them with
/// every client gone. Background by default; the server's line is what makes it finish well inside the system's 30
/// seconds. `Wait until saved` (iOS and macOS 27) runs inside `performBackgroundTask`, so the system keeps the process
/// and shows its own progress with a stop button.
struct SaveLinksIntent: AppIntent, ProgressReportingIntent {
    static let title: LocalizedStringResource = "Save links"
    static let description = IntentDescription(
        "Hands links to cobalt, which saves them to your library. With no links given it saves the link you copied.",
        categoryName: "cobalt")
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @Parameter(
        title: "Links",
        description: "A link, a URL, or text with links in it. Empty means the link you copied.", default: [])
    var links: [String]

    @Parameter(title: "Title", description: "Names the save. Used when there is exactly one link.")
    var saveTitle: String?

    @Parameter(title: "Visibility", default: .appDefault)
    var visibility: CobaltVisibility

    @Parameter(
        title: "Galleries",
        description: "What to do with a post that holds several photos or videos. Everything is saved to cobalt, not to Photos.",
        default: .everything)
    var galleries: CobaltGalleries

    @Parameter(title: "Layout", description: "How Save + gallery image arranges the photos.", default: .grid3)
    var layout: CobaltGalleryLayout

    @Parameter(
        title: "Wait until saved",
        description: "Returns when cobalt has saved them, with their public links. Save + slideshow webp and Save + gallery image also wait for the file to be made. iOS and macOS 27.",
        default: false)
    var waitUntilSaved: Bool

    @Parameter(title: "Open cobalt", description: "Brings cobalt forward and shows what is saving.", default: false)
    var openCobalt: Bool

    @Dependency var actions: ShortcutActions

    /// The layout is asked only for the gallery image (a `When` wraps whole summaries, so the two are spelled out).
    static var parameterSummary: some ParameterSummary {
        When(\.$galleries, .equalTo, CobaltGalleries.image) {
            Summary("Save \(\.$links)") {
                \.$galleries
                \.$layout
                \.$saveTitle
                \.$visibility
                \.$waitUntilSaved
                \.$openCobalt
            }
        } otherwise: {
            Summary("Save \(\.$links)") {
                \.$galleries
                \.$saveTitle
                \.$visibility
                \.$waitUntilSaved
                \.$openCobalt
            }
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[CobaltSave]> & ProvidesDialog {
        do {
            let ready = try await actions.prepare()
            var allowDeviceLine = false
            if !ready.hasLine {
                // An old server holds no line: this device does, and only while cobalt is open (15.2.3).
                guard await continueInForegroundIfNeeded(Copy.Shortcuts.continueForOldServer) else { throw ShortcutError.oldServer }
                allowDeviceLine = true
            }
            let makes = galleries.shortcut.makes
            // The make behind the save is sent by cobalt once the save is over, so the action stays with it (iOS and macOS
            // 27: the system keeps the process and shows its progress). Earlier systems cannot wait: they ask to bring cobalt
            // forward instead, and a refusal leaves the make to the app's own line.
            var waits = false
            if #available(iOS 27, macOS 27, *) { waits = waitUntilSaved || makes }
            else if makes { _ = await continueInForegroundIfNeeded(Copy.Shortcuts.continueForMake) }
            let follow: ShortcutActions.FollowUp = waits ? .wait : (openCobalt ? .open : .leave)
            var outcome = try await actions.saveLinks(
                links, title: saveTitle, visibility: visibility.shortcut, galleries: galleries.shortcut, layout: layout.layout,
                then: follow, allowDeviceLine: allowDeviceLine)
            if #available(iOS 27, macOS 27, *), waits {
                outcome = try await waitInBackground(outcome)
            }
            if openCobalt, await continueInForegroundIfNeeded(nil) { actions.openTray() }
            return IntentResults.saves(outcome.saves, dialog: Copy.Shortcuts.saveDialog(outcome))
        } catch ShortcutError.failed(.unsupported) where galleries.shortcut.makes {
            // a server that cannot make a slideshow webp or a gallery image: nothing was saved
            throw CobaltIntentError(message: Copy.Gallery.serverCantMake)
        } catch {
            throw IntentErrors.map(error)
        }
    }

    /// Brings cobalt forward when the system allows it and the owner does not refuse. False when it was declined or the
    /// action cannot continue in the foreground; true when cobalt already is in front.
    @MainActor
    func continueInForegroundIfNeeded(_ words: String?) async -> Bool {
        if systemContext.currentMode == .foreground { return true }
        guard systemContext.currentMode.canContinueInForeground else { return false }
        do {
            try await continueInForeground(words.map(IntentErrors.dialog), alwaysConfirm: false)
            return true
        } catch {
            return false
        }
    }
}

@available(iOS 27, macOS 27, *)
extension SaveLinksIntent: LongRunningIntent, CancellableIntent {
    /// "Wait until saved": inside `performBackgroundTask` the system keeps the process and shows `progress` (saves
    /// finished of saves asked for) with a stop button; stop cancels what is still queued (15.6).
    @MainActor
    func waitInBackground(_ outcome: ShortcutSaveOutcome) async throws -> ShortcutSaveOutcome {
        let cancel = ShortcutCancel()
        let report: ShortcutProgress = { done, total in
            progress.totalUnitCount = total
            progress.completedUnitCount = done
        }
        let actions = actions
        return try await performBackgroundTask(
            operation: { @Sendable in try await actions.waitUntilSaved(outcome, cancel: cancel, progress: report) },
            onCancel: { _ in cancel.cancel() })
    }
}
