import Foundation

/// How the server handles audio loudness on newly saved videos (`GET/PUT /audio/settings`).
public enum AudioLevelMode: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    case off
    case measure
    case auto

    public var label: String {
        switch self {
        case .off: return "Off"
        case .measure: return "Measure"
        case .auto: return "Auto"
        }
    }

    public var summary: String {
        switch self {
        case .off: return "No loudness measurement or automatic leveling."
        case .measure: return "Measure every saved video on ingest; level only when you ask."
        case .auto: return "Automatically create a leveled copy when a video is too loud, clipping, or too quiet."
        }
    }
}

/// Target integrated loudness for EBU R128 2-pass leveling (`-14` or `-16` LUFS).
public enum AudioTargetLufs: Int, Sendable, Codable, Equatable, Hashable, CaseIterable {
    case lufs14 = -14
    case lufs16 = -16

    public var label: String { "\(rawValue) LUFS" }

    public var shortLabel: String { "\(rawValue)" }

    public var subtitle: String {
        switch self {
        case .lufs14: return "YouTube, Twitch & Discord standard"
        case .lufs16: return "Apple Podcasts & broadcast headroom"
        }
    }

    public init(clamped value: Int) {
        self = value == -16 ? .lufs16 : .lufs14
    }
}

/// Which audio version shared links default to when a leveled copy is ready.
public enum AudioDefaultLink: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    case orig
    case normal

    public var label: String {
        switch self {
        case .orig: return "Original"
        case .normal: return "Leveled (?audio=normal)"
        }
    }

    public var shortLabel: String {
        switch self {
        case .orig: return "Original"
        case .normal: return "Leveled"
        }
    }
}

/// Loudness zone classified from measured integrated LUFS and true peak dBTP.
public enum AudioZone: String, Sendable, Codable, Equatable, Hashable {
    case pending
    case balanced
    case loud
    case quiet
    case silent

    public var label: String {
        switch self {
        case .pending: return "Pending"
        case .balanced: return "Balanced"
        case .loud: return "Too Loud"
        case .quiet: return "Too Quiet"
        case .silent: return "Silent"
        }
    }

    public var isOutOfRange: Bool {
        self == .loud || self == .quiet
    }
}

/// Lifecycle state of a video's audio loudness measurement and leveled alternate.
public enum AudioLevelState: String, Sendable, Codable, Equatable, Hashable {
    case pending
    case measured
    case rendering
    case ready
    case skipped
    case failed
}

/// Loudness metadata attached to a `LibraryFile` from `GET /library` and `GET /sync`.
public struct AudioLoudnessInfo: Sendable, Codable, Equatable, Hashable {
    public var integratedLufs: Double?
    public var truePeakDbtp: Double?
    public var lraLu: Double?
    public var zone: AudioZone
    public var state: AudioLevelState
    public var targetLufs: Int?
    public var outputLufs: Double?
    public var outputTruePeak: Double?
    public var altID: String?
    public var altURL: URL?
    public var error: String?
    public var measuredAt: Date?
    public var leveledAt: Date?

    public init(
        integratedLufs: Double? = nil,
        truePeakDbtp: Double? = nil,
        lraLu: Double? = nil,
        zone: AudioZone = .pending,
        state: AudioLevelState = .pending,
        targetLufs: Int? = nil,
        outputLufs: Double? = nil,
        outputTruePeak: Double? = nil,
        altID: String? = nil,
        altURL: URL? = nil,
        error: String? = nil,
        measuredAt: Date? = nil,
        leveledAt: Date? = nil
    ) {
        self.integratedLufs = integratedLufs
        self.truePeakDbtp = truePeakDbtp
        self.lraLu = lraLu
        self.zone = zone
        self.state = state
        self.targetLufs = targetLufs
        self.outputLufs = outputLufs
        self.outputTruePeak = outputTruePeak
        self.altID = altID
        self.altURL = altURL
        self.error = error
        self.measuredAt = measuredAt
        self.leveledAt = leveledAt
    }

