import Foundation
import Observation

// The countdown (CONTRACT-SYNC.md decisions 1 to 5, with the owner's 2026-10-04 amendment).
//
// Starts at the first moment the server holds the save (`canContinueInBackground`) and the server
// finishes it unpolled. Stops for good on stay, any other control, or the run failing. The save
// finishing does NOT stop it: when it ends the sheet closes through the same path the close button
// takes at that moment, so a keep download still running is handed to the background download.
// Never on a file share (the upload runs inside the extension), plain cobalt or a picker post.

extension ShareCore {
    /// The stay button.
    func stay() { stopAutoContinue(.stay) }

    /// Any other control on the sheet.
    func noteInteraction() { stopAutoContinue(.interaction) }

    /// Previews show a fixed state; the real countdown goes quiet.
    func previewAutoContinue(_ state: AutoContinue) {
        countdownTask?.cancel()
        countdownTask = nil
        autoContinue = state
    }

    /// The sheet is closing for some other reason (close, swipe, trim in cobalt, the countdown
    /// itself): nothing may fire after this.
    func noteClosing() {
        closed = true
        countdownTask?.cancel()
        countdownTask = nil
        switch autoContinue {
        case .armed, .counting: autoContinue = .stopped(.interaction)
        default: break
        }
    }

    private func stopAutoContinue(_ reason: AutoContinueStop) {
        switch autoContinue {
        case .armed, .counting:
            countdownTask?.cancel()
            countdownTask = nil
            autoContinue = .stopped(reason)
        case .off, .stopped, .fired:
            break
        }
    }

    /// Watches what the decision depends on: the pipeline's state, session and input, and the
    /// capabilities. Re-arms itself until the countdown is settled.
    func observeAutoContinue() {
        switch autoContinue {
        case .armed, .counting: break
        default: return
        }
        withObservationTracking {
            _ = pipeline.state
            _ = pipeline.sessionID
            _ = pipeline.input
            _ = capabilities
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.evaluateAutoContinue()
                self?.observeAutoContinue()
            }
        }
    }

    func evaluateAutoContinue() {
        switch autoContinue {
        case .armed, .counting: break
        default: return
        }
        // Runs that never count: the upload is the extension's own work and closing would kill it.
        if case .file = pipeline.input { settleOff(); return }
        switch pipeline.state {
        case .failed: stopAutoContinue(.failed); return
        case .picker, .image: settleOff(); return
        default: break
        }
        guard case .armed = autoContinue else { return }

        let caps = capabilities
        switch caps.kind {
        case .unreachable: return                       // the sheet starts before it knows the server
        case .plainCobalt, .notCobalt, .legacyFork: settleOff(); return
        case .fork: if !caps.finishesUnpolled { settleOff(); return }
        }
        guard canContinueInBackground else { return }
        startCountdown()
    }

    private func settleOff() {
        countdownTask?.cancel()
        countdownTask = nil
        autoContinue = .off
    }

    private func startCountdown() {
        let chosen = ctx.settings.autoContinueSeconds
        let seconds = assistiveRunning ? max(chosen, AssistiveTech.floorSeconds) : chosen
        let endsAt = ctx.clock.now().addingTimeInterval(Double(seconds))
        autoContinue = .counting(endsAt: endsAt, seconds: seconds)
        let clock = ctx.clock
        countdownTask = Task { [weak self] in
            do { try await clock.sleep(seconds: Double(seconds)) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.countdownEnded()
        }
    }

    private func countdownEnded() async {
        guard case .counting = autoContinue, !closed else { return }
        autoContinue = .fired
        countdownTask = nil
        if canContinueInBackground {
            _ = await continueInBackground()
        } else {
            _ = await close()                           // the save finished: the close path (hands the original off)
        }
    }
}
