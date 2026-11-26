import CobaltKit
import SwiftUI

// The activity and health sheet (apple 03-PHASE3 3.4.2): one sheet, two segments. "activity" lists everything capystore is doing
// (`model.activity`): running, needs attention (retry, dismiss) and the last ten finished with their cloud and device receipts, each
// running row with the shared stepper. "system" is the health inspector (`SystemHealthInspector`): the API edge, the containers,
// the library sync, the offline storage and the OBS stage.
//
// It is the iPhone and iPad's queue sheet (`AppModel.showQueue()`), opened by the pill on the segment the pill points at
// (`ActivitySheetRoute`). The Mac keeps the queue tab. Every action goes through `model.activity.perform`, which routes it to the
// store that owns the work, exactly as the queue tab's rows do.

struct ActivityAndHealthSheet: View {
    let model: AppModel

    @State private var segment: ActivityPillState.Segment
    @State private var actionTicks = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: AppModel) {
        self.model = model
        var first = ActivitySheetRoute.shared.take()
        #if DEBUG
        // `-previewActivitySheet system`: the sheet opens on that segment whatever opened it (simulator evidence)
        if let raw = UserDefaults.standard.string(forKey: "previewActivitySegment"), let forced = ActivityPillState.Segment(rawValue: raw) {
            first = forced
        }
        #endif
        _segment = State(initialValue: first)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker(Copy.Activity.segmentsA11y, selection: $segment) {
                Text(Copy.Activity.segmentActivity).tag(ActivityPillState.Segment.activity)
                Text(Copy.Activity.segmentSystem).tag(ActivityPillState.Segment.system)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 12)
            .accessibilityIdentifier("activity.segments")

            ScrollView {
                Group {
                    switch segment {
                    case .activity: ActivityList(model: model, actionTicks: $actionTicks)
                    case .system: SystemHealthInspector(model: model)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.automatic)
            .refreshable { _ = await model.unifiedQueue.refresh() }
        }
        .background(CobaltColor.bg)
        .navigationTitle(Copy.Activity.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .motion(Motion.card, value: segment)
        .haptic(.impact(weight: .light), trigger: actionTicks)
        .haptic(.selection, trigger: segment)
        .accessibilityIdentifier("activity.sheet")
        // the server's line is only read while something that lists it is on screen (`UnifiedQueue`'s own rule)
        .onAppear { model.unifiedQueue.setVisible(true) }
        .onDisappear { model.unifiedQueue.setVisible(false) }
    }
}

// MARK: - the activity segment

private struct ActivityList: View {
    let model: AppModel
    @Binding var actionTicks: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var offline: Bool { model.capabilities.kind == .unreachable }

    var body: some View {
        // one read: the header, the sections and the pill all come from this one summary
        let summary = model.activity.summary
        let running = summary.running
        let attention = summary.attention
        let recent = summary.recent(limit: 10)
        VStack(alignment: .leading, spacing: 22) {
            header(summary)
            if summary.items.isEmpty {
                empty
            } else {
                section(Copy.Activity.running, running)
                section(Copy.Activity.attention, attention)
                section(Copy.Activity.recent, recent)
            }
        }
        .animation(reduceMotion ? Motion.fade : Motion.rows, value: summary.items.map(\.id))
    }

    private func header(_ summary: ActivitySummary) -> some View {
        Text(Copy.Activity.header(active: summary.activeCount, attention: summary.attentionCount))
            .font(CobaltType.bodyMedium)
            .foregroundStyle(CobaltColor.text)
            .contentTransition(reduceMotion ? .identity : .numericText())
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits([.isHeader, .updatesFrequently])
            .accessibilityIdentifier("activity.header")
    }

    private var empty: some View {
        ContentUnavailableView {
            Label(Copy.Activity.emptyTitle, systemImage: Symbol.queueEmpty)
                .font(CobaltType.body)
        } description: {
            Text(Copy.Activity.emptyBody)
                .font(CobaltType.caption)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    @ViewBuilder
    private func section(_ name: String, _ items: [JobStatus]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(name)
                    Text("\(items.count)")
                        .monospacedDigit()
                        .foregroundStyle(CobaltColor.caption)
                }
                .font(CobaltType.caption)
                .foregroundStyle(CobaltColor.text)
                .padding(.leading, 4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Copy.Activity.sectionA11y(name, count: items.count))
                .accessibilityAddTraits(.isHeader)
                ForEach(items) { status in
                    ActivityRow(model: model, status: status, offline: offline, actionTicks: $actionTicks)
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .scale(scale: 0.96, anchor: .top).combined(with: .opacity), removal: .opacity))
                }
            }
        }
    }
}

// MARK: - one row

private struct ActivityRow: View {
    let model: AppModel
    let status: JobStatus
    let offline: Bool
    @Binding var actionTicks: Int
    /// A row that has not started shows one line with its current step; this opens the whole stepper.
    @State private var expanded = false

    private var bucket: JobStatus.Bucket { status.bucket }

