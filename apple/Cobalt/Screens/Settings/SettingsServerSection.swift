import CobaltKit
import SwiftUI

/// Settings › account & server: the server address, what it can do, and (on a server without accounts) the pasted
/// api key. Moved out of `SettingsScreen` unchanged; it owns the two error lines the paste actions write.
struct SettingsServerSection: View {
    let model: AppModel

    @State private var keyError: String?
    @State private var serverError: String?
    @State private var featuresOpen = false

    private var settings: CobaltKit.Settings { model.settings }
    private var summary: ServerSummary { model.serverSummary }

    var body: some View {
        Section {
            // the row keeps its words; paste and reset are small icons beside the value
            SettingsRows.row(Copy.api, Symbol.api) {
                HStack(spacing: 8) {
                    SettingsRows.value(summary.host)
                    Button { pasteServer() } label: { Label(Copy.pasteServerURL, systemImage: Symbol.paste) }
                        .buttonStyle(.cobaltIcon(.small))
                    Button(role: .destructive) { resetServer() } label: { Label(Copy.reset, systemImage: Symbol.reset) }
                        .buttonStyle(.cobaltIcon(.small, tint: CobaltColor.errorText))
                        .disabled(settings.serverURL == CobaltKit.Settings.defaultServer)
                }
            }
            SettingsRows.row(Copy.thisServer, Symbol.server) { SettingsRows.value(Copy.serverKind(summary, checking: model.isCheckingServer)) }
            if summary.kind != .unreachable, summary.kind != .notCobalt {
                DisclosureGroup(isExpanded: $featuresOpen) {
                    ForEach(Copy.serverFeatures(model.capabilities)) { feature in
                        LabeledContent {
                            Text(feature.on ? Copy.featureOn : Copy.featureOff)
                                .font(Font.cobalt(12.5))
                                .foregroundStyle(feature.on ? Color.primary : Color.secondary)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(feature.name)
                                Text(feature.detail).font(Font.cobalt(11.5)).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                } label: {
                    Label(Copy.serverFeaturesTitle, systemImage: Symbol.quality)
                }
            }
            // a server with accounts signs in instead (settings › account below); the paste stays for every other server
            if !model.capabilities.accounts {
                SettingsRows.row(Copy.apiKey, Symbol.key) {
                    HStack(spacing: 8) {
                        if !settings.hasAPIKey {
                            SettingsRows.value(Copy.noKey)
                        } else if summary.key == .invalid {
                            Text(Copy.keyRevoked).font(Font.cobalt(12.5)).foregroundStyle(CobaltColor.errorText)
                        } else {
                            SettingsRows.value(summary.keyName.map { Copy.keyLine(name: $0) } ?? Copy.keySet).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        Button { pasteKey() } label: {
                            Label(settings.hasAPIKey ? Copy.pasteNewKey : Copy.pasteKey, systemImage: Symbol.paste)
                        }
                        .buttonStyle(.cobaltIcon(.small))
                    }
                }
            }
            if let keyError { SettingsRows.problem(keyError) }
            if let serverError { SettingsRows.problem(serverError) }
        } header: {
            SettingsRows.header(Copy.groupServer)
        } footer: {
            if !model.capabilities.accounts { SettingsRows.footer(Copy.keyFootnote) }
        }
    }

    private func pasteKey() {
        keyError = nil
        guard let text = Pasteboard.string() else { keyError = Copy.notAKey; return }
        Task {
            do {
                try await model.setAPIKey(pasted: text)
            } catch {
                // a real key this device would not store is not "not a key"
                keyError = (error as? KeyInputError) == .couldNotSave ? Copy.keyNotSaved : Copy.notAKey
            }
        }
    }

    private func pasteServer() {
        serverError = nil
        guard let text = Pasteboard.string() else { serverError = Copy.notAURL; return }
        Task {
            do { try await model.setServer(pasted: text) } catch { serverError = Copy.notAURL }
        }
    }

    private func resetServer() {
        serverError = nil
        settings.resetServer()
        Task {
            do { try await model.setServer(pasted: CobaltKit.Settings.defaultServer.absoluteString) } catch { serverError = Copy.notAURL }
        }
    }
}
