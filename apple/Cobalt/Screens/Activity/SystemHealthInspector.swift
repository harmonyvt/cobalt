import CobaltKit
import SwiftUI

// The system segment of the activity sheet (apple 03-PHASE3 3.4.2, "03 Sync & Offline" of the prototype): what capystore is
// connected to and how it is doing, one card each. Every line is a reading with its own time ("last observed", "checked 12:46"),
// never a made-up "live": the API edge is timed when this opens and on "retry now", the containers are read off the work that
// ran, the library sync is the engine's own status, the storage and the stage are the stores' own numbers.

struct SystemHealthInspector: View {
    let model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var health: SystemHealth { model.health }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            edgeCard
            containersCard
            librarySyncCard
            storageCard
            stageCard
        }
        .animation(reduceMotion ? Motion.fade : Motion.rows, value: health.edge)
        .animation(reduceMotion ? Motion.fade : Motion.rows, value: health.pendingEdits)
        // `.contain` keeps the cards' own identifiers (a plain container's identifier would replace theirs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("activity.system")
        .task {
            // opening the segment times the edge and reads the outbox; nothing polls after that
            health.sample(model.activity.items, now: Date())
            await health.refreshPendingEdits(from: model.library)
            await health.checkEdge()
        }
        .onChange(of: model.library.syncStatus) { _, _ in
            Task { await health.refreshPendingEdits(from: model.library) }
        }
        .onChange(of: model.activity.items) { _, items in health.sample(items, now: Date()) }
    }

    // MARK: api edge

    private var edgeCard: some View {
        let edge = health.edge
        let tone: HealthTone = {
            if health.isCheckingEdge && edge == nil { return .quiet }
            guard let edge else { return .quiet }
            switch edge.kind {
            case .unreachable: return .bad
            case .notCobalt: return .warn
            default: return .ok
            }
        }()
        return HealthCard(title: Copy.Activity.edgeGroup, subtitle: model.serverSummary.host, tone: tone) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(edgeLine).font(CobaltType.bodyMedium).foregroundStyle(CobaltColor.text)
                    Spacer(minLength: 8)
                    if health.isCheckingEdge {
                        ProgressView().controlSize(.small)
                    }
                }
                if let edge {
                    Text(Copy.Activity.edgeChecked(Format.when(edge.at, now: Date())))
                        .font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption)
                }
                if edge?.reachable == false || model.capabilities.kind == .unreachable {
                    Button { Task { await retryEdge() } } label: { Label(Copy.Activity.retryNow, systemImage: Symbol.retry) }
                        .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                        .accessibilityIdentifier("activity.edge.retry")
                }
            }
        }
    }

    private var edgeLine: String {
        guard let edge = health.edge else { return health.isCheckingEdge ? Copy.Activity.edgeChecking : Copy.Activity.edgeNotChecked }
        switch edge.kind {
        case .unreachable: return Copy.Activity.edgeUnreachable
        case .notCobalt: return Copy.Activity.edgeNotCobalt
        default: return Copy.Activity.edgeReachable(rtt: edge.rttMilliseconds)
        }
    }

    /// Times the edge again; when it answers while the app still thinks it is offline, the app asks the server too, so the
    /// offline mark (and every caption that follows it) clears without waiting for the next foreground.
    private func retryEdge() async {
        await health.checkEdge()
        if health.edge?.reachable == true, model.capabilities.kind == .unreachable { await model.refreshServer() }
    }

    // MARK: containers

    private var containersCard: some View {
        let readings = health.containers
        let tone: HealthTone = readings.contains { $0.state == .waking } ? .warn
            : (readings.contains { $0.state == .warm } ? .ok : .quiet)
        return HealthCard(title: Copy.Activity.containersGroup, subtitle: nil, tone: tone) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(readings) { reading in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Copy.Activity.containerName(reading.name))
                            .font(CobaltType.body).foregroundStyle(CobaltColor.text)
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(containerState(reading.state))
                                .font(CobaltType.body)
                                .foregroundStyle(reading.state == .waking ? ActivityInk.warn : CobaltColor.text)
                            if let at = reading.observedAt {
                                Text(Copy.Activity.containerSeen(Format.when(at, now: Date())))
                                    .font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                Text(Copy.Activity.containersFooter)
                    .font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption)
            }
        }
    }

    private func containerState(_ state: SystemHealth.ContainerState) -> String {
        switch state {
        case .unknown: return Copy.Activity.containerUnknown
        case .warm: return Copy.Activity.containerWarm
        case .waking: return Copy.Activity.containerWaking
        }
    }

    // MARK: library sync

    private var librarySyncCard: some View {
        let status = model.library.syncStatus
        let on = model.settings.syncEngine
        return HealthCard(title: Copy.Activity.syncGroup, subtitle: nil, tone: syncTone(status, on: on)) {
            VStack(alignment: .leading, spacing: 10) {
                // live: the switch starts and stops the engine at once, no restart
                Toggle(isOn: Binding(get: { model.settings.syncEngine }, set: { model.library.setSyncEnabled($0) })) {
                    Text(Copy.Activity.syncToggle).font(CobaltType.body).foregroundStyle(CobaltColor.text)
                }
                .accessibilityIdentifier("activity.sync.toggle")
                if on, let status {
                    syncBody(status)
                } else if !on {
                    Text(Copy.Activity.syncOff).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption)
                }
            }
        }
    }

    private func syncTone(_ status: SyncStatusSnapshot?, on: Bool) -> HealthTone {
        guard on, let status else { return .quiet }
        switch status.state {
        case .idle: return .ok
        case .syncing, .repulling, .disabled: return .quiet
        case .offline: return .bad
        case .error: return .bad
        }
    }

    @ViewBuilder
    private func syncBody(_ status: SyncStatusSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(syncLine(status.state))
                .font(CobaltType.bodyMedium)
                .foregroundStyle(syncIsProblem(status.state) ? ActivityInk.bad : CobaltColor.text)
            if case .error(let code, _, let nextRetryAt) = status.state {
                Text(Copy.LibrarySync.errorDetail(code: code))
                    .font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption)
                if let nextRetryAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Copy.Activity.syncNextTry(seconds: Int(nextRetryAt.timeIntervalSince(context.date).rounded(.up))))
                            .font(CobaltType.captionSmall).monospacedDigit().foregroundStyle(CobaltColor.caption)
                    }
                }
            }
            HStack(spacing: 12) {
                Text(Copy.Activity.syncCursor(status.cursorSeq))
                Text(status.lastSyncedAt.map { Copy.Activity.syncLast(Format.when($0, now: Date())) } ?? Copy.Activity.syncNever)
            }
            .font(CobaltType.captionSmall).monospacedDigit().foregroundStyle(CobaltColor.caption)
            pending(status)
            HStack(spacing: 8) {
                Button { Task { await model.library.retrySync() } } label: { Label(Copy.Activity.syncNow, systemImage: Symbol.retry) }
                    .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                    .accessibilityIdentifier("activity.sync.now")
                if case .error = status.state {
                    Button { model.library.dismissSyncError() } label: { Text(Copy.Activity.dismiss) }
                        .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                }
            }
        }
    }

    private func syncIsProblem(_ state: SyncHealthState) -> Bool {
        switch state {
        case .error, .offline: return true
        default: return false
        }
    }

    private func syncLine(_ state: SyncHealthState) -> String {
        switch state {
        case .idle: return Copy.LibrarySync.statusIdle
        case .syncing: return Copy.LibrarySync.statusSyncing
        case .repulling: return Copy.LibrarySync.statusRepulling
        case .offline(let pending): return Copy.LibrarySync.statusOffline(pending: pending)
        case .error: return Copy.LibrarySync.errorTitle
        case .disabled: return Copy.LibrarySync.statusDisabled
        }
    }

    @ViewBuilder
    private func pending(_ status: SyncStatusSnapshot) -> some View {
        let edits = health.pendingEdits
        VStack(alignment: .leading, spacing: 4) {
            Text(status.pendingCount > 0 ? Copy.LibrarySync.waiting(status.pendingCount) : Copy.Activity.syncPendingNone)
                .font(CobaltType.captionSmall)
                .foregroundStyle(status.pendingCount > 0 ? CobaltColor.text : CobaltColor.caption)
                .accessibilityIdentifier("activity.sync.pending")
            ForEach(edits) { edit in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Copy.Activity.pendingEdit(edit, postTitle: postTitle(edit.postID)))
                        .font(Font.cobalt(11.5, .regular, relativeTo: .caption))
                        .foregroundStyle(CobaltColor.text)
                        .lineLimit(2)
                    Spacer(minLength: 6)
                    if edit.isSending {
                        Text(Copy.Activity.pendingSending).font(CobaltType.badge).foregroundStyle(CobaltColor.caption)
                    } else if edit.tries > 0 {
                        Text(Copy.Activity.pendingTries(edit.tries)).font(CobaltType.badge).foregroundStyle(CobaltColor.caption)
                    }
                }
                .padding(.leading, 8)
            }
        }
    }

    /// The post's own name, when the library has it on this device.
    private func postTitle(_ id: String) -> String? {
        guard let post = model.library.posts.first(where: { $0.id == id }) else { return nil }
        return post.customTitle ?? post.title
    }

    // MARK: offline storage

    private var storageCard: some View {
        let usage = model.store.usage
        return HealthCard(title: Copy.Activity.storageGroup, subtitle: nil, tone: .quiet) {
            VStack(alignment: .leading, spacing: 8) {
                Text(usage.count == 0 ? Copy.Activity.storageEmpty : Copy.Activity.storageUsage(items: usage.mediaCount, bytes: usage.bytes))
                    .font(CobaltType.bodyMedium).foregroundStyle(CobaltColor.text)
                    .monospacedDigit()
                Button {
                    model.queueShown = false
                    model.selectedTab = .settings
                } label: { Text(Copy.Activity.manageStorage) }
                    .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
            }
        }
    }

    // MARK: obs stage

    @ViewBuilder
    private var stageCard: some View {
        if model.capabilities.stage, let stage = model.stage.stage {
            let tone: HealthTone = {
                guard stage.onAir else { return .quiet }
                if case .disconnected = stage.obsPresence { return .warn }
                return .ok
            }()
            HealthCard(title: Copy.Activity.stageGroup, subtitle: nil, tone: tone) {
                Text(stageLine(stage)).font(CobaltType.bodyMedium).foregroundStyle(CobaltColor.text)
            }
        }
    }

    private func stageLine(_ stage: StageSettings) -> String {
        guard stage.onAir else { return Copy.Activity.obsOffAir }
        switch stage.obsPresence {
        case .unknown: return Copy.Activity.obsOnAirUnknown
        case .disconnected: return Copy.Activity.obsOnAirNone
        case .connected(let n): return Copy.Activity.obsOnAir(n)
        }
    }
}

// MARK: - a card

/// One card of the inspector, the prototype's `wcard`: a status dot and a name in the header, the readings under it, a border that
/// takes the colour of the news (green, amber, red; the quiet ones keep the hairline).
private enum HealthTone { case ok, warn, bad, quiet }

private struct HealthCard<Content: View>: View {
    let title: String
    let subtitle: String?
    let tone: HealthTone
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(ink).frame(width: 8, height: 8).accessibilityHidden(true)
                Text(title).font(CobaltType.caption).foregroundStyle(CobaltColor.text)
                if let subtitle {
                    Text(subtitle)
                        .font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CobaltColor.row, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                .strokeBorder(tone == .quiet || tone == .ok ? CobaltColor.hairline : ink.opacity(0.5), lineWidth: 1)
        }
    }

    private var ink: Color {
        switch tone {
        case .ok: return ActivityInk.ok
        case .warn: return ActivityInk.warn
        case .bad: return ActivityInk.bad
        case .quiet: return CobaltColor.caption
        }
    }
}
