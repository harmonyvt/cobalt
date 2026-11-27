import CobaltKit
import SwiftUI

// MARK: - Studio Deck Shared Styling

extension View {
    /// Crisp dark rounded card matching Studio Deck's translucent surface aesthetic.
    func studioDeckCard(border: Color = Color.white.opacity(0.08)) -> some View {
        padding(12)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(border, lineWidth: 0.75)
            )
    }
}

struct StudioDeckHairline: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 0.75)
    }
}

struct StudioDeckSectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(Font.cobalt(10.5, .semibold, relativeTo: .caption2))
            .foregroundStyle(.secondary)
            .tracking(0.6)
    }
}

// MARK: - Persistent Lazy Loader (Preserves State Across Fold / Tab Switches)

/// Lazily loads "what it's about", search index status, and post names for Studio Deck.
/// Held by `AmbientCinemaPostStudio` so folding/unfolding (docked <-> crease <-> compact sheet)
/// and switching Studio Deck tabs never flicker or discard loaded insight state.
@MainActor
@Observable
final class StudioDeckInsightStore {
    enum AboutPhase: Equatable {
        case idle, loading, loaded(LibraryAbout), notFound, failed
    }

    enum IndexPhase: Equatable {
        case idle, loading, loaded(LibrarySearchStatus), notFound, failed
    }

    enum NamesPhase: Equatable {
        case idle, loading, loaded([PostName]), failed
    }

    var aboutPhase: AboutPhase = .idle
    var indexPhase: IndexPhase = .idle
    var namesPhase: NamesPhase = .idle

    var tagSaveFailed = false
    var nameMarkFailed = false

    @ObservationIgnored private var confirmedAbout: LibraryAbout?
    @ObservationIgnored private var loadedAboutKey: String?
    @ObservationIgnored private var loadedIndexKey: String?
    @ObservationIgnored private var loadedNamesKey: String?
    @ObservationIgnored private var tagGeneration = 0

    func loadAbout(model: AppModel, postKey: String, refreshKey: String) async {
        let key = "\(postKey)|\(refreshKey)"
        if loadedAboutKey == key, case .loaded = aboutPhase { return }
        if loadedAboutKey != key {
            confirmedAbout = nil
            tagSaveFailed = false
            aboutPhase = .loading
        } else if case .loaded = aboutPhase {
            // Keep existing content visible during refresh.
        } else {
            aboutPhase = .loading
        }

        do {
            let about = try await model.library.about(postKey: postKey)
            guard !Task.isCancelled else { return }
            confirmedAbout = about
            loadedAboutKey = key
            aboutPhase = .loaded(about)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            loadedAboutKey = key
            aboutPhase = LibraryModel.searchErrorCode(error) == "error.library.not_found" ? .notFound : .failed
        }
    }

    func loadIndex(model: AppModel, postKey: String, refreshKey: String) async {
        let key = "\(postKey)|\(refreshKey)"
        if loadedIndexKey == key, case .loaded = indexPhase { return }
        if loadedIndexKey != key {
            indexPhase = .loading
        } else if case .loaded = indexPhase {
            // Keep existing status visible during refresh.
        } else {
            indexPhase = .loading
        }

        do {
            let status = try await model.library.searchStatus(postKey: postKey)
            guard !Task.isCancelled else { return }
            loadedIndexKey = key
            indexPhase = .loaded(status)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            loadedIndexKey = key
            indexPhase = LibraryModel.searchErrorCode(error) == "error.library.not_found" ? .notFound : .failed
        }
    }

    func loadNames(model: AppModel, postKey: String, revision: Int) async {
        let key = "\(postKey)|\(revision)"
        if loadedNamesKey == key, case .loaded = namesPhase { return }
        if loadedNamesKey != key, case .idle = namesPhase {
            namesPhase = .loading
        } else if loadedNamesKey != key, case .loaded = namesPhase {
            // Keep current pills while updating in place.
        } else if case .loaded = namesPhase {
            // Already loaded for this revision.
        } else {
            namesPhase = .loading
        }

        do {
            let list = try await model.searchNames.names(forPost: postKey)
            guard !Task.isCancelled else { return }
            loadedNamesKey = key
            nameMarkFailed = false
            namesPhase = .loaded(list)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            if case .loaded = namesPhase, loadedNamesKey?.hasPrefix("\(postKey)|") == true { return }
            loadedNamesKey = key
            namesPhase = .failed
        }
    }

