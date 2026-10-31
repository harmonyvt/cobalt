import CobaltKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Settings › hidden (APP-API-CONTRACT 37.7): the auto-hide rules (kind, value, how many posts each hid, a switch, swipe
/// or menu to delete, `add rule…`), the Face ID lock for the hidden album, and `open hidden`.
struct HiddenRulesScreen: View {
    let model: AppModel
    /// Shown in a sheet (the Mac): a Done button closes it.
    var closes = false

    @State private var adding = false
    @State private var notice: String?
    @State private var noticeToken = 0
    @State private var askingLock = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.shell) private var shell
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    private var rules: HiddenRulesModel { model.hiddenRules }
    private var postCount: Int { max(model.library.hiddenCount, rules.hidden) }

    var body: some View {
        Form {
            rulesSection
            privacySection
            openSection
        }
        .formStyle(.grouped)
        .font(CobaltType.body)
        .navigationTitle(Copy.Hidden.screenTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheetCorner()
        .environment(\.sheetClose, closes ? SheetCloseAction { dismiss() } : nil)
        .task { await rules.load() }
        .sheet(isPresented: $adding) {
            AddHiddenRuleSheet(model: model) { text in
                show(text)
            }
        }
        .motion(Motion.rows, value: rules.rules)
    }

    // MARK: hide automatically

    private var rulesSection: some View {
        Section {
            if rules.rules.isEmpty {
                if rules.isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(Copy.Hidden.loadingRules).font(Font.cobalt(12.5)).foregroundStyle(.secondary)
                    }
                } else if rules.failure == nil {
                    Text(Copy.Hidden.noRules).font(Font.cobalt(12.5)).foregroundStyle(.secondary)
                }
            }
            ForEach(rules.rules) { rule in
                row(rule)
            }
            if let failure = rules.failure {
                HStack(spacing: 8) {
                    Text(Copy.failure(failure)).font(Font.cobalt(12.5)).foregroundStyle(CobaltColor.errorText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if rules.rules.isEmpty {
                        Button { Task { await rules.load() } } label: {
                            Label(Copy.Hidden.retry, systemImage: Symbol.HiddenRules.retry)
                        }
                        .buttonStyle(.cobaltIcon(.small))
                    }
                }
            }
            if let notice {
                Label(notice, systemImage: "checkmark")
                    .font(Font.cobalt(12.5)).foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        } header: {
            // "add rule" is a small icon at the group's trailing edge
            HStack(spacing: 8) {
                Text(Copy.Hidden.rulesGroup).font(CobaltType.caption).textCase(nil)
                Spacer(minLength: 0)
                Button { adding = true } label: { Label(Copy.Hidden.addRule, systemImage: Symbol.HiddenRules.add) }
                    .buttonStyle(.cobaltIcon(.small))
            }
        } footer: {
            Text(Copy.Hidden.rulesFooter).font(CobaltType.captionSmall).lineSpacing(2)
        }
    }

    private func row(_ rule: HideRule) -> some View {
        Toggle(isOn: Binding(
            get: { rule.enabled },
            set: { on in Task { await rules.setEnabled(rule, on) } })
        ) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Copy.Hidden.kindLabel(rule.kind)).font(Font.cobalt(11.5)).foregroundStyle(.secondary)
                    Text(Copy.Hidden.ruleValue(rule)).lineLimit(2)
                    Text(Copy.Hidden.hits(rule)).font(Font.cobalt(11.5)).foregroundStyle(.secondary).monospacedDigit()
                }
            } icon: {
                Image(systemName: Symbol.HiddenRules.kind(rule.kind))
            }
        }
        .accessibilityLabel(Copy.Hidden.ruleA11y(rule))
        .accessibilityValue(Copy.Hidden.hits(rule))
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                Task { await rules.delete(rule) }
            } label: {
                Label(Copy.Hidden.deleteRule, systemImage: Symbol.HiddenRules.delete)
            }
        }
        // the Mac has no swipe
        .contextMenu {
            Button(role: .destructive) {
                Task { await rules.delete(rule) }
            } label: {
                Label(Copy.Hidden.deleteRule, systemImage: Symbol.HiddenRules.delete)
            }
        }
    }

    // MARK: privacy

    private var privacySection: some View {
        Section {
            Toggle(isOn: Binding(get: { model.settings.hiddenLock }, set: { setLock($0) })) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Copy.Hidden.lock)
                        Text(Copy.Hidden.lockDetail).font(Font.cobalt(11.5)).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: Symbol.HiddenRules.lock)
                }
            }
        } header: {
            Text(Copy.Hidden.privacyGroup).font(CobaltType.caption).textCase(nil)
        }
    }

    /// Turning the lock on needs nothing; turning it OFF asks the system first (Face ID / Touch ID / passcode), so someone
    /// holding an unlocked phone cannot take the lock off the hidden album. The switch stays on until the system says yes.
    private func setLock(_ on: Bool) {
        if on { model.settings.hiddenLock = true; return }
        guard model.settings.hiddenLock, !askingLock else { return }
        askingLock = true
        Task {
            let outcome = await HiddenLock.authenticate(reason: Copy.Hidden.lockOffReason)
            askingLock = false
            if outcome == .unlocked { model.settings.hiddenLock = false }
        }
    }

    // MARK: open hidden

    private var openSection: some View {
        Section {
            Button { openHidden() } label: {
                LabeledContent {
                    HStack(spacing: 6) {
                        Text(Copy.Hidden.posts(postCount))
                            .font(Font.cobalt(12.5)).foregroundStyle(.secondary).monospacedDigit()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                } label: {
                    Label(Copy.Hidden.openHidden, systemImage: Symbol.HiddenRules.open)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
        }
    }

    /// The library's hidden album (it asks for the lock itself when it opens): leave settings, show the library tab.
    private func openHidden() {
        model.library.showingHidden = true
        dismiss()
        model.selectedTab = .library
        #if os(macOS)
        // the Settings window is its own window: bring the main one forward
        openWindow(id: "main")
        NSApp.activate()
        #endif
    }

    // MARK: notice

    /// "3 posts hidden" / "rule added": over the shell where there is one, and under the list for a few seconds.
    private func show(_ text: String) {
        shell.showStatus(text)
        withAnimation(Motion.rows) { notice = text }
        noticeToken += 1
        let token = noticeToken
        Task {
            try? await Task.sleep(for: .seconds(4))
            if noticeToken == token { withAnimation(Motion.rows) { notice = nil } }
        }
    }
}

#if DEBUG
#Preview("settings · hidden screen") {
    PreviewHost(.hidden, tab: .settings) { model in
        NavigationStack { HiddenRulesScreen(model: model) }
    }
}
#Preview("settings · hidden screen · no rules") {
    PreviewHost(.happy, tab: .settings) { model in
        NavigationStack { HiddenRulesScreen(model: model, closes: true) }
            .task { for rule in model.hiddenRules.rules { await model.hiddenRules.delete(rule) } }
    }
}
#endif
