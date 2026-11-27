import Foundation
import Observation

// Phase 4 Combined Twitch Chat coordinator + Opus's Foolproof Dual-Target Composer state machine.
// Coordinates 1 or 2 `TwitchChatEngine` actors on `@MainActor`, merges incoming snapshots in strict
// monotonic live arrival order (zero scroll-back jitter), assigns deterministic channel accents
// (Stream A sky blue, Stream B rose), shifts colliding Twitch username hues, and enforces
// reply > filter > focus composer target locking.

/// Which channel(s) are visible in the chat scroll view.
public enum TwitchChatChannelFilter: Sendable, Hashable {
    case all
    case channel(String)

    public var channelLogin: String? {
        if case .channel(let login) = self { return login }
        return nil
    }
}

/// Which channel(s) the composer sends messages to.
/// `.both` is ONLY reachable via explicit selection inside the composer channel menu (never automatic).
public enum TwitchChatSendTarget: Sendable, Hashable {
    case channel(String)
    case both

    public var isBoth: Bool {
        if case .both = self { return true }
        return false
    }

    public var channelLogin: String? {
        if case .channel(let login) = self { return login }
        return nil
    }
}

/// Slot index for deterministic channel accent assignment in multi-stream mode (1...4 channels).
public enum TwitchChannelSlot: Int, Sendable, Hashable, CaseIterable, Comparable {
    case primary = 0
    case secondary = 1
    case tertiary = 2
    case quaternary = 3

    public static func < (lhs: TwitchChannelSlot, rhs: TwitchChannelSlot) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var fallbackMark: String {
        switch self {
        case .primary: "A"
        case .secondary: "B"
        case .tertiary: "C"
        case .quaternary: "D"
        }
    }
}

/// Deterministic channel visual identity for combined chat (left stripe, compact 1–2 letter mark, filter chip).
public struct TwitchChannelAccent: Sendable, Hashable {
    /// Stream A: Sky Blue (~199°).
    public static let primaryDarkRGB: UInt32 = 0x38BDF8
    public static let primaryLightRGB: UInt32 = 0x0284C7
    /// Stream B: Rose (~351°).
    public static let secondaryDarkRGB: UInt32 = 0xFB7185
    public static let secondaryLightRGB: UInt32 = 0xE11D48
    /// Stream C: Amber (~43°).
    public static let tertiaryDarkRGB: UInt32 = 0xFBBF24
    public static let tertiaryLightRGB: UInt32 = 0xD97706
    /// Stream D: Mint (~142°).
    public static let quaternaryDarkRGB: UInt32 = 0x4ADE80
    public static let quaternaryLightRGB: UInt32 = 0x16A34A

    public var slot: TwitchChannelSlot
    public var channel: String
    public var displayName: String
    /// Compact 1-letter (or 2-letter when initials collide) channel mark badge drawn inline on combined chat rows.
    public var mark: String
    public var darkRGB: UInt32
    public var lightRGB: UInt32
    /// HSL hue in `0..<360` used for username color collision avoidance.
    public var hueDegrees: Double

    public init(slot: TwitchChannelSlot, channel: String, displayName: String? = nil, markOverride: String? = nil) {
        let lower = channel.lowercased()
        let shown = (displayName?.isEmpty == false ? displayName! : lower)
        self.slot = slot
        self.channel = lower
        self.displayName = shown
        if let markOverride, !markOverride.isEmpty {
            self.mark = markOverride
        } else {
            let firstAlnum = shown.first(where: { $0.isLetter || $0.isNumber })
            self.mark = firstAlnum.map { String($0).uppercased() } ?? slot.fallbackMark
        }
        switch slot {
        case .primary:
            self.darkRGB = Self.primaryDarkRGB
            self.lightRGB = Self.primaryLightRGB
        case .secondary:
            self.darkRGB = Self.secondaryDarkRGB
            self.lightRGB = Self.secondaryLightRGB
        case .tertiary:
            self.darkRGB = Self.tertiaryDarkRGB
            self.lightRGB = Self.tertiaryLightRGB
        case .quaternary:
            self.darkRGB = Self.quaternaryDarkRGB
            self.lightRGB = Self.quaternaryLightRGB
        }
        self.hueDegrees = TwitchUsernameColorShifter.rgbToHSL(self.darkRGB).h
    }