    /// Optimistically updates tags (or resets when `tags == nil`), rolling back cleanly if the server refuses.
    func commitTags(model: AppModel, postKey: String, tags: [String]?, onFailure: @escaping () -> Void) {
        guard case .loaded(let current) = aboutPhase, var words = current.about else { return }
        if let tags {
            words.tags = tags
            words.edited = true
        } else {
            words.edited = false
        }
        var next = current
        next.about = words
        aboutPhase = .loaded(next)
        tagSaveFailed = false
        tagGeneration += 1
        let mine = tagGeneration

        Task {
            do {
                let answer = try await model.library.setAboutTags(postKey: postKey, tags: tags)
                confirmedAbout = answer
                guard mine == tagGeneration else { return }
                aboutPhase = .loaded(answer)
            } catch {
                guard mine == tagGeneration, !(error is CancellationError) else { return }
                aboutPhase = .loaded(confirmedAbout ?? current)
                withAnimation(Motion.rows) { tagSaveFailed = true }
                onFailure()
            }
        }
    }

    /// Optimistically marks a post as "not <name>", rolling back if the server refuses.
    func markNotName(model: AppModel, postKey: String, name: PostName) {
        guard case .loaded(let list) = namesPhase else { return }
        namesPhase = .loaded(list.filter { $0.id != name.id })
        nameMarkFailed = false
        Task {
            if await model.searchNames.mark(postKey, .no, on: name.id) == nil {
                namesPhase = .loaded(list)
                withAnimation(Motion.rows) { nameMarkFailed = true }
            }
        }
    }
}

// MARK: - On This Device / Offline Card

struct StudioDeckOfflineCard: View {
    let model: AppModel
    let item: MediaItem
    let rendition: Rendition

    @State private var confirmRemove = false

    private var state: RenditionOffline { model.offlineState(of: rendition) }

    private var isOn: Bool {
        switch state {
        case .offline, .downloading, .waiting: return true
        case .cached, .failed, .none, .unavailable: return false
        }
    }

    private var isOffline: Bool {
        if case .offline = state { return true }
        return false
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private var inUse: Bool { rendition.local.map { model.store.isInUse($0.id) } ?? false }

    private var disabled: Bool {
        if case .unavailable = state { return true }
        return isOffline && inUse
    }

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { isOn },
            set: { on in
                if on {
                    model.keepOffline(item, rendition: rendition)
                } else if isOffline {
                    confirmRemove = true
                } else {
                    model.stopDownloading(item, rendition: rendition)
                }
            }
        )
    }

    private var iconSymbol: String {
        switch state {
        case .offline: return "checkmark.circle.fill"
        case .downloading, .waiting: return "arrow.down.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .cached, .none, .unavailable: return Symbol.keepOffline
        }
    }

    private var iconTint: Color {
        switch state {
        case .offline: return Color(hex: 0x34d399)
        case .downloading, .waiting: return CobaltColor.linkBlue
        case .failed: return CobaltColor.errorText
        case .cached, .none, .unavailable: return .white.opacity(0.78)
        }
    }

    var body: some View {
        let currentState = state
        let onlyCopy = model.isOnlyCopy(rendition)
        let place = OfflineWords.keptPlace(of: rendition, model: model)
        let formatLabel = OfflineWords.typeLabel(rendition).uppercased()

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StudioDeckSectionLabel(text: Copy.Storage.group)
                Spacer(minLength: 4)
                Text(formatLabel)
                    .font(Font.cobalt(10, .semibold, relativeTo: .caption2))
                    .foregroundStyle(.white.opacity(0.84))
                    .tracking(0.5)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Color.white.opacity(0.09), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75))
            }

            Toggle(isOn: toggleBinding) {
                HStack(spacing: 10) {
                    Image(systemName: iconSymbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(iconTint)
                        .frame(width: 28, height: 28)
                        .background(iconTint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentTransition(.symbolEffect(.replace))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(Copy.Offline.keep)
                            .font(Font.cobalt(13, .semibold, relativeTo: .subheadline))
                            .foregroundStyle(.white)
                        Text(OfflineWords.status(currentState, place: place))
                            .font(Font.cobalt(11.5, .regular, relativeTo: .caption))
                            .foregroundStyle(isFailed ? CobaltColor.errorText : .secondary)
                            .monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .toggleStyle(.switch)
            .tint(Color(hex: 0x34d399))
            .disabled(disabled)
            .confirmationDialog(
                OfflineWords.removeTitle(onlyCopy: onlyCopy),
                isPresented: $confirmRemove,
                titleVisibility: .visible
            ) {
                Button(Copy.remove, role: .destructive) {
                    Task { await model.removeOfflineCopy(item, rendition: rendition) }
                }
                Button(Copy.keep, role: .cancel) {}
            } message: {
                Text(OfflineWords.removeMessage(onlyCopy: onlyCopy))
            }

            if case .downloading(let progress) = currentState {
                if let fraction = OfflineWords.fraction(progress) {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(CobaltColor.linkBlue)
                        .accessibilityHidden(true)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(CobaltColor.linkBlue)
                        .accessibilityHidden(true)
                }
            }

            if isFailed {
                Button {
                    model.keepOffline(item, rendition: rendition)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: Symbol.retry)
                            .font(.system(size: 11.5, weight: .semibold))
                        Text(Copy.tryAgain)
                            .font(Font.cobalt(12, .semibold, relativeTo: .caption))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 32)
                    .background(Color.white.opacity(0.1), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75))
                }
                .buttonStyle(.plain)
            }
        }
        .studioDeckCard()
        .hapticChange(.success, trigger: currentState, when: Self.justLanded)
        .haptic(.error, trigger: currentState, when: Self.justFailed)
    }

    private static func justLanded(_ old: RenditionOffline, _ new: RenditionOffline) -> Bool {
        if case .downloading = old, case .offline = new { return true }
        return false
    }

    private static func justFailed(_ state: RenditionOffline) -> Bool {
        if case .failed = state { return true }
        return false
    }
}

