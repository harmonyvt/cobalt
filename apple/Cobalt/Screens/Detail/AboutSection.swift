import CobaltKit
import SwiftUI

// "What it's about" (APP-API-CONTRACT 34.7; only with `features.about`, which needs `features.search`): what the server's
// embedding of the post is made of, in plain words. The sentence it wrote from three frames, what it heard, the tags
// (the owner's to edit), the words the vector reads closest to as bars, what it is searched by (folded: the index badge,
// dates, title, text, poster, model), and the four closest videos. Loaded when the detail opens, and again after a rename
// (`refreshKey`). Editing the tags is optimistic: the chips change at once, the server answers, a refusal puts them back
// with a quiet line.

struct AboutSection: View {
    let model: AppModel
    /// The post's key (`LibraryPost.id`).
    let postKey: String
    /// Anything that changes what the post is embedded from (its title): a change loads it again.
    var refreshKey: String = ""

    enum Phase: Equatable { case loading, loaded(LibraryAbout), notFound, failed }

    @State private var phase: Phase = .loading
    /// What the server last answered: where a refused edit goes back to.
    @State private var confirmed: LibraryAbout?
    @State private var showsFold = false
    @State private var showsTranscript = false
    @State private var draft = ""
    @State private var saveFailed = false
    /// The newest edit; an older answer never lands over it.
    @State private var generation = 0
    @State private var opened: OpenedMedia?
    @State private var tagsAdded = 0
    @State private var tagsRemoved = 0
    @State private var saveFailures = 0
    @FocusState private var adding: Bool
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var pushes: Bool { sizeClass == .compact }
    #else
    private var pushes: Bool { false }
    #endif

    var body: some View {
        Section {
            content
        } header: {
            Text(Copy.Search.aboutSection)
        }
        .task(id: "\(postKey)|\(refreshKey)") { await load() }
        .motion(Motion.rows, value: phase)
    }

