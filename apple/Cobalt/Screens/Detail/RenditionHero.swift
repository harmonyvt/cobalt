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

    private var remote: HeroRemote { HeroRemote(rendition, in: item) }

    var body: some View {
        Group {
            if let local = rendition.local {
                DetailPlayer(video: local, maxHeight: maxHeight, aspect: rendition.aspect, remote: remote)
            } else {
                // the server's poster comes through `remote.still`, so a private video not on this device has its picture
                RemoteHero(
                    poster: nil, remote: remote, aspect: rendition.aspect, maxHeight: maxHeight,
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

private extension View {
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

/// The picture of a rendition the device does not hold, without a frame around it: the poster the device kept,
/// else the server's poster, else the first frame of a public file, under the animated webp or the hosted video once they run; a small
/// cloud badge says it is not here.
struct RemoteHeroPicture: View {
    var poster: URL?
    let remote: HeroRemote

    var body: some View {
        ZStack {
            Rectangle().fill(FrameGradient.fill(1))
            if let poster {
                StillImage(url: poster)
            } else if let still = remote.still {
                RemoteStill(poster: still, maxPixel: 960)
            }
            if let webp = remote.animatedWebp {
                AnimatedImageView(source: HeroSource.animated(webp))
            } else if let video = remote.playableVideo {
                RemoteVideo(url: HeroSource.resolve(video))
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

private struct RemoteHero: View {
    var poster: URL?
    let remote: HeroRemote
    let aspect: CGFloat
    let maxHeight: CGFloat
    let label: String
    @State private var fullScreen: HeroFullScreen?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var request: HeroFullScreen? {
        if let webp = remote.animatedWebp { return .webp(source: HeroSource.animated(webp), aspect: aspect, name: label) }
        if let video = remote.playableVideo { return .video(url: HeroSource.resolve(video), name: label, start: .zero) }
        return nil
    }

    private func open() {
        guard let request else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = reduceMotion
        withTransaction(transaction) { fullScreen = request }
    }

    private var expander: (() -> Void)? {
        guard request != nil else { return nil }
        return { open() }
    }

    var body: some View {
        RemoteHeroPicture(poster: poster, remote: remote)
            .heroFrame(aspect: aspect, maxHeight: maxHeight, label: label, expand: expander)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { open() }
            .heroFullScreen(item: $fullScreen) { _ in }
    }
}

/// A hosted mp4 played from its link, muted and looping, over the poster. Invisible until frames run.
private struct RemoteVideo: View {
    let url: URL
    @State private var player: AVPlayer?
    @State private var loop: NSObjectProtocol?
    @State private var statusWatch: NSKeyValueObservation?
    @State private var playing = false

    var body: some View {
        Group {
            if let player {
                PlayerSurface(player: player, gravity: .resizeAspect).allowsHitTesting(false).opacity(playing ? 1 : 0)
            } else {
                Color.clear
            }
        }
        .animation(.easeOut(duration: 0.2), value: playing)
        .task(id: url) {
            AudioPolicy.ambient()
            let item = await HeroItems.pictureOnly(url)
            guard !Task.isCancelled else { return }
            let next = AVPlayer(playerItem: item)
            next.isMuted = true
            next.actionAtItemEnd = .none
            loop = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { [weak next] _ in
                next?.seek(to: .zero)
                next?.play()
            }
            let flag = $playing
            statusWatch = next.observe(\.timeControlStatus, options: [.initial, .new]) { observed, _ in
                let isPlaying = observed.timeControlStatus == .playing
                Task { @MainActor in flag.wrappedValue = isPlaying }
            }
            player = next
            next.play()
        }
        .onDisappear {
            player?.pause()
            statusWatch?.invalidate()
            if let loop { NotificationCenter.default.removeObserver(loop) }
            player = nil
            loop = nil
            statusWatch = nil
            playing = false
        }
    }
}

/// Items for a picture nobody hears.
@MainActor
enum HeroItems {
    /// The clip's picture without its sound: an item over a composition holding only the video track, so no audio
    /// pipeline starts for a muted hero (the sound comes with the tap). A clip with no audio, or one that cannot be
    /// split, plays as it is.
    static func pictureOnly(_ url: URL) async -> AVPlayerItem {
        let asset = AVURLAsset(url: url)
        do {
            guard try await !asset.loadTracks(withMediaType: .audio).isEmpty,
                  let source = try await asset.loadTracks(withMediaType: .video).first else { return AVPlayerItem(asset: asset) }
            let (duration, transform) = try await (asset.load(.duration), source.load(.preferredTransform))
            let composition = AVMutableComposition()
            guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                return AVPlayerItem(asset: asset)
            }
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
            track.preferredTransform = transform
            return AVPlayerItem(asset: composition)
        } catch {
            return AVPlayerItem(asset: asset)
        }
    }
}

// MARK: - the player

/// The stored file of one rendition: a video muted and looping (the orbit's own player when it lent it, so the
/// zoom carries the picture), an animated webp, or a still. An evicted file shows its poster, dimmed, with the
/// file-type badge on the corner like the planet's.
struct DetailPlayer: View {
    let video: StoredVideo
    var maxHeight: CGFloat = 420
    /// The picture's aspect when the record does not carry its size.
    var aspect: CGFloat?
    /// What the server's public files can show while this device has no file.
    var remote = HeroRemote()

    @State private var player: AVPlayer?
    /// Restarts the clip at its end (a plain `AVPlayer` with the end-of-item notification, not an
    /// `AVPlayerLooper`: the looper stayed in "evaluating buffering rate" for good on the dev machine's OS).
    @State private var loop: NSObjectProtocol?
    @State private var onDisk = false
    /// The disk was looked at (until then a record that names a file shows its poster, not the remote picture).
    @State private var diskChecked = false
    /// Follows the player's `timeControlStatus` (`playing` below). A plain KVO observer: the publisher's async
    /// `values` and `onReceive` (which keeps the first publisher it was given, a nil player's) both missed the
    /// change to `.playing`, so the poster stayed over a playing video.
    @State private var statusWatch: NSKeyValueObservation?
    /// The clip's first frame, for a record with no poster.
    @State private var firstFrame: CGImage?
    /// The player's item carries the clip's audio (after the first unmute).
    @State private var withSound = false
    /// The video is on screen (a player is playing): until then the poster stands in, never a black frame.
    @State private var playing = false
    /// Frames have run at least once: from then on the poster stays away, so a paused clip shows the frame it stopped on.
    @State private var videoUp = false
    /// The media controls (play, scrubber, sound, full screen) over a video that plays here.
    @State private var transport = HeroTransport()
    /// Muted until the owner taps the picture (the orbit's players are always muted).
    @State private var muted = true
    /// The orbit's own player for this planet, when it lent it.
    @Environment(\.lentPlayer) private var lent
    /// The full-screen player or viewer, while it is up.
    @State private var fullScreen: HeroFullScreen?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What the full-screen button opens: the stored video (from where the hero is), the stored webp, or, with no
    /// file here, the public webp or hosted video.
    private func fullScreenRequest(withTime: Bool) -> HeroFullScreen? {
        if onDisk, let url = video.fileURL {
            if video.kind == .webp { return .webp(source: .file(url), aspect: shape, name: video.name) }
            guard !isStill else { return nil }
            let start = withTime ? (player?.currentTime() ?? .zero) : .zero
            return .video(url: url, name: video.name, start: start)
        }
        guard diskChecked || video.fileURL == nil else { return nil }
        if let webp = remote.animatedWebp { return .webp(source: HeroSource.animated(webp), aspect: shape, name: video.name) }
        if let hosted = remote.playableVideo { return .video(url: HeroSource.resolve(hosted), name: video.name, start: .zero) }
        return nil
    }

    private var expander: (() -> Void)? {
        guard fullScreenRequest(withTime: false) != nil else { return nil }
        return { openFullScreen() }
    }

    /// The stored video is playing here, so the bar is up (not for a webp, a still, a poster or a remote picture).
    private var hasBar: Bool { player != nil && video.kind == .original && onDisk && !isStill }

    /// The bar's sound button: the first unmute swaps to the item with audio, muting gives the session back.
    private func toggleSound() {
        guard let player, video.kind == .original else { return }
        muted.toggle()
        if muted {
            player.isMuted = true
            AudioPolicy.release()
        } else {
            Task { await unmute(player) }
        }
    }

    private func openFullScreen() {
        guard let request = fullScreenRequest(withTime: true) else { return }
        player?.pause()
        var transaction = Transaction()
        transaction.disablesAnimations = reduceMotion
        withTransaction(transaction) { fullScreen = request }
    }

    /// Back from the full-screen player: the same tab, from where it got to, muted and playing again.
    private func closedFullScreen(at time: CMTime?) {
        guard let player else { return }
        muted = true
        player.isMuted = true
        Task {
            if let time, time.isValid { await player.seek(to: time) }
            player.play()
        }
    }

    private var shape: CGFloat {
        if let w = video.width, let h = video.height, w > 0, h > 0 { return CGFloat(w) / CGFloat(h) }
        return aspect ?? 9.0 / 16.0
    }

    private var isStill: Bool {
        guard let ext = video.fileURL?.pathExtension.lowercased(), !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image) && ext != "webp" && ext != "gif"
    }

    private var label: String {
        var ext = (video.fileURL ?? video.remoteURL)?.pathExtension.lowercased() ?? ""
        if ext == "jpeg" { ext = "jpg" }
        return ext.isEmpty || ext.count > 5 ? (video.kind == .webp ? "webp" : "mp4") : ext
    }

    /// `playing` follows the player: the poster fades out once frames run.
    private func watchStatus(of player: AVPlayer) {
        statusWatch?.invalidate()
        let flag = $playing
        let latch = $videoUp
        statusWatch = player.observe(\.timeControlStatus, options: [.initial, .new]) { observed, _ in
            let isPlaying = observed.timeControlStatus == .playing
            Task { @MainActor in
                flag.wrappedValue = isPlaying
                if isPlaying { latch.wrappedValue = true }
            }
        }
    }

    /// Restarts the clip at its end.
    private func watchLoop(of item: AVPlayerItem, on player: AVPlayer) {
        if let loop { NotificationCenter.default.removeObserver(loop) }
        loop = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }
    }

    /// The first tap brings the sound: the clip's own item (with its audio) replaces the picture-only one at the
    /// same moment. A lent player has its sound already.
    private func unmute(_ player: AVPlayer) async {
        if !withSound, !(lent.map { player === $0.player } ?? false), let url = video.fileURL {
            let resume = player.currentTime()
            let full = AVPlayerItem(url: url)
            player.replaceCurrentItem(with: full)
            watchLoop(of: full, on: player)
            await full.seek(to: resume)
            withSound = true
            if !muted { player.play() }
        }
        guard !muted else { return }
        player.isMuted = false
        AudioPolicy.playback()
    }

    /// The first frame of a clip whose record has no poster, so the hero is never an empty box while the player
    /// starts.
    private static func frame(of url: URL) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 720)
        return try? await generator.image(at: .zero).image
    }

    var body: some View {
        Group {
            if onDisk, let url = video.fileURL {
                if video.kind == .webp {
                    AnimatedImageView(source: .file(url))
                } else if isStill {
                    StillImage(url: url)
                } else {
                    ZStack {
                        Rectangle().fill(FrameGradient.fill(1))
                        if let player { PlayerSurface(player: player, gravity: .resizeAspect).allowsHitTesting(false) }
                        // the picture the zoom came from stays until the video is up
                        if let poster = video.posterURL {
                            StillImage(url: poster).opacity(videoUp ? 0 : 1).allowsHitTesting(false)
                        } else if let firstFrame {
                            Image(decorative: firstFrame, scale: 1).resizable().scaledToFill()
                                .opacity(videoUp ? 0 : 1).allowsHitTesting(false)
                        }
                    }
                    .animation(.easeOut(duration: 0.2), value: videoUp)
                }
            } else if video.fileURL != nil, !diskChecked {
                ZStack {
                    Rectangle().fill(FrameGradient.fill(1))
                    if let poster = video.posterURL { StillImage(url: poster) }
                }
            } else {
                RemoteHeroPicture(poster: video.posterURL, remote: remote)
            }
        }
        .overlay {
            // a video that plays here has the bar (full screen is in it); a webp keeps the lone corner button
            if hasBar {
                HeroControls(
                    transport: transport, muted: muted, onSound: toggleSound, onFullScreen: fullScreenRequest(withTime: false) == nil ? nil : { openFullScreen() })
            }
        }
        .heroFrame(
            aspect: shape, maxHeight: maxHeight, label: label,
            expand: hasBar ? nil : expander)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if !hasBar { openFullScreen() } }
        .task(id: video.fileURL) {
            guard let url = video.fileURL, FileManager.default.fileExists(atPath: url.path) else { onDisk = false; diskChecked = true; return }
            onDisk = true
            diskChecked = true
            guard video.kind == .original, !isStill else { return }
            if let lent, lent.id == video.id {
                // the planet's own player, still playing: the picture is already on screen
                player = lent.player
                watchStatus(of: lent.player)
                transport.attach(lent.player)
                return
            }
            AudioPolicy.ambient()
            if video.posterURL == nil { firstFrame = await Self.frame(of: url) }
            // Muted until tapped: no audio pipeline is started for a picture nobody hears (the sound comes with the tap).
            let item = await HeroItems.pictureOnly(url)
            guard !Task.isCancelled else { return }
            let next = AVPlayer(playerItem: item)
            next.isMuted = true
            next.actionAtItemEnd = .none
            withSound = false
            watchLoop(of: item, on: next)
            player = next
            watchStatus(of: next)
            transport.attach(next)
            next.play()
        }
        .onDisappear {
            if !muted { AudioPolicy.release() }
            if let lent, player === lent.player {
                // the orbit's player goes back to the orbit: silent again, still playing (a pause is the owner's
                // and ends here: the orbit shows moving pictures)
                lent.player.isMuted = true
                transport.resumeIfPausedByUser()
            } else {
                player?.pause()
            }
            transport.detach()
            if let loop { NotificationCenter.default.removeObserver(loop) }
            player = nil
            loop = nil
            statusWatch?.invalidate()
            statusWatch = nil
            playing = false
            videoUp = false
        }
        .heroFullScreen(item: $fullScreen) { closedFullScreen(at: $0) }
        #if DEBUG
        .task(id: video.fileURL) {
            // `-previewHeroFullScreen 1` (simulator evidence): opens the full-screen player or viewer by itself
            guard UserDefaults.standard.bool(forKey: "previewHeroFullScreen"), video.fileURL != nil else { return }
            try? await Task.sleep(for: .seconds(2.5))
            openFullScreen()
        }
        #endif
        // a group, so the bar's own buttons stay reachable under the hero's name
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Media.heroA11y(video.name, evicted: !onDisk))
    }
}
