import CobaltKit
import SwiftUI

// The post-frame sheet (APP-API-CONTRACT 52.6, the mockup's sections 2 and 3): a live preview drawn from the post's details,
// style chips, light or dark, the size, which parts to show, and "make framed copy". From the item page it frames the whole
// video and offers "open in editor for more"; from the editor's "post" tool it frames the main clip with its trim and lets
// the details be fixed (saved with PATCH when they changed). The framed copy is a render of the queue: closing the sheet
// stops nothing.

/// What the sheet frames.
struct PostFrameTarget: Identifiable, Equatable {
    enum Mode: Equatable {
        /// The item page: the whole video.
        case item
        /// The editor: the main clip's trim (seconds of the source); the details can be edited.
        case editor(from: Double, to: Double)
    }

    /// The library item (the video's file on the server).
    let itemID: String
    let mode: Mode
    /// The page it was saved from, when known (the item page); the editor reads the style from the details.
    var link: URL?
    var poster: URL?
    var width: Int?
    var height: Int?
    var duration: Double?
    /// The media, for "open in editor for more" (the item page only).
    var media: MediaItem?

    var id: String { itemID }

    var isEditor: Bool { mode != .item }

    /// The video's width over its height (16:9 when unknown).
    var aspect: CGFloat {
        guard let width, let height, width > 0, height > 0 else { return 16 / 9 }
        return CGFloat(width) / CGFloat(height)
    }

    /// The length the copy will have: the trim's, else the video's.
    var length: Double? {
        if case .editor(let from, let to) = mode, to > from { return to - from }
        return duration
    }

    /// The item page's target for a media (nil when it cannot be framed).
    @MainActor
    static func item(_ item: MediaItem, model: AppModel) -> PostFrameTarget? {
        guard model.canPostFrame(item), let id = model.postFrameSource(item), let video = item.video else { return nil }
        return PostFrameTarget(
            itemID: id, mode: .item, link: item.link, poster: video.posterURL ?? video.file?.posterURL,
            width: video.width ?? video.file?.width, height: video.height ?? video.file?.height,
            duration: video.duration ?? video.file?.duration, media: item)
    }
}

struct PostFrameSheet: View {
    let model: AppModel
    let target: PostFrameTarget

    @Environment(\.dismiss) private var dismiss
    @Environment(\.shell) private var shell
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var style: PostFrameStyle
    @State private var styleTouched = false
    @State private var theme: PostFrameTheme
    @State private var canvas: PostFrameCanvas
    @State private var show: PostFrameShow
    /// The editor's fields, seeded from the details once they arrive.
    @State private var fields = PostDetailsFields()
    @State private var seeded = false
    @State private var making = false
    @State private var problem: String?
    @State private var failTick = 0
    @State private var styleTick = 0

    init(model: AppModel, target: PostFrameTarget) {
        self.model = model
        self.target = target
        let look = model.settings.postFrameLook
        _style = State(initialValue: PostFrameStyle(link: target.link))
        _theme = State(initialValue: look.theme)
        _canvas = State(initialValue: look.canvas)
        _show = State(initialValue: look.show)
    }

    private var state: PostDetailsState? { model.postFrames.state(for: target.itemID) }
    private var details: PostDetails? { state?.details }

    /// The details as the card draws them: the editor's typed fields over the stored ones.
    private var drawn: PostDetails? {
        guard let details else { return nil }
        return target.isEditor ? details.applying(fields) : details
    }

    private var content: PostCardContent {
        PostCardContent(
            details: drawn, style: style, theme: theme, show: show, videoAspect: target.aspect, poster: target.poster,
            duration: target.length, avatar: model.postFrames.avatars[target.itemID])
    }