// MARK: - What It's About + Search Index + Names Card

struct StudioDeckAboutCard: View {
    let model: AppModel
    let postKey: String
    let refreshKey: String
    let store: StudioDeckInsightStore
    let onOpenPost: (LibraryPost) -> Void
    let onBeforeOpenName: () -> Void

    @Environment(\.subtitles) private var subtitles
    @State private var draft = ""
    @State private var showsTranscript = false
    @State private var showsClosestWords = true
    @State private var showsSearchInput = false
    @State private var tagsAdded = 0
    @State private var tagsRemoved = 0
    @State private var saveFailures = 0
    @State private var nameMarks = 0
    @FocusState private var addingTag: Bool

    var body: some View {
        if model.capabilities.about {
            richAboutCard
        } else {
            plainSearchIndexCard
        }
    }

    // MARK: Full "What It's About" Card

    private var richAboutCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                StudioDeckSectionLabel(text: Copy.Search.aboutSection)
                Spacer(minLength: 4)
                if case .loading = store.aboutPhase {
                    ProgressView().controlSize(.mini).tint(.secondary)
                } else if case .loaded(let about) = store.aboutPhase, let index = about.index, index.searchEnabled {
                    SearchIndexBadge(state: index.state)
                }
            }

            aboutBody

            if model.capabilities.names {
                StudioDeckHairline()
                namesBlock
            }
        }
        .studioDeckCard()
        .task(id: "\(postKey)|\(refreshKey)") {
            await store.loadAbout(model: model, postKey: postKey, refreshKey: refreshKey)
        }
        .task(id: "\(postKey)|\(model.searchNames.revision)") {
            guard model.capabilities.names else { return }
            await store.loadNames(model: model, postKey: postKey, revision: model.searchNames.revision)
        }
        .motion(Motion.rows, value: store.aboutPhase)
        .haptic(.impact(weight: .light), trigger: tagsAdded)
        .haptic(.impact(weight: .light), trigger: tagsRemoved)
        .haptic(.error, trigger: saveFailures)
        .haptic(.impact(weight: .light), trigger: nameMarks)
    }

    @ViewBuilder
    private var aboutBody: some View {
        switch store.aboutPhase {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(.white.opacity(0.75))
                Text(Copy.Search.aboutLoading)
                    .font(Font.cobalt(12.5, .regular, relativeTo: .caption))
                    .foregroundStyle(.secondary)
            }
        case .notFound:
            quietLine(Copy.Search.notListed)
        case .failed:
            quietLine(Copy.Search.aboutUnavailable)
        case .loaded(let about):
            if about.index?.searchEnabled == false {
                quietLine(Copy.Search.searchOff)
            } else {
                loadedAbout(about)
            }
        }
    }

    @ViewBuilder
    private func loadedAbout(_ about: LibraryAbout) -> some View {
        if let words = about.about {
            if let sentence = words.sentence {
                Text(sentence)
                    .font(Font.cobalt(13, .regular, relativeTo: .body))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            StudioDeckHairline()
            heardBlock(words)

            StudioDeckHairline()
            tagsBlock(words)
        } else {
            undescribedBlock(about.probe)
        }

        if about.about != nil || !about.words.isEmpty {
            StudioDeckHairline()
            closestWordsBlock(about.words)
        }

        if let index = about.index {
            StudioDeckHairline()
            searchedByDisclosure(index)
        }

        let near = about.neighbourPosts
        if !near.isEmpty {
            StudioDeckHairline()
            closestVideosRail(near)
        }
    }

    @ViewBuilder
    private func undescribedBlock(_ probe: LibraryAbout.Probe) -> some View {
        switch probe {
        case .pending:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(.white.opacity(0.75))
                Text(Copy.Search.aboutPending)
                    .font(Font.cobalt(12.5, .regular, relativeTo: .caption))
                    .foregroundStyle(.secondary)
            }
        case .failed:
            quietLine(Copy.Search.aboutFailed)
        case .done, .none, .unknown:
            quietLine(Copy.Search.aboutNotDescribed)
        }
    }

    // MARK: Heard

    private func heardBlock(_ words: LibraryAbout.About) -> some View {
        let timed = subtitles?.postKey == postKey ? subtitles?.transcript : nil
        let hasTimedLines = timed?.hasLines == true
        let language = timed?.language ?? words.language

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label(Copy.Search.heard.uppercased(), systemImage: Symbol.SearchIndex.heard)
                    .font(Font.cobalt(10, .semibold, relativeTo: .caption2))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                Spacer(minLength: 4)
                if let language, !language.isEmpty {
                    Text(Copy.Search.language(language))
                        .font(Font.cobalt(10, .medium, relativeTo: .caption2))
                        .foregroundStyle(.white.opacity(0.72))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.07), in: Capsule())
                }
            }

            if let subtitles, hasTimedLines, let timed {
                SubtitleHeardList(session: subtitles, transcript: timed)
            } else if let transcript = words.transcript {
                Text(transcript)
                    .font(Font.cobalt(12, .regular, relativeTo: .caption))
                    .foregroundStyle(.white.opacity(0.84))
                    .lineSpacing(2)
                    .lineLimit(showsTranscript ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(Motion.rows) { showsTranscript.toggle() }
                    }
            } else {
                Text(words.hasAudio ? Copy.Search.noSpeech : Copy.Search.noSound)
                    .font(Font.cobalt(12, .regular, relativeTo: .caption))
                    .foregroundStyle(.secondary)
            }

            if !words.soundTags.isEmpty {
                AboutFlow(spacing: 5) {
                    ForEach(words.soundTags, id: \.self) { tag in
                        StudioDeckTagChip(tag: tag, tone: .sound)
                    }
                }
            }
        }
        .accessibilityElement(children: hasTimedLines ? .contain : .combine)
    }

    // MARK: Tags

    private func tagsBlock(_ words: LibraryAbout.About) -> some View {
        let trimmedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                StudioDeckSectionLabel(text: words.edited ? Copy.Search.editedTags : Copy.Search.tags)
                Text("\(words.tags.count)/\(LibraryAbout.maxTags)")
                    .font(Font.cobalt(10, .regular, relativeTo: .caption2))
                    .foregroundStyle(.secondary.opacity(0.8))
                    .monospacedDigit()
                Spacer(minLength: 4)
                if words.edited {
                    Button {
                        store.commitTags(model: model, postKey: postKey, tags: nil) { saveFailures += 1 }
                    } label: {
                        Label(Copy.Search.resetTags, systemImage: Symbol.SearchIndex.resetTags)
                            .font(Font.cobalt(10.5, .medium, relativeTo: .caption2))
                            .foregroundStyle(.white.opacity(0.82))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(Color.white.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Copy.Search.resetTagsA11yHint)
                }
            }

            if !words.tags.isEmpty {
                AboutFlow(spacing: 6) {
                    ForEach(words.tags, id: \.self) { tag in
                        StudioDeckTagChip(tag: tag, tone: words.edited ? .owner : .written) {
                            tagsRemoved += 1
                            store.commitTags(model: model, postKey: postKey, tags: words.tags.filter { $0 != tag }) {
                                saveFailures += 1
                            }
                        }
                    }
                }
            }

            if words.tags.count < LibraryAbout.maxTags {
                HStack(spacing: 6) {
                    Image(systemName: Symbol.SearchIndex.addTag)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)

                    TextField(Copy.Search.addTag, text: $draft)
                        .textFieldStyle(.plain)
                        .font(Font.cobalt(12, .regular, relativeTo: .caption))
                        .foregroundStyle(.white)
                        .focused($addingTag)
                        .submitLabel(.done)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .onSubmit { addTag(to: words) }
                        .onChange(of: draft) { _, new in
                            if new.count > LibraryAbout.maxTagLength {
                                draft = String(new.prefix(LibraryAbout.maxTagLength))
                            }
                        }
                        .accessibilityLabel(Copy.Search.addTagA11y)

                    if !trimmedDraft.isEmpty {
                        Button {
                            addTag(to: words)
                        } label: {
                            Text("Add")
                                .font(Font.cobalt(11, .semibold, relativeTo: .caption2))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Color.white, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(addingTag ? CobaltColor.linkBlue.opacity(0.55) : Color.white.opacity(0.1), lineWidth: 0.75)
                )
            } else {
                quietLine(Copy.Search.tagsFull)
            }

            if store.tagSaveFailed {
                Text(Copy.Search.tagsNotSaved)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.errorText)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
    }

    private func addTag(to words: LibraryAbout.About) {
        defer { addingTag = true }
        guard let tag = LibraryAbout.cleanTag(draft) else {
            draft = ""
            return
        }
        draft = ""
        guard !words.tags.contains(tag), words.tags.count < LibraryAbout.maxTags else { return }
        tagsAdded += 1
        store.commitTags(model: model, postKey: postKey, tags: words.tags + [tag]) { saveFailures += 1 }
    }

    // MARK: Reads Closest To (Collapsible Similarity Bars)

    private func closestWordsBlock(_ words: [LibraryAbout.Word]) -> some View {
        let top = max(words.map(\.score).max() ?? 0, 0.01)
        return VStack(alignment: .leading, spacing: 7) {
            Button {
                withAnimation(Motion.rows) { showsClosestWords.toggle() }
            } label: {
                HStack(spacing: 6) {
                    StudioDeckSectionLabel(text: Copy.Search.closestWords)
                    if !words.isEmpty {
                        Text("\(words.count)")
                            .font(Font.cobalt(10, .medium, relativeTo: .caption2))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Color.white.opacity(0.07), in: Capsule())
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showsClosestWords ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsClosestWords {
                if words.isEmpty {
                    quietLine(Copy.Search.noWords)
                } else {
                    VStack(alignment: .leading, spacing: 5.5) {
                        ForEach(words) { entry in
                            StudioDeckSimilarityBar(
                                word: entry.word,
                                score: entry.score,
                                fraction: entry.score / top
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: What It's Searched By (Collapsible Search Index Metadata)

    private func searchedByDisclosure(_ status: LibrarySearchStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(Motion.rows) { showsSearchInput.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text(Copy.Search.whatWasEmbedded)
                        .font(Font.cobalt(12.5, .medium, relativeTo: .caption))
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showsSearchInput ? 90 : 0))
                }
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsSearchInput {
                StudioDeckSearchIndexDetails(status: status)
                    .padding(10)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.75)
                    )
            }
        }
    }

    // MARK: Closest Videos Horizontal Rail

    private func closestVideosRail(_ near: [(post: LibraryPost, score: Double)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                StudioDeckSectionLabel(text: Copy.Search.closestVideos)
                Text("\(near.count)")
                    .font(Font.cobalt(10, .medium, relativeTo: .caption2))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: 4)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(near.enumerated()), id: \.offset) { index, entry in
                        StudioDeckNeighbourTile(
                            model: model,
                            post: entry.post,
                            score: entry.score,
                            index: index,
                            open: onOpenPost
                        )
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    // MARK: Names Pills

    private var namesBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            StudioDeckSectionLabel(text: Copy.Names.detailRow)

            switch store.namesPhase {
            case .idle, .loading:
                ProgressView().controlSize(.small).tint(.white.opacity(0.75))
            case .failed:
                quietLine(Copy.Names.detailFailed)
            case .loaded(let list):
                if list.isEmpty {
                    quietLine(Copy.Names.detailNone)
                } else {
                    AboutFlow(spacing: 6) {
                        ForEach(list) { name in
                            StudioDeckNamePill(name: name) {
                                onBeforeOpenName()
                                Task { await model.searchNames.open(id: name.id) }
                            } notThis: {
                                nameMarks += 1
                                store.markNotName(model: model, postKey: postKey, name: name)
                            }
                        }
                    }
                }
            }

            if store.nameMarkFailed {
                Text(Copy.Names.markFailed)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.errorText)
                    .transition(.opacity)
            }
        }
    }

    // MARK: Fallback Search Index Card (when `features.search` is on without `features.about`)

    private var plainSearchIndexCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StudioDeckSectionLabel(text: Copy.Search.section)
                Spacer(minLength: 4)
                if case .loading = store.indexPhase {
                    ProgressView().controlSize(.mini).tint(.secondary)
                } else if case .loaded(let status) = store.indexPhase, status.searchEnabled {
                    SearchIndexBadge(state: status.state)
                }
            }

            switch store.indexPhase {
            case .idle, .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(.white.opacity(0.75))
                    Text(Copy.Search.loading)
                        .font(Font.cobalt(12.5, .regular, relativeTo: .caption))
                        .foregroundStyle(.secondary)
                }
            case .notFound:
                quietLine(Copy.Search.notListed)
            case .failed:
                quietLine(Copy.Search.unavailable)
            case .loaded(let status):
                if !status.searchEnabled {
                    quietLine(Copy.Search.searchOff)
                } else {
                    StudioDeckSearchIndexDetails(status: status)
                }
            }
        }
        .studioDeckCard()
        .task(id: "\(postKey)|\(refreshKey)") {
            await store.loadIndex(model: model, postKey: postKey, refreshKey: refreshKey)
        }
        .motion(Motion.rows, value: store.indexPhase)
    }

    private func quietLine(_ text: String) -> some View {
        Text(text)
            .font(Font.cobalt(12, .regular, relativeTo: .caption))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Studio Deck About Subcomponents

private struct StudioDeckTagChip: View {
    enum Tone { case written, owner, sound }

    let tag: String
    var tone: Tone = .written
    var remove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Text(tag)
                .font(Font.cobalt(11.5, .medium, relativeTo: .caption))
                .foregroundStyle(ink)
                .lineLimit(1)

            if let remove {
                Button(action: remove) {
                    Image(systemName: Symbol.SearchIndex.removeTag)
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(ink.opacity(0.68))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Copy.Search.removeTag(tag))
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, remove == nil ? 9 : 4)
        .padding(.vertical, 4)
        .background(fill, in: Capsule())
        .overlay(Capsule().strokeBorder(border, lineWidth: 0.75))
        .accessibilityElement(children: remove == nil ? .combine : .contain)
    }

    private var ink: Color {
        switch tone {
        case .written: return .white.opacity(0.9)
        case .owner: return CobaltColor.sharedInk
        case .sound: return .white.opacity(0.72)
        }
    }

    private var fill: Color {
        switch tone {
        case .written: return Color.white.opacity(0.08)
        case .owner: return CobaltColor.linkBlue.opacity(0.18)
        case .sound: return Color.white.opacity(0.05)
        }
    }

    private var border: Color {
        switch tone {
        case .written: return Color.white.opacity(0.12)
        case .owner: return CobaltColor.linkBlue.opacity(0.36)
        case .sound: return Color.white.opacity(0.09)
        }
    }
}

