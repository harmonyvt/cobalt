#if os(iOS)
import CobaltKit
import SwiftUI

// What the iPhone's four tabs show and where they are (apple 04-PHASE4 4.1).
//
// `AppModel.selectedTab` is the app's one answer to "which screen is in front", and screens read it (the studio stops its
// polling, the library locks the hidden album, the home screen takes pastes). On the iPad and the Mac a tab is a screen, so
// the answer was the tab. On the iPhone four tabs hold twelve screens, so the answer is worked out here: `PhoneNavState.active`
// is the screen that is really showing, and `PhoneTabs` writes it into `selectedTab` whenever it changes (a segment, a
// pushed row, a pop, a tab). Anything that writes `selectedTab` (a deep link, a paste, a launch argument) is read the other
// way: `show(_:)` moves the tabs to that screen.

/// The four tabs.
enum PhoneSlot: String, Hashable, CaseIterable, Sendable {
    case capture, library, live, tools

    var title: String {
        switch self {
        case .capture: return Copy.PhoneNav.capture
        case .library: return Copy.PhoneNav.library
        case .live: return Copy.PhoneNav.live
        case .tools: return Copy.PhoneNav.tools
        }
    }

    var symbol: String {
        switch self {
        case .capture: return Symbol.PhoneNav.capture
        case .library: return Symbol.PhoneNav.library
        case .live: return Symbol.PhoneNav.live
        case .tools: return Symbol.PhoneNav.tools
        }
    }
}

/// The live tab's parts: the OBS stage (first), the twitch watch and the 7tv emotes.
enum LiveSegment: String, Hashable, CaseIterable, Sendable {
    case stage, twitch, sevenTv

    var tab: AppTab {
        switch self {
        case .stage: return .stage
        case .twitch: return .twitch
        case .sevenTv: return .sevenTv
        }
    }

    init?(tab: AppTab) {
        switch tab {
        case .stage: self = .stage
        case .twitch: self = .twitch
        case .sevenTv: self = .sevenTv
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .stage: return Copy.PhoneNav.liveStage
        case .twitch: return Copy.PhoneNav.liveTwitch
        case .sevenTv: return Copy.PhoneNav.liveSevenTv
        }
    }
}

/// The two halves of the tools row "chat & swarms".
enum AssistantSegment: String, Hashable, CaseIterable, Sendable {
    case chat, swarms

    var tab: AppTab { self == .chat ? .chat : .swarms }
}

/// What a row of the tools list pushes. The stack's path is these, so a pop is a change of `path` and `active` follows it.
enum ToolsDestination: String, Hashable, CaseIterable, Sendable {
    case links, assistants, editor, booru, names

    /// Whether this server (and this device) has the screen.
    @MainActor
    func isAvailable(_ model: AppModel) -> Bool {
        switch self {
        case .links: return AppTab.links.isAvailable(with: model.capabilities)
        case .assistants: return AppTab.chat.isAvailable(with: model.capabilities) || AppTab.swarms.isAvailable(with: model.capabilities)
        case .editor: return model.editor.isAvailable
        case .booru: return AppTab.booru.isAvailable(with: model.capabilities)
        case .names: return AppTab.names.isAvailable(with: model.capabilities)
        }
    }
}

@MainActor
@Observable
final class PhoneNavState {
    var slot: PhoneSlot = .capture
    /// The part of the live tab that was last open; kept across launches.
    var live: LiveSegment { didSet { Self.defaults.set(live.rawValue, forKey: Self.liveKey) } }
    /// The half of "chat & swarms" that was last open; kept across launches.
    var assistants: AssistantSegment { didSet { Self.defaults.set(assistants.rawValue, forKey: Self.assistantsKey) } }
    /// What the tools tab has pushed, in order (empty: the list).
    var path: [ToolsDestination] = []
    /// The settings sheet (the gear in every root tab's bar).
    var settingsShown = false

    private static let defaults = UserDefaults.standard
    private static let liveKey = "phone.live.segment"
    private static let assistantsKey = "phone.tools.assistants"

    init() {
        live = Self.defaults.string(forKey: Self.liveKey).flatMap(LiveSegment.init(rawValue:)) ?? .stage
        assistants = Self.defaults.string(forKey: Self.assistantsKey).flatMap(AssistantSegment.init(rawValue:)) ?? .chat
    }

    /// The screen that is showing, as `selectedTab` says it: the tab's own screen, the live segment, or what the tools tab
    /// has on top (the tools list itself is `.tools`).
    var active: AppTab {
        switch slot {
        case .capture: return .save
        case .library: return .library
        case .live: return live.tab
        case .tools:
            switch path.last {
            case nil: return .tools
            case .links: return .links
            case .assistants: return assistants.tab
            case .editor: return .tools
            case .booru: return .booru
            case .names: return .names
            }
        }
    }

    /// Moves the tabs to the screen `tab` names (something wrote `selectedTab`). Settings is a sheet here, not a tab: it opens
    /// over whatever shows. The queue is left to `QueueTabRedirect` (it opens the activity sheet and selects capture).
    func show(_ tab: AppTab) {
        switch tab {
        case .save: slot = .capture
        case .library: slot = .library
        case .stage, .twitch, .sevenTv:
            slot = .live
            if let segment = LiveSegment(tab: tab) { live = segment }
        case .links: push(.links)
        case .chat: assistants = .chat; push(.assistants)
        case .swarms: assistants = .swarms; push(.assistants)
        case .booru: push(.booru)
        case .names: push(.names)
        case .tools:
            slot = .tools
            if !path.isEmpty { path = [] }
        case .settings: settingsShown = true
        case .queue: break
        }
    }

    private func push(_ destination: ToolsDestination) {
        slot = .tools
        if path != [destination] { path = [destination] }
    }

    /// The tabs this server has. Capture is always there; the library needs `features.library`, live needs the stage,
    /// tools needs at least one of its screens.
    static func slots(for model: AppModel) -> [PhoneSlot] {
        var slots: [PhoneSlot] = [.capture]
        if AppTab.library.isAvailable(with: model.capabilities) { slots.append(.library) }
        if AppTab.stage.isAvailable(with: model.capabilities) { slots.append(.live) }
        if ToolsDestination.allCases.contains(where: { $0.isAvailable(model) }) { slots.append(.tools) }
        return slots
    }

    /// A tab the server lost (the capabilities changed under it) falls back to capture; a pushed screen it lost goes back to the list.
    func settle(with model: AppModel) {
        if !Self.slots(for: model).contains(slot) { slot = .capture }
        if slot == .tools, let top = path.last, !top.isAvailable(model) { path = [] }
    }
}
#endif
