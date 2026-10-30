import Foundation
import Observation

/// The auto-hide rules (APP-API-CONTRACT 37.3, 37.4): the list in settings, the add sheet's live count, the switches.
/// `AppModel.hiddenRules`. Idle until `load()`; a server or key change empties it.
@MainActor @Observable
public final class HiddenRulesModel {
    /// Oldest first, as the server lists them.
    public internal(set) var rules: [HideRule] = []
    /// Posts hidden on the server, and posts held back by an `about` rule until its words are written.
    public internal(set) var hidden: Int = 0
    public internal(set) var held: Int = 0
    public internal(set) var isLoading: Bool = false
    /// Why the last load or change failed; nil after one that worked.
    public internal(set) var failure: PipelineFailure?

    @ObservationIgnored let ctx: PipelineContext
    @ObservationIgnored let library: LibraryModel

    init(context: PipelineContext, library: LibraryModel) {
        self.ctx = context
        self.library = library
    }

    func reset() {
        rules = []; hidden = 0; held = 0; isLoading = false; failure = nil
    }

    /// `GET /hidden/rules`.
    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let list = try await ctx.client.hiddenRules()
            rules = list.rules
            hidden = list.hidden
            held = list.held
            failure = nil
        } catch {
            if let f = pipelineFailure(from: error, during: .saving) { failure = f }
        }
    }

    /// `POST /hidden/rules`: the new rule joins the list. With `apply`, the saved posts it matches are hidden at once;
    /// the answer is how many, and the library and the album are read again. A refusal (`error.hidden.bad_rule`,
    /// `error.hidden.too_many`) is thrown as the `PipelineFailure` it maps to (`.server(code:)`).
    @discardableResult
    public func add(kind: HiddenRuleKind, value: String, apply: Bool) async throws -> Int {
        let created: (rule: HideRule, applied: Int)
        do {
            created = try await ctx.client.createHiddenRule(kind: kind, value: value, apply: apply)
        } catch {
            throw pipelineFailure(from: error, during: .saving) ?? error
        }
        rules.removeAll { $0.id == created.rule.id }
        rules.append(created.rule)
        failure = nil
        if created.applied > 0 {
            hidden += created.applied
            await settleLibrary()
        }
        return created.applied
    }

    /// The switch: optimistic, put back when the server refuses.
    public func setEnabled(_ rule: HideRule, _ on: Bool) async {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }), rules[index].enabled != on else { return }
        let before = rules[index]
        rules[index].enabled = on
        do {
            let saved = try await ctx.client.updateHiddenRule(id: rule.id, enabled: on, value: nil, apply: false)
            if let at = rules.firstIndex(where: { $0.id == rule.id }) { rules[at] = saved.rule }
            failure = nil
        } catch {
            if let at = rules.firstIndex(where: { $0.id == rule.id }) { rules[at] = before }
            if let f = pipelineFailure(from: error, during: .saving) { failure = f }
        }
    }

    /// Swipe to delete: optimistic, put back where it was when the server refuses. The posts it hid stay hidden.
    public func delete(_ rule: HideRule) async {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        let removed = rules.remove(at: index)
        do {
            try await ctx.client.deleteHiddenRule(id: rule.id)
            failure = nil
        } catch {
            // an id the server no longer has is gone, which is what was asked
            if case .api(_, 404)? = error as? CobaltError { return }
            rules.insert(removed, at: min(index, rules.endIndex))
            if let f = pipelineFailure(from: error, during: .saving) { failure = f }
        }
    }

    /// `POST /hidden/rules/preview`: what the rule would hide now. Nil when the server cannot say (a bad value, offline).
    public func preview(kind: HiddenRuleKind, value: String) async -> HiddenRulePreview? {
        try? await ctx.client.previewHiddenRule(kind: kind, value: value)
    }

    /// Posts were hidden by a rule: the library drops them and the album lists them.
    private func settleLibrary() async {
        await library.refresh()
        await library.loadHidden()
    }
}