private struct StudioDeckSimilarityBar: View {
    let word: String
    let score: Double
    let fraction: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(word)
                .font(Font.cobalt(11.5, .regular, relativeTo: .caption))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 94, alignment: .leading)

            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [CobaltColor.focus.opacity(0.72), CobaltColor.focus],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .scaleEffect(x: max(0.04, min(1, fraction)), y: 1, anchor: .leading)
            }
            .frame(height: 5.5)
            .motion(Motion.rows, value: fraction)

            Text(Copy.Search.scoreText(score))
                .font(Font.cobalt(11, .regular, relativeTo: .caption2))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.Search.wordA11y(word, score: score))
    }
}

private struct StudioDeckSearchIndexDetails: View {
    let status: LibrarySearchStatus

    private var posterIncluded: Bool {
        status.hasImage ?? (status.input?.imageURL != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                VStack(alignment: .leading, spacing: 4) {
                    SearchIndexBadge(state: status.state)
                    if let line = Copy.Search.detail(status, now: timeline.date) {
                        Text(line)
                            .font(Font.cobalt(11, .regular, relativeTo: .caption2))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if status.state == .indexed, status.embeddedMatchesInput == false {
                        Text(Copy.Search.changedSince)
                            .font(Font.cobalt(11, .regular, relativeTo: .caption2))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }

            HStack {
                Text(Copy.Search.posterIncluded)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(posterIncluded ? Copy.Search.yes : Copy.Search.no)
                    .foregroundStyle(.white.opacity(0.9))
            }
            .font(Font.cobalt(11.5, .medium, relativeTo: .caption))

            if status.attempts > 1 || status.state == .failed || status.state == .gaveUp {
                HStack {
                    Text(Copy.Search.attempts)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text("\(status.attempts)")
                        .foregroundStyle(.white.opacity(0.9))
                        .monospacedDigit()
                }
                .font(Font.cobalt(11.5, .medium, relativeTo: .caption))
            }

            if let input = status.input {
                StudioDeckHairline()
                inputRow(Copy.Search.titleLabel, input.title)
                inputRow(Copy.Search.textLabel, input.text)
                inputRow(Copy.Search.posterLabel, input.imageURL?.absoluteString)
                if let model = status.model {
                    inputRow(Copy.Search.model, status.dims.map { "\(model) · \($0)" } ?? model)
                }
            }
        }
    }

    private func inputRow(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Font.cobalt(10, .semibold, relativeTo: .caption2))
                .foregroundStyle(.secondary)
                .tracking(0.4)
            Text(value.flatMap { $0.isEmpty ? nil : $0 } ?? Copy.Search.none)
                .font(Font.cobalt(11.5, .regular, relativeTo: .caption))
                .foregroundStyle(.white.opacity(0.84))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct StudioDeckNeighbourTile: View {
    let model: AppModel
    let post: LibraryPost
    let score: Double
    let index: Int
    let open: (LibraryPost) -> Void

    var body: some View {
        let row = LibraryRow(item: model.mediaItem(for: post))
        let shareURL = model.capabilities.liveLink(for: row.item.face)

        Button {
            open(post)
        } label: {
            Color.clear
                .frame(width: 76, height: 76)
                .overlay {
                    FacePicture(item: row.item, maxPixel: 256, gradient: FrameGradient.variant(forIndex: index))
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(Copy.Chat.collageOpen, systemImage: Symbol.Library.open) { open(post) }
            if let shareURL {
                ShareLink(item: shareURL) {
                    Label(Copy.Chat.collageShare, systemImage: Symbol.Library.share)
                }
            }
        } preview: {
            LibraryPreviewCard(row: row)
        }
        .accessibilityLabel(Copy.Search.closestA11y(row.title, score: score))
        .accessibilityHint(Copy.Chat.openPostA11yHint)
        .accessibilityAddTraits(.isButton)
    }
}

private struct StudioDeckNamePill: View {
    let name: PostName
    let open: () -> Void
    let notThis: () -> Void

    private var isRejected: Bool { name.mark == .no }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: open) {
                Text(Copy.Names.detailChip(name))
                    .font(Font.cobalt(11.5, .semibold, relativeTo: .caption))
                    .foregroundStyle(isRejected ? CobaltColor.errorText : CobaltColor.sharedInk)
                    .monospacedDigit()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        (isRejected ? CobaltColor.errorText : CobaltColor.linkBlue).opacity(0.16),
                        in: Capsule()
                    )
                    .overlay(
                        Capsule().strokeBorder(
                            (isRejected ? CobaltColor.errorText : CobaltColor.linkBlue).opacity(0.36),
                            lineWidth: 0.75
                        )
                    )
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Copy.Names.openName(name.name))

            if !isRejected {
                Button(action: notThis) {
                    Text(Copy.Names.notThis(name.name))
                        .font(Font.cobalt(11, .medium, relativeTo: .caption2))
                        .foregroundStyle(.white.opacity(0.68))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.05), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Copy.Names.notThisA11y(name.name))
            }
        }
    }
}

