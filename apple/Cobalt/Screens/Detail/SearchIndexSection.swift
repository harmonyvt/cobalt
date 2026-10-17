import CobaltKit
import SwiftUI

/// SF Symbols of the "search index" section (all from SF Symbols 1 to 3).
extension Symbol {
    enum SearchIndex {
        static let indexed = "checkmark.circle.fill"
        static let stale = "arrow.triangle.2.circlepath"
        static let pending = "clock"
        static let failed = "exclamationmark.triangle.fill"
        static let gaveUp = "xmark.circle.fill"
        static let unknown = "questionmark.circle"
    }
}

/// How a post sits in the server's search index (`GET /library/search/post`, APP-API-CONTRACT 21; only with
/// `features.search`), at the end of the detail: a badge (indexed / waiting to re-index / waiting / failed / gave up),
/// when it was indexed or is retried, whether the poster went in, and, folded, the exact title and text it is searched
/// by. Loaded when the detail opens, and again after a rename (`refreshKey`). Read-only.
struct SearchIndexSection: View {
    let model: AppModel
    /// The post's key (`LibraryPost.id`).
    let postKey: String
    /// Anything that changes what the post is embedded from (its title): a change loads the state again.
    var refreshKey: String = ""

    enum Phase: Equatable { case loading, loaded(LibrarySearchStatus), notFound, failed }

    @State private var phase: Phase = .loading
    @State private var showsInput = false

    var body: some View {
        Section {
            content
        } header: {
            Text(Copy.Search.section)
        }
        .task(id: "\(postKey)|\(refreshKey)") { await load() }
        .motion(Motion.rows, value: phase)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(Copy.Search.loading)
            }
            .font(CobaltType.body)
            .foregroundStyle(.secondary)
        case .notFound:
            quiet(Copy.Search.notListed)
        case .failed:
            quiet(Copy.Search.unavailable)
        case .loaded(let status):
            if !status.searchEnabled {
                quiet(Copy.Search.searchOff)
            } else {
                loaded(status)
            }
        }
    }

    private func quiet(_ text: String) -> some View {
        Text(text)
            .font(CobaltType.body)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func loaded(_ status: LibrarySearchStatus) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            VStack(alignment: .leading, spacing: 4) {
                SearchIndexBadge(state: status.state)
                if let line = Copy.Search.detail(status, now: timeline.date) {
                    Text(line)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
                if status.state == .indexed, status.embeddedMatchesInput == false {
                    Text(Copy.Search.changedSince)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
        }
        LabeledContent(Copy.Search.posterIncluded) {
            Text(posterIncluded(status) ? Copy.Search.yes : Copy.Search.no)
        }
        .font(CobaltType.body)
        if status.attempts > 1 || status.state == .failed || status.state == .gaveUp {
            LabeledContent(Copy.Search.attempts) { Text("\(status.attempts)").monospacedDigit() }
                .font(CobaltType.body)
        }
        if let input = status.input {
            DisclosureGroup(isExpanded: $showsInput) {
                inputRow(Copy.Search.titleLabel, input.title)
                inputRow(Copy.Search.textLabel, input.text)
                inputRow(Copy.Search.posterLabel, input.imageURL?.absoluteString)
                if let model = status.model {
                    inputRow(Copy.Search.model, status.dims.map { "\(model) · \($0)" } ?? model)
                }
            } label: {
                Text(Copy.Search.whatWasEmbedded)
                    .font(CobaltType.body)
            }
        }
    }

    /// The vector was made with the poster (else: the poster would go in, for a post not embedded yet).
    private func posterIncluded(_ status: LibrarySearchStatus) -> Bool {
        status.hasImage ?? (status.input?.imageURL != nil)
    }

    private func inputRow(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(CobaltType.captionSmall)
                .foregroundStyle(.secondary)
            Text(value.flatMap { $0.isEmpty ? nil : $0 } ?? Copy.Search.none)
                .font(CobaltType.captionSmall)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        if case .loaded = phase {} else { phase = .loading }
        do {
            let status = try await model.library.searchStatus(postKey: postKey)
            guard !Task.isCancelled else { return }
            phase = .loaded(status)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            phase = LibraryModel.searchErrorCode(error) == "error.library.not_found" ? .notFound : .failed
        }
    }
}

/// The state as a small tinted capsule: green when indexed, grey while waiting, red when it failed.
struct SearchIndexBadge: View {
    let state: LibrarySearchStatus.State

    var body: some View {
        Label(Copy.Search.state(state), systemImage: symbol)
            .font(CobaltType.captionSmall.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
            .contentTransition(.symbolEffect(.replace))
    }

    private var symbol: String {
        switch state {
        case .indexed: return Symbol.SearchIndex.indexed
        case .stale: return Symbol.SearchIndex.stale
        case .pending: return Symbol.SearchIndex.pending
        case .failed: return Symbol.SearchIndex.failed
        case .gaveUp: return Symbol.SearchIndex.gaveUp
        case .unknown: return Symbol.SearchIndex.unknown
        }
    }

    private var tint: Color {
        switch state {
        case .indexed: return CobaltColor.success
        case .failed, .gaveUp: return CobaltColor.errorText
        case .stale, .pending, .unknown: return CobaltColor.caption
        }
    }
}

#if DEBUG
/// One section per state of the preview index: indexed (with the poster), waiting to re-index, waiting, failed with a
/// retry, gave up, and a key the server does not know.
@MainActor
private struct SearchIndexPreview: View {
    @State private var model: AppModel

    init(_ mode: PreviewSearchMode = .ready) {
        _model = State(initialValue: AppModel.previewSearch(mode))
    }

    var body: some View {
        Form {
            ForEach(["Dd55fEyN1Yy", "Dd7P496wolG", "2105432512428445875", "Dd5JFkMDt4N", "2105358343657427103", "nope"], id: \.self) {
                SearchIndexSection(model: model, postKey: $0)
            }
        }
        .formStyle(.grouped)
    }
}

#Preview("search index · every state") {
    SearchIndexPreview()
}

#Preview("search index · every state, dark") {
    SearchIndexPreview()
        .preferredColorScheme(.dark)
}

/// The whole detail of the first preview post (indexed two hours ago, poster included), the section at the end.
@MainActor
private struct SearchDetailPreview: View {
    @State private var model: AppModel

    init() {
        _model = State(initialValue: AppModel.previewSearch(.ready))
    }

    var body: some View {
        NavigationStack {
            if let post = model.library.posts.first {
                MediaDetail(model: model, item: model.mediaItem(for: post))
            }
        }
    }
}

#Preview("detail · search index") {
    SearchDetailPreview()
}
#endif