    /// Resolves accents for 1...4 active channels, keeping crisp 1-letter marks unless two active channels share
    /// the same leading initial (e.g. `shroud` & `summit1g` -> `SH` & `SU`).
    public static func resolvedAccents(
        for channels: [String],
        displayNames: [String: String] = [:]
    ) -> [String: TwitchChannelAccent] {
        var initialCounts: [String: Int] = [:]
        var shownByChannel: [String: String] = [:]
        var baseMarkByChannel: [String: String] = [:]

        for (idx, ch) in channels.prefix(TwitchChannelSlot.allCases.count).enumerated() {
            let slot = TwitchChannelSlot(rawValue: idx) ?? .quaternary
            let rawDisplay = displayNames[ch] ?? displayNames[ch.lowercased()]
            let shown = (rawDisplay?.isEmpty == false ? rawDisplay! : ch)
            shownByChannel[ch] = shown
            let alnums = shown.filter { $0.isLetter || $0.isNumber }
            let single = alnums.first.map { String($0).uppercased() } ?? slot.fallbackMark
            baseMarkByChannel[ch] = single
            initialCounts[single, default: 0] += 1
        }

        var result: [String: TwitchChannelAccent] = [:]
        for (idx, ch) in channels.prefix(TwitchChannelSlot.allCases.count).enumerated() {
            let slot = TwitchChannelSlot(rawValue: idx) ?? .quaternary
            let shown = shownByChannel[ch] ?? ch
            let single = baseMarkByChannel[ch] ?? slot.fallbackMark
            let mark: String
            if (initialCounts[single] ?? 0) > 1 {
                let alnums = shown.filter { $0.isLetter || $0.isNumber }
                let two = String(alnums.prefix(2)).uppercased()
                mark = two.isEmpty ? slot.fallbackMark : two
            } else {
                mark = single
            }
            result[ch] = TwitchChannelAccent(slot: slot, channel: ch, displayName: shown, markOverride: mark)
        }
        return result
    }
}

/// Shifts Twitch username RGB colors when their hue lands too close to the active channel accent hues
/// (Stream A sky blue / Stream B rose), so usernames never visually blur into channel attribution badges.
public enum TwitchUsernameColorShifter {
    /// Twitch's default username palette for chatters without a custom color.
    public static let defaultTwitchColors: [UInt32] = [
        0xFF0000, 0x0000FF, 0x008000, 0xB22222, 0xFF7F50, 0x9ACD32, 0xFF4500, 0x2E8B57,
        0xDAA520, 0xD2691E, 0x5F9EA0, 0x1E90FF, 0xFF69B4, 0x8A2BE2, 0x00FF7F,
    ]

    /// Deterministic fallback Twitch RGB for a login that has no `color` tag.
    public static func defaultTwitchColor(for login: String) -> UInt32 {
        let sum = login.unicodeScalars.reduce(UInt32(0)) { $0 &+ $1.value }
        return defaultTwitchColors[Int(sum % UInt32(defaultTwitchColors.count))]
    }

    /// Shortest circular angular distance in degrees (`0...180`) between two hues.
    public static func circularHueDistance(_ a: Double, _ b: Double) -> Double {
        let diff = abs(normalizeHue(a) - normalizeHue(b))
        return min(diff, 360 - diff)
    }

    /// Returns `rgb` shifted away from any hue in `accentHues` within `threshold` degrees, preserving saturation
    /// and lightness. Nearly-neutral colors (`s < 0.15`) and non-colliding hues are returned unchanged.
    public static func shiftedIfColliding(
        _ rgb: UInt32,
        avoiding accentHues: [Double],
        threshold: Double = 24,
        safeDistance: Double = 32
    ) -> UInt32 {
        guard !accentHues.isEmpty else { return rgb }
        let hsl = rgbToHSL(rgb)
        // Low-saturation / gray colors never read as the sky-blue or rose channel accents.
        guard hsl.s >= 0.15 else { return rgb }

        let normalizedAccents = accentHues.map(normalizeHue)
        guard let nearest = normalizedAccents.min(by: { circularHueDistance(hsl.h, $0) < circularHueDistance(hsl.h, $1) }),
              circularHueDistance(hsl.h, nearest) < threshold
        else {
            return rgb
        }

        let delta = signedHueDelta(from: nearest, to: hsl.h)
        let preferredSign: Double = delta < 0 ? -1 : 1
        let primaryCandidate = normalizeHue(nearest + preferredSign * safeDistance)
        let oppositeCandidate = normalizeHue(nearest - preferredSign * safeDistance)

        let primaryClearance = normalizedAccents.map { circularHueDistance(primaryCandidate, $0) }.min() ?? 180
        let oppositeClearance = normalizedAccents.map { circularHueDistance(oppositeCandidate, $0) }.min() ?? 180
        let chosenHue = primaryClearance >= oppositeClearance ? primaryCandidate : oppositeCandidate

        return hslToRGB(h: chosenHue, s: hsl.s, l: hsl.l)
    }