    private var canMake: Bool {
        guard !making else { return false }
        if case .failed(let why)? = state, why == .noLink || why == .off || why == .notFound { return false }
        return true
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                PostFrameSheetPreview(content: content, canvas: canvas)
                PostFrameDetailsLine(model: model, itemID: target.itemID, isEditor: target.isEditor)
                styleRow
                PostFrameSegments(label: Copy.PostFrame.look, selection: $theme, options: PostFrameTheme.allCases) {
                    Copy.PostFrame.themeName($0)
                }
                PostFrameSegments(
                    label: target.isEditor ? Copy.PostFrame.canvas : Copy.PostFrame.size, selection: $canvas,
                    options: PostFrameCanvas.allCases
                ) { Copy.PostFrame.canvasName($0) }
                PostFrameShowChips(show: $show, textTitle: target.isEditor ? Copy.PostFrame.postText : Copy.PostFrame.text)
                if target.isEditor { PostFrameFields(fields: $fields, style: style) }
                footer
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 16)
        }
        .modifier(PostFrameSheetChrome(making: making, failTick: failTick, styleTick: styleTick, isAccessibilitySize: typeSize.isAccessibilitySize))
        .task(id: target.itemID) { await model.postFrames.loadIfNeeded(itemID: target.itemID) }
        .onChange(of: details, initial: true) { _, fresh in adopt(fresh) }
    }

    // MARK: parts

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(target.isEditor ? Copy.PostFrame.editorTitle : Copy.PostFrame.sheetTitle)
                .font(Font.cobalt(16, .semibold, relativeTo: .headline))
                .foregroundStyle(CobaltColor.text)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            CloseButton(cancels: true) { dismiss() }
                .disabled(making)
        }
    }

    private var styleLabel: String {
        if let host = details?.host ?? target.link?.host(percentEncoded: false) { return Copy.PostFrame.styleFound(host) }
        return Copy.PostFrame.style
    }

    private var styleRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            PostFrameRowLabel(text: styleLabel)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(PostFrameStyle.allCases, id: \.self) { s in
                        PostFrameChip(title: Copy.PostFrame.styleName(s), on: style == s) { pick(s) }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.PostFrame.style)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(target.isEditor ? Copy.PostFrame.editorNote : Copy.PostFrame.note)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
                .fixedSize(horizontal: false, vertical: true)
            if let problem {
                Text(problem)
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.errorText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            Button(making ? Copy.PostFrame.making : Copy.PostFrame.make, systemImage: Symbol.PostFrame.frame) { make() }
                .buttonStyle(.cobaltPrimary())
                .keyboardShortcut(.defaultAction)
                .disabled(!canMake)
            if !target.isEditor, target.media != nil, model.editor.isAvailable {
                Button(Copy.PostFrame.openInEditor, systemImage: Symbol.PostFrame.openInEditor) { openInEditor() }
                    .buttonStyle(.cobaltSecondary())
                    .disabled(making)
            }
        }
    }

    // MARK: actions

    private func pick(_ s: PostFrameStyle) {
        guard s != style else { return }
        styleTouched = true
        style = s
        styleTick += 1
    }

    /// The details arrived (or changed): the style follows the post's site until one is picked; the editor's fields start
    /// from the stored ones, once.
    private func adopt(_ fresh: PostDetails?) {
        guard let fresh else { return }
        if !styleTouched { style = fresh.site }
        guard target.isEditor, !seeded else { return }
        seeded = true
        fields = PostDetailsFields(
            name: fresh.name ?? "", handle: fresh.handle ?? "", text: fresh.text ?? "", title: fresh.title ?? "",
            channel: fresh.channel ?? "", game: fresh.game ?? "")
    }

    private func make() {
        guard canMake else { return }
        making = true
        problem = nil
        var chosen = PostFrameOptions(style: style, theme: theme, canvas: canvas, show: show)
        if case .editor(let from, let to) = target.mode {
            chosen.from = from
            chosen.to = to
        }
        let base = chosen
        let itemID = target.itemID
        let isEditor = target.isEditor
        let typed = fields
        let stored = details
        model.settings.postFrameLook = PostFrameLook(theme: theme, canvas: canvas, show: show)
        Task {
            defer { making = false }
            var options = base
            if isEditor, let stored {
                // fixed details are saved for good; if the save fails they still go into this copy
                let patch = PostDetailsPatch(from: stored, to: typed)
                if !patch.isEmpty {
                    do { try await model.postFrames.save(itemID: itemID, patch) }
                    catch { options.details = Self.overrides(stored, typed) }
                }
            }
            do {
                try await model.makePostFrame(itemID: itemID, options: options)
                let model = self.model
                shell.showNote(StatusNote(
                    text: Copy.PostFrame.queued, detail: Copy.PostFrame.queuedDetail, actionTitle: Copy.PostFrame.openQueue
                ) { model.showQueue() })
                dismiss()
            } catch {
                problem = Copy.PostFrame.message(for: error)
                failTick += 1
            }
        }
    }

    /// The typed fields that differ from the stored ones, for this render only.
    private static func overrides(_ stored: PostDetails, _ typed: PostDetailsFields) -> PostDetailsFields {
        func changed(_ was: String?, _ now: String?) -> String? {
            guard let now else { return nil }
            let clean = now.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean == (was ?? "") ? nil : clean
        }
        return PostDetailsFields(
            name: changed(stored.name, typed.name), handle: changed(stored.handle, typed.handle), text: changed(stored.text, typed.text),
            title: changed(stored.title, typed.title), channel: changed(stored.channel, typed.channel),
            game: changed(stored.game, typed.game))
    }

    private func openInEditor() {
        guard let media = target.media else { return }
        model.settings.postFrameLook = PostFrameLook(theme: theme, canvas: canvas, show: show)
        let model = self.model
        let shell = self.shell
        dismiss()
        Task {
            do { try await model.openPostFrameInEditor(media) }
            catch { shell.showStatus(Copy.Editor.couldntCreate) }
        }
    }
}

