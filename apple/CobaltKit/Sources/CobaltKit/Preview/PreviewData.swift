import Foundation

/// The boards' real data (`Main.dc.html`, `Share.dc.html`, `Library.dc.html`), reused as preview
/// and test fixtures. Section 4.8 of the contract is the source of every number here.
enum PreviewData {
    static let base = URL(string: "https://api.capybaraharmony.com")!
    static let mediaBase = URL(string: "https://media.capybaraharmony.com/")!
    static let tunnelURL = URL(string: "https://api.capybaraharmony.com/tunnel?id=PrEvIeW")!

    struct Clip: Sendable, Equatable {
        var title: String
        var link: URL
        var duration: Double
        var width: Int
        var height: Int
        var bytes: Int64
        var webpWidth: Int
        var webpHeight: Int
        var webpSeconds: Double
        var webpBytes: Int64
        var webpURL: URL
    }

    /// `https://www.instagram.com/reel/Dd7P496wolG/`, 14.77 s, 720×1280, 4,331,778 bytes.
    static let long = Clip(
        title: "instagram_Dd7P496wolG",
        link: URL(string: "https://www.instagram.com/reel/Dd7P496wolG/")!,
        duration: 14.77, width: 720, height: 1280, bytes: 4_331_778,
        webpWidth: 480, webpHeight: 854, webpSeconds: 10.1, webpBytes: 4_500_000,
        webpURL: URL(string: "https://media.capybaraharmony.com/PrEvIeW001.webp")!)

    /// The share sheet's short post: 5.46 s, 480×568; webp 841 KB, 5.4 s.
    static let short = Clip(
        title: "twitter_2105435404002562056",
        link: URL(string: "https://x.com/i/status/2105435404002562056")!,
        duration: 5.46, width: 480, height: 568, bytes: 256_000,
        webpWidth: 480, webpHeight: 568, webpSeconds: 5.4, webpBytes: 841_000,
        webpURL: URL(string: "https://media.capybaraharmony.com/PrEvIeW002.webp")!)

    static func clip(for scenario: PreviewScenario) -> Clip { scenario == .shortClip ? short : long }

    // MARK: timings (timeScale 1 = the lab's compressed timings)

    static let fetchSeconds = 1.5
    static let coldFetchSeconds = 4.2
    static let wakingAfterSeconds = 1.5
    static let saveSeconds = 0.9
    static let frameSeconds = 0.15
    static let readHoldSeconds = 0.25
    static let uploadBytesPerSecond = 8_000_000.0
    static let renderSeconds = 23.5 / 5
    static let renderDecodeShare = 0.6
    static let renderLostShare = 0.55
    static let uploadReadSeconds = 0.3

    // MARK: upload sizes

    static let videoUploadBytes: Int64 = 18_200_000     // "1.2 MB / 18.2 MB"
    static let imageUploadBytes: Int64 = 1_200_000      // "a 1.2 MB PNG upload"
    static let tooBigBytes: Int64 = 142_000_000

    /// A picked file smaller than 100 KB (or missing) stands in for the scenario's canned size.
    static func uploadBytes(forFileSize size: Int64?, scenario: PreviewScenario) -> Int64 {
        if scenario == .tooBig { return tooBigBytes }
        if let size, size >= 100_000 { return size }
        return scenario == .image ? imageUploadBytes : videoUploadBytes
    }

    // MARK: capabilities

    static func capabilities(for scenario: PreviewScenario) -> Capabilities {
        var caps = Capabilities(
            kind: .fork, cobaltVersion: "11.7.1", studio: true, upload: true, library: true,
            saveProgress: true, renderProgress: true, finishesUnpolled: true, limits: .fork,
            mediaBaseURL: mediaBase, key: .valid, keyName: "iphone")
        caps.sourceWait = true
        caps.deletePost = true
        caps.titles = true
        caps.publicDefault = true                  // a fork since section 13: `public` on a save
        switch scenario {
        case .plainCobalt:
            caps.kind = .plainCobalt
            caps.studio = false; caps.upload = false; caps.library = false
            caps.saveProgress = false; caps.renderProgress = false; caps.finishesUnpolled = false
            caps.limits.maxUploadBytes = 0
            caps.mediaBaseURL = nil
            caps.sourceWait = false
            caps.deletePost = false
            caps.titles = false
            caps.publicDefault = false
            caps.key = .unknown; caps.keyName = nil
        case .legacyFork:
            caps.kind = .legacyFork
            caps.cobaltVersion = nil
            caps.upload = false; caps.library = false
            caps.saveProgress = false; caps.renderProgress = false; caps.finishesUnpolled = false
            caps.limits.maxUploadBytes = 0
            caps.mediaBaseURL = nil
            caps.sourceWait = false
            caps.deletePost = false
            caps.titles = false
            caps.publicDefault = false
            caps.key = .unknown; caps.keyName = nil
        case .renditionsLegacy:
            caps.deletePost = false
            caps.titles = false
        case .revokedKey:
            caps.key = .invalid; caps.keyName = nil
        default:
            break
        }
        if scenario.isGallery {
            caps.gallery = true
            caps.galleryMake = scenario != .galleryNoMake
            caps.visibility = true
            caps.line = true
        }
        return caps
    }