    enum CodingKeys: String, CodingKey {
        case integratedLufs
        case truePeakDbtp
        case lraLu
        case zone
        case state
        case targetLufs
        case outputLufs
        case outputTruePeak
        case altID = "altId"
        case altURL = "altUrl"
        case error
        case measuredAt
        case leveledAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        integratedLufs = try? c.decodeIfPresent(Double.self, forKey: .integratedLufs)
        truePeakDbtp = try? c.decodeIfPresent(Double.self, forKey: .truePeakDbtp)
        lraLu = try? c.decodeIfPresent(Double.self, forKey: .lraLu)
        zone = (try? c.decodeIfPresent(AudioZone.self, forKey: .zone)) ?? .pending
        state = (try? c.decodeIfPresent(AudioLevelState.self, forKey: .state)) ?? .pending
        targetLufs = try? c.decodeIfPresent(Int.self, forKey: .targetLufs)
        outputLufs = try? c.decodeIfPresent(Double.self, forKey: .outputLufs)
        outputTruePeak = try? c.decodeIfPresent(Double.self, forKey: .outputTruePeak)
        altID = try? c.decodeIfPresent(String.self, forKey: .altID)
        altURL = try? c.decodeIfPresent(URL.self, forKey: .altURL)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        measuredAt = try? c.decodeIfPresent(Date.self, forKey: .measuredAt)
        leveledAt = try? c.decodeIfPresent(Date.self, forKey: .leveledAt)
    }

    /// True when a leveled alternate has been rendered and is available.
    public var isLeveled: Bool {
        state == .ready && altID != nil
    }

    /// True while the helper container is actively rendering a leveled copy.
    public var isRendering: Bool {
        state == .rendering
    }

    /// True when the clip has no audible track (<= -60 LUFS).
    public var isSilent: Bool {
        zone == .silent
    }

    /// True when the clip is out-of-range (too loud, clipping, or too quiet) and does not yet have a leveled copy.
    public var needsAttention: Bool {
        !isLeveled && !isRendering && (zone.isOutOfRange || state == .failed)
    }

    /// True when a leveled copy exists but was rendered for a different target than the user's current target.
    public func needsRelevel(for target: AudioTargetLufs) -> Bool {
        guard isLeveled, let rendered = targetLufs else { return false }
        return rendered != target.rawValue
    }

    /// Gain change in dB from original integrated LUFS to output (or target) LUFS.
    public func gainDelta(for target: AudioTargetLufs = .lufs14) -> Double? {
        guard let input = integratedLufs, !isSilent else { return nil }
        let dest = outputLufs ?? Double(targetLufs ?? target.rawValue)
        return dest - input
    }

    /// True when the original track clips near 0 dBTP (> -0.3 dBTP).
    public var isClipping: Bool {
        guard let tp = truePeakDbtp else { return false }
        return tp > -0.3
    }

    public static func formatLufs(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.1f LUFS", value)
    }

    public static func formatTruePeak(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        let sign = value > 0 ? "+" : ""
        return String(format: "%@%.1f dBTP", sign, value)
    }

    public static func formatGain(_ delta: Double?) -> String {
        guard let delta, delta.isFinite else { return "—" }
        let sign = delta >= 0 ? "+" : ""
        return String(format: "%@%.1f dB", sign, delta)
    }
}

/// Library-wide audio loudness counts returned by `GET /audio/settings`.
public struct AudioLoudnessCounts: Sendable, Codable, Equatable, Hashable {
    public var totalVideos: Int
    public var measured: Int
    public var leveled: Int
    public var needsLevel: Int
    public var rendering: Int
    public var failed: Int

    public init(
        totalVideos: Int = 0,
        measured: Int = 0,
        leveled: Int = 0,
        needsLevel: Int = 0,
        rendering: Int = 0,
        failed: Int = 0
    ) {
        self.totalVideos = totalVideos
        self.measured = measured
        self.leveled = leveled
        self.needsLevel = needsLevel
        self.rendering = rendering
        self.failed = failed
    }