// MARK: - the sheet's parts

/// The sheet's background, size and haptics, in one modifier so the body stays easy to type-check.
private struct PostFrameSheetChrome: ViewModifier {
    let making: Bool
    let failTick: Int
    let styleTick: Int
    let isAccessibilitySize: Bool

    func body(content: Content) -> some View {
        content
            #if os(macOS)
            .frame(width: 460, height: 640)
            #else
            .presentationDetents(isAccessibilitySize ? [.large] : [.medium, .large])
            .presentationDragIndicator(.visible)
            #endif
            .background(CobaltColor.bg)
            .interactiveDismissDisabled(making)
            .haptic(.error, trigger: failTick)
            .haptic(.selection, trigger: styleTick)
            .accessibilityElement(children: .contain)
    }
}

/// The live preview, in a dark well like the mockup's.
private struct PostFrameSheetPreview: View {
    let content: PostCardContent
    let canvas: PostFrameCanvas

    var body: some View {
        PostFramePreview(content: content, canvas: canvas, maxWidth: 300, maxHeight: 250)
            .frame(maxWidth: .infinity)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(hex: 0x0e0e11)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Copy.PostFrame.preview)
    }
}

/// A small caption over a row of choices.
struct PostFrameRowLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(CobaltType.captionSmall)
            .foregroundStyle(CobaltColor.caption)
            .accessibilityHidden(true)
    }
}

/// One labelled segmented choice.
struct PostFrameSegments<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [Value]
    let name: (Value) -> String

    init(label: String, selection: Binding<Value>, options: [Value], name: @escaping (Value) -> String) {
        self.label = label
        self._selection = selection
        self.options = options
        self.name = name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PostFrameRowLabel(text: label)
            Picker(label, selection: $selection) {
                ForEach(options, id: \.self) { value in
                    Text(name(value)).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(label)
        }
        .haptic(.selection, trigger: selection)
    }
}

/// A chip: a capsule with a word, filled when on.
struct PostFrameChip: View {
    let title: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(CobaltType.buttonSmall)
                .foregroundStyle(on ? CobaltColor.onText : CobaltColor.text)
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .background(Capsule().fill(on ? CobaltColor.text : CobaltColor.surface))
                .overlay { Capsule().stroke(CobaltColor.border.opacity(on ? 0 : 0.6), lineWidth: 1) }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(minHeight: Metrics.hit)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// "show": avatar, text, likes and views, time.
struct PostFrameShowChips: View {
    @Binding var show: PostFrameShow
    var textTitle: String = Copy.PostFrame.text

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PostFrameRowLabel(text: Copy.PostFrame.show)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    PostFrameChip(title: Copy.PostFrame.avatar, on: show.avatar) { show.avatar.toggle() }
                    PostFrameChip(title: textTitle, on: show.text) { show.text.toggle() }
                    PostFrameChip(title: Copy.PostFrame.counts, on: show.counts) { show.counts.toggle() }
                    PostFrameChip(title: Copy.PostFrame.time, on: show.time) { show.time.toggle() }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .haptic(.selection, trigger: show)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.PostFrame.show)
    }
}

