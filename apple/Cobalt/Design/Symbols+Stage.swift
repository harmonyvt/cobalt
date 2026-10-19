import SwiftUI

/// SF Symbols for the studio tab (APP-API-CONTRACT section 29): the tab, the spotlight bar, the pool, Twitch, the rewards, the
/// links. An extension of `Symbol` in its own file, compiled into the extensions too (`Cobalt/Design`). Every name exists since
/// SF Symbols 4, so it resolves on iOS 26 and macOS 26.
extension Symbol {
    /// The studio tab and its sidebar row.
    static let stage = "dot.radiowaves.left.and.right"
    /// "go live".
    static let stageGoLive = "play.fill"
    /// "stop".
    static let stageStop = "stop.fill"
    /// The preview while the stage is off air.
    static let stageOffAir = "moon.zzz"
    /// "copy obs link", "copy store link".
    static let stageCopy = "doc.on.doc"

    // MARK: the spotlight bar

    /// "pin" and "pinned".
    static let stagePin = "pin"
    static let stagePinned = "pin.fill"
    /// "skip".
    static let stageSkip = "forward.end"
    /// "pick": the pool sheet.
    static let stagePick = "square.grid.2x2"
    /// The bar's menu (shuffle, chaos).
    static let stageMore = "ellipsis.circle"
    /// "shuffle the canvas".
    static let stageShuffle = "shuffle"
    /// "chaos".
    static let stageChaos = "tornado"
    /// A summoned file's corner.
    static let stageSummon = "sparkle.magnifyingglass"
    /// A video in a pool tile.
    static let stagePlay = "play.fill"

    // MARK: the pool

    static let stagePoolCollection = "folder"
    static let stagePoolSet = "square.stack.3d.up"
    static let stagePoolSearch = "magnifyingglass"
    static let stagePoolLibrary = "photo.on.rectangle.angled"
    /// The picked collection or set in a menu.
    static let stageChosen = "checkmark"

    // MARK: Twitch

    static let stageTwitch = "person.crop.circle.badge.checkmark"
    static let stageTwitchWarn = "exclamationmark.triangle"
    static let stageConnect = "link.badge.plus"
    static let stageDisconnect = "xmark.circle"

    // MARK: rewards and the feed

    static let stageRewardSummon = "sparkle.magnifyingglass"
    static let stageRewardChaos = "tornado"
    static let stageRewardShuffle = "shuffle"
    static let stageRewardPin = "pin"
    /// A redemption that was refunded or failed.
    static let stageRefunded = "arrow.uturn.backward.circle"
    /// Twitch has not got a reward's latest values yet.
    static let stageUnsynced = "arrow.triangle.2.circlepath"

    // MARK: links

    /// "rotate" the obs link.
    static let stageRotate = "arrow.triangle.2.circlepath"
    static let stageLocked = "lock.fill"
    static let stageUnlocked = "lock.open"
}