    public var unmeasured: Int {
        max(0, totalVideos - measured)
    }
}

/// Server-wide audio loudness settings + library counts (`GET/PUT /audio/settings`).
public struct AudioLevelSettings: Sendable, Codable, Equatable, Hashable {
    public var mode: AudioLevelMode
    public var target: AudioTargetLufs
    public var defaultLink: AudioDefaultLink
    public var updatedAt: Date?
    public var counts: AudioLoudnessCounts

    public init(
        mode: AudioLevelMode = .auto,
        target: AudioTargetLufs = .lufs14,
        defaultLink: AudioDefaultLink = .orig,
        updatedAt: Date? = nil,
        counts: AudioLoudnessCounts = .init()
    ) {
        self.mode = mode
        self.target = target
        self.defaultLink = defaultLink
        self.updatedAt = updatedAt
        self.counts = counts
    }

    enum CodingKeys: String, CodingKey {
        case mode
        case targetLufs
        case defaultLink
        case updatedAt
        case counts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? c.decodeIfPresent(AudioLevelMode.self, forKey: .mode)) ?? .auto
        let rawTarget = (try? c.decodeIfPresent(Int.self, forKey: .targetLufs)) ?? -14
        target = AudioTargetLufs(clamped: rawTarget)
        defaultLink = (try? c.decodeIfPresent(AudioDefaultLink.self, forKey: .defaultLink)) ?? .orig
        if let ts = try? c.decodeIfPresent(Double.self, forKey: .updatedAt), ts > 0 {
            updatedAt = Date(timeIntervalSince1970: ts / 1000)
        } else {
            updatedAt = nil
        }
        counts = (try? c.decodeIfPresent(AudioLoudnessCounts.self, forKey: .counts)) ?? .init()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode)
        try c.encode(target.rawValue, forKey: .targetLufs)
        try c.encode(defaultLink, forKey: .defaultLink)
        if let updatedAt {
            try c.encode((updatedAt.timeIntervalSince1970 * 1000).rounded(), forKey: .updatedAt)
        }
        try c.encode(counts, forKey: .counts)
    }
}

/// Partial update sent to `PUT /audio/settings`.
public struct AudioLevelSettingsPatch: Sendable, Equatable {
    public var mode: AudioLevelMode?
    public var target: AudioTargetLufs?
    public var defaultLink: AudioDefaultLink?

    public init(mode: AudioLevelMode? = nil, target: AudioTargetLufs? = nil, defaultLink: AudioDefaultLink? = nil) {
        self.mode = mode
        self.target = target
        self.defaultLink = defaultLink
    }

    var body: [String: Any] {
        var out: [String: Any] = [:]
        if let mode { out["mode"] = mode.rawValue }
        if let target { out["target_lufs"] = target.rawValue }
        if let defaultLink { out["default_link"] = defaultLink.rawValue }
        return out
    }
}

/// Response from `POST /library/items/:id/audio/level` (`202 Accepted`).
public struct AudioLevelQueued: Sendable, Codable, Equatable {
    public var state: AudioLevelState
    public var target: AudioTargetLufs
    public var queued: Bool

    public init(state: AudioLevelState = .rendering, target: AudioTargetLufs = .lufs14, queued: Bool = true) {
        self.state = state
        self.target = target
        self.queued = queued
    }

    enum CodingKeys: String, CodingKey {
        case state
        case targetLufs
        case queued
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = (try? c.decodeIfPresent(AudioLevelState.self, forKey: .state)) ?? .rendering
        target = AudioTargetLufs(clamped: (try? c.decodeIfPresent(Int.self, forKey: .targetLufs)) ?? -14)
        queued = (try? c.decodeIfPresent(Bool.self, forKey: .queued)) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(state, forKey: .state)
        try c.encode(target.rawValue, forKey: .targetLufs)
        try c.encode(queued, forKey: .queued)
    }
}

