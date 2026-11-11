import AVKit
import CobaltKit
import SwiftUI
import UniformTypeIdentifiers

/// The hero of one tab (CONTRACT-MEDIA 1.10): the rendition at its own aspect (a cropped webp is square or
/// 4:5), at most `maxHeight` tall. The video plays muted and looping; a tap brings the sound. A webp animates.
/// A file this device does not hold is never an empty box: a webp plays from its public link, a hosted video
/// plays from its link, anything else shows the poster the device kept, else the server's poster (so a private
/// video that is not on this device still has its picture), else the first frame of a public file;
/// "not on this iphone" is only a small cloud badge in the corner. The file type sits on the other corner like
/// the planet's.
struct RenditionHero: View {
    let rendition: Rendition
    /// The media: a video with no picture of its own borrows the first frame of its newest public webp.
    var item: MediaItem?
    var maxHeight: CGFloat = 360

    private var remote: HeroRemote {
        let remote = HeroRemote(rendition, in: item)
        #if DEBUG
        // `-previewRemoteVideo <file name>` (with `-previewMediaDir <folder>` holding it): a video the server hosts no file of
        // plays that file, so the hosted-video hero (bar, sound, full screen) can be driven without a server
        if let name = UserDefaults.standard.string(forKey: "previewRemoteVideo"), !rendition.isWebp, rendition.local?.fileURL == nil,
           remote.playableVideo == nil, remote.animatedWebp == nil, let url = URL(string: "https://media.capybaraharmony.com/\(name)") {
            var forced = remote
            forced.playableVideo = url
            return forced
        }
        #endif
        return remote
    }

    var body: some View {
        Group {
            if case .galleryImage = rendition.kind {
                // a long strip scrolls inside its frame (CONTRACT-GALLERY 1.19)
                GalleryImageHero(rendition: rendition, maxHeight: maxHeight)
            } else if rendition.isStillPicture {
                // a photo, a crop, an older single photo: the viewer with zoom, not the player
                PhotoHero(rendition: rendition, item: item, maxHeight: maxHeight)
            } else if let local = rendition.local {
                DetailPlayer(video: local, maxHeight: maxHeight, aspect: rendition.knownAspect, remote: remote)
            } else {
                // the server's poster comes through `remote.still`, so a private video not on this device has its picture
                RemoteHero(
                    poster: nil, remote: remote, aspect: rendition.knownAspect, maxHeight: maxHeight,
                    label: rendition.typeLabel)
                    .accessibilityLabel(Copy.Media.heroA11y(rendition.local?.name ?? rendition.typeLabel, evicted: true))
            }
        }
        .id(rendition.id)
        .transition(.opacity)
        .accessibilityElement(children: .contain)
    }
}

/// What a rendition the device does not hold can still show: the server's public files.
struct HeroRemote: Equatable {
    /// A webp's public file: plays animated.
    var animatedWebp: URL?
    /// A hosted mp4: plays muted and looping.
    var playableVideo: URL?
    /// The picture under (or instead of) the playing file: the server's poster for a video, else the first frame of
    /// a public file, for the poster while it loads (and for good when it cannot play).
    var still: RemotePoster?
    /// A webp the owner made private, with no copy on this device: nothing of it can show, so the frame holds a
    /// lock instead of looking broken.
    var lockedWebp = false

    init() {}

