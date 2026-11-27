import Foundation

// Models for on-device Twitch stream clipping, continuous recording, time-synced chat logs,
// and vertical split-frame (Region A / B) draft editing.
//
// All types here are immutable, `Sendable`, `Equatable`, and `Codable` so they cross actor
// boundaries cleanly and persist off the main thread (apple/ARCHITECTURE.md rules 1 & 2).

public enum TwitchClipKind: String, Sendable, Equatable, Codable, CaseIterable {
    case clip
    case recording
}

public struct RecordedChatBadge: Sendable, Equatable, Hashable, Codable {
    public var id: String
    public var title: String
    public var url: URL

    public init(id: String, title: String, url: URL) {
        self.id = id
        self.title = title
        self.url = url
    }

    public init(_ badge: ChatBadge) {
        self.id = badge.id
        self.title = badge.title
        self.url = badge.url
    }
}

public struct RecordedChatEmote: Sendable, Equatable, Hashable, Codable {
    public var id: String
    public var name: String
    public var url: URL
    public var animated: Bool
    public var zeroWidth: Bool
    public var aspect: Double
    public var source: String

    public init(
        id: String, name: String, url: URL, animated: Bool = false,
        zeroWidth: Bool = false, aspect: Double = 1, source: String = "sevenTv"
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.animated = animated
        self.zeroWidth = zeroWidth
        self.aspect = aspect
        self.source = source
    }

    public init(_ emote: ChatEmote) {
        self.id = emote.id
        self.name = emote.name
        self.url = emote.url
        self.animated = emote.animated
        self.zeroWidth = emote.zeroWidth
        self.aspect = emote.aspect
        self.source = emote.source.rawValue
    }
}

public struct RecordedChatPaint: Sendable, Equatable, Hashable, Codable {
    public struct Stop: Sendable, Equatable, Hashable, Codable {
        public var at: Double
        public var rgba: UInt32

        public init(at: Double, rgba: UInt32) {
            self.at = at
            self.rgba = rgba
        }
    }

    public var id: String
    public var name: String
    public var kind: String
    public var angle: Double
    public var stops: [Stop]
    public var color: UInt32?

    public init(
        id: String, name: String, kind: String = "linear", angle: Double = 90,
        stops: [Stop] = [], color: UInt32? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.angle = angle
        self.stops = stops
        self.color = color
    }

    public init(_ paint: SevenTvPaint) {
        self.id = paint.id
        self.name = paint.name
        self.kind = paint.kind.rawValue
        self.angle = paint.angle
        self.stops = paint.resolvedStops.map { Stop(at: $0.at, rgba: $0.rgba) }
        self.color = paint.color
    }
}

public enum RecordedChatFragment: Sendable, Equatable, Hashable, Codable {
    case text(String)
    case emote(RecordedChatEmote)
    case stack(RecordedChatEmote, [RecordedChatEmote])
    case mention(String)
    case link(URL)

    public init(_ fragment: ChatFragment) {
        switch fragment {
        case .text(let value): self = .text(value)
        case .emote(let emote): self = .emote(RecordedChatEmote(emote))
        case .stack(let base, let overlays): self = .stack(RecordedChatEmote(base), overlays.map(RecordedChatEmote.init))
        case .mention(let name): self = .mention(name)
        case .link(let url): self = .link(url)
        }
    }

    public var plainText: String {
        switch self {
        case .text(let s): return s
        case .emote(let e): return e.name
        case .stack(let base, let overlays): return ([base.name] + overlays.map(\.name)).joined(separator: " ")
        case .mention(let m): return "@\(m)"
        case .link(let u): return u.absoluteString
        }
    }
}

/// One recorded chat message anchored to clip-relative seconds (`t >= 0`).
public struct RecordedChatEntry: Sendable, Equatable, Hashable, Codable, Identifiable {
    public var id: String
    /// Clip-relative seconds from the start of the captured video.
    public var t: Double
    public var login: String
    public var displayName: String
    /// `0xRRGGBB`, nil when Twitch did not send a custom color.
    public var color: UInt32?
    public var paint: RecordedChatPaint?
    public var badges: [RecordedChatBadge]
    public var fragments: [RecordedChatFragment]
    public var isAction: Bool
    public var notice: String?