/// Response from `DELETE /library/items/:id/audio/level`.
public struct AudioLevelRemoval: Sendable, Codable, Equatable {
    public var removed: Bool
    public var altID: String?
    public var bytes: Int64

    public init(removed: Bool, altID: String? = nil, bytes: Int64 = 0) {
        self.removed = removed
        self.altID = altID
        self.bytes = bytes
    }

    enum CodingKeys: String, CodingKey {
        case removed
        case altID = "altId"
        case bytes
    }
}

/// Response from `POST /audio/backfill`.
public struct AudioBackfillResult: Sendable, Codable, Equatable {
    public var queuedMeasure: Int
    public var queuedLevel: Int
    public var eligible: Int
    public var mode: AudioLevelMode
    public var target: AudioTargetLufs

    public init(
        queuedMeasure: Int,
        queuedLevel: Int,
        eligible: Int,
        mode: AudioLevelMode,
        target: AudioTargetLufs
    ) {
        self.queuedMeasure = queuedMeasure
        self.queuedLevel = queuedLevel
        self.eligible = eligible
        self.mode = mode
        self.target = target
    }

    enum CodingKeys: String, CodingKey {
        case queuedMeasure
        case queuedLevel
        case eligible
        case mode
        case targetLufs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        queuedMeasure = (try? c.decodeIfPresent(Int.self, forKey: .queuedMeasure)) ?? 0
        queuedLevel = (try? c.decodeIfPresent(Int.self, forKey: .queuedLevel)) ?? 0
        eligible = (try? c.decodeIfPresent(Int.self, forKey: .eligible)) ?? 0
        mode = (try? c.decodeIfPresent(AudioLevelMode.self, forKey: .mode)) ?? .auto
        target = AudioTargetLufs(clamped: (try? c.decodeIfPresent(Int.self, forKey: .targetLufs)) ?? -14)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(queuedMeasure, forKey: .queuedMeasure)
        try c.encode(queuedLevel, forKey: .queuedLevel)
        try c.encode(eligible, forKey: .eligible)
        try c.encode(mode, forKey: .mode)
        try c.encode(target.rawValue, forKey: .targetLufs)
    }
}

/// Deterministic EBU R128 loudness classifier matching `deploy/cloudflare/api/src/audio-loudness.ts`.
public enum AudioLoudnessClassifier {
    public struct Verdict: Sendable, Equatable {
        public var zone: AudioZone
        public var autoLevel: Bool
        public var rule: String
        public var summary: String
    }

    /// Classifies a clip by integrated LUFS and true peak dBTP.
    ///
    /// Rules (identical to server `classifyLoudness`):
    /// - `lufs <= -60` → `.silent` (skip)
    /// - `lufs > -10.5` → `.loud` (auto-level)
    /// - `lufs > -12 && truePeak > -0.3` → `.loud` (clipping, auto-level)
    /// - `lufs < -22` → `.quiet` (auto-level)
    /// - otherwise → `.balanced` (skip auto, manual ok)
    public static func classify(lufs: Double, truePeak: Double) -> Verdict {
        if !lufs.isFinite || lufs <= -60 {
            return Verdict(
                zone: .silent,
                autoLevel: false,
                rule: "LUFS ≤ −60",
                summary: "No audible audio track — skipped."
            )
        }
        if lufs > -10.5 {
            return Verdict(
                zone: .loud,
                autoLevel: true,
                rule: "LUFS > −10.5",
                summary: "Too loud — auto-leveled down to target."
            )
        }
        if lufs > -12.0 && truePeak.isFinite && truePeak > -0.3 {
            return Verdict(
                zone: .loud,
                autoLevel: true,
                rule: "LUFS > −12 & True Peak > −0.3 dBTP",
                summary: "Hot & clipping near 0 dBTP — auto-leveled with −1.5 dBTP ceiling."
            )
        }
        if lufs < -22.0 {
            return Verdict(
                zone: .quiet,
                autoLevel: true,
                rule: "LUFS < −22",
                summary: "Too quiet — auto-leveled up to target with gentle limiter."
            )
        }
        return Verdict(
            zone: .balanced,
            autoLevel: false,
            rule: "−22 ≤ LUFS ≤ −10.5 (no clipping)",
            summary: "Balanced loudness — skipped by Auto, available on demand."
        )
    }
}

