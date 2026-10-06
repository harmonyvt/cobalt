import CobaltKit
import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Where a made picture goes when the owner asks for it (the repost tools' save): the Photos app on iPhone and iPad (through
/// `AppModel.repostFrames`), a file or a folder the owner picks on the Mac (there is no Photos sync there). Panels are
/// modal and run on the main actor, like the detail's own saves (`RenditionPhotos`).
@MainActor
enum ToolsExport {
    #if os(macOS)
    /// A save panel for one picture; nothing when the owner cancels. The file is copied (an existing one replaced).
    static func save(_ file: URL) throws -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return false }
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.copyItem(at: file, to: destination)
        return true
    }

    /// A folder for several pictures (each keeps its name); nil when the owner cancels.
    static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = Copy.Media.savePhotos
        return panel.runModal() == .OK ? panel.url : nil
    }
    #endif

    /// Removes the temporary folder `AppModel.repostFrames` made a picture in (its parent), never anything else.
    static func discard(_ files: [URL]) {
        for file in files where file.deletingLastPathComponent().lastPathComponent.hasPrefix("cobalt-frames-") {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
    }
}

/// A frame to hand to the share sheet: made when the sheet asks for it (the owner may close the sheet without sharing, and a
/// frame nobody sends costs nothing). A `Transferable` file of the one photo with the spec as it is when the share starts.
struct SharedFrame: Transferable {
    let model: AppModel
    let rendition: Rendition
    let spec: FrameSpec

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .jpeg) { frame in
            let result = try await frame.model.repostFrames([frame.rendition], spec: frame.spec, to: .files)
            guard let file = result.files.first else { throw PipelineFailure.unsupported }
            return SentTransferredFile(file)
        }
    }
}