    public init(
        id: String, t: Double, login: String, displayName: String,
        color: UInt32? = nil, paint: RecordedChatPaint? = nil,
        badges: [RecordedChatBadge] = [], fragments: [RecordedChatFragment] = [],
        isAction: Bool = false, notice: String? = nil
    ) {
        self.id = id
        self.t = t
        self.login = login
        self.displayName = displayName
        self.color = color
        self.paint = paint
        self.badges = badges
        self.fragments = fragments
        self.isAction = isAction
        self.notice = notice
    }

    public init?(line: TwitchChatLine, clipRelativeSeconds t: Double, paint: SevenTvPaint?) {
        guard !line.deleted else { return nil }
        switch line.kind {
        case .system:
            return nil
        case .message:
            self.isAction = false
            self.notice = nil
        case .action:
            self.isAction = true
            self.notice = nil
        case .notice(let text):
            self.isAction = false
            self.notice = text
        }
        self.id = line.id
        self.t = max(0, (t * 1000).rounded() / 1000)
        self.login = line.login
        self.displayName = line.displayName.isEmpty ? line.login : line.displayName
        self.color = line.color
        self.paint = paint.map(RecordedChatPaint.init)
        self.badges = line.badges.map(RecordedChatBadge.init)
        self.fragments = line.fragments.map(RecordedChatFragment.init)
    }

    /// Plain text body (used for clear-text fallback, accessibility, and GIF/MP4 rendering).
    public var plainText: String {
        fragments.map(\.plainText).joined()
    }

    /// Deterministic Twitch-style name color when the user has not chosen one.
    public var resolvedColorRGB: UInt32 {
        if let color { return color }
        let palette: [UInt32] = [
            0xFF6B6B, 0xFF9F6B, 0xFFCF5A, 0xB6E36A,
            0x5FD0C5, 0x6BB5FF, 0xB48AFF, 0xFF7AD1,
        ]
        var hash: UInt64 = 5381
        for byte in login.lowercased().utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

/// An interval within the clip where live chat was disconnected (while the video stayed whole).
public struct RecordedChatGap: Sendable, Equatable, Hashable, Codable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = max(0, start)
        self.end = max(self.start, end)
    }

    public var duration: Double { max(0, end - start) }

    public func contains(_ t: Double) -> Bool {
        t >= start && t < end
    }
}

/// Sidecar chat log stored alongside each captured stream clip (`<id>.chat.json`).
public struct RecordedChatLog: Sendable, Equatable, Codable {
    public var version: Int
    public var channel: String
    public var duration: Double
    public var entries: [RecordedChatEntry]
    public var gaps: [RecordedChatGap]

    public init(
        version: Int = 1, channel: String, duration: Double,
        entries: [RecordedChatEntry], gaps: [RecordedChatGap] = []
    ) {
        self.version = version
        self.channel = channel
        self.duration = max(0, duration)
        self.entries = entries.sorted { $0.t < $1.t }
        self.gaps = gaps.filter { $0.duration >= 0.5 }.sorted { $0.start < $1.start }
    }

    /// Per-second chat activity buckets for the shelf & timeline heat bars.
    public func densityBuckets(maxBuckets: Int = 60) -> [Int] {
        let count = max(1, min(maxBuckets, Int(ceil(max(1, duration)))))
        guard count > 0 else { return [0] }
        let span = max(0.001, duration)
        var counts = Array(repeating: 0, count: count)
        for entry in entries {
            let idx = min(count - 1, max(0, Int((entry.t / span) * Double(count))))
            counts[idx] += 1
        }
        return counts
    }

    /// Whether the chat timeline has a recorded disconnect gap at `time` (already offset-adjusted).
    public func isInGap(at time: Double) -> Bool {
        gaps.contains { $0.contains(time) }
    }

    /// Total seconds lost to chat reconnect gaps.
    public var totalGapSeconds: Double {
        gaps.reduce(0) { $0 + $1.duration }
    }

    /// Messages visible on screen at playhead `playheadSeconds` with chat sync nudge `syncOffset`.
    /// Matches Fable's mockup: looks up `tt = playhead - syncOffset`, keeps up to `maxLines` recent
    /// entries within `windowSeconds`.
    public func visibleEntries(
        at playheadSeconds: Double,
        syncOffset: Double = 0,
        windowSeconds: Double = 9.0,
        maxLines: Int = 6
    ) -> [RecordedChatEntry] {
        let tt = playheadSeconds - syncOffset
        guard tt >= 0 else { return [] }
        if isInGap(at: tt) { return [] }
        var lastIndex = -1
        for (i, entry) in entries.enumerated() {
            if entry.t <= tt {
                lastIndex = i
            } else {
                break
            }
        }
        guard lastIndex >= 0 else { return [] }
        let firstIndex = max(0, lastIndex - max(1, maxLines) + 1)
        var out: [RecordedChatEntry] = []
        for i in firstIndex...lastIndex {
            let entry = entries[i]
            if tt - entry.t < windowSeconds {
                out.append(entry)
            }
        }
        return out
    }
}