    // MARK: picker

    static func pickerItems() -> [PickerItem] {
        [
            PickerItem(id: 0, type: .video, url: URL(string: "https://api.capybaraharmony.com/tunnel?id=PrEvIeWpick0")!, thumb: nil),
            PickerItem(id: 1, type: .photo, url: URL(string: "https://api.capybaraharmony.com/tunnel?id=PrEvIeWpick1")!, thumb: nil),
        ]
    }

    // MARK: orbit (7 videos) and usage

    struct OrbitSeed { var key: String; var width: Int; var height: Int; var duration: Double? }

    static let orbitSeeds: [OrbitSeed] = [
        OrbitSeed(key: "Dd55fEyN1Yy", width: 720, height: 1280, duration: 37.43),
        OrbitSeed(key: "2105435404002562056", width: 480, height: 568, duration: 5.46),
        OrbitSeed(key: "2105432512428445875", width: 498, height: 280, duration: 1.9),
        OrbitSeed(key: "Dd5JFkMDt4N", width: 720, height: 720, duration: 10.77),
        OrbitSeed(key: "Dd7RFsmT45H", width: 640, height: 1136, duration: nil),
        OrbitSeed(key: "2105358343657427103", width: 1920, height: 1080, duration: 5.06),
        OrbitSeed(key: "clip", width: 1280, height: 720, duration: 28),
    ]

    static func link(forKey key: String) -> URL? {
        if key == "clip" { return nil }
        if key.allSatisfy(\.isNumber) { return URL(string: "https://x.com/i/status/\(key)") }
        return URL(string: "https://www.instagram.com/reel/\(key)/")
    }

    static func name(forKey key: String) -> String {
        if key == "clip" { return "clip" }
        return key.allSatisfy(\.isNumber) ? "twitter_\(key)" : "instagram_\(key)"
    }

    static func orbit(now: Date) -> [StoredVideo] {
        orbitSeeds.enumerated().map { i, seed in
            StoredVideo(
                id: "preview-orbit-\(i + 1)", kind: .original, fileURL: nil, posterURL: nil,
                name: name(forKey: seed.key), duration: seed.duration, width: seed.width, height: seed.height,
                bytes: Int64(Double(seed.width * seed.height) * (seed.duration ?? 6) * 0.07),
                sessionID: nil, link: link(forKey: seed.key), remoteURL: nil,
                createdAt: now.addingTimeInterval(-Double(i + 1) * 3_600))
        }
    }

    /// What the store is seeded with: the orbit, and (`.happy`, `.renditions`, `.renditionsLegacy`) the
    /// media with three webps and a webp-only media, newest first like the index.
    static func seeds(for scenario: PreviewScenario, now: Date) -> [StoredVideo] {
        switch scenario {
        case .happy, .renditions, .renditionsLegacy:
            return (orbit(now: now) + renditionSeeds(now: now)).sorted { $0.createdAt > $1.createdAt }
        case .offline:
            return PreviewOffline.seeds(now: now)
        default:
            // `.renameFails` is `.renditions` with a rename that fails once
            return scenario.failsRenames ? (orbit(now: now) + renditionSeeds(now: now)).sorted { $0.createdAt > $1.createdAt } : orbit(now: now)
        }
    }

