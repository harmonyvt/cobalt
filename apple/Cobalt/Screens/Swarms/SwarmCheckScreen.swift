import CobaltKit
import SwiftUI

// Check changes (CONTRACT-SWARMS 3.4): one row per change, "old → new" with a tick. A change that clashes with another shows
// unticked with "another change already uses this name". Tap a new name to change it. One "apply n" button asks Face ID (in
// the store) and leaves the clashes out. After the apply the rows show how each one went.

struct SwarmCheckScreen: View {
    let model: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var controller = SwarmController()
    @State private var editing: SwarmChange?
    @State private var draft = ""

    private var store: SwarmStore { model.swarms }
    private var swarm: Swarm? { store.shown }
    private var open: Bool { swarm?.apply.status == .ready }

    /// What "apply" will do and send (`SwarmStore.applyCount`: the one number both screens and the call use).
    private var applyCount: Int { store.applyCount }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                    header
                    if store.changes.isEmpty {
                        empty
                    } else {
                        ForEach(store.changes) { change in
                            SwarmChangeRow(change: change, open: open, tick: { tick(change) }, edit: { startEditing(change) })
                            Divider().overlay(CobaltColor.hairline)
                        }
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            if open { bottomBar }
        }
        .background(CobaltColor.bg)
        .navigationTitle(Copy.Swarms.checkTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { if store.changes.isEmpty { await store.loadChanges() } }
        .alert(Copy.Swarms.renameTitle, isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("", text: $draft)
            Button(Copy.Swarms.save) { saveName() }
            Button(Copy.Swarms.cancel, role: .cancel) {}
        }
    }

    // MARK: the rows

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            SwarmSentence(text: sentence)
            if open {
                Text(Copy.Swarms.tapToChange).font(CobaltType.caption).foregroundStyle(CobaltColor.caption)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    private var sentence: String {
        let total = store.changesTotal > 0 ? store.changesTotal : (swarm?.apply.total ?? 0)
        if open { return Copy.Swarms.changesReady(total) }
        return swarm.map { SwarmWords.rowLine($0, now: .now) } ?? Copy.Swarms.checkTitle
    }

    @ViewBuilder
    private var empty: some View {
        if let problem = store.changesProblem {
            InlineStatus(message: Copy.Swarms.problem(problem)) {
                Button(Copy.Swarms.tryAgain) { Task { await store.loadChanges() } }
                    .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
            }
            .padding(.vertical, 12)
        } else if (swarm?.apply.total ?? 0) == 0, swarm?.apply.status == Swarm.Apply.Status.none {
            Text(Copy.Swarms.noChanges).font(CobaltType.body).foregroundStyle(CobaltColor.caption).padding(.vertical, 12)
        } else {
            HStack(spacing: 10) {
                ProgressView()
                Text(Copy.Swarms.loadingChanges).font(CobaltType.caption).foregroundStyle(CobaltColor.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 30)
        }
    }

    // MARK: apply

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if let problem = controller.problem {
                SwarmProblemLine(error: problem) { controller.clear() }
            }
            Button(Copy.Swarms.apply(applyCount)) {
                Task {
                    await controller.run { try await store.apply(skipClashes: true) }
                    if controller.problem == nil { dismiss() }
                }
            }
            .buttonStyle(.cobaltPrimary())
            .disabled(controller.busy || applyCount == 0)
            Text(Copy.Swarms.confirmHint).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption)
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .background(CobaltColor.bg)
    }

    // MARK: edits

    private func tick(_ change: SwarmChange) {
        guard open, change.status == .proposed else { return }
        // ticked -> off; a clash that shows unticked is dropped for good (its note goes); off -> on
        let keep = change.clash == nil && !change.keep
        Task { await controller.run { try await store.setKeep(change.n, keep) } }
    }

    private func startEditing(_ change: SwarmChange) {
        guard open, change.canEdit, change.status == .proposed else { return }
        draft = change.after ?? ""
        editing = change
    }

    private func saveName() {
        guard let change = editing else { return }
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = nil
        guard !name.isEmpty, name != change.after else { return }
        Task { await controller.run { try await store.rename(change.n, to: name) } }
    }
}

// MARK: - one change

struct SwarmChangeRow: View {
    let change: SwarmChange
    let open: Bool
    let tick: () -> Void
    let edit: () -> Void

    private var ticked: Bool { change.keep && change.clash == nil }
    private var old: String { change.before ?? SwarmWords.writeWords(change.op) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            marker
            VStack(alignment: .leading, spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) { oldText; arrow; newButton }
                    VStack(alignment: .leading, spacing: 2) { oldText; HStack(spacing: 6) { arrow; newButton } }
                }
                if let clash = change.clash, change.keep, change.status == .proposed {
                    Text(Copy.Swarms.clash(clash)).font(CobaltType.captionSmall).foregroundStyle(SwarmColor.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if change.status == .failed, let error = change.error {
                    Text(error).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.errorText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 11)
        .frame(minHeight: Metrics.hit)
        .opacity(change.status == .skipped ? 0.5 : 1)
    }

    private var oldText: some View {
        Text(old).font(CobaltType.body).foregroundStyle(CobaltColor.caption).strikethrough()
            .lineLimit(2)
    }

    private var arrow: some View {
        Text("→").font(CobaltType.body).foregroundStyle(CobaltColor.caption)
    }

    @ViewBuilder
    private var newButton: some View {
        let label = Text(change.after ?? "").font(CobaltType.bodySemibold).foregroundStyle(CobaltColor.text).lineLimit(2)
        if open, change.canEdit, change.status == .proposed {
            Button(action: edit) {
                HStack(spacing: 4) {
                    label
                    Image(systemName: Symbol.Swarms.edit).font(.system(size: 10)).foregroundStyle(CobaltColor.caption)
                }
            }
            .buttonStyle(.plain)
        } else {
            label
        }
    }

    @ViewBuilder
    private var marker: some View {
        switch change.status {
        case .done:
            Image(systemName: Symbol.Swarms.applied).foregroundStyle(CobaltColor.success)
                .font(.system(size: 20)).frame(width: 28, height: 28).accessibilityLabel(Copy.Swarms.changeDone)
        case .failed:
            Image(systemName: Symbol.Swarms.changeFailed).foregroundStyle(CobaltColor.errorText)
                .font(.system(size: 20)).frame(width: 28, height: 28)
        case .applying:
            ProgressView().controlSize(.small).frame(width: 28, height: 28)
        case .skipped:
            Image(systemName: Symbol.Swarms.unticked).foregroundStyle(CobaltColor.border)
                .font(.system(size: 20)).frame(width: 28, height: 28)
        case .proposed:
            Button(action: tick) {
                Image(systemName: ticked ? Symbol.Swarms.ticked : Symbol.Swarms.unticked)
                    .font(.system(size: 22))
                    .foregroundStyle(ticked ? CobaltColor.text : CobaltColor.border)
                    .frame(width: 28, height: 28)
                    .frame(minWidth: Metrics.hit - 10, minHeight: Metrics.hit - 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!open)
            .accessibilityLabel(ticked ? Copy.Swarms.dropA11y : Copy.Swarms.keepA11y)
        }
    }
}