/// Pure URL helper for Cobalt v10.1 `?audio=normal` share links.
public enum AudioShareURL {
    public static let queryName = "audio"
    public static let normalValue = "normal"

    /// Appends or replaces `audio=normal` on any share URL (`/<slug>`, `/p/<key>`, `/p/<key>/<n>.<ext>`, `/g/<id>`).
    public static func withNormalAudio(_ url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = comps.queryItems ?? []
        items.removeAll { $0.name == queryName }
        items.append(URLQueryItem(name: queryName, value: normalValue))
        comps.queryItems = items
        return comps.url ?? url
    }

    /// Removes `audio` query parameter from a share URL so it resolves to the untouched original.
    public static func withoutNormalAudio(_ url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        guard var items = comps.queryItems else { return url }
        items.removeAll { $0.name == queryName }
        comps.queryItems = items.isEmpty ? nil : items
        return comps.url ?? url
    }

    /// Returns true if the URL explicitly requests `?audio=normal`.
    public static func hasNormalAudio(_ url: URL) -> Bool {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems else { return false }
        return items.contains { $0.name == queryName && $0.value == normalValue }
    }

    /// Resolves the share URL to copy or display.
    /// When `useLeveled` is true AND a leveled alt is ready (`audio?.isLeveled == true`), appends `?audio=normal`.
    /// Otherwise strips any `audio` query param so the bare link stays untouched.
    public static func resolve(base: URL, audio: AudioLoudnessInfo?, useLeveled: Bool) -> URL {
        if useLeveled, audio?.isLeveled == true {
            return withNormalAudio(base)
        }
        return withoutNormalAudio(base)
    }
}

/// Unified LUFS ruler geometry over `[-32, 0]` LUFS used across Studio Deck, Settings, and badges.
public enum AudioRulerScale {
    public static let minLufs: Double = -32.0
    public static let maxLufs: Double = 0.0
    public static let quietUpper: Double = -22.0
    public static let clipLower: Double = -12.0
    public static let loudLower: Double = -10.5

    /// Normalizes a LUFS value into `0...1` across `[-32, 0]`.
    public static func fraction(for lufs: Double) -> Double {
        guard lufs.isFinite else { return 0 }
        let clamped = min(maxLufs, max(minLufs, lufs))
        return (clamped - minLufs) / (maxLufs - minLufs)
    }
}

extension Rendition {
    /// Audio loudness metadata for this rendition's server file (the original video file, or hosted copy).
    public var audio: AudioLoudnessInfo? {
        file?.audio ?? hosted?.audio
    }

    /// True when this rendition is a video that can have audio loudness measured/leveled.
    public var supportsAudioLeveling: Bool {
        switch kind {
        case .video:
            if let ct = file?.contentType?.lowercased(), ct.hasPrefix("image/") { return false }
            if let local, StoredMedia.isStill(local) { return false }
            return file != nil
        case .item(_, let type):
            return type == .video && file != nil
        case .slideshow(_, .mp4):
            return file != nil
        default:
            return false
        }
    }
}

extension MediaItem {
    /// Primary video loudness metadata for library badges and quick actions.
    public var primaryAudio: AudioLoudnessInfo? {
        if let a = video?.audio { return a }
        return items.compactMap(\.audio).first
    }

    /// Primary server file ID eligible for audio leveling (video original, or first video gallery item).
    public var primaryAudioFileID: String? {
        if let v = video, v.supportsAudioLeveling, let id = v.file?.id { return id }
        return items.first(where: { $0.supportsAudioLeveling })?.file?.id
    }
}