    init(_ r: Rendition, in item: MediaItem? = nil) {
        // the server's poster for a video (the rendition's own, else the post's): a still the server made, cheaper
        // and kinder than a frame pulled from the mp4, and the only picture a private-only video has
        let serverPoster = (r.posterURL ?? (r.isWebp ? nil : item?.post?.posterURL)).map { RemotePoster(url: $0, isVideo: false) }
        if r.isAnimatedMade || r.isGifItem {
            // a slideshow webp and a gif item are animated pictures, played like a webp from their public link
            if let url = r.publicURL ?? r.file?.url {
                animatedWebp = url
                still = serverPoster ?? RemotePoster(url: url, isVideo: false)
            } else {
                still = serverPoster
                lockedWebp = r.visibility == .private && serverPoster == nil
            }
            return
        }
        if r.isMade || r.isItem {
            // a made mp4 and a video item: the public file plays muted over the server's poster (a private one streams)
            if let url = r.publicURL ?? r.file?.url ?? Self.keyedStream(r.file) {
                playableVideo = url
                still = serverPoster ?? RemotePoster(url: url, isVideo: true)
            } else {
                still = serverPoster
            }
            return
        }
        if r.isWebp {
            if let url = r.publicURL ?? r.file?.url {
                animatedWebp = url
                still = RemotePoster(url: url, isVideo: false)
            } else if r.visibility == .private {
                lockedWebp = true
            }
        } else if let url = r.hosted?.url ?? r.publicURL, r.hosted?.contentType?.lowercased().hasPrefix("image/") != true {
            playableVideo = url
            still = serverPoster ?? RemotePoster(url: url, isVideo: true)
        } else if let url = Self.keyedStream(r.file) {
            // the private copy, not kept on this device: streamed from the server with the key
            playableVideo = url
            still = serverPoster
        } else {
            still = serverPoster
        }
        if still == nil { still = serverPoster }
        // a video that is only a private copy (or whose hosted file will not play) has no picture of its own: the
        // media's newest public webp stands in, as it does on the library's card
        if still == nil, !r.isWebp, let url = item?.webps.last(where: { $0.publicURL != nil })?.publicURL {
            still = RemotePoster(url: url, isVideo: false)
        }
    }

    /// The keyed stream of a private library video (KeyedStream): nil for an image, a webp, or no server file.
    static func keyedStream(_ file: LibraryFile?) -> URL? {
        guard let file, file.source != .webp, file.source != .emote else { return nil }
        let type = file.contentType?.lowercased() ?? ""
        let ext = (file.name as NSString).pathExtension.lowercased()
        let isVideo = type.hasPrefix("video/")
            || (type.isEmpty && UTType(filenameExtension: ext)?.conforms(to: .movie) == true)
        guard isVideo else { return nil }
        return KeyedStream.url(itemID: file.id, ext: ext.isEmpty ? "mp4" : ext)
    }
}

/// Where a public file is read from. `-previewMediaDir <folder>` (DEBUG) reads it from a local folder by file name,
/// as the library's cards do, so simulator evidence shows real pictures without the server.
enum HeroSource {
    static func resolve(_ url: URL) -> URL {
        #if DEBUG
        if let dir = UserDefaults.standard.string(forKey: "previewMediaDir"), !dir.isEmpty {
            return URL(fileURLWithPath: dir).appendingPathComponent(url.lastPathComponent)
        }
        #endif
        return url
    }

    static func animated(_ url: URL) -> AnimatedImageView.Source {
        let resolved = resolve(url)
        return resolved.isFileURL ? .file(resolved) : .remote(resolved)
    }
}

/// The corner capsule with the file's type (`mp4`, `webp`, `png`): the planet's own look, drawn here so the
/// detail does not depend on the orbit's badge (dark glass tint, light ink; legible over a white frame).
struct DetailTypeBadge: View {
    let label: String

    var body: some View {
        Text(label)
            .font(Font.cobalt(11, .medium, relativeTo: .caption))
            .dynamicTypeSize(...DynamicTypeSize.large)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(CobaltColor.badgeInk)
            .padding(.horizontal, 6.5)
            .padding(.vertical, 3)
            .background(CobaltColor.badgeBack, in: Capsule())
            .overlay(Capsule().strokeBorder(
                LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.1)], startPoint: .top, endPoint: .bottom),
                lineWidth: 0.75))
            .accessibilityHidden(true)
    }
}