// MARK: - Split-Frame & Chat Editor Configuration

public enum TwitchClipLayout: String, Sendable, Equatable, Codable, CaseIterable {
    case split
    case pip
    case single
}

public enum TwitchClipRegionID: String, Sendable, Equatable, Codable, CaseIterable {
    case a = "A"
    case b = "B"

    public var other: TwitchClipRegionID { self == .a ? .b : .a }
}

/// Desired center & width (normalized 0...1 on the 16:9 source frame) for Region A or Region B.
/// Storing desired center & width (rather than clamped height) preserves the user's framing when
/// switching between 50/50, 40/60, 35/65, PiP, and Single (matching Fable's mockup).
public struct TwitchClipRegionTarget: Sendable, Equatable, Codable {
    public var cx: Double
    public var cy: Double
    public var w: Double

    public init(cx: Double, cy: Double, w: Double) {
        self.cx = cx
        self.cy = cy
        self.w = w
    }
}

/// Floating picture-in-picture box position on the 9:16 canvas (normalized 0...1).
public struct TwitchClipPiPBox: Sendable, Equatable, Codable {
    public var x: Double
    public var y: Double
    public var w: Double

    public init(x: Double = 0.54, y: Double = 0.04, w: Double = 0.42) {
        self.x = x
        self.y = y
        self.w = w
    }
}

public enum TwitchClipChatPlacement: String, Sendable, Equatable, Codable, CaseIterable {
    case bottom
    case seam
    case top
    case band
}

public enum TwitchClipChatLook: String, Sendable, Equatable, Codable, CaseIterable {
    case liquidGlass
    case clearText
}

public struct TwitchClipChatConfig: Sendable, Equatable, Codable {
    public var enabled: Bool
    public var placement: TwitchClipChatPlacement
    public var look: TwitchClipChatLook
    /// Font scale multiplier (`0.8...1.6`, default `1.0`).
    public var scale: Double
    public var showEmotes: Bool
    public var showBadges: Bool
    public var showPaints: Bool
    /// Stream-delay sync nudge in seconds (`-5.0...5.0`, step `0.5`).
    public var syncOffset: Double

    public init(
        enabled: Bool = true,
        placement: TwitchClipChatPlacement = .bottom,
        look: TwitchClipChatLook = .liquidGlass,
        scale: Double = 1.0,
        showEmotes: Bool = true,
        showBadges: Bool = true,
        showPaints: Bool = true,
        syncOffset: Double = 0
    ) {
        self.enabled = enabled
        self.placement = placement
        self.look = look
        self.scale = scale
        self.showEmotes = showEmotes
        self.showBadges = showBadges
        self.showPaints = showPaints
        self.syncOffset = syncOffset
    }
}

public struct TwitchClipEditConfig: Sendable, Equatable, Codable {
    public var layout: TwitchClipLayout
    /// Top-half fraction of the video area in `.split` mode (`0.25...0.75`, snaps to 35/40/50/60/65%).
    public var splitRatio: Double
    /// Which region occupies the top slot in `.split` mode (`.a` default; swapped via `swap A ⇅ B`).
    public var topRegion: TwitchClipRegionID
    public var regionA: TwitchClipRegionTarget
    public var regionB: TwitchClipRegionTarget
    public var pip: TwitchClipPiPBox
    public var chat: TwitchClipChatConfig

    public init(
        layout: TwitchClipLayout = .split,
        splitRatio: Double = 0.5,
        topRegion: TwitchClipRegionID = .a,
        regionA: TwitchClipRegionTarget = TwitchClipRegionTarget(cx: 0.16, cy: 0.76, w: 0.28),
        regionB: TwitchClipRegionTarget = TwitchClipRegionTarget(cx: 0.62, cy: 0.50, w: 0.50),
        pip: TwitchClipPiPBox = TwitchClipPiPBox(),
        chat: TwitchClipChatConfig = TwitchClipChatConfig()
    ) {
        self.layout = layout
        self.splitRatio = splitRatio
        self.topRegion = topRegion
        self.regionA = regionA
        self.regionB = regionB
        self.pip = pip
        self.chat = chat
    }

