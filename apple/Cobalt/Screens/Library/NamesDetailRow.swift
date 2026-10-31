import CobaltKit
import SwiftUI

/// The "names" row of a post's "what it's about" (APP-API-CONTRACT 48.6; only with `features.names`): each name the post
/// carries or is marked for, with its score. A tap opens the name (library › names); "not <name>" marks the post `no`
/// there, and the name leaves the row. Read again whenever a name or a mark changes anywhere (`SearchNamesModel.revision`).
struct NamesDetailRow: View {
    let model: AppModel
    let postKey: String

    enum Phase: Equatable { case loading, loaded([PostName]), failed }

    @State private var phase: Phase = .loading
    @State private var markFailed = false
    @State private var marks = 0

    private var names: SearchNamesModel { model.searchNames }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Copy.Names.detailRow)
                .font(CobaltType.captionSmall)
                .foregroundStyle(.secondary)
            content
            if markFailed {
                Text(Copy.Names.markFailed)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.errorText)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 2)
        .task(id: "\(postKey)|\(names.revision)") { await load() }
        .motion(Motion.rows, value: phase)
        .haptic(.impact(weight: .light), trigger: marks)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView().controlSize(.small)
        case .failed:
            Text(Copy.Names.detailFailed).font(CobaltType.captionSmall).foregroundStyle(.secondary)
        case .loaded(let list):
            if list.isEmpty {
                Text(Copy.Names.detailNone).font(CobaltType.captionSmall).foregroundStyle(.secondary)
            } else {
                AboutFlow(spacing: 6) {
                    ForEach(list) { name in
                        NamesDetailChip(name: name) {
                            Task { await names.open(id: name.id) }
                        } notThis: {
                            markNot(name)
                        }
                    }
                }
            }
        }
    }

    private func load() async {
        do {
            let list = try await names.names(forPost: postKey)
            guard !Task.isCancelled else { return }
            phase = .loaded(list)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            if case .loaded = phase { return }       // keep what was shown
            phase = .failed
        }
    }

    /// Optimistic: the name leaves the row at once; a refusal puts it back with a quiet line.
    private func markNot(_ name: PostName) {
        guard case .loaded(let list) = phase else { return }
        phase = .loaded(list.filter { $0.id != name.id })
        markFailed = false
        marks += 1
        let key = postKey
        Task {
            if await names.mark(key, .no, on: name.id) == nil {
                phase = .loaded(list)
                withAnimation(Motion.rows) { markFailed = true }
            }
        }
    }
}

/// One name on the post: "Lia 0.71" (a tap opens it) and, unless it is marked `no` already, a small "not Lia".
private struct NamesDetailChip: View {
    let name: PostName
    let open: () -> Void
    let notThis: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: open) {
                Text(Copy.Names.detailChip(name))
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(name.mark == .no ? CobaltColor.errorText : CobaltColor.linkBlue)
                    .monospacedDigit()
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(CobaltColor.linkBlue.opacity(0.12), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.borderless)
            .accessibilityHint(Copy.Names.openName(name.name))
            if name.mark != .no {
                Button(action: notThis) {
                    Text(Copy.Names.notThis(name.name))
                        .font(CobaltType.badge)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .overlay(Capsule().strokeBorder(CobaltColor.border, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Copy.Names.notThisA11y(name.name))
            }
        }
    }
}