    public static func rgbToHSL(_ rgb: UInt32) -> (h: Double, s: Double, l: Double) {
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >> 8) & 0xFF) / 255
        let b = Double(rgb & 0xFF) / 255

        let maxC = max(r, max(g, b))
        let minC = min(r, min(g, b))
        let l = (maxC + minC) / 2
        let d = maxC - minC

        guard d > 1e-9 else { return (0, 0, l) }

        let s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
        var h: Double
        if maxC == r {
            h = (g - b) / d + (g < b ? 6 : 0)
        } else if maxC == g {
            h = (b - r) / d + 2
        } else {
            h = (r - g) / d + 4
        }
        h *= 60
        return (normalizeHue(h), max(0, min(1, s)), max(0, min(1, l)))
    }

    public static func hslToRGB(h: Double, s: Double, l: Double) -> UInt32 {
        let hue = normalizeHue(h) / 360
        let sat = max(0, min(1, s))
        let light = max(0, min(1, l))

        let r: Double
        let g: Double
        let b: Double
        if sat <= 1e-9 {
            r = light; g = light; b = light
        } else {
            let q = light < 0.5 ? light * (1 + sat) : light + sat - light * sat
            let p = 2 * light - q
            r = hueToRGB(p: p, q: q, t: hue + 1.0 / 3.0)
            g = hueToRGB(p: p, q: q, t: hue)
            b = hueToRGB(p: p, q: q, t: hue - 1.0 / 3.0)
        }

        let ri = UInt32((max(0, min(1, r)) * 255).rounded()) & 0xFF
        let gi = UInt32((max(0, min(1, g)) * 255).rounded()) & 0xFF
        let bi = UInt32((max(0, min(1, b)) * 255).rounded()) & 0xFF
        return (ri << 16) | (gi << 8) | bi
    }

    private static func normalizeHue(_ h: Double) -> Double {
        let mod = h.truncatingRemainder(dividingBy: 360)
        return mod < 0 ? mod + 360 : mod
    }

    /// Signed shortest angle in `(-180, 180]` from `a` to `b`.
    private static func signedHueDelta(from a: Double, to b: Double) -> Double {
        var d = normalizeHue(b) - normalizeHue(a)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }

    private static func hueToRGB(p: Double, q: Double, t: Double) -> Double {
        var tt = t
        if tt < 0 { tt += 1 }
        if tt > 1 { tt -= 1 }
        if tt < 1.0 / 6.0 { return p + (q - p) * 6 * tt }
        if tt < 1.0 / 2.0 { return q }
        if tt < 2.0 / 3.0 { return p + (q - p) * (2.0 / 3.0 - tt) * 6 }
        return p
    }
}

/// Coordinates 1...4 `TwitchChatEngine` actors on `@MainActor` with monotonic live arrival merging,
/// channel filtering, deterministic channel accents, and Opus's foolproof multi-target composer locking.
@MainActor @Observable
public final class TwitchCombinedChatModel {
    /// Maximum simultaneous channels supported in combined chat.
    public static let maxChannels = 4
    /// Maximum merged lines kept across active channels to bound memory.
    public static let combinedLineLimit = 400
    public static let recentEmotesMax = 24

    /// Active channels in slot order (1 in single-stream mode, 2...4 in dual/multi-stream mode; lowercased logins).
    public private(set) var channels: [String] = []
    /// Deterministic channel accent metadata keyed by lowercased login.
    public private(set) var accentsByChannel: [String: TwitchChannelAccent] = [:]
    /// The currently audio/visually focused stream login.
    public private(set) var focusedChannel: String?
    /// Active view filter (`All`, or a specific active `@channel`).
    public private(set) var filter: TwitchChatChannelFilter = .all
    /// Replied-to line (locks composer target to `replyTo.channel`).
    public private(set) var replyTo: TwitchChatLine?
    /// Active composer send target. Initialized once on keyboard open (`reply > filter > focus`),
    /// then changed ONLY via explicit menu selection (or tapping a line to reply).
    public private(set) var composerTarget: TwitchChatSendTarget = .channel("")
    /// True once composer target has been initialized for the current composer session / reply / menu override.
    public private(set) var composerTargetLocked = false

    /// Merged lines in strict monotonic live arrival order (never re-sorted by `tmi-sent-ts + delay`).
    public private(set) var allLines: [TwitchChatLine] = []
    /// Latest snapshot per channel login.
    public private(set) var channelSnapshots: [String: TwitchChatSnapshot] = [:]
    /// Latest emote list per channel login.
    public private(set) var channelEmotes: [String: TwitchEmoteList] = [:]
    /// Recently picked emotes across this session, newest first.
    public private(set) var recentEmotes: [ChatEmote] = []

