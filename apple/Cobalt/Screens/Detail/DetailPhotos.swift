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

    /// One rendition. A gallery's item or made file goes through the gallery call, which records the key the album sync
    /// reads (`g:<sid>:<n>`, `m:<library id>`); the rest is the video's and webp's call as before.
    static func save(_ r: Rendition, in item: MediaItem? = nil, model: AppModel) async throws {
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
        if let item, r.isItem || r.isMade {
            try await model.saveToPhotos([r], of: item)
        } else {
            try await model.saveToPhotos(r)
        }
        #endif
    }

    /// The ticked photos, or all of them: Photos on iOS and iPadOS (the owner asked); a folder the Mac owner picks, with
    /// each file's own name (the Mac has no Photos sync).
    static func save(_ renditions: [Rendition], of item: MediaItem, model: AppModel) async throws {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = Copy.Media.savePhotos
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let fm = FileManager.default
        for r in renditions {
            let source: URL
            if let url = r.local?.fileURL, fm.fileExists(atPath: url.path) {
                source = url
            } else if let file = r.file {
                source = try await model.library.localCopy(file)
            } else {
                continue
            }
            let destination = folder.appendingPathComponent(source.lastPathComponent)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.copyItem(at: source, to: destination)
        }
        #else
        try await model.saveToPhotos(renditions, of: item)
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