    /// CONTRACT-MEDIA 4.4: the instagram `Dd7P496wolG` media (`long`) with its video and three webps,
    /// and a webp-only media (`Dd5JFkMDt4N`: the original is not kept on this device). The orbit's own
    /// seeds are the plain saves. Every webp has the link the library post lists for it, so the two
    /// sides merge into one `MediaItem`.
    static func renditionSeeds(now: Date) -> [StoredVideo] {
        let c = long
        let media = "preview-media-dd7p496wolg"
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func webp(
            _ n: Int, w: Int, h: Int, seconds: Double, bytes: Int64, minutes: Double, clip: WebpClip
        ) -> StoredVideo {
            let name = String(format: "PrEvIeW%03d", n)
            return StoredVideo(
                id: "preview-dd7p-webp-\(n)", kind: .webp, fileURL: nil, posterURL: nil, name: "\(c.title).webp",
                duration: seconds, width: w, height: h, bytes: bytes, sessionID: nil, link: c.link,
                remoteURL: mediaBase.appendingPathComponent("\(name).webp"), createdAt: ago(minutes),
                mediaID: media, clip: clip)
        }
        let video = StoredVideo(
            id: "preview-dd7p-video", kind: .original, fileURL: nil, posterURL: nil, name: c.title,
            duration: c.duration, width: c.width, height: c.height, bytes: c.bytes,
            sessionID: "PrEvIeWsession0000000a2",                       // the library post's session, so the two merge
            link: c.link, remoteURL: nil, createdAt: ago(240), mediaID: media)
        let square = CropRect(x: 0, y: 0.21875, w: 1, h: 0.5625)          // 1:1 of 720×1280
        let fourFive = CropRect(x: 0, y: 0.1484375, w: 1, h: 0.703125)    // 4:5 of 720×1280
        let webps = [
            webp(1, w: 480, h: 854, seconds: 10.1, bytes: 4_500_000, minutes: 150,
                 clip: WebpClip(start: 0, length: 10.1, crop: nil, quality: .med, width: 480)),
            webp(5, w: 480, h: 480, seconds: 10.0, bytes: 2_371_210, minutes: 90,
                 clip: WebpClip(start: 2.0, length: 10.0, crop: square, quality: .med, width: 480)),
            webp(6, w: 480, h: 600, seconds: 5.4, bytes: 1_600_000, minutes: 30,
                 clip: WebpClip(start: 9.0, length: 5.4, crop: fourFive, quality: .med, width: 480)),
        ]
        let only = StoredVideo(
            id: "preview-dd5j-webp", kind: .webp, fileURL: nil, posterURL: nil, name: "instagram_Dd5JFkMDt4N.webp",
            duration: 10.1, width: 480, height: 480, bytes: 1_800_000, sessionID: nil,
            link: link(forKey: "Dd5JFkMDt4N"), remoteURL: mediaBase.appendingPathComponent("PrEvIeW003.webp"),
            createdAt: ago(300), mediaID: "preview-media-dd5j-webp")
        return [video] + webps + [only]
    }

    /// "13 videos · 54 MB"
    static let usage = StorageUsage(count: 13, bytes: 54_000_000)

    // MARK: library (the six posts of Library.dc.html; 15 posts · 24 files in the header)

