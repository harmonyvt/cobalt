import AVFoundation
import Foundation

/// How long each player in the app plays a clip before it loops. Pure rules, so a test can hold them.
public enum PlaybackWindow {
    /// The orbit's planets loop only the first seconds of a clip (a cheap, endless preview). Nothing that shows
    /// the whole clip (the detail's hero, the full-screen player) may reuse such a player: its looper ends every
    /// pass at this window, and a scrub can never reach past it.
    public static let orbitSeconds: Double = 3

    /// The span an orbit player loops for a clip of `duration` seconds (nil: not known, the usual window).
    public static func orbitLoopSeconds(duration: Double?) -> Double {
        max(0.5, min(orbitSeconds, duration ?? orbitSeconds))
    }

    /// An orbit player for a clip of `duration` seconds already loops the whole clip (a clip no longer than the
    /// window). An unknown duration is never taken for whole.
    public static func orbitLoopsWholeClip(duration: Double?) -> Bool {
        guard let duration, duration > 0 else { return false }
        return duration <= orbitLoopSeconds(duration: duration) + 0.05
    }
}

/// Items for a picture nobody hears.
@MainActor
public enum HeroItems {
    /// The clip's picture without its sound: an item over a composition holding only the video track, so no audio
    /// pipeline starts for a muted hero (the sound comes with the tap). A clip with no audio, or one that cannot be
    /// split, plays as it is. The composition spans the video track's own time range, loaded from the file (never
    /// an estimate), so the item is as long as the clip's picture.
    public static func pictureOnly(_ url: URL) async -> AVPlayerItem {
        let asset = AVURLAsset(url: url)
        do {
            guard try await !asset.loadTracks(withMediaType: .audio).isEmpty,
                  let source = try await asset.loadTracks(withMediaType: .video).first else { return AVPlayerItem(asset: asset) }
            let (range, transform) = try await (source.load(.timeRange), source.load(.preferredTransform))
            guard range.isValid, range.duration.isNumeric, range.duration.seconds > 0 else { return AVPlayerItem(asset: asset) }
            let composition = AVMutableComposition()
            guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                return AVPlayerItem(asset: asset)
            }
            try track.insertTimeRange(range, of: source, at: .zero)
            track.preferredTransform = transform
            return AVPlayerItem(asset: composition)
        } catch {
            return AVPlayerItem(asset: asset)
        }
    }
}
