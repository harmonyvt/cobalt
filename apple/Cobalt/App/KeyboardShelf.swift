import CobaltKit
import Foundation

/// Hardlinks of files already on this phone, so the keyboard can copy them without downloading.
/// The keyboard cannot see On My iPhone. A hardlink in the app group is the same bytes.
enum KeyboardShelf {
    struct Entry: Codable, Equatable {
        var libraryID: String?
        var publicURL: String?
        var file: String
        var bytes: Int64
    }

    /// Empty means the store is still loading: leave whatever is already published.
    static func publish(_ videos: [StoredVideo]) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-cobaltSandboxRoot") { return }
        #endif
        guard !videos.isEmpty, let root = videosRoot() else { return }
        let fm = FileManager.default
        let dir = root.appendingPathComponent("for-keyboard", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var entries: [Entry] = []
        var names = Set<String>()
        for video in videos {
            guard let src = video.fileURL, fm.fileExists(atPath: src.path) else { continue }
            let raw = video.libraryID.flatMap { $0.isEmpty ? nil : $0 } ?? video.id
            let ext = src.pathExtension.lowercased()
            let name = ext.isEmpty ? KeyboardFaceSafe.id(raw) : "\(KeyboardFaceSafe.id(raw)).\(ext)"
            if !names.insert(name).inserted { continue }
            let dest = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: dest.path) {
                do { try fm.linkItem(at: src, to: dest) } catch { continue }
            }
            entries.append(Entry(
                libraryID: video.libraryID,
                publicURL: video.publicURL?.absoluteString,
                file: name,
                bytes: video.bytes))
        }
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
        }
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for item in items where item.lastPathComponent != "manifest.json" && !names.contains(item.lastPathComponent) {
            try? fm.removeItem(at: item)
        }
    }

    private static func videosRoot() -> URL? {
        #if os(macOS)
        return nil
        #else
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.capybaraharmony.cobalt") else { return nil }
        return container.appendingPathComponent("Videos", isDirectory: true)
        #endif
    }
}

private enum KeyboardFaceSafe {
    static func id(_ raw: String) -> String {
        let safe = String(raw.map { ch in
            (ch.isASCII && (ch.isLetter || ch.isNumber)) || ch == "-" || ch == "_" ? ch : "-"
        })
        return safe.isEmpty ? "cobalt" : safe
    }
}
