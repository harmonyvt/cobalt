import Foundation

/// What a paste from the menu bar does with the clipboard. Files win over text, the same rule as the
/// window's paste. A single new link is saved here. Anything the window would ask about (the review
/// of several links, the name-it sheet for one file) is handed to that window instead.
public enum MenuBarPastePlan: Equatable, Sendable {
    /// One link, and no job is already saving it. Queue it. No sheet.
    case saveLinks([URL])
    /// Several files. The window uploads them with no sheet; the menu bar does the same.
    case saveFiles
    /// The window's existing sheet has to ask. Do not start the save in the popover.
    case needsAttention(MenuBarPasteAttention)
    /// No link in the text.
    case noLink
    /// One link a job is already saving. A status line, not a choice.
    case alreadySaving
}

public enum MenuBarPasteAttention: Equatable, Sendable {
    /// Two or more links. The review sheet, including links already saved that the owner can tick.
    case review
    /// One file. The name-it sheet before the upload goes out.
    case nameFile
}

public enum MenuBarPaste {
    /// `links` is every link the clipboard text held, in order, before the review's cap of 20.
    /// `isLive` is true when a job is already saving that exact link (`JobQueue.liveJob(for:)`).
    /// A file on the pasteboard wins: the text is not read, matching the window.
    public static func plan(fileCount: Int, links: [URL], isLive: (URL) -> Bool) -> MenuBarPastePlan {
        if fileCount == 1 { return .needsAttention(.nameFile) }
        if fileCount > 1 { return .saveFiles }
        guard let only = links.first else { return .noLink }
        if links.count == 1 { return isLive(only) ? .alreadySaving : .saveLinks(links) }
        return .needsAttention(.review)
    }

    /// The run is waiting on the owner: a multi-item post (`picker`, which is also where a video
    /// can be turned into a webp) or a file that still has no name. The popover does not draw that
    /// choice; the window already does.
    public static func jobNeedsOwner(isPicker: Bool, waitsForTitle: Bool) -> Bool {
        isPicker || waitsForTitle
    }
}
