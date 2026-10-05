import CobaltKit
import SwiftUI

/// "diagnostics": whether crash reports and logs go to the owner's own server, and a button that sends
/// them right now (what a debugging session wants). The service does the work; this view only draws it.
/// With no service (previews, tests) the button is dimmed.
struct TelemetrySettingsSection: View {
    let model: AppModel

    @State private var sending = false
    @State private var result: TelemetrySendResult?
    @State private var waiting: (events: Int, crashes: Int)?

    private var settings: CobaltKit.Settings { model.settings }
    private var host: String { model.serverSummary.host }

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { settings.sendTelemetry },
                set: { on in
                    settings.sendTelemetry = on
                    if on { model.telemetry?.uploadSoon() }
                })) {
                Label(Copy.Telemetry.toggle, systemImage: Symbol.Telemetry.toggle)
            }
            Button(sending ? Copy.Telemetry.sending : Copy.Telemetry.sendNow, systemImage: Symbol.Telemetry.sendNow) { send() }
                .disabled(sending || model.telemetry == nil)
            if let result {
                Text(Copy.Telemetry.result(result))
                    .font(Font.cobalt(12.5))
                    .foregroundStyle(Copy.Telemetry.isProblem(result) ? CobaltColor.errorText : Color.secondary)
                    .accessibilityIdentifier("telemetry-result")
            } else if let waiting, waiting.events > 0 || waiting.crashes > 0 {
                Label(Copy.Telemetry.waiting(events: waiting.events, crashes: waiting.crashes), systemImage: Symbol.Telemetry.waiting)
                    .font(Font.cobalt(12.5))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(Copy.Telemetry.group).font(CobaltType.caption).textCase(nil)
        } footer: {
            Text(Copy.Telemetry.footer(host: host)).font(CobaltType.captionSmall).lineSpacing(2)
        }
        .task { await refreshWaiting() }
    }

    private func refreshWaiting() async {
        guard let service = model.telemetry else { return }
        waiting = await service.pendingCounts()
    }

    private func send() {
        guard let service = model.telemetry, !sending else { return }
        sending = true
        result = nil
        Task {
            let outcome = await service.sendNow()
            result = outcome
            sending = false
            await refreshWaiting()
        }
    }
}

#if DEBUG
#Preview("settings · diagnostics") {
    PreviewHost(.happy, tab: .settings) { model in
        Form { TelemetrySettingsSection(model: model) }.formStyle(.grouped)
    }
}
#endif