    public func target(for region: TwitchClipRegionID) -> TwitchClipRegionTarget {
        region == .a ? regionA : regionB
    }

    public mutating func setTarget(_ target: TwitchClipRegionTarget, for region: TwitchClipRegionID) {
        if region == .a {
            regionA = target
        } else {
            regionB = target
        }
    }
}

// MARK: - Saved Draft & Live Capture State

public struct TwitchClipDraft: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var channel: String
    public var title: String
    public var kind: TwitchClipKind
    public var createdAt: Date
    public var updatedAt: Date
    public var duration: Double
    public var width: Int
    public var height: Int
    public var videoFileName: String
    public var chatFileName: String
    public var thumbnailFileName: String?
    public var chatLineCount: Int
    public var chatGaps: [RecordedChatGap]
    /// Precomputed per-second chat density buckets so the shelf renders instantly without reading JSON.
    public var density: [Int]
    public var isFresh: Bool
    /// Set once the raw 16:9 clip has been uploaded to the Library (reused when re-sending to Studio).
    public var uploadedVideoItemID: String?
    /// Set once a Studio project was created from this draft.
    public var studioProjectID: String?
    public var edit: TwitchClipEditConfig

    public init(
        id: String,
        channel: String,
        title: String,
        kind: TwitchClipKind,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        duration: Double,
        width: Int = 1920,
        height: Int = 1080,
        videoFileName: String,
        chatFileName: String,
        thumbnailFileName: String? = nil,
        chatLineCount: Int = 0,
        chatGaps: [RecordedChatGap] = [],
        density: [Int] = [],
        isFresh: Bool = true,
        uploadedVideoItemID: String? = nil,
        studioProjectID: String? = nil,
        edit: TwitchClipEditConfig = TwitchClipEditConfig()
    ) {
        self.id = id
        self.channel = channel
        self.title = title
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.duration = duration
        self.width = width
        self.height = height
        self.videoFileName = videoFileName
        self.chatFileName = chatFileName
        self.thumbnailFileName = thumbnailFileName
        self.chatLineCount = chatLineCount
        self.chatGaps = chatGaps
        self.density = density
        self.isFresh = isFresh
        self.uploadedVideoItemID = uploadedVideoItemID
        self.studioProjectID = studioProjectID
        self.edit = edit
    }

    public var sourceAspect: Double {
        guard width > 0, height > 0 else { return 16.0 / 9.0 }
        return Double(width) / Double(height)
    }

    public var totalChatGapSeconds: Double {
        chatGaps.reduce(0) { $0 + $1.duration }
    }
}

/// Live rolling-buffer & recording status published from `TwitchClipRecorder` to the watch UI.
public struct TwitchClipCaptureState: Sendable, Equatable {
    public var channel: String?
    public var bufferedSeconds: Double
    public var maxBufferSeconds: Double
    public var isRecording: Bool
    public var recordingSeconds: Double
    public var recordingChatCount: Int
    public var isSaving: Bool
    public var savingKind: TwitchClipKind?

    public init(
        channel: String? = nil,
        bufferedSeconds: Double = 0,
        maxBufferSeconds: Double = 60,
        isRecording: Bool = false,
        recordingSeconds: Double = 0,
        recordingChatCount: Int = 0,
        isSaving: Bool = false,
        savingKind: TwitchClipKind? = nil
    ) {
        self.channel = channel
        self.bufferedSeconds = bufferedSeconds
        self.maxBufferSeconds = maxBufferSeconds
        self.isRecording = isRecording
        self.recordingSeconds = recordingSeconds
        self.recordingChatCount = recordingChatCount
        self.isSaving = isSaving
        self.savingKind = savingKind
    }

    public static let idle = TwitchClipCaptureState()
}

/// Result returned when `TwitchClipRecorder` finishes writing a clip or recording to disk.
public struct TwitchClipSaveResult: Sendable, Equatable {
    public var draft: TwitchClipDraft
    public var wasPartialBuffer: Bool
    public var requestedSeconds: Double?

    public init(draft: TwitchClipDraft, wasPartialBuffer: Bool = false, requestedSeconds: Double? = nil) {
        self.draft = draft
        self.wasPartialBuffer = wasPartialBuffer
        self.requestedSeconds = requestedSeconds
    }
}