    /// Waiting in a line, nothing begun: one line is all there is to say yet.
    private var hasNotStarted: Bool {
        if case .queued = status.stage { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            top
            if bucket != .settled {
                if hasNotStarted {
                    HStack(alignment: .top, spacing: 8) {
                        JobStepperView(status: status, collapsed: !expanded)
                        Button { withAnimation(Motion.rows) { expanded.toggle() } } label: {
                            Label(
                                expanded ? Copy.Activity.hideSteps : Copy.Activity.showSteps,
                                systemImage: expanded ? "chevron.up" : "chevron.down"
                            )
                            .labelStyle(.iconOnly)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(CobaltColor.caption)
                            .frame(width: Metrics.hit, height: Metrics.hit)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(expanded ? Copy.Activity.hideSteps : Copy.Activity.showSteps)
                        .accessibilityIdentifier("activity.expand")
                    }
                } else {
                    JobStepperView(status: status)
                }
            } else {
                receipts
            }
            actions
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CobaltColor.row, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                .strokeBorder(bucket == .attention ? ActivityInk.bad.opacity(0.45) : CobaltColor.hairline, lineWidth: 1)
        }
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("activity.row")
    }

    // MARK: the title and the line under it

    @ViewBuilder
    private var top: some View {
        if let open = opener {
            Button(action: open) { topContent(chevron: true) }
                .buttonStyle(.plain)
                .accessibilityLabel(Copy.Activity.rowA11y(status))
                .accessibilityHint(Copy.Activity.open)
        } else {
            topContent(chevron: false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Copy.Activity.rowA11y(status))
        }
    }

    private func topContent(chevron: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Copy.Activity.title(status))
                    .font(CobaltType.bodyMedium)
                    .foregroundStyle(CobaltColor.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(Copy.Activity.stage(status))
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(bucket == .attention ? ActivityInk.bad : CobaltColor.caption)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 8)
            if status.isActive, let fraction = status.fraction {
                Text(Copy.Activity.percent(fraction))
                    .font(Font.cobalt(12, .medium, relativeTo: .caption))
                    .monospacedDigit()
                    .foregroundStyle(CobaltColor.text)
            }
            if chevron {
                Image(systemName: "chevron.forward")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(CobaltColor.caption)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    /// What a tap does: a job of this device opens in focus; anything with a stored media opens its detail; the rest is not tappable.
    private var opener: (() -> Void)? {
        if status.canFocus {
            return { open(focus: true) }
        }
        if status.mediaID != nil, bucket == .settled || !status.isActive {
            return { open(focus: false) }
        }
        return nil
    }

    private func open(focus: Bool) {
        actionTicks += 1
        Task { @MainActor in
            if focus {
                await model.activity.perform(.focus, on: status.id)
            } else if let id = status.mediaID {
                model.requestedMediaID = id
            }
            model.queueShown = false                    // the sheet gives way to where the work lives
            model.selectedTab = .save
        }
    }

    // MARK: finished

    @ViewBuilder
    private var receipts: some View {
        if case .completed(let cloudSaved, let device) = status.stage {
            HStack(spacing: 6) {
                if cloudSaved {
                    Chip(text: Copy.Activity.cloudOK, tone: .ok)
                        .accessibilityLabel(Copy.Activity.cloudOKA11y)
                }
                if let text = Copy.Activity.deviceReceipt(device) {
                    Chip(text: text, tone: tone(of: device))
                        .accessibilityLabel(Copy.Activity.deviceReceiptA11y(device) ?? text)
                }
                Spacer(minLength: 0)
            }
        } else {
            EmptyView()
        }
    }

    private func tone(of receipt: JobStatus.LocalCopyReceipt) -> Chip.Tone {
        switch receipt {
        case .failed: return .warn
        case .inProgress, .notNeeded: return .quiet
        case .savedOnDevice: return .ok
        }
    }

    // MARK: actions

    @ViewBuilder
    private var actions: some View {
        let showsRetry = status.canRetry && bucket != .running
        let showsCancel = status.canCancel && bucket == .running
        let showsDismiss = status.canDismiss
        if showsRetry || showsCancel || showsDismiss {
            HStack(spacing: 8) {
                if showsRetry {
                    Button { run(.retry) } label: { Label(Copy.Activity.retry, systemImage: Symbol.retry) }
                        .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                        .accessibilityIdentifier("activity.retry")
                        .offlineReason(offline, disables: false)
                }
                if showsCancel {
                    Button { run(.cancel) } label: { Text(Copy.Activity.cancel) }
                        .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                }
                if showsDismiss {
                    Button { run(.dismiss) } label: { Text(Copy.Activity.dismiss) }
                        .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                        .accessibilityIdentifier("activity.dismiss")
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
        if status.canFocus {
            Button(Copy.Activity.open) { open(focus: true) }
        }
        if status.canRetry { Button(Copy.Activity.retry) { run(.retry) } }
        if status.canCancel { Button(Copy.Activity.cancel, role: .destructive) { run(.cancel) } }
        if status.canDismiss { Button(Copy.Activity.dismiss) { run(.dismiss) } }
    }

    private func run(_ action: ActivityModel.Action) {
        actionTicks += 1
        let id = status.id
        Task { await model.activity.perform(action, on: id) }
    }
}

// MARK: - a receipt chip

struct Chip: View {
    enum Tone { case ok, warn, bad, quiet }
    let text: String
    var tone: Tone = .quiet

    var body: some View {
        Text(text)
            .font(CobaltType.pill)
            .lineLimit(1)
            .foregroundStyle(ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(ink.opacity(0.12)))
            .overlay(Capsule().strokeBorder(ink.opacity(0.35), lineWidth: 1))
    }

    private var ink: Color {
        switch tone {
        case .ok: return CobaltColor.text
        case .warn: return ActivityInk.warn
        case .bad: return ActivityInk.bad
        case .quiet: return CobaltColor.caption
        }
    }
}
