import CobaltKit
import SwiftUI

// The activity pill (apple 03-PHASE3 3.4.1): the one way into what capystore is doing and how it is connected, on every iPhone and
// iPad screen that has a toolbar. It replaces the queue button and its count (`QueueToolbarItem` keeps its name and init, so the
// screens that mount it change nothing).
//
// What it says is `ActivityPillState.resolve`: the six rows of the priority table (CobaltKit, tested). This file only draws the
// result: a symbol, a few lowercase words, an ink. Every number on it is `model.activity`'s: the same count the sheet, the island
// and the Mac's sidebar, dock and menu bar read, so they cannot disagree. A tap opens the activity and health sheet
// (`AppModel.showQueue()`) on the segment the state points at (`ActivitySheetRoute`).

/// Which segment the sheet opens on. The pill sets it just before `AppModel.showQueue()`; the sheet takes it once. Every other way into
/// the sheet (the tray's header, a toast's "view") leaves it on activity.
@MainActor
@Observable
final class ActivitySheetRoute {
    static let shared = ActivitySheetRoute()

    var segment: ActivityPillState.Segment = .activity

    /// The segment the sheet should open on; the next open goes back to activity unless a pill asks again.
    func take() -> ActivityPillState.Segment {
        defer { segment = .activity }
        return segment
    }
}

/// The colours the pill and the sheet's health cards use. Amber is the app's one warm accent (`CobaltColor.collection`); red is its
/// error ink; the rest are the monochrome text and caption inks.
enum ActivityInk {
    static let warn = CobaltColor.collection
    static let bad = CobaltColor.errorText
    static let ok = CobaltColor.success
    static let info = CobaltColor.linkBlue
}

#if os(iOS)
/// The queue button as a toolbar item, trailing. Add it to a screen's `.toolbar` (`QueueToolbarItem` in `QueueToolbarButton.swift`).
struct ActivityPill: View {
    let model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let summary = model.activity.summary
        let state = ActivityPillSource.state(model: model, summary: summary)
        Button {
            ActivitySheetRoute.shared.segment = state.segment
            model.showQueue()
        } label: {
            label(state)
        }
        .accessibilityIdentifier("activity.pill")
        .accessibilityLabel(Copy.Activity.pillA11yLabel)
        .accessibilityValue(Copy.Activity.pillValue(state))
        .accessibilityHint(Copy.Activity.pillHint)
        .help(Copy.Activity.title)
        // what is waking is read off the activity list while a pill is on screen (never asked of the server)
        .onChange(of: summary.items, initial: true) { _, items in
            model.health.sample(items, now: Date())
        }
    }

    private func label(_ state: ActivityPillState) -> some View {
        Label {
            if let text = Copy.Activity.pill(state) {
                Text(text)
                    .font(Font.cobalt(13, .semibold, relativeTo: .footnote))
                    .monospacedDigit()
                    .lineLimit(1)
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .transition(.opacity)
            } else {
                Text(Copy.Activity.title)
            }
        } icon: {
            symbol(state)
        }
        .labelStyle(ActivityPillLabelStyle(showsTitle: Copy.Activity.pill(state) != nil))
        .foregroundStyle(ink(state))
        .animation(reduceMotion ? Motion.fade : Motion.rows, value: state)
    }

    @ViewBuilder
    private func symbol(_ state: ActivityPillState) -> some View {
        switch state {
        case .attention:
            Image(systemName: "exclamationmark.triangle.fill")
        case .offline:
            Image(systemName: "wifi.slash")
        case .active:
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
        case .syncing:
            Image(systemName: "arrow.triangle.2.circlepath")
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
        case .waking:
            Image(systemName: "circle.lefthalf.filled")
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
        case .idle:
            // zero noise: a quiet check, nothing to read
            Image(systemName: "checkmark.circle")
        }
    }

    private func ink(_ state: ActivityPillState) -> Color {
        switch state {
        case .attention(let retries, _): return retries > 0 ? ActivityInk.bad : ActivityInk.warn
        case .offline: return ActivityInk.bad
        case .active: return CobaltColor.text
        case .syncing: return ActivityInk.info
        case .waking: return ActivityInk.warn
        case .idle: return CobaltColor.caption
        }
    }
}

private struct ActivityPillLabelStyle: LabelStyle {
    let showsTitle: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
            if showsTitle {
                configuration.title
            }
        }
    }
}
#endif

/// Where the pill's inputs come from: the one count (`model.activity`), the network (`capabilities.kind`), the library sync
/// (`library.syncStatus`) and the container wake (`health`). Shared with the Mac's counts so every surface resolves the same.
@MainActor
enum ActivityPillSource {
    static func state(model: AppModel, summary: ActivitySummary) -> ActivityPillState {
        #if DEBUG
        if let forced = ActivityPillDebug.forced { return forced }
        #endif
        return ActivityPillState.resolve(
            summary: summary, offline: model.capabilities.kind == .unreachable, sync: model.library.syncStatus,
            waking: model.health.isWaking)
    }
}

#if DEBUG
/// `-previewPill idle|active|active1|attention|syncerror|offline|syncing|waking`: forces the pill's state so every row of the table can
/// be photographed in the simulator (there is no preview scenario with the network down). The sheet, the counts and everything
/// else keep reading the real model. Debug builds only.
enum ActivityPillDebug {
    static var forced: ActivityPillState? {
        switch UserDefaults.standard.string(forKey: "previewPill") {
        case "idle": return .idle
        case "active": return .active(count: 2, fraction: nil)
        case "active1": return .active(count: 1, fraction: 0.42)
        case "attention": return .attention(retries: 1, sync: false)
        case "syncerror": return .attention(retries: 0, sync: true)
        case "offline": return .offline(pending: 2)
        case "syncing": return .syncing(pending: 3)
        case "waking": return .waking
        default: return nil
        }
    }
}
#endif