    /// True when 2 or more distinct streams are active. When false, the UI shows zero multi-stream clutter.
    public var isDualChannel: Bool { channels.count >= 2 }
    /// Semantic alias for `isDualChannel` when 2...4 channels are active.
    public var isMultiChannel: Bool { channels.count >= 2 }

    /// Ordered accents for the active channels (`1...4` slots).
    public var orderedAccents: [TwitchChannelAccent] {
        channels.compactMap { accentsByChannel[$0] }
    }

    /// Protected accent hues for username hue-collision shifting (empty in single-stream mode).
    public var activeAccentHues: [Double] {
        isDualChannel ? orderedAccents.map(\.hueDegrees) : []
    }

    /// Lines visible under the active channel filter, preserving strict monotonic arrival order.
    /// When filtered to a single channel, reads that channel's own snapshot history so a busy companion
    /// stream can never evict the quieter stream's messages from the filtered view.
    public var visibleLines: [TwitchChatLine] {
        switch filter {
        case .all:
            return allLines
        case .channel(let ch):
            if let snapLines = channelSnapshots[ch]?.lines, !snapLines.isEmpty {
                return snapLines
            }
            return allLines.filter { $0.channel == ch }
        }
    }

    /// True when multi-stream mode is active, targeting a single channel, and that channel is NOT the focused stream.
    public var isTargetOutOfFocus: Bool {
        guard isDualChannel,
              case .channel(let target) = composerTarget,
              let focused = focusedChannel,
              !focused.isEmpty
        else { return false }
        return target != focused
    }

    /// Whether the currently selected composer target can send messages.
    public var canSendToTarget: Bool {
        switch composerTarget {
        case .channel(let ch):
            return channelSnapshots[ch]?.canSend == true
        case .both:
            return channels.contains { channelSnapshots[$0]?.canSend == true }
        }
    }

    /// Whether any active channel can send messages (controls tap-to-reply availability).
    public var canSendAny: Bool {
        channels.contains { channelSnapshots[$0]?.canSend == true }
    }

    /// Status summary for the header (follows active filter when filtered, else combined summary).
    public var headerStatus: TwitchChatStatus {
        if case .channel(let ch) = filter, let snap = channelSnapshots[ch] {
            return snap.status
        }
        let snaps = channels.compactMap { channelSnapshots[$0] }
        if snaps.isEmpty { return .connecting }
        if snaps.contains(where: { $0.canSend }) { return .joined(canSend: true) }
        if snaps.contains(where: { if case .joined = $0.status { return true }; return false }) {
            return .joined(canSend: false)
        }
        for s in snaps {
            if case .reconnecting = s.status { return s.status }
        }
        for s in snaps {
            if case .failed = s.status { return s.status }
        }
        return .connecting
    }

    /// Room state for the header (shown for the active single channel or active filtered channel).
    public var headerRoom: TwitchRoomState {
        if case .channel(let ch) = filter, let snap = channelSnapshots[ch] {
            return snap.room
        }
        if channels.count == 1, let first = channels.first, let snap = channelSnapshots[first] {
            return snap.room
        }
        return TwitchRoomState()
    }

    /// Emote list tailored to the current composer target (channel-specific when targeting 1 channel; merged for All).
    public var activeEmotes: TwitchEmoteList {
        switch composerTarget {
        case .channel(let ch):
            return channelEmotes[ch] ?? TwitchEmoteList()
        case .both:
            return mergedEmotesForBoth()
        }
    }

    /// Recent emotes usable for the current composer target.
    public var recentEmotesForActiveTarget: [ChatEmote] {
        guard !recentEmotes.isEmpty else { return [] }
        let list = activeEmotes
        var usable = Set<String>()
        for section in list.sections {
            for e in section.emotes where !section.locked.contains(e.id) { usable.insert(e.id) }
        }
        if usable.isEmpty {
            for e in list.emotes { usable.insert(e.id) }
        }
        return recentEmotes.filter { usable.contains($0.id) }
    }

    // MARK: - private engine / merge bookkeeping

    @ObservationIgnored private let assetCache: TwitchChatAssetCache
    @ObservationIgnored private let sendLimiter: TwitchChatSendLimiter
    @ObservationIgnored private var engines: [String: TwitchChatEngine] = [:]
    @ObservationIgnored private var listeners: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var emotesVersions: [String: Int] = [:]
    /// Per-channel set of already-seen line IDs so an evicted line from a slower channel is never re-appended.
    @ObservationIgnored private var knownIDsByChannel: [String: Set<String>] = [:]
    /// Monotonic arrival sequence counter for deterministic arrival ordering.
    @ObservationIgnored private var arrivalSequence: UInt64 = 0
    /// True while the composer keyboard or emote picker is actively open.
    @ObservationIgnored private var isComposerOpen = false
    /// True after an explicit channel/both pick from the composer target menu until overridden by a filter pick or reply.
    @ObservationIgnored private var hasExplicitTargetSelection = false