/// The line about the details: "looking up the post…", "couldn't find the post…" (with "look up again"), or nothing once
/// they are here.
struct PostFrameDetailsLine: View {
    let model: AppModel
    let itemID: String
    var isEditor = false

    @State private var refreshing = false

    private var state: PostDetailsState? { model.postFrames.state(for: itemID) }

    var body: some View {
        switch state {
        case .loading?, nil:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(Copy.PostFrame.looking)
            }
            .font(CobaltType.captionSmall)
            .foregroundStyle(CobaltColor.caption)
        case .loaded(let d)?:
            if !d.found { goneLine }
        case .failed(let why)?:
            failedLine(why)
        }
    }

    private var goneLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: Symbol.PostFrame.gone).accessibilityHidden(true)
            Text(isEditor ? Copy.PostFrame.goneShort : Copy.PostFrame.gone)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            refreshButton
        }
        .font(CobaltType.captionSmall)
        .foregroundStyle(CobaltColor.caption)
    }

    @ViewBuilder
    private func failedLine(_ why: PostDetailsProblem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.words(why)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if why == .offline || why == .failed { refreshButton }
        }
        .font(CobaltType.captionSmall)
        .foregroundStyle(CobaltColor.errorText)
    }

    private var refreshButton: some View {
        Button {
            refreshing = true
            Task {
                await model.postFrames.load(itemID: itemID, refresh: true)
                refreshing = false
            }
        } label: {
            Label(Copy.PostFrame.lookUpAgain, systemImage: Symbol.PostFrame.lookUpAgain)
        }
        .buttonStyle(.cobaltIcon(.small, state: refreshing ? .working : .idle))
        .disabled(refreshing)
    }

    static func words(_ why: PostDetailsProblem) -> String {
        switch why {
        case .noLink: return Copy.PostFrame.noLink
        case .notFound: return Copy.PostFrame.message(for: PostFrameError.notFound)
        case .off: return Copy.PostFrame.off
        case .offline, .failed: return Copy.PostFrame.failed
        }
    }
}

/// The editor's details: name, handle, the post's text, and a title for the sites that have one.
private struct PostFrameFields: View {
    @Binding var fields: PostDetailsFields
    let style: PostFrameStyle

    private var hasTitle: Bool { style == .youtube || style == .twitch || style == .generic }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PostFrameRowLabel(text: Copy.PostFrame.detailsHeader)
            if style == .twitch || style == .youtube {
                PostFrameField(title: Copy.PostFrame.channel, text: binding(\.channel))
            }
            PostFrameField(title: Copy.PostFrame.name, text: binding(\.name))
            if style != .twitch { PostFrameField(title: Copy.PostFrame.handle, text: binding(\.handle)) }
            if hasTitle { PostFrameField(title: Copy.PostFrame.title, text: binding(\.title)) }
            if style == .twitch { PostFrameField(title: Copy.PostFrame.game, text: binding(\.game)) }
            PostFrameField(title: Copy.PostFrame.postText, text: binding(\.text), multiline: true)
            Text(Copy.PostFrame.shownAsPosted)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
        }
    }

    private func binding(_ key: WritableKeyPath<PostDetailsFields, String?>) -> Binding<String> {
        Binding(get: { fields[keyPath: key] ?? "" }, set: { fields[keyPath: key] = $0 })
    }
}

private struct PostFrameField: View {
    let title: String
    @Binding var text: String
    var multiline = false

    var body: some View {
        TextField(title, text: $text, axis: multiline ? .vertical : .horizontal)
            .lineLimit(multiline ? 2...6 : 1...1)
            .font(CobaltType.body)
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(CobaltColor.surface))
            .accessibilityLabel(title)
    }
}