// MARK: - Booru Card

struct StudioDeckBooruCard: View {
    let model: AppModel
    let item: MediaItem
    let rendition: Rendition

    @State private var showFindSheet = false

    private var fileID: String? { rendition.file?.id ?? item.post?.files.first?.id }
    private var linkedURL: URL? {
        guard let url = item.post?.link, url.host == "danbooru.donmai.us" else { return nil }
        return url
    }
    private var isLinked: Bool { linkedURL != nil }

    var body: some View {
        if let fileID {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    StudioDeckSectionLabel(text: Copy.BooruFind.header)
                    Spacer(minLength: 4)
                    if isLinked {
                        HStack(spacing: 4) {
                            Circle().fill(Color(hex: 0x34d399)).frame(width: 5.5, height: 5.5)
                            Text("LINKED")
                                .font(Font.cobalt(9.5, .semibold, relativeTo: .caption2))
                                .tracking(0.5)
                        }
                        .foregroundStyle(Color(hex: 0x34d399))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Color(hex: 0x34d399).opacity(0.14), in: Capsule())
                    }
                }

                Button {
                    showFindSheet = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: Symbol.Booru.search)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.88))
                        Text(isLinked ? Copy.BooruFind.findAgain : Copy.BooruFind.find)
                            .font(Font.cobalt(13, .semibold, relativeTo: .subheadline))
                            .foregroundStyle(.white)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 11)
                    .frame(minHeight: 40)
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.11), lineWidth: 0.75)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)

                if let linkedURL {
                    Link(destination: linkedURL) {
                        HStack(spacing: 8) {
                            Image(systemName: Symbol.Booru.open)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(CobaltColor.sharedInk)
                            Text(Copy.BooruFind.linkedTo(linkedURL))
                                .font(Font.cobalt(12, .medium, relativeTo: .caption))
                                .foregroundStyle(CobaltColor.sharedInk)
                                .monospacedDigit()
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(CobaltColor.linkBlue.opacity(0.2), lineWidth: 0.75)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .studioDeckCard()
            .sheet(isPresented: $showFindSheet) {
                BooruFindSheet(model: model, fileID: fileID, rendition: rendition)
            }
        }
    }
}

