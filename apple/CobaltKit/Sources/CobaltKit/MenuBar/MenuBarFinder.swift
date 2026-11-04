import Foundation
import Observation

/// The menu bar's "library in finder" line. Read-only: Finder can show the library, and a file
/// downloads when it is opened. Nothing here syncs a change from Finder back into the library.
///
/// `status` stays `.unavailable` (the section stays hidden) until the Mac app calls `connect`.
/// That wiring is `MenuBarFinderWiring`, next to `FinderDomain.install`. The domain and the app
/// group stay `FinderBridge`'s (`AppGroup.id`); this type does not name either.
public struct MenuBarFinderStatus: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case off
        /// The location is in the sidebar and nothing is being listed right now.
        case upToDate
        /// Finder is listing or fetching. `fraction` is 0...1 when a real total is known, else nil.
        case updating(fraction: Double?)
    }

    public var available: Bool
    public var enabled: Bool
    public var phase: Phase
    /// A problem line from the domain (`finderSidebarNote`), when there is one.
    public var note: String?

    public init(available: Bool, enabled: Bool, phase: Phase, note: String? = nil) {
        self.available = available
        self.enabled = enabled
        self.phase = phase
        self.note = note
    }

    public static let unavailable = MenuBarFinderStatus(available: false, enabled: false, phase: .off)
}

/// The menu bar reads this. The stub never connects, so the section stays hidden.
@MainActor @Observable
public final class MenuBarFinderModel {
    public private(set) var status: MenuBarFinderStatus = .unavailable

    @ObservationIgnored private var refresh: (@MainActor () -> MenuBarFinderStatus)?
    @ObservationIgnored private var apply: (@MainActor (Bool) async -> Void)?
    @ObservationIgnored private var reveal: (@MainActor () -> Void)?

    public init() {}

    /// The section draws only when a File Provider has connected.
    public var isAvailable: Bool { status.available }

    /// Replaces the stub. `refresh` is read immediately and again after every switch.
    public func connect(
        refresh: @escaping @MainActor () -> MenuBarFinderStatus,
        setEnabled: @escaping @MainActor (Bool) async -> Void,
        open: @escaping @MainActor () -> Void
    ) {
        self.refresh = refresh
        self.apply = setEnabled
        self.reveal = open
        reload()
    }

    public func reload() {
        if let refresh { status = refresh() }
    }

    public func setEnabled(_ on: Bool) async {
        // The domain add can take a moment. Say so before it returns; `reload` then reads the result.
        if status.available {
            status = MenuBarFinderStatus(
                available: true, enabled: status.enabled, phase: .updating(fraction: nil), note: status.note)
        }
        await apply?(on)
        reload()
    }

    public func openInFinder() {
        reveal?()
    }
}