    static func libraryPage(now: Date) -> LibraryPage {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let yesterday = cal.date(byAdding: .day, value: -1, to: today) ?? today
        func at(_ day: Date, _ h: Int, _ m: Int) -> Date { day.addingTimeInterval(Double(h * 3_600 + m * 60)) }

        func file(
            _ id: String, _ kind: LibraryFile.Kind, _ source: LibraryFile.Source, name: String,
            url: String?, type: String, bytes: Int64, w: Int?, h: Int?, d: Double?, at when: Date,
            media: String?, deletable: Bool, poster: String? = nil
        ) -> LibraryFile {
            LibraryFile(
                id: id, kind: kind, source: source, name: name, url: url.flatMap(URL.init(string:)),
                contentType: type, bytes: bytes, width: w, height: h, duration: d, createdAt: when,
                mediaName: media, deletable: deletable, posterURL: poster.flatMap(URL.init(string:)))
        }

        func session(_ id: String, daysLeft: Double, now: Date) -> LibrarySession {
            LibrarySession(
                id: id, status: .ready, expiresAt: now.addingTimeInterval(daysLeft * 86_400),
                sourceURL: URL(string: "https://api.capybaraharmony.com/studio/\(id)/source")!)
        }

        func post(
            _ key: String, service: String, dur: Double, w: Int, h: Int, when: Date,
            session: LibrarySession?, files: [LibraryFile], custom: String? = nil, poster: String? = nil
        ) -> LibraryPost {
            LibraryPost(
                id: key, service: service, link: link(forKey: key), title: name(forKey: key),
                duration: dur, width: w, height: h, createdAt: when, session: session, files: files,
                customTitle: custom, posterURL: poster.flatMap(URL.init(string:)))
        }

        let p1t = at(today, 12, 46), p2t = at(yesterday, 13, 59), p3t = at(yesterday, 13, 43)
        let p4t = at(yesterday, 13, 25), p5t = at(yesterday, 13, 20), p6t = at(yesterday, 9, 31)

        let posts: [LibraryPost] = [
            post("Dd55fEyN1Yy", service: "instagram", dur: 37.43, w: 720, h: 1280, when: p1t,
                 session: session("PrEvIeWsession0000000a1", daysLeft: 7, now: now), files: [
                    file("PrEvIeWitem000001", .public, .host, name: "instagram_Dd55fEyN1Yy.mp4",
                         url: "https://media.capybaraharmony.com/PrEvIeW011.mp4", type: "video/mp4",
                         bytes: 8_300_000, w: 720, h: 1280, d: 37.43, at: p1t, media: "PrEvIeW011.mp4", deletable: false,
                         poster: "https://media.capybaraharmony.com/PrEvIeWp11.jpg"),
                    file("PrEvIeWitem000002", .private, .saved, name: "instagram_Dd55fEyN1Yy",
                         url: nil, type: "video/mp4", bytes: 8_300_000, w: 720, h: 1280, d: 37.43,
                         at: p1t.addingTimeInterval(-10), media: nil, deletable: false,
                         poster: "https://media.capybaraharmony.com/PrEvIeWp11.jpg")],
                 poster: "https://media.capybaraharmony.com/PrEvIeWp11.jpg"),
            post("Dd7P496wolG", service: "instagram", dur: 14.77, w: 720, h: 1280, when: p2t,
                 session: session("PrEvIeWsession0000000a2", daysLeft: 6, now: now), files: [
                    file("PrEvIeWitem000003", .public, .studio, name: "instagram_Dd7P496wolG.webp",
                         url: "https://media.capybaraharmony.com/PrEvIeW001.webp", type: "image/webp",
                         bytes: 4_500_000, w: 480, h: 854, d: 10.1, at: p2t, media: "PrEvIeW001.webp", deletable: true),
                    file("PrEvIeWitem000004", .private, .saved, name: "instagram_Dd7P496wolG",
                         url: nil, type: "video/mp4", bytes: 4_331_778, w: 720, h: 1280, d: 14.77,
                         at: p2t.addingTimeInterval(-10), media: nil, deletable: false,
                         poster: "https://media.capybaraharmony.com/PrEvIeWp22.jpg"),
                    // the two renders of `renditionSeeds` (CONTRACT-MEDIA 4.4): 1:1 and 4:5 crops
                    file("PrEvIeWitem000012", .public, .studio, name: "instagram_Dd7P496wolG.webp",
                         url: "https://media.capybaraharmony.com/PrEvIeW005.webp", type: "image/webp",
                         bytes: 2_371_210, w: 480, h: 480, d: 10.0, at: p2t.addingTimeInterval(14 * 60),
                         media: "PrEvIeW005.webp", deletable: true),
                    file("PrEvIeWitem000013", .public, .studio, name: "instagram_Dd7P496wolG.webp",
                         url: "https://media.capybaraharmony.com/PrEvIeW006.webp", type: "image/webp",
                         bytes: 1_600_000, w: 480, h: 600, d: 5.4, at: p2t.addingTimeInterval(32 * 60),
                         media: "PrEvIeW006.webp", deletable: true)],
                 poster: "https://media.capybaraharmony.com/PrEvIeWp22.jpg"),
            post("2105435404002562056", service: "x", dur: 5.46, w: 480, h: 568, when: p3t,
                 session: session("PrEvIeWsession0000000a3", daysLeft: 6, now: now), files: [
                    file("PrEvIeWitem000005", .public, .studio, name: "twitter_2105435404002562056.webp",
                         url: "https://media.capybaraharmony.com/PrEvIeW002.webp", type: "image/webp",
                         bytes: 841_000, w: 480, h: 568, d: 5.4, at: p3t, media: "PrEvIeW002.webp", deletable: true),
                    file("PrEvIeWitem000006", .private, .saved, name: "twitter_2105435404002562056",
                         url: nil, type: "video/mp4", bytes: 256_000, w: 480, h: 568, d: 5.46,
                         at: p3t.addingTimeInterval(-10), media: nil, deletable: false)],
                 custom: "kitchen timer loop"),
            post("2105432512428445875", service: "x", dur: 1.9, w: 498, h: 280, when: p4t,
                 session: nil, files: [
                    file("PrEvIeWitem000007", .private, .saved, name: "twitter_2105432512428445875",
                         url: nil, type: "video/mp4", bytes: 1_000_000, w: 498, h: 280, d: 1.9,
                         at: p4t, media: nil, deletable: false)]),
            post("Dd5JFkMDt4N", service: "instagram", dur: 10.77, w: 720, h: 720, when: p5t,
                 session: nil, files: [
                    file("PrEvIeWitem000008", .public, .studio, name: "instagram_Dd5JFkMDt4N.webp",
                         url: "https://media.capybaraharmony.com/PrEvIeW003.webp", type: "image/webp",
                         bytes: 1_800_000, w: 480, h: 480, d: 10.1, at: p5t, media: "PrEvIeW003.webp", deletable: true),
                    file("PrEvIeWitem000009", .private, .saved, name: "instagram_Dd5JFkMDt4N",
                         url: nil, type: "video/mp4", bytes: 1_300_000, w: 720, h: 720, d: 10.77,
                         at: p5t.addingTimeInterval(-10), media: nil, deletable: false)]),
            post("2105358343657427103", service: "x", dur: 5.06, w: 1920, h: 1080, when: p6t,
                 session: nil, files: [
                    file("PrEvIeWitem000010", .public, .studio, name: "twitter_2105358343657427103.webp",
                         url: "https://media.capybaraharmony.com/PrEvIeW004.webp", type: "image/webp",
                         bytes: 933_000, w: 480, h: 270, d: 5.0, at: p6t, media: "PrEvIeW004.webp", deletable: true),
                    file("PrEvIeWitem000011", .private, .saved, name: "twitter_2105358343657427103",
                         url: nil, type: "video/mp4", bytes: 3_900_000, w: 1920, h: 1080, d: 5.06,
                         at: p6t.addingTimeInterval(-10), media: nil, deletable: false)]),
        ]
        return LibraryPage(
            posts: posts, postCount: 15, fileCount: 24,
            publicBytes: 17_000_000, privateBytes: 36_000_000, next: nil)
    }