// MARK: - From The Post Card (Video Post Frame Metadata & Framed Copies)

struct StudioDeckPostFrameCard: View {
    let model: AppModel
    let item: MediaItem

    private var itemID: String? { model.postFrameSource(item) }

    var body: some View {
        if let itemID {
            let running = model.postFrameRenders(of: itemID)
            let copies = Array(model.framedCopies(of: itemID).prefix(6))

            VStack(alignment: .leading, spacing: 10) {
                StudioDeckSectionLabel(text: Copy.PostFrame.fromThePost)

                if let details = model.postFrames.state(for: itemID)?.details, details.found {
                    HStack(alignment: .top, spacing: 10) {
                        PostAvatar(name: details.displayName ?? details.host ?? "?", data: model.postFrames.avatars[itemID], size: 30)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(Copy.PostFrame.whoLine(details))
                                .font(Font.cobalt(12.5, .semibold, relativeTo: .caption))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            if let words = details.text ?? details.title {
                                Text(words)
                                    .font(Font.cobalt(12, .regular, relativeTo: .caption))
                                    .foregroundStyle(.white.opacity(0.84))
                                    .lineLimit(3)
                            }
                            if let counts = Copy.PostFrame.countsLine(details.counts) {
                                Text(counts)
                                    .font(Font.cobalt(11, .regular, relativeTo: .caption2))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                } else {
                    PostFrameDetailsLine(model: model, itemID: itemID)
                }

                if !running.isEmpty || !copies.isEmpty {
                    StudioDeckHairline()
                    VStack(alignment: .leading, spacing: 8) {
                        StudioDeckSectionLabel(text: Copy.PostFrame.framedCopies)
                        ForEach(running) { render in
                            renderRow(render)
                        }
                        ForEach(copies) { post in
                            copyRow(post, style: model.framedCopyStyle(post))
                        }
                    }
                    .motion(Motion.rows, value: running.map(\.id) + copies.map(\.id))
                }
            }
            .studioDeckCard()
            .task(id: itemID) {
                await model.postFrames.loadIfNeeded(itemID: itemID)
            }
        }
    }

    private func renderRow(_ render: EditRender) -> some View {
        let line: String = switch render.status {
        case .queued: Copy.PostFrame.queuedLine
        case .error, .cancelled: Copy.PostFrame.renderFailed
        default: Copy.PostFrame.rendering(Int(((render.progress ?? 0) * 100).rounded()))
        }
        return HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08))
                if render.status == .error {
                    Image(systemName: Symbol.PostFrame.gone).foregroundStyle(CobaltColor.errorText)
                } else {
                    ProgressView(value: min(1, max(0, render.progress ?? 0)))
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(.white)
                }
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(render.title)
                    .font(Font.cobalt(12, .medium, relativeTo: .caption))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(line)
                    .font(Font.cobalt(11, .regular, relativeTo: .caption2))
                    .foregroundStyle(render.status == .error ? CobaltColor.errorText : .secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func copyRow(_ post: LibraryPost, style: PostFrameStyle?) -> some View {
        let poster = post.posterURL ?? post.files.first?.posterURL
        return HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08))
                if let poster {
                    RemoteStill(poster: RemotePoster(url: poster, isVideo: false), maxPixel: 120)
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(post.customTitle ?? post.title ?? Copy.PostFrame.postFrame)
                    .font(Font.cobalt(12, .medium, relativeTo: .caption))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(Copy.PostFrame.copyLine(style: style, created: post.createdAt))
                    .font(Font.cobalt(11, .regular, relativeTo: .caption2))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