extension View {
    /// Fits `aspect` inside `maxHeight`, centred, with the corner capsule, and (when there is something to open) the
    /// full-screen button in the bottom-right corner.
    func heroFrame(aspect: CGFloat, maxHeight: CGFloat, label: String, expand: (() -> Void)? = nil) -> some View {
        self
            .aspectRatio(aspect, contentMode: .fit)
            .overlay(alignment: .topTrailing) { DetailTypeBadge(label: label).padding(PlanetBadgeInset.value * 2) }
            .overlay(alignment: .bottomTrailing) {
                if let expand { HeroFullScreenButton(action: expand).padding(2) }
            }
            .clipShape(RoundedRectangle(cornerRadius: Metrics.thumbRadius, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: maxHeight)
    }
}

/// The corner inset the planet's badge uses (4 pt), kept here so the two stay matched without importing the orbit.
private enum PlanetBadgeInset { static let value: CGFloat = 4 }

/// The picture of a rendition the device does not hold, when it is not a video that plays (`HeroVideoBox` has those):
/// the poster the device kept, else the server's poster, else the first frame of a public file, under the animated webp
/// once it runs; a small cloud badge says it is not here.
struct RemoteHeroPicture: View {
    var poster: URL?
    let remote: HeroRemote
    /// The animated webp has drawn a frame. The still underneath leaves then: an emote's frames are
    /// transparent, and a first frame left under them shows as a second, frozen copy.
    @State private var webpUp = false

    var body: some View {
        ZStack {
            Rectangle().fill(FrameGradient.fill(1))
            if !webpUp {
                if let poster {
                    StillImage(url: poster)
                } else if let still = remote.still {
                    RemoteStill(poster: still, maxPixel: 960)
                }
            }
            if let webp = remote.animatedWebp {
                AnimatedImageView(source: HeroSource.animated(webp), started: $webpUp)
            } else if remote.lockedWebp, poster == nil, remote.still == nil {
                Image(systemName: Symbol.Media.isPrivate)
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(CobaltColor.badgeInk.opacity(0.7))
                    .accessibilityLabel(Copy.Media.privateWebpA11y)
            }
        }
        .overlay(alignment: .bottomLeading) {
            Image(systemName: Symbol.offlineMissing)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CobaltColor.badgeInk)
                .frame(width: 24, height: 24)
                .background(CobaltColor.badgeBack, in: Circle())
                .padding(8)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// The hero of a rendition with no record on this device: its hosted or streamed video in the video hero, else its
/// webp or poster.
private struct RemoteHero: View {
    var poster: URL?
    let remote: HeroRemote
    /// The record's shape (nil: not known).
    let aspect: CGFloat?
    let maxHeight: CGFloat
    let label: String
    @State private var fullScreen: HeroFullScreen?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let video = remote.playableVideo, remote.animatedWebp == nil {
            HeroVideoBox(
                url: HeroSource.resolve(video), name: label, label: label, recordedAspect: aspect, maxHeight: maxHeight,
                poster: poster, remoteStill: remote.still, streamed: true)
        } else {
            RemoteHeroPicture(poster: poster, remote: remote)
                .heroFrame(aspect: aspect ?? 9.0 / 16.0, maxHeight: maxHeight, label: label, expand: webpRequest == nil ? nil : { open() })
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { open() }
                .heroFullScreen(item: $fullScreen) { _ in }
        }
    }

    private var webpRequest: HeroFullScreen? {
        remote.animatedWebp.map { .webp(source: HeroSource.animated($0), aspect: aspect ?? 9.0 / 16.0, name: label) }
    }

    private func open() {
        guard let request = webpRequest else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = reduceMotion
        withTransaction(transaction) { fullScreen = request }
    }
}

// MARK: - the stored rendition

/// The stored file of one rendition: a video in the video hero (the orbit's own player when it lent it, so the zoom
/// carries the picture), an animated webp, or a still. A file this device no longer holds plays its hosted or streamed
/// copy, else shows its poster or public webp.
struct DetailPlayer: View {
    let video: StoredVideo
    var maxHeight: CGFloat = 420
    /// The picture's shape when the record does not carry its size (nil: not known).
    var aspect: CGFloat?
    /// What the server's public files can show while this device has no file.
    var remote = HeroRemote()

