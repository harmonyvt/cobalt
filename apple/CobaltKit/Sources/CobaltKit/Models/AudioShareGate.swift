import Foundation

/// One item evaluated by `AudioShareGate` when determining whether a share link or multi-select pick
/// is allowed to expose or copy `?audio=normal`.
public struct AudioGateItem: Sendable, Equatable, Identifiable {
    public var id: String
    /// True when the item represents a video (non-video items like photos/WebPs/GIFs never block `?audio=normal`).
    public var isVideo: Bool
    /// Known loudness metadata for this file, if any. For a video, `nil` conservatively blocks `?audio=normal`.
    public var audio: AudioLoudnessInfo?

    public init(id: String, isVideo: Bool, audio: AudioLoudnessInfo? = nil) {
        self.id = id
        self.isVideo = isVideo
        self.audio = audio
    }
}

/// Deterministic, strictly enforced gate for `?audio=normal` on multi-item share links and Library multi-select.
///
/// Hard gate rules:
/// - Non-video items (images, WebPs, GIFs, generic files) NEVER block `?audio=normal`.
/// - Silent videos (`audio?.isSilent == true`, i.e., `<= -60 LUFS`) NEVER block `?audio=normal`.
/// - Every audible video MUST have a ready leveled alternate (`audio?.isLeveled == true`).
/// - Unknown loudness on a video (`audio == nil`, `.pending`, `.measured`, `.rendering`, `.failed`) CONSERVATIVELY BLOCKS.
/// - When there are 0 audible videos, status is `.notApplicable` (original link stays shareable; `?audio=normal` is N/A).
/// - `resolveURL(base:useNormal:)` MUST NEVER append `?audio=normal` unless `status == .unlocked && useNormal`.
public struct AudioShareGate: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        /// Every audible video is leveled (and there is at least one audible video): `?audio=normal` is unlocked.
        case unlocked
        /// At least one audible video is not yet leveled: `?audio=normal` is strictly blocked.
        case blocked
        /// No audible videos in this selection/set (only images/WebPs/silent videos): `?audio=normal` is N/A.
        case notApplicable
    }

    public let status: Status
    public let totalItems: Int
    public let audibleVideoCount: Int
    public let leveledCount: Int
    public let renderingCount: Int
    public let failedCount: Int
    public let loudCount: Int
    public let quietCount: Int
    public let balancedUnleveledCount: Int
    public let unmeasuredCount: Int
    public let silentVideoCount: Int
    public let nonVideoCount: Int

    /// Ordered, deduplicated file IDs of every audible video that is not yet leveled.
    public let unleveledVideoIDs: [String]
    /// Ordered, deduplicated file IDs that can be queued right now (unleveled, not currently rendering or in-flight).
    public let queueableVideoIDs: [String]

    public init(items: [AudioGateItem], inFlight: Set<String> = []) {
        var total = 0
        var audible = 0
        var leveled = 0
        var rendering = 0
        var failed = 0
        var loud = 0
        var quiet = 0
        var balancedUnleveled = 0
        var unmeasured = 0
        var silent = 0
        var nonVideo = 0
        var unleveledIDs: [String] = []
        var queueableIDs: [String] = []
        var seenUnleveled = Set<String>()
        var seenQueueable = Set<String>()

        for item in items {
            total += 1
            guard item.isVideo else {
                nonVideo += 1
                continue
            }
            if item.audio?.isSilent == true {
                silent += 1
                continue
            }

            audible += 1
            let audio = item.audio
            let activelyRendering = (audio?.isRendering == true) || inFlight.contains(item.id)

            if audio?.isLeveled == true {
                leveled += 1
                continue
            }

            if seenUnleveled.insert(item.id).inserted {
                unleveledIDs.append(item.id)
            }

            if activelyRendering {
                rendering += 1
            } else {
                if seenQueueable.insert(item.id).inserted {
                    queueableIDs.append(item.id)
                }
                if audio?.state == .failed {
                    failed += 1
                } else if let a = audio {
                    switch a.zone {
                    case .loud: loud += 1
                    case .quiet: quiet += 1
                    case .balanced: balancedUnleveled += 1
                    case .pending: unmeasured += 1
                    case .silent: break
                    }
                } else {
                    unmeasured += 1
                }
            }
        }

        self.totalItems = total
        self.audibleVideoCount = audible
        self.leveledCount = leveled
        self.renderingCount = rendering
        self.failedCount = failed
        self.loudCount = loud
        self.quietCount = quiet
        self.balancedUnleveledCount = balancedUnleveled
        self.unmeasuredCount = unmeasured
        self.silentVideoCount = silent
        self.nonVideoCount = nonVideo
        self.unleveledVideoIDs = unleveledIDs
        self.queueableVideoIDs = queueableIDs

        if audible == 0 {
            self.status = .notApplicable
        } else if leveled == audible {
            self.status = .unlocked
        } else {
            self.status = .blocked
        }
    }

    /// Evaluates the live/shown items of a `ShareSet` (deleted/private/hidden items are excluded on the server page).
    public static func forShareSet(
        _ set: ShareSet,
        audioFor: (ShareSetItem) -> AudioLoudnessInfo? = { $0.audio },
        inFlight: Set<String> = []
    ) -> AudioShareGate {
        let shown = set.items.filter { $0.isPublic && !$0.hidden }
        let items = shown.map { item in
            AudioGateItem(id: item.id, isVideo: item.isVideo, audio: audioFor(item))
        }
        return AudioShareGate(items: items, inFlight: inFlight)
    }

    /// How many audible videos still lack a leveled alternate.
    public var unleveledCount: Int { max(0, audibleVideoCount - leveledCount) }

    /// True when `?audio=normal` is permitted.
    public var canShareNormalAudio: Bool { status == .unlocked }

    /// True while one or more audible videos in this set are actively leveling.
    public var isLeveling: Bool { renderingCount > 0 }

    /// Fraction of audible videos currently leveled (`0...1`). Returns `1` when there are no audible videos.
    public var progressFraction: Double {
        guard audibleVideoCount > 0 else { return 1 }
        return Double(leveledCount) / Double(audibleVideoCount)
    }

    /// Human-readable lowercase explanation when `status == .blocked`, or `nil` when unlocked / N/A.
    public var blockedReason: String? {
        guard status == .blocked else { return nil }
        if renderingCount > 0 && queueableVideoIDs.isEmpty {
            return renderingCount == 1
                ? "leveling 1 of \(audibleVideoCount) \(audibleVideoCount == 1 ? "video" : "videos")…"
                : "leveling \(renderingCount) of \(audibleVideoCount) videos…"
        }
        if failedCount > 0 && failedCount == unleveledCount {
            return failedCount == 1
                ? "1 video failed leveling · retry to unlock"
                : "\(failedCount) videos failed leveling · retry to unlock"
        }
        if audibleVideoCount == 1 {
            return "video isn't leveled yet"
        }
        return unleveledCount == 1
            ? "1 of \(audibleVideoCount) videos isn't leveled yet"
            : "\(unleveledCount) of \(audibleVideoCount) videos aren't leveled yet"
    }

    /// Strict hard gate: appends `?audio=normal` ONLY when `status == .unlocked && useNormal`.
    /// Otherwise strips any `audio` query parameter so the base link stays untouched.
    public func resolveURL(base: URL, useNormal: Bool) -> URL {
        guard status == .unlocked, useNormal else {
            return AudioShareURL.withoutNormalAudio(base)
        }
        return AudioShareURL.withNormalAudio(base)
    }
}