    /// The owner's uploads (service "upload", no link; public by default, so each has a hosted copy and a
    /// poster; `crop-gestures.mov` carries a custom title). NOT part of `libraryPage`: three tests pin that
    /// page at six posts. Tests (and a preview that wants them) append these to `library.posts`.
    static func uploadPosts(now: Date) -> [LibraryPost] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let yesterday = cal.date(byAdding: .day, value: -1, to: today) ?? today
        func at(_ day: Date, _ h: Int, _ m: Int) -> Date { day.addingTimeInterval(Double(h * 3_600 + m * 60)) }
        func file(
            _ id: String, _ kind: LibraryFile.Kind, _ source: LibraryFile.Source, name: String,
            url: String?, type: String, bytes: Int64, w: Int, h: Int, d: Double, at when: Date,
            media: String?, poster: String
        ) -> LibraryFile {
            LibraryFile(
                id: id, kind: kind, source: source, name: name, url: url.flatMap(URL.init(string:)),
                contentType: type, bytes: bytes, width: w, height: h, duration: d, createdAt: when,
                mediaName: media, deletable: false, posterURL: URL(string: poster))
        }
        func upload(
            _ key: String, file name: String, type: String, bytes: Int64, w: Int, h: Int, d: Double, when: Date,
            hosted: String, poster: String, custom: String? = nil
        ) -> LibraryPost {
            LibraryPost(
                id: key, service: "upload", link: nil, title: name, duration: d, width: w, height: h,
                createdAt: when, session: nil, files: [
                    file("\(key)-pub", .public, .host, name: name,
                         url: "https://media.capybaraharmony.com/\(hosted).mp4", type: "video/mp4", bytes: bytes,
                         w: w, h: h, d: d, at: when, media: "\(hosted).mp4", poster: poster),
                    file("\(key)-src", .private, .upload, name: name, url: nil, type: type, bytes: bytes,
                         w: w, h: h, d: d, at: when.addingTimeInterval(-10), media: nil, poster: poster)],
                customTitle: custom, posterURL: URL(string: poster))
        }
        return [
            upload("PrEvIeWupost0001", file: "crop-gestures.mov", type: "video/quicktime", bytes: 8_979_061,
                   w: 1206, h: 2622, d: 15.6, when: at(today, 10, 12), hosted: "PrEvIeW031",
                   poster: "https://media.capybaraharmony.com/PrEvIeWp31.jpg", custom: "crop editor, pinch and drag"),
            upload("PrEvIeWupost0002", file: "from photos · 4 oct.mp4", type: "video/mp4", bytes: 4_964_526,
                   w: 1080, h: 1920, d: 6.0, when: at(yesterday, 22, 10), hosted: "PrEvIeW032",
                   poster: "https://media.capybaraharmony.com/PrEvIeWp32.jpg"),
        ]
    }

}

extension PreviewScenario {
    /// `.renameFails` (CONTRACT-LIBRARY2 4.2): `.renditions` data where the first `setTitle` for item
    /// `PrEvIeWitem000008` fails. Matched by raw value so the preview layer needs no `AppModel.swift` edit.
    var failsRenames: Bool { rawValue == "renameFails" }
}
