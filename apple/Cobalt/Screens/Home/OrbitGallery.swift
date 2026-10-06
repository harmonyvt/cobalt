import CobaltKit
import SwiftUI

// Photo and gallery planets (apple/CONTRACT-GALLERY.md 1.22, board `Orbit-Photos`). A photo planet is the still at its
// aspect with `jpg` in its corner: no player, no flipbook, no `video` label. A gallery planet wears its face with two card
// edges behind it and a stack-and-count badge instead of a type; in the front band, while the orbit moves, it turns
// through its items every 3 s (a crossfade; Reduce Motion holds item 1). The inner bands show the face. The face is
// CobaltKit's (`StoredMedia.face`): the newest webp (a slideshow webp counts), else the newest made video, else item 1.

/// What a planet's files are, decided from names and the disk (never inside a view body that runs every frame).
enum PlanetStills {
    /// A still photo file (not a video, not a made animated webp): by the record's file name.
    static func isStill(_ video: StoredVideo) -> Bool {
        guard video.kind == .original else { return false }
        let name = (video.fileURL?.lastPathComponent ?? video.name).lowercased()
        return ["jpg", "jpeg", "png", "heic", "heif", "webp", "avif"].contains((name as NSString).pathExtension)
    }

    /// The picture a still draws: its poster when the disk has it, else the photo's own file.
    static func picture(of video: StoredVideo) -> URL? {
        let fm = FileManager.default
        #if DEBUG
        // `-previewGalleryImages`: the preview's posters are flat gradients; the swapped-in photo is the picture
        if GalleryPreviewImages.directory != nil, isStill(video), let file = video.fileURL, fm.fileExists(atPath: file.path) { return file }
        #endif
        if let poster = video.posterURL, fm.fileExists(atPath: poster.path) { return poster }
        if isStill(video), let file = video.fileURL, fm.fileExists(atPath: file.path) { return file }
        return nil
    }

    /// The pictures a gallery planet turns through: its items that have one, in the post's order.
    static func turn(_ media: StoredMedia) -> [URL] {
        guard media.isGallery else { return [] }
        return media.items.compactMap { picture(of: $0) }
    }
}

/// What the orbit resolved off the main thread for its planets: which files are on the disk, which picture each still
/// draws, which pictures a gallery turns through.
struct OrbitFiles: Equatable {
    var onDisk: Set<String> = []
    var still: [String: URL] = [:]
    var turn: [String: [URL]] = [:]

    /// One pass over the shown planets; run it detached (it stats files).
    static func resolve(_ media: [StoredMedia]) -> OrbitFiles {
        var out = OrbitFiles()
        let fm = FileManager.default
        for m in media {
            let face = m.face
            if let url = face.fileURL, fm.fileExists(atPath: url.path) { out.onDisk.insert(m.id) }
            if PlanetStills.isStill(face), let picture = PlanetStills.picture(of: face) { out.still[m.id] = picture }
            let turning = PlanetStills.turn(m)
            if turning.count >= 2 { out.turn[m.id] = turning }
        }
        return out
    }
}

// MARK: - turning through the items

/// The front band's gallery planet: one picture at a time, the next every 3 s, a crossfade between. Starts at a place of
/// its own so planets side by side do not turn together.
struct GalleryTurner: View {
    let urls: [URL]
    let seed: String
    static let interval: Double = 3

    var body: some View {
        let offset = Double(seed.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 997 } % 3)
        TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: Self.interval)) { context in
            let n = max(1, urls.count)
            let tick = Int(((context.date.timeIntervalSinceReferenceDate / Self.interval) + offset).rounded(.down))
            let i = ((tick % n) + n) % n
            ZStack {
                StillImage(url: urls[i])
                    .id(i)
                    .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.7), value: i)
        }
    }
}

// MARK: - what VoiceOver hears

enum PlanetSpeak {
    /// "open instagram · Ddy0-gpGg5U, 10 photos, a video and a webp" / "open IMG_0412, photo".
    static func text(title: String, media: StoredMedia) -> String {
        switch media.kind {
        case .gallery:
            let photos = media.items.filter { PlanetStills.isStill($0) }.count
            var parts = [Copy.Gallery.count(photos: photos, videos: media.items.count - photos)]
            let made = media.made + media.webps
            var extras: [String] = []
            let videos = made.filter { $0.kind == .original && !PlanetStills.isStill($0) && $0.role != .crop }.count
            let webps = made.filter { $0.kind == .webp }.count
            let images = made.filter { PlanetStills.isStill($0) }.count
            if videos > 0 { extras.append(videos == 1 ? "a video" : "\(videos) videos") }
            if webps > 0 { extras.append(webps == 1 ? "a webp" : "\(webps) webps") }
            if images > 0 { extras.append(images == 1 ? "a gallery image" : "\(images) gallery images") }
            if !extras.isEmpty { parts.append(extras.count == 1 ? extras[0] : extras.dropLast().joined(separator: ", ") + " and " + extras.last!) }
            return "open \(title), \(parts.joined(separator: ", "))"
        case .photo:
            return "open \(title), photo"
        default:
            return Copy.Media.planetA11y(title: title, webps: media.webps.count, hasVideo: media.original != nil)
        }
    }

    /// The solo caption's second line: "10 photos" / "1200×1500" instead of a length.
    static func caption(media: StoredMedia) -> String? {
        switch media.kind {
        case .gallery:
            let photos = media.items.filter { PlanetStills.isStill($0) }.count
            return Copy.Gallery.count(photos: photos, videos: media.items.count - photos)
        case .photo:
            let face = media.face
            if let w = face.width, let h = face.height { return Format.size(w, h) }
            return "photo"
        default:
            return nil
        }
    }
}