    public init(
        assetCache: TwitchChatAssetCache = .shared,
        sendLimiter: TwitchChatSendLimiter = .shared
    ) {
        self.assetCache = assetCache
        self.sendLimiter = sendLimiter
    }

    // MARK: - channel & engine lifecycle

    /// Configures 1...4 active channels, reusing any already-running engine for channels that remain open.
    public func configure(
        channels rawChannels: [String],
        displayNames: [String: String] = [:],
        credentials: TwitchCredentials?,
        focusedChannel rawFocused: String? = nil,
        session: URLSession = .shared
    ) {
        let normalized = normalizeChannels(rawChannels)
        let incomingSet = Set(normalized)

        // Stop engines for removed channels
        for existing in Array(engines.keys) where !incomingSet.contains(existing) {
            listeners[existing]?.cancel()
            listeners[existing] = nil
            if let engine = engines.removeValue(forKey: existing) {
                Task { await engine.stop() }
            }
            channelSnapshots[existing] = nil
            channelEmotes[existing] = nil
            emotesVersions[existing] = nil
            knownIDsByChannel[existing] = nil
        }

        // Start engines for newly added channels, sharing assetCache & sendLimiter
        for ch in normalized where engines[ch] == nil {
            let engine = TwitchChatEngine(
                channel: ch,
                credentials: credentials,
                session: session,
                assetCache: assetCache,
                sendLimiter: sendLimiter)
            engines[ch] = engine
            startListening(to: engine, channel: ch)
            Task { await engine.start() }
        }

        applyChannelLayout(normalized: normalized, displayNames: displayNames, focusedChannel: rawFocused)
    }

    /// Attaches pre-constructed `TwitchChatEngine` instances (useful for testing or custom wiring).
    public func attachEngines(
        _ newEngines: [TwitchChatEngine],
        displayNames: [String: String] = [:],
        focusedChannel rawFocused: String? = nil,
        autoStart: Bool = false
    ) {
        stop()
        var ordered: [String] = []
        for engine in newEngines.prefix(Self.maxChannels) {
            let ch = engine.channelName.lowercased()
            guard !ch.isEmpty, !ordered.contains(ch) else { continue }
            ordered.append(ch)
            engines[ch] = engine
            startListening(to: engine, channel: ch)
            if autoStart {
                Task { await engine.start() }
            }
        }
        applyChannelLayout(normalized: ordered, displayNames: displayNames, focusedChannel: rawFocused)
    }

    /// Configures channel metadata without starting live sockets (useful for pure snapshot-driven previews/tests).
    public func configureChannelsWithoutEngines(
        _ rawChannels: [String],
        displayNames: [String: String] = [:],
        focusedChannel rawFocused: String? = nil
    ) {
        let normalized = normalizeChannels(rawChannels)
        applyChannelLayout(normalized: normalized, displayNames: displayNames, focusedChannel: rawFocused)
    }

    public func stop() {
        for task in listeners.values { task.cancel() }
        listeners.removeAll()
        let toStop = Array(engines.values)
        engines.removeAll()
        for engine in toStop {
            Task { await engine.stop() }
        }
        channels = []
        accentsByChannel = [:]
        focusedChannel = nil
        filter = .all
        replyTo = nil
        composerTarget = .channel("")
        composerTargetLocked = false
        isComposerOpen = false
        hasExplicitTargetSelection = false
        allLines = []
        channelSnapshots = [:]
        channelEmotes = [:]
        emotesVersions = [:]
        knownIDsByChannel = [:]
    }

    private func startListening(to engine: TwitchChatEngine, channel: String) {
        listeners[channel]?.cancel()
        listeners[channel] = Task { [weak self] in
            for await snap in engine.snapshots {
                guard let self else { return }
                self.ingest(snap)
                if snap.emotesVersion != self.emotesVersions[channel] {
                    self.emotesVersions[channel] = snap.emotesVersion
                    let list = await engine.emotes()
                    if list != self.channelEmotes[channel] {
                        self.channelEmotes[channel] = list
                    }
                }
            }
        }
    }

