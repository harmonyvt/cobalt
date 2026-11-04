#if os(macOS)
import AppKit
import CobaltKit
import Foundation
@preconcurrency import FileProvider

/// The menu bar's read-only "library in finder" line, over the File Provider `FinderDomain` already
/// registers. The domain id is `FinderBridge.domainIdentifier` and the container is `AppGroup.id`
/// (`group.com.capybaraharmony.cobalt`); this does not introduce another group.
@MainActor
enum MenuBarFinderWiring {
    static func connect(_ model: AppModel) {
        guard model.managesFinderDomain else { return }
        model.menuBarFinder.connect(
            refresh: { status(of: model) },
            setEnabled: { on in await FinderDomain.setEnabled(on, model: model) },
            open: { openInFinder() })
    }

    /// Off when the sidebar switch is off. Updating while the library page is loading (a real fraction
    /// when "load everything" reports one) or while Finder has been signalled and has not answered.
    /// Otherwise the location is up to date. No byte count: the extension lists on its own.
    static func status(of model: AppModel) -> MenuBarFinderStatus {
        let on = model.finderSidebar
        let phase: MenuBarFinderStatus.Phase
        if !on {
            phase = .off
        } else if let progress = model.library.loadingAll, progress.total > 0 {
            phase = .updating(fraction: min(1, Double(progress.loaded) / Double(progress.total)))
        } else if model.library.isLoading || FinderDomain.isSignalling {
            phase = .updating(fraction: nil)
        } else {
            phase = .upToDate
        }
        return MenuBarFinderStatus(
            available: true, enabled: on, phase: phase, note: model.finderSidebarNote)
    }

    /// Opens the Capystore location itself, not its parent. No manager means the domain is not registered.
    static func openInFinder() {
        guard let manager = NSFileProviderManager(for: FinderDomain.domain) else { return }
        manager.getUserVisibleURL(for: .rootContainer) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                NSWorkspace.shared.open(url)
            }
        }
    }
}
#endif
