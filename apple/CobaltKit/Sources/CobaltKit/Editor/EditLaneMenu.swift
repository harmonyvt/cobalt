import Foundation

// Which clip actions the equal-lane menu can offer, and why one is dimmed. The views supply the facts (a locked lane,
// the playhead, a v1 server). The words are the same short lines the session already toasts.

public enum LaneMenuAction: String, CaseIterable, Sendable {
    case effect
    case cutout
    case split
    case duplicate
    case hide
    case newLane
    case layerUp
    case layerDown
    case delete
}

public struct LaneMenuItem: Equatable, Sendable {
    public var action: LaneMenuAction
    public var enabled: Bool
    /// Why it is dimmed. Nil when the action can run.
    public var reason: String?

    public init(action: LaneMenuAction, enabled: Bool, reason: String? = nil) {
        self.action = action
        self.enabled = enabled
        self.reason = enabled ? nil : reason
    }
}

/// Everything the menu needs that is not the clip's own pixels.
public struct LaneMenuInput: Equatable, Sendable {
    public var savesV2: Bool
    public var lane: Int
    public var fromLocked: Bool
    public var upInRange: Bool
    public var downInRange: Bool
    public var upLocked: Bool
    public var downLocked: Bool
    public var upTaken: Bool
    public var downTaken: Bool
    public var canNewLane: Bool
    public var duplicateBlocked: Bool
    public var isVideo: Bool
    public var isPicture: Bool
    public var playheadInside: Bool

    public init(
        savesV2: Bool, lane: Int, fromLocked: Bool, upInRange: Bool, downInRange: Bool, upLocked: Bool, downLocked: Bool,
        upTaken: Bool, downTaken: Bool, canNewLane: Bool, duplicateBlocked: Bool, isVideo: Bool, isPicture: Bool,
        playheadInside: Bool
    ) {
        self.savesV2 = savesV2
        self.lane = lane
        self.fromLocked = fromLocked
        self.upInRange = upInRange
        self.downInRange = downInRange
        self.upLocked = upLocked
        self.downLocked = downLocked
        self.upTaken = upTaken
        self.downTaken = downTaken
        self.canNewLane = canNewLane
        self.duplicateBlocked = duplicateBlocked
        self.isVideo = isVideo
        self.isPicture = isPicture
        self.playheadInside = playheadInside
    }
}

public enum EditLaneMenu {
    public static let alreadyBottom = "already on the bottom lane"
    public static let playheadOutside = "the playhead isn't inside this clip"
    public static let pickVideo = "pick a video"
    public static let pickVideoOrPicture = "pick a video or a picture"

    /// The menu, top to bottom. A dimmed row still has its reason.
    public static func items(_ input: LaneMenuInput) -> [LaneMenuItem] {
        [
            item(.effect, input.isVideo, EditLaneMenu.pickVideo, locked: input),
            item(.cutout, input.isVideo || input.isPicture, EditLaneMenu.pickVideoOrPicture, locked: input),
            item(.split, input.playheadInside, EditLaneMenu.playheadOutside, locked: input),
            item(.duplicate, !input.duplicateBlocked, input.duplicateBlocked ? EditLanes.lanesFullMessage : nil, locked: input),
            hide(input),
            crossLane(.newLane, allowed: input.canNewLane, blocked: EditLanes.lanesFullMessage, input: input),
            crossLane(.layerUp, allowed: input.upInRange && !input.upTaken && !input.upLocked, blocked: upReason(input), input: input),
            crossLane(.layerDown, allowed: input.downInRange && !input.downTaken && !input.downLocked, blocked: downReason(input), input: input),
            item(.delete, true, nil, locked: input),
        ]
    }

    /// Lanes a VoiceOver "move to lane …" action can offer: every other drawn lane, skipping a locked one.
    /// Empty when this lane is locked or the server still saves version 1.
    public static func moveLanes(from lane: Int, count: Int, locked: Set<Int>, savesV2: Bool) -> [Int] {
        guard savesV2, count > 0, !locked.contains(lane) else { return [] }
        return (0..<count).filter { $0 != lane && !locked.contains($0) }
    }

    // MARK: rows

    private static func hide(_ input: LaneMenuInput) -> LaneMenuItem {
        if input.fromLocked { return LaneMenuItem(action: .hide, enabled: false, reason: EditLanes.laneLockedMessage) }
        // A hidden lane-0 clip cannot be written back to a version 1 server.
        if !input.savesV2, input.lane == 0 {
            return LaneMenuItem(action: .hide, enabled: false, reason: EditLanes.needsServerMessage)
        }
        return LaneMenuItem(action: .hide, enabled: true)
    }

    /// Up, down and a new lane change which lane a clip is on. A version 1 server is told no before the drag.
    private static func crossLane(
        _ action: LaneMenuAction, allowed: Bool, blocked: String, input: LaneMenuInput
    ) -> LaneMenuItem {
        if input.fromLocked { return LaneMenuItem(action: action, enabled: false, reason: EditLanes.laneLockedMessage) }
        if !input.savesV2 { return LaneMenuItem(action: action, enabled: false, reason: EditLanes.needsServerMessage) }
        return LaneMenuItem(action: action, enabled: allowed, reason: allowed ? nil : blocked)
    }

    private static func item(
        _ action: LaneMenuAction, _ allowed: Bool, _ reason: String?, locked input: LaneMenuInput
    ) -> LaneMenuItem {
        if input.fromLocked { return LaneMenuItem(action: action, enabled: false, reason: EditLanes.laneLockedMessage) }
        return LaneMenuItem(action: action, enabled: allowed, reason: allowed ? nil : reason)
    }

    private static func upReason(_ input: LaneMenuInput) -> String {
        if !input.upInRange { return EditLanes.lanesFullMessage }
        if input.upLocked { return EditLanes.laneLockedMessage }
        return EditLanes.spotTakenMessage
    }

    private static func downReason(_ input: LaneMenuInput) -> String {
        if !input.downInRange { return EditLaneMenu.alreadyBottom }
        if input.downLocked { return EditLanes.laneLockedMessage }
        return EditLanes.spotTakenMessage
    }
}
