import AuthenticationServices
import CobaltKit
import Observation
import SwiftUI

// What the studio screen's parts share (APP-API-CONTRACT section 29.11): the buttons that call the store and say what came of
// it, the confirms (rotate, disconnect), the pick sheet and the reward editor. One controller per screen; the parts are small
// views that read the store (`model.stage`) and send taps here. `.stagePresentations(_:)` draws the confirms and sheets.

/// The three panels of the compact layout's segmented control.
enum StagePanel: String, CaseIterable, Identifiable {
    case rewards, feed, links

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rewards: return Copy.Stage.rewards
        case .feed: return Copy.Stage.feedTab
        case .links: return Copy.Stage.linksTab
        }
    }
}

@MainActor @Observable
final class StageController {
    /// What was copied last, so its button says "copied" for a moment.
    enum Copied: Equatable {
        case obs, store
    }

    let model: AppModel

    /// The compact layout's panel.
    var panel: StagePanel = .rewards
    /// The pick sheet (the pool's files, for the spotlight).
    var pickShown = false
    /// The rotate confirm and the disconnect confirm.
    var confirmingRotate = false
    var confirmingDisconnect = false
    /// The reward editor's sheet.
    var editingReward: StageRewardKind?
    /// What is in flight (a second tap does nothing): "air", "action", "pool", "sound", "rotate", "store", "reward-<name>".
    private(set) var busy: Set<String> = []
    /// The Twitch sign-in is open.
    private(set) var connecting = false
    private(set) var copied: Copied?
    /// +1 when a call lands (success haptic) or fails (error haptic).
    private(set) var doneTick = 0
    private(set) var failTick = 0

    @ObservationIgnored private var copiedToken = 0

    init(model: AppModel) {
        self.model = model
    }

    var store: StageStore { model.stage }

    func isBusy(_ key: String) -> Bool { busy.contains(key) }

    // MARK: running a call

    /// Runs `work` once at a time per `key`; a refusal becomes the shell's status line and the error haptic.
    private func run(_ key: String, shell: ShellActions, success: String? = nil, work: @escaping @MainActor () async throws -> Void) {
        guard !busy.contains(key) else { return }
        busy.insert(key)
        Task {
            defer { busy.remove(key) }
            do {
                try await work()
                if let success { shell.showStatus(success) }
                doneTick += 1
            } catch {
                shell.showStatus(Copy.Stage.message(for: error))
                failTick += 1
            }
        }
    }

    // MARK: header

    /// "go live" / "stop".
    func toggleAir(shell: ShellActions) {
        let next = !(store.stage?.onAir ?? false)
        run("air", shell: shell) { try await self.store.setOnAir(next) }
    }

    func copyObsLink(shell: ShellActions) {
        guard let url = store.stage?.liveURL else { return }
        Pasteboard.copy(url.absoluteString)
        shell.showStatus(Copy.Stage.obsCopied)
        markCopied(.obs)
    }

    func copyStoreLink(shell: ShellActions) {
        guard let url = store.stage?.storeURL else { return }
        Pasteboard.copy(url.absoluteString)
        shell.showStatus(Copy.Stage.linkCopied)
        markCopied(.store)
    }

