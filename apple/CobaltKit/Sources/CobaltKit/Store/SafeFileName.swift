import Foundation

/// A file name that came from outside (a server's `filename`, another app's suggested name, a
/// picked file) turned into one safe path component: no separators, no control characters, never
/// empty, ".", or "..", and not longer than a file system will take.
enum SafeFileName {
    static let maxLength = 120

    /// `nil` when nothing usable is left (the caller picks its own fallback).
    static func clean(_ raw: String) -> String? {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "/", ":", "\\", "\0": scalars.append("_")
            default:
                // controls, and the bidi overrides that make "mp4.exe" read as something else
                let bidi = (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
                if scalar.properties.generalCategory == .control || bidi { continue }
                scalars.append(scalar)
            }
        }
        var name = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        // "." and ".." (and "..." style runs of dots with nothing else) are not names.
        guard name.contains(where: { $0 != "." }) else { return nil }
        if name.hasPrefix(".") { name = "_" + name.dropFirst() }   // no hidden files, nothing dot-dot-led
        guard !name.isEmpty else { return nil }
        return capped(name)
    }

    static func clean(_ raw: String, fallback: String) -> String {
        clean(raw) ?? fallback
    }

    /// Cuts the stem, never the extension.
    private static func capped(_ name: String) -> String {
        guard name.count > maxLength else { return name }
        let ext = (name as NSString).pathExtension
        let keepExt = ext.count <= 16 ? ext : ""
        let stem = keepExt.isEmpty ? name : (name as NSString).deletingPathExtension
        let room = max(1, maxLength - (keepExt.isEmpty ? 0 : keepExt.count + 1))
        let cut = String(stem.prefix(room))
        return keepExt.isEmpty ? cut : "\(cut).\(keepExt)"
    }

    /// `dir/name`, but only when the result really sits inside `dir`.
    static func contained(_ name: String, in dir: URL) -> URL? {
        let url = dir.appendingPathComponent(name)
        let base = dir.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base.hasSuffix("/") ? base : base + "/"), path != base else { return nil }
        return url
    }
}