    private func applyChannelLayout(
        normalized: [String],
        displayNames: [String: String],
        focusedChannel rawFocused: String?
    ) {
        let normalizedSet = Set(normalized)
        channels = normalized

        var mergedNames: [String: String] = [:]
        for ch in normalized {
            if let existing = accentsByChannel[ch]?.displayName, !existing.isEmpty {
                mergedNames[ch] = existing
            }
            if let incoming = displayNames[ch] ?? displayNames[ch.lowercased()], !incoming.isEmpty {
                mergedNames[ch] = incoming
            }
        }
        accentsByChannel = TwitchChannelAccent.resolvedAccents(for: normalized, displayNames: mergedNames)

        // Drop lines from removed channels
        if allLines.contains(where: { !normalizedSet.contains($0.channel) }) {
            allLines.removeAll { !normalizedSet.contains($0.channel) }
        }

        // Revalidate focus
        let nextFocused = rawFocused?.lowercased()
        if let nextFocused, normalizedSet.contains(nextFocused) {
            focusedChannel = nextFocused
        } else if let current = focusedChannel, normalizedSet.contains(current) {
            focusedChannel = current
        } else {
            focusedChannel = normalized.first
        }

        // Revalidate filter
        if case .channel(let filtered) = filter, !normalizedSet.contains(filtered) {
            filter = .all
        }
        if !isDualChannel {
            filter = .all
        }

        // Revalidate replyTo
        if let reply = replyTo, !normalizedSet.contains(reply.channel) {
            replyTo = nil
        }

        // Revalidate composerTarget if its channel was removed or dropped from dual/multi to single
        switch composerTarget {
        case .both:
            if !isDualChannel {
                composerTargetLocked = false
                hasExplicitTargetSelection = false
                composerTarget = resolvedInitialTarget()
            }
        case .channel(let ch):
            if !normalizedSet.contains(ch) {
                composerTargetLocked = false
                hasExplicitTargetSelection = false
                composerTarget = resolvedInitialTarget()
            } else if !composerTargetLocked && !hasExplicitTargetSelection {
                composerTarget = resolvedInitialTarget()
            }
        }
    }

    private func normalizeChannels(_ raw: [String]) -> [String] {
        var out: [String] = []
        for ch in raw {
            let lower = ch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !lower.isEmpty, !out.contains(lower) else { continue }
            out.append(lower)
            if out.count == Self.maxChannels { break }
        }
        return out
    }

    // MARK: - monotonic live arrival merging

    /// Merges a channel's snapshot into the combined feed in strict monotonic live arrival order.
    /// Existing lines update in place (moderation deletes, backfilled badges, late 7TV emotes) without moving.
    public func ingest(_ snapshot: TwitchChatSnapshot) {
        let ch = snapshot.channel.lowercased()
        guard !ch.isEmpty else { return }
        if !channels.contains(ch), channels.count < Self.maxChannels {
            configureChannelsWithoutEngines(channels + [ch], focusedChannel: focusedChannel)
        }
        var normalizedSnapshot = snapshot
        if normalizedSnapshot.lines.contains(where: { $0.channel.isEmpty }) {
            normalizedSnapshot.lines = normalizedSnapshot.lines.map { raw in
                guard raw.channel.isEmpty else { return raw }
                var copy = raw
                copy.channel = ch
                return copy
            }
        }
        let previousSnapshot = channelSnapshots[ch]
        if previousSnapshot != normalizedSnapshot {
            channelSnapshots[ch] = normalizedSnapshot
        } else if knownIDsByChannel[ch] != nil {
            // Identical snapshot already merged — zero main-thread churn.
            return
        }

        // If only cosmetics/status/room changed while the channel's lines are identical, skip the O(N) line merge.
        if let previousSnapshot, previousSnapshot.lines == normalizedSnapshot.lines, knownIDsByChannel[ch] != nil {
            return
        }

        var known = knownIDsByChannel[ch] ?? []
        var indexByID: [String: Int] = [:]
        indexByID.reserveCapacity(allLines.count)
        for (idx, line) in allLines.enumerated() where line.channel == ch {
            indexByID[line.id] = idx
        }

        var updated = allLines
        var linesChanged = false
        var trimmed = false

        for line in normalizedSnapshot.lines {
            if let existingIdx = indexByID[line.id] {
                if updated[existingIdx] != line {
                    updated[existingIdx] = line
                    linesChanged = true
                }
            } else if !known.contains(line.id) {
                known.insert(line.id)
                arrivalSequence &+= 1
                updated.append(line)
                linesChanged = true
            }
        }

        if updated.count > Self.combinedLineLimit {
            updated.removeFirst(updated.count - Self.combinedLineLimit)
            linesChanged = true
            trimmed = true
        }

        // Bound `known` to IDs still in either this channel's snapshot or the combined buffer so memory never grows unbounded.
        // Only allocate pruning sets when trimming occurred or `known` exceeds the buffer budget.
        if trimmed || known.count > Self.combinedLineLimit {
            let currentSnapIDs = Set(normalizedSnapshot.lines.map(\.id))
            let stillVisibleIDs = Set(updated.lazy.filter { $0.channel == ch }.map(\.id))
            known = known.filter { currentSnapIDs.contains($0) || stillVisibleIDs.contains($0) }
        }
        knownIDsByChannel[ch] = known

        if linesChanged {
            allLines = updated
        }
    }

