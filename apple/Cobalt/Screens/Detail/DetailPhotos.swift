import CobaltKit
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// "save to photos" for one rendition (CONTRACT-MEDIA 1.10, 1.15).
///
/// iPhone and iPad: one call, `AppModel.saveToPhotos(_:)`, which puts the file in Photos (into the `cobalt` album
/// when the sync has it on), fetching the stored copy first when the device has no file, and records the Photos
/// ledger key so the album sync never adds it again. Mac: a save panel (the Mac has no Photos sync).
@MainActor
enum RenditionPhotos {
    static func canSave(_ r: Rendition) -> Bool {
        r.hasFileHere || r.file != nil
    }

    static func save(_ r: Rendition, model: AppModel) async throws {
        #if os(macOS)
        if let file = r.file {
            try await saveWithPanel(source: model.library.localCopy(file), suggested: nil)
            return
        }
        guard let url = r.local?.fileURL, FileManager.default.fileExists(atPath: url.path) else {
            throw PipelineFailure.unsupported
        }
        try saveWithPanel(source: url, suggested: url.lastPathComponent)
        #else
        try await model.saveToPhotos(r)
        #endif
    }

    #if os(macOS)
    private static func saveWithPanel(source: URL, suggested: String?) throws {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggested ?? source.lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.copyItem(at: source, to: destination)
    }
    #endif
}