    // MARK: states

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(Copy.Search.aboutLoading)
            }
            .font(CobaltType.body)
            .foregroundStyle(.secondary)
        case .notFound:
            quiet(Copy.Search.notListed)
        case .failed:
            quiet(Copy.Search.aboutUnavailable)
        case .loaded(let about):
            if about.index?.searchEnabled == false {
                quiet(Copy.Search.searchOff)
            } else {
                loaded(about)
            }
        }
    }

    private func quiet(_ text: String) -> some View {
        Text(text)
            .font(CobaltType.body)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func loaded(_ about: LibraryAbout) -> some View {
        if let words = about.about {
            if let sentence = words.sentence {
                Text(sentence)
                    .font(CobaltType.body)
                    .foregroundStyle(CobaltColor.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            heard(words)
            tagsRow(words)
        } else {
            undescribed(about.probe)
        }
        if about.about != nil || !about.words.isEmpty {
            closestWords(about.words)
        }
        if let index = about.index {
            DisclosureGroup(isExpanded: $showsFold) {
                SearchIndexRows(status: index, showsInput: .constant(true), inline: true)
            } label: {
                Text(Copy.Search.whatWasEmbedded)
                    .font(CobaltType.body)
            }
        }
        let near = about.neighbourPosts
        if !near.isEmpty {
            closestVideos(near)
        }
    }

    @ViewBuilder
    private func undescribed(_ probe: LibraryAbout.Probe) -> some View {
        switch probe {
        case .pending:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(Copy.Search.aboutPending)
            }
            .font(CobaltType.body)
            .foregroundStyle(.secondary)
        case .failed:
            quiet(Copy.Search.aboutFailed)
        case .done, .none, .unknown:
            quiet(Copy.Search.aboutNotDescribed)
        }
    }

    // MARK: heard

    private func heard(_ words: LibraryAbout.About) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(Copy.Search.heard, systemImage: Symbol.SearchIndex.heard)
                .font(CobaltType.captionSmall)
                .foregroundStyle(.secondary)
            if let transcript = words.transcript {
                Text(transcript)
                    .font(CobaltType.captionSmall)
                    .lineLimit(showsTranscript ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(Motion.rows) { showsTranscript.toggle() } }
                if let language = words.language {
                    Text(Copy.Search.language(language))
                        .font(CobaltType.badge)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(words.hasAudio ? Copy.Search.noSpeech : Copy.Search.noSound)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(.secondary)
            }
            if !words.soundTags.isEmpty {
                AboutFlow(spacing: 6) {
                    ForEach(words.soundTags, id: \.self) { AboutTagChip(tag: $0, tone: .sound) }
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    // MARK: tags

    private func tagsRow(_ words: LibraryAbout.About) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(words.edited ? Copy.Search.editedTags : Copy.Search.tags)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if words.edited {
                    Button {
                        commit(nil)
                    } label: {
                        Label(Copy.Search.resetTags, systemImage: Symbol.SearchIndex.resetTags)
                            .font(CobaltType.captionSmall)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityHint(Copy.Search.resetTagsA11yHint)
                }
            }
            AboutFlow(spacing: 6) {
                ForEach(words.tags, id: \.self) { tag in
                    AboutTagChip(tag: tag, tone: words.edited ? .owner : .written) { remove(tag, from: words) }
                }
            }
            if words.tags.count < LibraryAbout.maxTags {
                addField(words)
            } else {
                Text(Copy.Search.tagsFull)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(.secondary)
            }
            if saveFailed {
                Text(Copy.Search.tagsNotSaved)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.errorText)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 2)
        .modifier(AboutTagHaptics(added: tagsAdded, removed: tagsRemoved, failed: saveFailures))
    }

    private func addField(_ words: LibraryAbout.About) -> some View {
        HStack(spacing: 6) {
            Image(systemName: Symbol.SearchIndex.addTag)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(Copy.Search.addTag, text: $draft)
                .font(CobaltType.captionSmall)
                .focused($adding)
                .submitLabel(.done)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit { add(to: words) }
                .onChange(of: draft) { _, new in
                    if new.count > LibraryAbout.maxTagLength { draft = String(new.prefix(LibraryAbout.maxTagLength)) }
                }
                .accessibilityLabel(Copy.Search.addTagA11y)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(CobaltColor.elevated.opacity(0.6), in: Capsule())
    }

    private func add(to words: LibraryAbout.About) {
        defer { adding = true }
        guard let tag = LibraryAbout.cleanTag(draft) else {
            draft = ""
            return
        }
        draft = ""
        guard !words.tags.contains(tag), words.tags.count < LibraryAbout.maxTags else { return }
        tagsAdded += 1
        commit(words.tags + [tag])
    }

    private func remove(_ tag: String, from words: LibraryAbout.About) {
        tagsRemoved += 1
        commit(words.tags.filter { $0 != tag })
    }

    /// Shows the new tags (nil: reset) at once, asks the server, and lands its answer; a refusal puts the last answer back.
    private func commit(_ tags: [String]?) {
        guard case .loaded(let current) = phase, var words = current.about else { return }
        if let tags {
            words.tags = tags
            words.edited = true
        } else {
            words.edited = false
        }
        var next = current
        next.about = words
        phase = .loaded(next)
        saveFailed = false
        generation += 1
        let mine = generation
        let key = postKey
        Task {
            do {
                let answer = try await model.library.setAboutTags(postKey: key, tags: tags)
                confirmed = answer
                guard mine == generation, key == postKey else { return }
                phase = .loaded(answer)
            } catch {
                guard mine == generation, key == postKey, !(error is CancellationError) else { return }
                phase = .loaded(confirmed ?? current)
                withAnimation(Motion.rows) { saveFailed = true }
                saveFailures += 1
            }
        }
    }

    // MARK: reads closest to

    private func closestWords(_ words: [LibraryAbout.Word]) -> some View {
        let top = max(words.map(\.score).max() ?? 0, 0.01)
        return VStack(alignment: .leading, spacing: 6) {
            Text(Copy.Search.closestWords)
                .font(CobaltType.captionSmall)
                .foregroundStyle(.secondary)
            if words.isEmpty {
                Text(Copy.Search.noWords)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(words) { AboutWordBar(word: $0.word, score: $0.score, fraction: $0.score / top) }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: closest videos

    private func closestVideos(_ near: [(post: LibraryPost, score: Double)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Copy.Search.closestVideos)
                .font(CobaltType.captionSmall)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(Array(near.enumerated()), id: \.offset) { index, entry in
                    AboutNeighbourTile(model: model, post: entry.post, score: entry.score, index: index) { open($0) }
                }
                // a short list keeps its tiles' size
                ForEach(0..<max(0, 4 - near.count), id: \.self) { _ in Color.clear.aspectRatio(1, contentMode: .fit) }
            }
        }
        .padding(.vertical, 2)
        .navigationDestination(item: $opened) { target in
            MediaDetail(model: model, item: target.item, initial: target.initial)
        }
    }

    /// A close video: the phone pushes its detail, the iPad and Mac show it in the library tab (as the chat does).
    private func open(_ post: LibraryPost) {
        if pushes {
            let item = model.mediaItem(for: post)
            opened = OpenedMedia(item: item, initial: item.face.id)
        } else {
            model.revealInLibrary(postID: post.id)
        }
    }

    // MARK: loading

    private func load() async {
        if case .loaded = phase {} else { phase = .loading }
        do {
            let about = try await model.library.about(postKey: postKey)
            guard !Task.isCancelled else { return }
            confirmed = about
            phase = .loaded(about)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            phase = LibraryModel.searchErrorCode(error) == "error.library.not_found" ? .notFound : .failed
        }
    }
}

// MARK: - pieces

/// A tag as a small capsule; with `remove`, a × beside it.
struct AboutTagChip: View {
    enum Tone { case written, owner, sound }

    let tag: String
    var tone: Tone = .written
    var remove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Text(tag)
                .font(CobaltType.captionSmall)
                .foregroundStyle(ink)
                .lineLimit(1)
            if let remove {
                Button(action: remove) {
                    Image(systemName: Symbol.SearchIndex.removeTag)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(ink.opacity(0.7))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Copy.Search.removeTag(tag))
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, remove == nil ? 9 : 3)
        .padding(.vertical, 3)
        .background(back, in: Capsule())
        .accessibilityElement(children: remove == nil ? .combine : .contain)
    }

    private var ink: Color {
        switch tone {
        case .written: return CobaltColor.text
        case .owner: return CobaltColor.linkBlue
        case .sound: return CobaltColor.captionOnElevated
        }
    }

    private var back: Color {
        switch tone {
        case .written: return CobaltColor.elevated
        case .owner: return CobaltColor.linkBlue.opacity(0.12)
        case .sound: return CobaltColor.elevated.opacity(0.6)
        }
    }
}

/// One word the vector reads close to: the word, a bar as long as its value against the best one, the value.
struct AboutWordBar: View {
    let word: String
    let score: Double
    /// 0...1 against the closest word.
    let fraction: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(word)
                .font(CobaltType.captionSmall)
                .lineLimit(1)
                .frame(width: 92, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule().fill(CobaltColor.elevated)
                Capsule()
                    .fill(CobaltColor.focus)
                    .scaleEffect(x: max(0.03, min(1, fraction)), y: 1, anchor: .leading)
            }
            .frame(height: 6)
            .motion(Motion.rows, value: fraction)
            Text(Copy.Search.scoreText(score))
                .font(CobaltType.captionSmall)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.Search.wordA11y(word, score: score))
    }
}

/// A close post as a square picture; tap opens it, long press shows it bigger with open and share (like a collage tile).
struct AboutNeighbourTile: View {
    let model: AppModel
    let post: LibraryPost
    let score: Double
    let index: Int
    let open: (LibraryPost) -> Void

    var body: some View {
        let row = LibraryRow(item: model.mediaItem(for: post))
        let shareURL = row.item.face.publicURL.map { model.capabilities.shareLink(for: $0) }
        Button { open(post) } label: {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    FacePicture(item: row.item, maxPixel: 256, gradient: FrameGradient.variant(forIndex: index))
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(Copy.Chat.collageOpen, systemImage: Symbol.Library.open) { open(post) }
            if let shareURL {
                ShareLink(item: shareURL) { Label(Copy.Chat.collageShare, systemImage: Symbol.Library.share) }
            }
        } preview: {
            LibraryPreviewCard(row: row)
        }
        .accessibilityLabel(Copy.Search.closestA11y(row.title, score: score))
        .accessibilityHint(Copy.Chat.openPostA11yHint)
        .accessibilityAddTraits(.isButton)
    }
}

/// A tag added or removed ticks; a refused save thuds.
private struct AboutTagHaptics: ViewModifier {
    let added: Int
    let removed: Int
    let failed: Int

    func body(content: Content) -> some View {
        content
            .haptic(.impact(weight: .light), trigger: added)
            .haptic(.impact(weight: .light), trigger: removed)
            .haptic(.error, trigger: failed)
    }
}

/// Wraps its children onto lines, left to right, as many to a line as fit.
struct AboutFlow: Layout {
    var spacing: CGFloat = 6

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var used: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            x += size.width + spacing
            used = max(used, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return (frames, CGSize(width: used, height: y + rowHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? result.size.width, height: result.size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(subviews, width: bounds.width)
        for (index, subview) in subviews.enumerated() {
            let frame = result.frames[index]
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}

#if DEBUG
/// One section per state of the preview server: described with sound (the fursuit sample), described with no speech,
/// cutting frames, probed but not described, an image-only post with owner-less tags, and a key the server does not know.
@MainActor
private struct AboutPreview: View {
    @State private var model: AppModel

    init() {
        _model = State(initialValue: AppModel.previewSearch(.ready))
    }

    var body: some View {
        NavigationStack {
            Form {
                ForEach([PreviewData.aboutFursuitKey, "Dd55fEyN1Yy", "Dd7P496wolG", "2105432512428445875", "Dd5JFkMDt4N", "nope"], id: \.self) {
                    AboutSection(model: model, postKey: $0)
                }
            }
            .formStyle(.grouped)
        }
    }
}

#Preview("what it's about · every state") {
    AboutPreview()
}

#Preview("what it's about · every state, dark") {
    AboutPreview()
        .preferredColorScheme(.dark)
}

/// The whole detail of the first preview post, the section at the end.
@MainActor
private struct AboutDetailPreview: View {
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

#Preview("detail · what it's about") {
    AboutDetailPreview()
}
#endif