    // MARK: - channel cosmetics & accents

    public func accent(for channel: String) -> TwitchChannelAccent? {
        accentsByChannel[channel.lowercased()]
    }

    public func paint(for line: TwitchChatLine) -> SevenTvPaint? {
        if let direct = channelSnapshots[line.channel]?.paints[line.login] { return direct }
        for ch in channels {
            if let p = channelSnapshots[ch]?.paints[line.login] { return p }
        }
        return nil
    }

    public func sevenTvBadge(for line: TwitchChatLine) -> ChatBadge? {
        if let direct = channelSnapshots[line.channel]?.sevenTvBadges[line.login] { return direct }
        for ch in channels {
            if let b = channelSnapshots[ch]?.sevenTvBadges[line.login] { return b }
        }
        return nil
    }

    /// Display name for a channel login (falling back to the login itself).
    public func displayName(for channel: String) -> String {
        let lower = channel.lowercased()
        return accentsByChannel[lower]?.displayName ?? lower
    }

    /// Updates cached display names for active channels without disturbing running sockets, messages, or composer state.
    public func updateDisplayNames(_ displayNames: [String: String]) {
        guard !channels.isEmpty, !displayNames.isEmpty else { return }
        var merged: [String: String] = [:]
        for ch in channels {
            if let existing = accentsByChannel[ch]?.displayName, !existing.isEmpty {
                merged[ch] = existing
            }
            if let raw = displayNames[ch] ?? displayNames[ch.lowercased()], !raw.isEmpty {
                merged[ch] = raw
            }
        }
        let next = TwitchChannelAccent.resolvedAccents(for: channels, displayNames: merged)
        if next != accentsByChannel {
            accentsByChannel = next
        }
    }

    // MARK: - focus, filter & Opus's Foolproof Composer Target Locking

    /// Updates which stream currently holds audio/visual focus.
    /// Does NOT disturb a locked composer target, an explicit menu selection, or an active reply.
    public func setFocusedChannel(_ channel: String?) {
        let lower = channel?.lowercased()
        guard lower != focusedChannel else { return }
        if let lower, !channels.contains(lower) { return }
        focusedChannel = lower
        if !composerTargetLocked, !hasExplicitTargetSelection, replyTo == nil {
            composerTarget = resolvedInitialTarget()
        }
    }

    /// Changes the visible channel filter (`All` / `@StreamA` / `@StreamB`).
    /// Peeking a filter NEVER silently corrupts an already-open reply or locked mid-type composer target;
    /// when idle (no open composer/draft and no active reply), switching the filter also switches the
    /// composer target and clears any earlier menu override.
    public func setFilter(_ next: TwitchChatChannelFilter) {
        let validated: TwitchChatChannelFilter
        switch next {
        case .all:
            validated = .all
        case .channel(let raw):
            let lower = raw.lowercased()
            validated = channels.contains(lower) ? .channel(lower) : .all
        }
        guard validated != filter else { return }
        filter = validated
        if !composerTargetLocked, replyTo == nil {
            hasExplicitTargetSelection = false
            composerTarget = resolvedInitialTarget()
        }
    }

    /// Computes the initial composer target following Opus's strict precedence:
    /// (1) replied-to message's channel -> (2) active filter channel -> (3) focused stream -> (4) primary channel.
    /// Never returns `.both` automatically.
    public func resolvedInitialTarget() -> TwitchChatSendTarget {
        if let reply = replyTo, !reply.channel.isEmpty, channels.contains(reply.channel) {
            return .channel(reply.channel)
        }
        if case .channel(let filtered) = filter, channels.contains(filtered) {
            return .channel(filtered)
        }
        if let focused = focusedChannel, channels.contains(focused) {
            return .channel(focused)
        }
        return .channel(channels.first ?? "")
    }

    /// Called when the composer keyboard opens. Initializes `composerTarget` ONCE using
    /// `reply > filter > focus` (preserving an explicit menu pick) and locks it so filter peeks or
    /// focus swaps never corrupt the target while typing.
    public func composerDidOpen() {
        isComposerOpen = true
        guard !composerTargetLocked else { return }
        if !hasExplicitTargetSelection {
            composerTarget = resolvedInitialTarget()
        }
        composerTargetLocked = true
    }

