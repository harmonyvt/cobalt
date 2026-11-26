import CobaltKit
import Foundation
import ImageIO
import MediaPlayer
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Centralizes Lock Screen / Control Center Now Playing metadata and `MPRemoteCommandCenter` handling for Twitch
/// playback on both iOS and macOS.
///
/// Artwork download and decoding run off-main (`nonisolated`) and are cached by URL so metadata refreshes never block
/// UI rendering. Wave 2 dual-stream audio focus can plug directly into `onNextTrack` / `onPreviousTrack`.
@MainActor
final class TwitchNowPlayingController {
    static let shared = TwitchNowPlayingController()

    struct Metadata: Equatable, Sendable {
        var channel: String
        var displayName: String
        var title: String?
        var game: String?
        var artworkURL: URL?
        var isPlaying: Bool
        var isLive: Bool = true
    }

    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    var onTogglePlayPause: (() -> Void)?
    /// Extensible hooks for Wave 2 dual-stream audio focus swap (enabled automatically when assigned).
    var onNextTrack: (() -> Void)? { didSet { syncTrackCommandEnablement() } }
    var onPreviousTrack: (() -> Void)? { didSet { syncTrackCommandEnablement() } }

    private var isRegistered = false
    private var currentMetadata: Metadata?
    private var cachedArtworkURL: URL?
    private var cachedArtwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?

    private init() {}

    func update(_ metadata: Metadata) {
        registerCommandsIfNeeded()
        syncTrackCommandEnablement()

        let urlChanged = metadata.artworkURL != cachedArtworkURL
        let metadataChanged = metadata != currentMetadata
        currentMetadata = metadata

        if metadataChanged {
            applyNowPlayingInfo(metadata)
        }

        if urlChanged {
            artworkTask?.cancel()
            artworkTask = nil
            cachedArtworkURL = metadata.artworkURL
            cachedArtwork = nil
            guard let url = metadata.artworkURL else {
                applyNowPlayingInfo(metadata)
                return
            }
            artworkTask = Task { [weak self] in
                guard let cgImage = await Self.fetchArtworkCGImage(url: url), !Task.isCancelled else { return }
                guard let self, self.cachedArtworkURL == url, let latest = self.currentMetadata else { return }
                self.cachedArtwork = Self.makeMediaArtwork(cgImage: cgImage)
                self.applyNowPlayingInfo(latest)
            }
        }
    }

    func clear() {
        artworkTask?.cancel()
        artworkTask = nil
        currentMetadata = nil
        cachedArtworkURL = nil
        cachedArtwork = nil

        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        #if os(macOS)
        center.playbackState = .stopped
        #endif

        unregisterCommandsIfNeeded()
    }

    // MARK: - Now Playing info

    private func applyNowPlayingInfo(_ metadata: Metadata) {
        var info: [String: Any] = [:]
        let trimmedTitle = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGame = metadata.game?.trimmingCharacters(in: .whitespacesAndNewlines)
        let artistName = metadata.displayName.isEmpty ? metadata.channel : metadata.displayName

        if let trimmedTitle, !trimmedTitle.isEmpty {
            info[MPMediaItemPropertyTitle] = trimmedTitle
            info[MPMediaItemPropertyArtist] = artistName
        } else {
            info[MPMediaItemPropertyTitle] = artistName
            info[MPMediaItemPropertyArtist] = (trimmedGame?.isEmpty == false ? trimmedGame : "Twitch") ?? "Twitch"
        }

        if let trimmedGame, !trimmedGame.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = trimmedGame
        } else {
            info[MPMediaItemPropertyAlbumTitle] = "Twitch"
        }

        info[MPNowPlayingInfoPropertyIsLiveStream] = metadata.isLive
        info[MPNowPlayingInfoPropertyPlaybackRate] = metadata.isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue

        if let artwork = cachedArtwork, cachedArtworkURL == metadata.artworkURL {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        #if os(macOS)
        center.playbackState = metadata.isPlaying ? .playing : .paused
        #endif
    }

    // MARK: - Remote commands

    private func registerCommandsIfNeeded() {
        guard !isRegistered else { return }
        isRegistered = true

        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.isEnabled = true
        Self.addRemoteTarget(cc.playCommand) { [weak self] in self?.onPlay?() }

        cc.pauseCommand.isEnabled = true
        Self.addRemoteTarget(cc.pauseCommand) { [weak self] in self?.onPause?() }

        cc.togglePlayPauseCommand.isEnabled = true
        Self.addRemoteTarget(cc.togglePlayPauseCommand) { [weak self] in self?.onTogglePlayPause?() }

        Self.addRemoteTarget(cc.nextTrackCommand) { [weak self] in self?.onNextTrack?() }
        Self.addRemoteTarget(cc.previousTrackCommand) { [weak self] in self?.onPreviousTrack?() }

        // Live streams do not scrub.
        cc.changePlaybackPositionCommand.isEnabled = false
        cc.seekForwardCommand.isEnabled = false
        cc.seekBackwardCommand.isEnabled = false
        syncTrackCommandEnablement()
    }

    private func unregisterCommandsIfNeeded() {
        guard isRegistered else { return }
        isRegistered = false

        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.removeTarget(nil)
        cc.pauseCommand.removeTarget(nil)
        cc.togglePlayPauseCommand.removeTarget(nil)
        cc.nextTrackCommand.removeTarget(nil)
        cc.previousTrackCommand.removeTarget(nil)
        cc.playCommand.isEnabled = false
        cc.pauseCommand.isEnabled = false
        cc.togglePlayPauseCommand.isEnabled = false
        cc.nextTrackCommand.isEnabled = false
        cc.previousTrackCommand.isEnabled = false
    }

    private func syncTrackCommandEnablement() {
        guard isRegistered else { return }
        let cc = MPRemoteCommandCenter.shared()
        cc.nextTrackCommand.isEnabled = onNextTrack != nil
        cc.previousTrackCommand.isEnabled = onPreviousTrack != nil
    }

    /// Registers a `MPRemoteCommand` block outside `@MainActor` isolation so MediaRemote invoking the Obj-C block
    /// on a background queue never trips Swift 6's `_dispatch_assert_queue_fail` check.
    private nonisolated static func addRemoteTarget(
        _ command: MPRemoteCommand,
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        command.addTarget { _ in
            Task { @MainActor in action() }
            return .success
        }
    }

    // MARK: - Off-main artwork fetch & decode

    private nonisolated static func fetchArtworkCGImage(url: URL) async -> CGImage? {
        var req = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 10)
        req.httpMethod = "GET"
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 600,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Constructed `nonisolated` so `MPMediaItemArtwork`'s `requestHandler` Obj-C block does not inherit `@MainActor`.
    /// `MediaPlayer` invokes `requestHandler` on its own background queue; a `@MainActor` closure traps with `SIGTRAP`.
    private nonisolated static func makeMediaArtwork(cgImage: CGImage) -> MPMediaItemArtwork {
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        return MPMediaItemArtwork(boundsSize: size) { _ in
            #if os(iOS)
            UIImage(cgImage: cgImage)
            #else
            NSImage(cgImage: cgImage, size: size)
            #endif
        }
    }
}
