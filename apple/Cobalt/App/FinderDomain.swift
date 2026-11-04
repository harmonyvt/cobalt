import CobaltKit
@preconcurrency import FileProvider
import Foundation

/// Adds and removes the Capystore Finder domain. The extension does the listing; this only registers
/// the domain, drops it on sign-out, and signals it after the app refreshes the library.
@MainActor
enum FinderDomain {
    static let domain = NSFileProviderDomain(
        identifier: NSFileProviderDomainIdentifier(FinderBridge.domainIdentifier),
        displayName: FinderBridge.displayName)

    /// The live model, so a sign-out on a nonisolated hook can reach it without capturing the class.
    private static var liveModel: AppModel?

    /// Hooks the live app. A preview (`managesFinderDomain` false) is left alone.
    static func install(_ model: AppModel) {
        guard model.managesFinderDomain else { return }
        liveModel = model
        model.finderSidebar = model.settings.finderSidebarEnabled
        FinderLibraryEvents.setRefreshHook { Self.signal() }
        FinderLibraryEvents.setSignOutHook { Self.signedOut() }
        Task { await reconcile(model) }
    }

    /// `forgetSession` runs this. The domain comes down and the switch turns off.
    nonisolated static func signedOut() {
        Task { @MainActor in
            guard let model = liveModel else { return }
            let wasOn = model.finderSidebar
            model.finderSidebar = false
            model.finderSidebarNote = nil
            // The group container is only opened once the sidebar has been on. Signing out of a
            // device that never used it must not raise the macOS app-group prompt.
            if wasOn { try? FinderBridge.publish(serverURL: model.settings.serverURL, enabled: false) }
            await remove()
        }
    }

    /// The switch in Settings. On publishes the server URL into the app group (the macOS prompt) and
    /// adds the domain. Off removes it. No key: the switch stays off.
    static func setEnabled(_ on: Bool, model: AppModel) async {
        guard model.settings.hasAPIKey else {
            model.finderSidebar = false
            model.settings.finderSidebarEnabled = false
            model.finderSidebarNote = Copy.Folder.finderNeedsSignIn
            return
        }
        model.finderSidebarNote = nil
        do {
            if on {
                try FinderBridge.publish(serverURL: model.settings.serverURL, enabled: true)
                try await add()
                model.settings.finderSidebarEnabled = true
                model.finderSidebar = true
                signal()
            } else {
                model.settings.finderSidebarEnabled = false
                model.finderSidebar = false
                try? FinderBridge.publish(serverURL: model.settings.serverURL, enabled: false)
                await remove()
            }
        } catch {
            model.settings.finderSidebarEnabled = false
            model.finderSidebar = false
            model.finderSidebarNote = Copy.Folder.finderFailed
            await remove()
        }
    }

    /// After launch: put the domain back if the switch is on and there is a key, otherwise take it down
    /// (a sign-out that happened while the app was closed, or a switch that is off).
    static func reconcile(_ model: AppModel) async {
        guard model.managesFinderDomain else { return }
        if model.finderSidebar && model.settings.hasAPIKey {
            do {
                try FinderBridge.publish(serverURL: model.settings.serverURL, enabled: true)
                try await add()
                model.finderSidebarNote = nil
            } catch {
                model.finderSidebar = false
                model.settings.finderSidebarEnabled = false
                model.finderSidebarNote = Copy.Folder.finderFailed
            }
        } else {
            if model.finderSidebar {
                model.finderSidebar = false
                model.settings.finderSidebarEnabled = false
            }
            await remove()
        }
    }

    nonisolated static func signal() {
        guard let manager = NSFileProviderManager(for: domain) else { return }
        manager.signalEnumerator(for: .rootContainer) { _ in }
        manager.signalEnumerator(for: .workingSet) { _ in }
    }

    private static func add() async throws {
        let existing = try await NSFileProviderManager.domains()
        if existing.contains(where: { $0.identifier == domain.identifier }) { return }
        try await NSFileProviderManager.add(domain)
    }

    private static func remove() async {
        do {
            let existing = try await NSFileProviderManager.domains()
            guard existing.contains(where: { $0.identifier == domain.identifier }) else { return }
            try await NSFileProviderManager.remove(domain)
        } catch {
            // already gone, or Finder has not loaded the extension yet
        }
    }
}