    private func markCopied(_ what: Copied) {
        copied = what
        doneTick += 1
        copiedToken += 1
        let token = copiedToken
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if copiedToken == token { copied = nil }
        }
    }

    // MARK: the spotlight

    func perform(_ action: StageAction, shell: ShellActions) {
        run("action", shell: shell) { try await self.store.perform(action) }
    }

    /// "pin" while the spotlight is free, "pinned" (tap to let go) while it is held.
    func togglePin(pinned: Bool, shell: ShellActions) {
        perform(pinned ? .unpin : .pin, shell: shell)
    }

    func setSound(_ on: Bool, shell: ShellActions) {
        run("sound", shell: shell) { try await self.store.setSound(on) }
    }

    /// A file from the pick sheet goes up in the spotlight.
    func pickItem(_ item: StageItem, shell: ShellActions) {
        pickShown = false
        perform(.spotlight(itemID: item.id), shell: shell)
    }

    // MARK: the pool

    func choosePool(_ choice: StagePoolChoice, shell: ShellActions) {
        run("pool", shell: shell) { try await self.store.setPool(choice) }
    }

    func setSpotlightAuto(_ on: Bool, shell: ShellActions) {
        run("auto", shell: shell) { try await self.store.apply(StagePatch(spotlightAuto: on)) }
    }

    // MARK: links

    func rotate(shell: ShellActions) {
        run("rotate", shell: shell) {
            try await self.store.rotate()
            if let url = self.store.stage?.liveURL {
                Pasteboard.copy(url.absoluteString)
                shell.showStatus(Copy.Stage.rotated)
                self.markCopied(.obs)
            }
        }
    }

    func setStoreOpen(_ open: Bool, shell: ShellActions) {
        run("store", shell: shell) { try await self.store.setStoreOpen(open) }
    }

    // MARK: rewards

    func setReward(_ kind: StageRewardKind, enabled: Bool, shell: ShellActions) {
        run("reward-\(kind.rawValue)", shell: shell) { try await self.store.updateReward(kind, enabled: enabled) }
    }

    // MARK: Twitch

    /// The sign-in: the server's authorize URL in a web authentication session whose callback is `cobalt-apple://`. Whatever
    /// the session ends with (done, cancelled, failed) the stage is read again, so the card shows what Twitch did.
    func connectTwitch(using session: WebAuthenticationSession, shell: ShellActions) {
        guard !connecting else { return }
        connecting = true
        Task {
            defer { connecting = false }
            do {
                let authorize = try await store.connectTwitch()
                let callback = try await session.authenticate(using: authorize, callbackURLScheme: "cobalt-apple")
                await store.load()
                switch StageTwitchReturn(url: callback) {
                case .connected?:
                    shell.showStatus(Copy.Stage.connectedToast)
                    doneTick += 1
                case .failed(let reason)?:
                    shell.showStatus(Copy.Stage.connectFailed(reason: reason))
                    failTick += 1
                case nil:
                    break
                }
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                await store.load()                       // closed on purpose; it may have gone through anyway
            } catch {
                await store.load()
                shell.showStatus(Copy.Stage.message(for: error))
                failTick += 1
            }
        }
    }

    func disconnectTwitch(shell: ShellActions) {
        run("twitch", shell: shell, success: Copy.Stage.disconnectedToast) { try await self.store.disconnectTwitch() }
    }
}

// MARK: - confirms and sheets

private struct StagePresentations: ViewModifier {
    @Bindable var controller: StageController

    @Environment(\.shell) private var shell

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                Copy.Stage.rotateTitle, isPresented: $controller.confirmingRotate, titleVisibility: .visible
            ) {
                Button(Copy.Stage.rotate, role: .destructive) { controller.rotate(shell: shell) }
                Button(Copy.Stage.keep, role: .cancel) {}
            } message: {
                Text(Copy.Stage.rotateMessage)
            }
            .confirmationDialog(
                Copy.Stage.disconnectTitle, isPresented: $controller.confirmingDisconnect, titleVisibility: .visible
            ) {
                Button(Copy.Stage.disconnect, role: .destructive) { controller.disconnectTwitch(shell: shell) }
                Button(Copy.Stage.keep, role: .cancel) {}
            } message: {
                Text(Copy.Stage.disconnectMessage)
            }
            .sheet(isPresented: $controller.pickShown) {
                StagePickSheet(controller: controller)
            }
            .sheet(item: $controller.editingReward) { kind in
                StageRewardSheet(controller: controller, kind: kind)
            }
            .haptic(.success, trigger: controller.doneTick)
            .haptic(.error, trigger: controller.failTick)
    }
}

extension View {
    /// The studio's confirms (rotate, disconnect), its pick sheet and its reward editor, with the haptics of `controller`.
    func stagePresentations(_ controller: StageController) -> some View {
        modifier(StagePresentations(controller: controller))
    }
}
