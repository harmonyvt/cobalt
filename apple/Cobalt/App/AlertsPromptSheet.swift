#if os(iOS)
import ActivityKit
import CobaltKit
import SwiftUI
import UIKit
import UserNotifications

/// Rises over the shell when notifications or live activities are off (and the key works), with one button that
/// turns on both: the system prompt while notifications were never asked, the app's page in Settings otherwise.
/// "not now" keeps it away for a week; it closes by itself once both are on. Rule: `AlertsPrompt`.
struct AlertsPromptPresenter: ViewModifier {
    let model: AppModel
    /// Another sheet is over the shell (the paste review, the title sheet): this one waits for the next foreground.
    var blocked = false

    @Environment(\.scenePhase) private var scenePhase
    @State private var shown = false
    @State private var notifications: AlertsPrompt.Notifications = .on
    @State private var liveActivities = true

    private static let snoozeKey = "alertsPrompt.snoozedUntil"

    func body(content: Content) -> some View {
        content
            .task(id: model.capabilities.key) {
                try? await Task.sleep(for: .seconds(1.5))       // let launch settle (and the queue sheet, if any) first
                await refresh(rise: true)
            }
            .task {
                for await enabled in ActivityAuthorizationInfo().activityEnablementUpdates {
                    liveActivities = enabled
                    await refresh(rise: false)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await refresh(rise: true) }              // back from Settings: closes when both are on
            }
            .sheet(isPresented: $shown, onDismiss: snoozeUnlessAllOn) {
                AlertsPromptSheet(notifications: notifications, liveActivities: liveActivities) {
                    Task { await turnOn() }
                } notNow: {
                    shown = false               // onDismiss snoozes it
                }
                .cobaltRoot(model: model)
            }
    }

    private func refresh(rise: Bool) async {
        guard !model.isPreview else { return }
        notifications = await Self.notificationState()
        liveActivities = ActivityAuthorizationInfo().areActivitiesEnabled
        if AlertsPrompt.allOn(notifications: notifications, liveActivities: liveActivities) {
            shown = false
            return
        }
        guard rise, !shown, !model.queueShown, !blocked else { return }
        shown = AlertsPrompt.shouldShow(
            notifications: notifications, liveActivities: liveActivities, keyValid: model.capabilities.key == .valid,
            snoozedUntil: UserDefaults.standard.object(forKey: Self.snoozeKey) as? Date, now: Date())
    }

    /// "not now" and a swipe down both keep it away for a week; closing because both are on does not.
    private func snoozeUnlessAllOn() {
        guard !AlertsPrompt.allOn(notifications: notifications, liveActivities: liveActivities) else { return }
        UserDefaults.standard.set(Date().addingTimeInterval(AlertsPrompt.snooze), forKey: Self.snoozeKey)
    }

    private func turnOn() async {
        if AlertsPrompt.action(notifications: notifications) == .ask {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            await refresh(rise: false)          // closes the sheet when that was all that was off
            // allowed, but live activities are still off: their switch is in Settings. A "don't allow" stays on the
            // sheet, which now offers Settings.
            guard notifications == .on, !liveActivities else { return }
        }
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        await UIApplication.shared.open(url)
    }

    private static func notificationState() async -> AlertsPrompt.Notifications {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: return .notAsked
        case .denied: return .off
        default: return .on
        }
    }
}

struct AlertsPromptSheet: View {
    let notifications: AlertsPrompt.Notifications
    let liveActivities: Bool
    let turnOn: () -> Void
    let notNow: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Text(Copy.AlertsPrompt.title)
                    .font(Font.cobalt(18, .semibold, relativeTo: .headline))
                    .foregroundStyle(CobaltColor.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                // "not now" is the sheet's close, top right (closing snoozes it for a week)
                CloseButton(cancels: true, action: notNow)
            }
            Text(Copy.AlertsPrompt.body)
                .font(CobaltType.body)
                .foregroundStyle(CobaltColor.caption)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                row(Copy.AlertsPrompt.notifications, on: notifications == .on, symbol: "bell.badge")
                row(Copy.AlertsPrompt.liveActivities, on: liveActivities, symbol: Symbol.liveActivity)
            }
            if notifications != .notAsked {
                Text(Copy.AlertsPrompt.settingsHint)
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            // "turn on" keeps its word; "not now" is the close in the top-right corner
            Button(notifications == .notAsked ? Copy.AlertsPrompt.turnOn : Copy.AlertsPrompt.openSettings, action: turnOn)
                .buttonStyle(.cobaltPrimary(compact: true))
        }
        .padding(.horizontal, 16)
        .padding(.top, 24)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.height(400), .large])
        .presentationDragIndicator(.visible)
        .background(CobaltColor.bg)
    }

    private func row(_ title: String, on: Bool, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(CobaltColor.text)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(title)
                .font(CobaltType.body)
                .foregroundStyle(CobaltColor.text)
            Spacer(minLength: 8)
            Text(on ? Copy.AlertsPrompt.on : Copy.AlertsPrompt.off)
                .font(CobaltType.caption)
                .foregroundStyle(on ? CobaltColor.caption : CobaltColor.errorText)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: Metrics.hit)
        .background(CobaltColor.elevated, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

#Preview("alerts prompt · never asked") {
    AlertsPromptSheet(notifications: .notAsked, liveActivities: false, turnOn: {}, notNow: {})
}

#Preview("alerts prompt · turned off") {
    AlertsPromptSheet(notifications: .off, liveActivities: true, turnOn: {}, notNow: {})
}
#endif