    /// Called when the composer keyboard closes. Unlocks target initialization ONLY when there is no
    /// in-progress draft and no active reply, and preserves any explicit target picked from the menu
    /// (so a SwiftUI `Menu` focus drop never snaps the target back).
    public func composerDidClose(hasDraft: Bool) {
        isComposerOpen = false
        guard !hasDraft, replyTo == nil else { return }
        composerTargetLocked = false
        if !hasExplicitTargetSelection {
            composerTarget = resolvedInitialTarget()
        }
    }

    /// Tapping a chat line to reply: stores `replyTo` and locks composer target to that line's channel.
    public func beginReply(to line: TwitchChatLine) {
        guard !line.deleted else { return }
        replyTo = line
        if !line.channel.isEmpty, channels.contains(line.channel) {
            composerTarget = .channel(line.channel)
            composerTargetLocked = true
            hasExplicitTargetSelection = false
        }
    }

    /// Cancels the active reply banner without disturbing an active mid-type target.
    public func cancelReply(composerOpen: Bool = false, hasDraft: Bool = false) {
        replyTo = nil
        if !composerOpen && !hasDraft {
            composerTargetLocked = false
            hasExplicitTargetSelection = false
            composerTarget = resolvedInitialTarget()
        }
    }

    /// Explicit target change from the composer's SwiftUI `Menu` (the ONLY way to select `.both` or switch mid-type).
    /// When currently filtered to a different single channel, switches the filter along with the target so the user
    /// immediately sees the chat they switched to; keeps `.all` combined view intact.
    public func selectSendTarget(_ target: TwitchChatSendTarget) {
        switch target {
        case .both:
            guard isDualChannel else { return }
            composerTarget = .both
            hasExplicitTargetSelection = true
            composerTargetLocked = isComposerOpen
            // Never attach a single-channel reply-parent-msg-id when broadcasting to Both.
            replyTo = nil
        case .channel(let raw):
            let lower = raw.lowercased()
            guard channels.contains(lower) else { return }
            composerTarget = .channel(lower)
            hasExplicitTargetSelection = true
            composerTargetLocked = isComposerOpen
            if case .channel(let filtered) = filter, filtered != lower {
                filter = .channel(lower)
            }
            if let reply = replyTo, reply.channel != lower {
                replyTo = nil
            }
        }
    }

    // MARK: - sending & emotes

    public func noteEmotePicked(_ emote: ChatEmote) {
        var list = recentEmotes.filter { $0.id != emote.id }
        list.insert(emote, at: 0)
        if list.count > Self.recentEmotesMax { list.removeLast(list.count - Self.recentEmotesMax) }
        recentEmotes = list
    }

    /// Sends `text` to the selected target channel (or both channels, staggered via shared `TwitchChatSendLimiter`).
    @discardableResult
    public func send(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        switch composerTarget {
        case .channel(let ch):
            guard let engine = engines[ch] else { return false }
            let replyID: String?
            if let reply = replyTo, reply.channel == ch, !reply.isSyntheticID {
                replyID = reply.id
            } else {
                replyID = nil
            }
            let ok = await engine.send(trimmed, replyTo: replyID)
            if ok { replyTo = nil }
            return ok

        case .both:
            var anyOK = false
            for ch in channels {
                guard let engine = engines[ch] else { continue }
                let sent = await engine.send(trimmed, replyTo: nil)
                if sent { anyOK = true }
            }
            if anyOK { replyTo = nil }
            return anyOK
        }
    }

    private func mergedEmotesForBoth() -> TwitchEmoteList {
        var emotes: [ChatEmote] = []
        var seenNames = Set<String>()
        var sectionsByKind: [TwitchEmoteSection.Kind: ([ChatEmote], Set<String>)] = [:]

        for ch in channels {
            guard let list = channelEmotes[ch] else { continue }
            for e in list.emotes where seenNames.insert(e.name).inserted {
                emotes.append(e)
            }
            for s in list.sections {
                var existing = sectionsByKind[s.kind] ?? ([], [])
                var seenIDs = Set(existing.0.map(\.id))
                for e in s.emotes where seenIDs.insert(e.id).inserted {
                    existing.0.append(e)
                }
                existing.1.formUnion(s.locked)
                sectionsByKind[s.kind] = existing
            }
        }

        let sections = TwitchEmoteSection.Kind.allCases.compactMap { kind -> TwitchEmoteSection? in
            guard let (items, locked) = sectionsByKind[kind], !items.isEmpty else { return nil }
            return TwitchEmoteSection(kind: kind, emotes: items, locked: locked)
        }
        return TwitchEmoteList(emotes: emotes, sections: sections)
    }
}
