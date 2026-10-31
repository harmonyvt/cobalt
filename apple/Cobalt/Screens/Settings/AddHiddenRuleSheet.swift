import CobaltKit
import SwiftUI

/// "new rule" (APP-API-CONTRACT 37.7): what to hide a post by (a site or account, a word in its title or link, a word in
/// what it is about, or "i uploaded it"), the value, a live count of the saved posts that match now (`/hidden/rules/preview`,
/// asked 400 ms after the last keystroke), and `also hide what's saved` (= `apply`). `add` hides nothing the server refuses;
/// its refusal is words under the form. `added` gets the line to show ("3 posts hidden" / "rule added").
struct AddHiddenRuleSheet: View {
    let model: AppModel
    let added: (String) -> Void

    @State private var kind: HiddenRuleKind = .site
    @State private var value = ""
    @State private var apply = true
    @State private var matches: Int?
    @State private var working = false
    @State private var problem: String?
    @FocusState private var typing: Bool
    @Environment(\.dismiss) private var dismiss

    /// What the live count depends on: a change cancels the wait and asks again.
    private struct Probe: Equatable {
        var kind: HiddenRuleKind
        var value: String
    }

    private var cleaned: String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var needsValue: Bool { kind != .upload }
    private var canAdd: Bool { !working && (!needsValue || !cleaned.isEmpty) }
    private var probe: Probe { Probe(kind: kind, value: needsValue ? cleaned : "") }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(selection: $kind) {
                        ForEach(HiddenRuleKind.allCases, id: \.self) { k in
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Copy.Hidden.kindTitle(k))
                                    Text(Copy.Hidden.kindDetail(k)).font(Font.cobalt(11.5)).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: Symbol.HiddenRules.kind(k))
                            }
                            .tag(k)
                        }
                    } label: {
                        Text(Copy.Hidden.hidePostWhen)
                    }
                    .pickerStyle(.inline)
                } header: {
                    Text(Copy.Hidden.hidePostWhen).font(CobaltType.caption).textCase(nil)
                }

                if needsValue {
                    Section {
                        field
                    } header: {
                        Text(Copy.Hidden.fieldTitle(kind)).font(CobaltType.caption).textCase(nil)
                    }
                }

                Section {
                    Toggle(isOn: $apply) {
                        Text(Copy.Hidden.alsoHide)
                    }
                } footer: {
                    if let note = matchNote {
                        Text(note).font(CobaltType.captionSmall).lineSpacing(2)
                    }
                }

                if let problem {
                    Section {
                        Text(problem).font(Font.cobalt(12.5)).foregroundStyle(CobaltColor.errorText)
                    }
                }
            }
            .formStyle(.grouped)
            .font(CobaltType.body)
            .navigationTitle(Copy.Hidden.newRule)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            // close sits top right (CloseButton keeps escape); the add button stays the sheet's confirm
            .sheetCorner()
            .sheetClose { dismiss() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(working ? Copy.Hidden.adding : Copy.Hidden.add) { Task { await add() } }
                        .disabled(!canAdd)
                }
            }
            .onChange(of: kind) { _, _ in
                problem = nil
                if needsValue { typing = true }
            }
            .onChange(of: value) { _, _ in problem = nil }
            .task(id: probe) { await count(probe) }
            .motion(Motion.rows, value: needsValue)
            .motion(Motion.rows, value: problem)
        }
        #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #else
        .frame(width: 460, height: 600)
        #endif
        .interactiveDismissDisabled(working)
        .onAppear { typing = true }
    }

    private var field: some View {
        TextField(Copy.Hidden.placeholder(kind), text: $value)
            .focused($typing)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(kind == .site ? .URL : .default)
            .submitLabel(.done)
            #endif
            .onSubmit { if canAdd { Task { await add() } } }
    }

    /// "9 saved posts match now · their links stop working", once the server has said.
    private var matchNote: String? {
        guard let matches else { return nil }
        return Copy.Hidden.matches(matches, applying: apply)
    }

    /// The live count: after a pause, the server's answer for what the rule would hide now. An empty value has none.
    private func count(_ probe: Probe) async {
        if probe.kind != .upload, probe.value.isEmpty {
            matches = nil
            return
        }
        do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
        let answer = await model.hiddenRules.preview(kind: probe.kind, value: probe.value)
        guard !Task.isCancelled else { return }
        matches = answer?.matches
    }

    private func add() async {
        guard canAdd else { return }
        working = true
        problem = nil
        defer { working = false }
        do {
            let hidden = try await model.hiddenRules.add(kind: kind, value: needsValue ? cleaned : "", apply: apply)
            added(apply && hidden > 0 ? Copy.Hidden.hiddenNow(hidden) : Copy.Hidden.ruleAdded)
            dismiss()
        } catch {
            problem = Copy.Hidden.addFailure(error, kind: kind)
        }
    }
}

#if DEBUG
#Preview("add rule") {
    PreviewHost(.hidden, tab: .settings) { model in
        AddHiddenRuleSheet(model: model) { _ in }
    }
}
#endif
