import CobaltKit
import SwiftUI

/// "sharing" (APP-API-CONTRACT 36.6): what a new gallery link starts as (`public` / `private`, the server's `new_links`),
/// how many private links are live, and a red `rotate every key…` that asks first. Grouped rows like settings › mcp.
/// Shown only on a server with `features.private_links` and a key.
struct PrivateLinksSettingsSection: View {
    let model: AppModel

    @State private var asking = false
    @State private var working = false
    @State private var loadFailed = false
    @State private var actionError: String?
    @State private var doneToken = 0
    @Environment(\.shell) private var shell

    private var store: ShareSetStore { model.shareSets }

    var body: some View {
        if model.capabilities.privateLinks && model.settings.hasAPIKey {
            Section {
                if loadFailed && !store.privateLoaded {
                    Text(Copy.PrivateLinks.loadFailed).font(Font.cobalt(12.5)).foregroundStyle(CobaltColor.errorText)
                    Button(Copy.PrivateLinks.retry, systemImage: Symbol.PrivateLinks.rotate) { Task { await reload() } }
                } else {
                    Picker(selection: Binding(get: { store.newLinks }, set: { choose($0) })) {
                        Label(Copy.PrivateLinks.choicePublic, systemImage: Symbol.PrivateLinks.publicLink).tag(NewLinks.public)
                        Label(Copy.PrivateLinks.choicePrivate, systemImage: Symbol.PrivateLinks.makePrivate).tag(NewLinks.private)
                    } label: {
                        Label(Copy.PrivateLinks.newLinksStart, systemImage: Symbol.PrivateLinks.newLinks)
                    }
                    .disabled(working || !store.privateLoaded)
                    LabeledContent {
                        if store.privateLoaded {
                            Text("\(store.privateLinkCount)").font(Font.cobalt(12.5)).foregroundStyle(.secondary).monospacedDigit()
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    } label: {
                        Label(Copy.PrivateLinks.privateCount, systemImage: Symbol.PrivateLinks.lock)
                    }
                    .accessibilityElement(children: .combine)
                    Button(working ? Copy.PrivateLinks.working : Copy.PrivateLinks.rotateAll,
                           systemImage: Symbol.PrivateLinks.rotate, role: .destructive) { asking = true }
                        .foregroundStyle(CobaltColor.errorText)
                        .disabled(working || store.privateLinkCount == 0)
                }
                if let actionError {
                    Text(actionError).font(Font.cobalt(12.5)).foregroundStyle(CobaltColor.errorText)
                }
            } header: {
                Text(Copy.PrivateLinks.settingsGroup).font(CobaltType.caption).textCase(nil)
            } footer: {
                Text(Copy.PrivateLinks.settingsFooter).font(CobaltType.captionSmall).lineSpacing(2)
            }
            .task { await reload() }
            .confirmationDialog(Copy.PrivateLinks.rotateAllTitle, isPresented: $asking, titleVisibility: .visible) {
                Button(Copy.PrivateLinks.rotateAllConfirm, role: .destructive) { Task { await rotateAll() } }
                Button(Copy.PrivateLinks.cancel, role: .cancel) {}
            } message: {
                Text(Copy.PrivateLinks.rotateAllMessage)
            }
            .haptic(.success, trigger: doneToken)
        }
    }

    private func reload() async {
        do {
            try await store.refreshPrivate()
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }

    private func choose(_ value: NewLinks) {
        guard value != store.newLinks, !working else { return }
        actionError = nil
        working = true
        Task {
            defer { working = false }
            do {
                try await store.setNewLinks(value)
                doneToken += 1
            } catch {
                actionError = Copy.PrivateLinks.message(for: error)
            }
        }
    }

    private func rotateAll() async {
        guard !working else { return }
        actionError = nil
        working = true
        defer { working = false }
        do {
            let answer = try await model.rotateAllPrivateLinks()
            shell.showStatus(Copy.PrivateLinks.rotatedEvery(answer.rotated))
            doneToken += 1
        } catch {
            actionError = Copy.PrivateLinks.message(for: error)
        }
    }
}

#if DEBUG
#Preview("settings · sharing") {
    PreviewHost(.happy, tab: .settings) { model in
        Form { PrivateLinksSettingsSection(model: model) }.formStyle(.grouped)
    }
}
#endif