    @State private var onDisk = false
    /// The disk was looked at (until then a record that names a file shows its poster, not the remote picture).
    @State private var diskChecked = false
    /// The webp or gif viewer, while it is up (a video's full screen belongs to its hero).
    @State private var fullScreen: HeroFullScreen?
    /// The orbit's own player for this planet, when it lent it.
    @Environment(\.lentPlayer) private var lent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The record's own shape, else the rendition's.
    private var recorded: CGFloat? {
        if let w = video.width, let h = video.height, w > 0, h > 0 { return CGFloat(w) / CGFloat(h) }
        return aspect
    }

    /// A picture's frame (a webp, a gif, a still, a poster).
    private var pictureShape: CGFloat { recorded ?? 9.0 / 16.0 }

    private var isStill: Bool {
        guard let ext = video.fileURL?.pathExtension.lowercased(), !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image) && ext != "webp" && ext != "gif"
    }

    /// A gif is an animated picture: it plays like a webp (a plain `AVPlayer` cannot open it).
    private var isGif: Bool { video.fileURL?.pathExtension.lowercased() == "gif" }

    /// The record is an animated picture file: a webp or a gif.
    private var isAnimatedPicture: Bool { video.kind == .webp || isGif }

    private var label: String {
        var ext = (video.fileURL ?? video.remoteURL)?.pathExtension.lowercased() ?? ""
        if ext == "jpeg" { ext = "jpg" }
        return ext.isEmpty || ext.count > 5 ? (video.kind == .webp ? "webp" : "mp4") : ext
    }

    /// The webp viewer for the stored file, else the public one.
    private var webpRequest: HeroFullScreen? {
        if onDisk, let url = video.fileURL, isAnimatedPicture { return .webp(source: .file(url), aspect: pictureShape, name: video.name) }
        if !onDisk, diskChecked || video.fileURL == nil, let webp = remote.animatedWebp {
            return .webp(source: HeroSource.animated(webp), aspect: pictureShape, name: video.name)
        }
        return nil
    }

    private var expander: (() -> Void)? {
        guard webpRequest != nil else { return nil }
        return { openWebp() }
    }

    private func openWebp() {
        guard let request = webpRequest else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = reduceMotion
        withTransaction(transaction) { fullScreen = request }
    }

    var body: some View {
        Group {
            if onDisk, let url = video.fileURL {
                if isAnimatedPicture {
                    picture { AnimatedImageView(source: .file(url)) }
                } else if isStill {
                    picture { StillImage(url: url) }
                } else {
                    HeroVideoBox(
                        url: url, name: video.name, label: label, recordedAspect: recorded, maxHeight: maxHeight,
                        poster: video.posterURL, lent: lent?.id == video.id ? lent : nil)
                }
            } else if video.fileURL != nil, !diskChecked {
                // a moment, while the disk is looked at: the poster in a frame the clip will most likely keep
                let shape = video.fileURL.flatMap { HeroVideo.knownShape(of: $0) } ?? recorded ?? (video.kind == .webp ? 9.0 / 16.0 : 16.0 / 9.0)
                ZStack {
                    Rectangle().fill(FrameGradient.fill(1))
                    if let poster = video.posterURL { StillImage(url: poster) }
                }
                .heroFrame(aspect: shape, maxHeight: maxHeight, label: label)
            } else if let hosted = remote.playableVideo, remote.animatedWebp == nil {
                HeroVideoBox(
                    url: HeroSource.resolve(hosted), name: video.name, label: label, recordedAspect: recorded,
                    maxHeight: maxHeight, poster: video.posterURL, remoteStill: remote.still, streamed: true)
            } else {
                picture { RemoteHeroPicture(poster: video.posterURL, remote: remote) }
            }
        }
        .task(id: video.fileURL) {
            guard let url = video.fileURL else { onDisk = false; diskChecked = true; return }
            onDisk = FileManager.default.fileExists(atPath: url.path)
            diskChecked = true
        }
        .heroFullScreen(item: $fullScreen) { _ in }
        // a group, so the bar's own buttons stay reachable under the hero's name
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Media.heroA11y(video.name, evicted: !onDisk))
    }

    /// A webp, a gif, a still or a poster in the hero's frame, with the full-screen corner button for an animated one.
    private func picture<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .heroFrame(aspect: pictureShape, maxHeight: maxHeight, label: label, expand: expander)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { openWebp() }
    }
}
