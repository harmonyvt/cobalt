import CobaltKit
import SwiftUI

/// The keyboard gallery. Filters match the library. A tile with a video and a webp asks which to copy.
struct KeyboardGalleryView: View {
    let model: KeyboardGalleryModel

    private static let widePanel: CGFloat = 420

    var body: some View {
        VStack(spacing: 0) {
            if model.fullAccess, model.phase == .ready {
                if model.searching { searchPill } else { chips }
            }
            if model.searching {
                emoteRow
                KeyboardKeys { model.type($0) } backspace: { model.backspace() }
            } else {
                content
                if let id = model.chooserPostID, let post = model.posts.first(where: { $0.id == id }) {
                    chooser(post)
                }
            }
            if model.fullAccess, model.phase == .ready || model.notice != nil || model.transfer != nil {
                caption
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .task(id: model.emoteQuery) {
            guard model.searching else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await model.loadEmotes()
        }
    }

    private var chips: some View {
        ZStack(alignment: .trailing) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(LibraryKindFilter.allCases, id: \.self) { kind in
                        let selected = model.kind == kind
                        Button {
                            model.setKind(kind)
                        } label: {
                            Text(Copy.Library2.name(kind))
                                .font(Font.cobalt(12, selected ? .semibold : .regular, relativeTo: .caption))
                                .foregroundStyle(selected ? CobaltColor.onText : Color.primary)
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 28)
                                .background(Capsule().fill(selected ? CobaltColor.text : CobaltColor.elevated))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(.leading, Metrics.gutter)
                // The globe owns the last 52pt. The glass sits just to its left.
                .padding(.trailing, 96)
                .padding(.vertical, 4)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollEdgeEffectHidden(true)

            Button { model.beginSearch() } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 52)
            .accessibilityLabel(Copy.seventvA11y)
        }
    }

    private var searchPill: some View {
        HStack(spacing: 8) {
            Text(model.emoteQuery.isEmpty ? Copy.seventvA11y : model.emoteQuery)
                .font(Font.cobalt(14))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { model.stopSearch() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Copy.cancel)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(minHeight: 36)
        .background(Capsule().fill(CobaltColor.elevated))
        .padding(.leading, Metrics.gutter)
        .padding(.trailing, 52)
        .padding(.vertical, 4)
    }

    private var emoteRow: some View {
        Group {
            if let note = model.emoteNote, model.emoteHits.isEmpty {
                Text(note)
                    .font(Font.cobalt(12))
                    .foregroundStyle(CobaltColor.caption)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    // lazy: only the emotes on screen are built, decoded and animated (the extension's memory is small)
                    LazyHStack(spacing: 8) {
                        ForEach(model.emoteHits) { hit in
                            EmoteKeyTile(hit: hit, saving: model.savingEmoteID == hit.id) {
                                model.onCopyEmote(hit)
                            } hold: {
                                model.onHoldEmote(hit)
                            } save: {
                                Task { await model.saveEmote(hit) }
                            }
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 4)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var captionLine: (text: String, color: Color) {
        switch model.notice {
        case .copied:
            return (KeyboardWords.copied, CobaltColor.text)
        case .failed(let message):
            return (message, CobaltColor.errorText)
        case nil:
            if let transfer = model.transfer {
                return ("\(transfer.title)\n\(transfer.detail)", CobaltColor.text)
            }
            if model.chooserPostID != nil {
                let line = model.sendsHostedLink ? KeyboardWords.chooseLink : KeyboardWords.chooseFile
                return (line, CobaltColor.caption)
            }
            if model.asksToChoose {
                return (KeyboardWords.choose, CobaltColor.caption)
            }
            return (KeyboardWords.idle, CobaltColor.caption)
        }
    }

    private var caption: some View {
        let line = captionLine
        return Text(line.text)
            .font(Font.cobalt(12))
            .textCase(.lowercase)
            .foregroundStyle(line.color)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, 2)
            .padding(.bottom, 6)
    }

    @ViewBuilder
    private var content: some View {
        if !model.fullAccess {
            message(KeyboardWords.noAccess, color: CobaltColor.text)
        } else {
            switch model.phase {
            case .loading: status(ProgressView(), color: CobaltColor.caption)
            case .noKey: message(KeyboardWords.noKey, color: CobaltColor.text)
            case .empty: message(Copy.libraryEmpty, color: CobaltColor.caption)
            case .failed: message(Copy.actionFailed, color: CobaltColor.errorText)
            case .ready:
                if model.visiblePosts.isEmpty {
                    let text = model.kind == .emotes
                        ? KeyboardWords.emoteEmpty
                        : Copy.Library2.nothingOfKind(model.kind, kept: false)
                    message(text, color: CobaltColor.caption)
                } else {
                    grid
                }
            }
        }
    }

    private func chooser(_ post: LibraryPost) -> some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.choices(for: post)) { choice in
                        ChoiceButton(
                            title: choice.label,
                            holdName: model.sendsHostedLink ? "hold to copy the file" : "hold for the link"
                        ) {
                            send(post, choice, asLink: model.sendsHostedLink)
                        } hold: {
                            send(post, choice, asLink: !model.sendsHostedLink)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollEdgeEffectHidden(true)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            SendAsToggle(hostedLink: model.sendsHostedLink) { model.sendsHostedLink = $0 }
                .layoutPriority(1)
        }
        .padding(.horizontal, Metrics.gutter)
    }

    private func send(_ post: LibraryPost, _ choice: KeyboardChoice, asLink: Bool) {
        if asLink {
            model.onHold(post, choice)
        } else {
            model.onCopy(post, choice)
        }
    }

    private func message(_ text: String, color: Color) -> some View {
        status(Text(text).font(Font.cobalt(12)).foregroundStyle(color).multilineTextAlignment(.center), color: color)
    }

    private func status<V: View>(_ view: V, color: Color) -> some View {
        GeometryReader { geo in
            ScrollView {
                view
                    .padding(.horizontal, Metrics.gutter)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.always)
            .scrollEdgeEffectHidden(true)
            .refreshable { await model.refresh() }
        }
        .foregroundStyle(color)
    }

    private var grid: some View {
        GeometryReader { geo in
            let columns = Array(
                repeating: GridItem(.flexible(), spacing: 8),
                count: geo.size.width > Self.widePanel ? 4 : 3)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(model.visiblePosts) { post in
                        KeyboardTile(post: post, model: model)
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 8)
            }
            .scrollBounceBehavior(.always)
            .scrollEdgeEffectHidden(true)
            .refreshable { await model.refresh() }
        }
    }
}

/// Actual file or hosted link, pinned to the right of the webp / video choices.
private struct SendAsToggle: View {
    let hostedLink: Bool
    let choose: (Bool) -> Void

    var body: some View {
        HStack(spacing: 2) {
            segment("actual file", on: !hostedLink) { choose(false) }
            segment("hosted link", on: hostedLink) { choose(true) }
        }
        .padding(2)
        .background(Capsule().fill(CobaltColor.elevated))
        .fixedSize()
        .accessibilityElement(children: .contain)
    }

    private func segment(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Font.cobalt(11, on ? .semibold : .regular, relativeTo: .caption))
                .foregroundStyle(on ? CobaltColor.onText : Color.primary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(minHeight: 28)
                .background {
                    if on { Capsule().fill(CobaltColor.text) }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

private struct EmoteKeyTile: View {
    let hit: EmoteHit
    let saving: Bool
    let copy: () -> Void
    let hold: () -> Void
    let save: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .topTrailing) {
                EmotePicture(url: hit.previewURL, animated: hit.animated, side: 56)
                .contentShape(Rectangle())
                .gesture(
                    LongPressGesture(minimumDuration: 0.45).onEnded { _ in hold() }
                        .exclusively(before: TapGesture().onEnded { copy() })
                )
                Button(action: save) {
                    Image(systemName: hit.libraryID == nil ? "square.and.arrow.down" : "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(CobaltColor.elevated))
                }
                .buttonStyle(.plain)
                .disabled(hit.libraryID != nil || saving)
                .accessibilityLabel(hit.libraryID == nil ? "save" : "saved")
                if saving { ProgressView().controlSize(.mini) }
            }
            Text(hit.name)
                .font(Font.cobalt(10))
                .lineLimit(1)
                .frame(width: 64)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(hit.name)
    }
}

private struct ChoiceButton: View {
    let title: String
    var holdName = "hold for the link"
    let copy: () -> Void
    let hold: () -> Void

    var body: some View {
        Text(title)
            .font(Font.cobalt(13, .semibold, relativeTo: .caption))
            .foregroundStyle(CobaltColor.onText)
            .padding(.horizontal, 14)
            .frame(minHeight: 32)
            .background(Capsule().fill(CobaltColor.text))
            .contentShape(Capsule())
            .gesture(
                LongPressGesture(minimumDuration: 0.45).onEnded { _ in hold() }
                    .exclusively(before: TapGesture().onEnded { copy() })
            )
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { copy() }
            .accessibilityAction(named: Text(holdName)) { hold() }
    }
}

/// One post. The long press is exclusive of the tap, so a hold does not also copy.
private struct KeyboardTile: View {
    let post: LibraryPost
    let model: KeyboardGalleryModel

    private var face: Rendition? { KeyboardFace.of(post) }
    private var busy: Bool { model.busyID == post.id }
    private var several: Bool { model.kind == .all && model.choices(for: post).count > 1 }
    private var showsVideo: Bool {
        !several && model.relevant(post).contains { $0.label == "video" }
    }

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { picture }
            .clipShape(RoundedRectangle(cornerRadius: Metrics.thumbRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Metrics.thumbRadius, style: .continuous))
            .gesture(
                LongPressGesture(minimumDuration: 0.45).onEnded { _ in model.hold(post) }
                    .exclusively(before: TapGesture().onEnded { model.tap(post) })
            )
            .onAppear { model.loadMoreIfNeeded(showing: post.id) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(KeyboardFace.label(post: post, face: face))
            .accessibilityHint(several ? KeyboardWords.choose : KeyboardWords.idle)
            .accessibilityAddTraits(busy ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { model.tap(post) }
    }

    private var picture: some View {
        ZStack {
            CobaltColor.elevated
            if let face, let url = KeyboardFace.thumbnailURL(post: post, face: face) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    }
                }
            }
            if several {
                mark("+")
            } else if showsVideo {
                Image(systemName: Symbol.typeVideo)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(CobaltColor.badgeInk)
                    .frame(width: 18, height: 18)
                    .background(CobaltColor.badgeBack, in: Circle())
                    .padding(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .allowsHitTesting(false)
            }
            if busy {
                ProgressView()
                    .controlSize(.small)
                    .tint(CobaltColor.badgeInk)
                    .padding(6)
                    .background(CobaltColor.badgeBack, in: Circle())
                    .allowsHitTesting(false)
            }
        }
    }

    private func mark(_ text: String) -> some View {
        Text(text)
            .font(Font.cobalt(12, .semibold, relativeTo: .caption))
            .foregroundStyle(CobaltColor.badgeInk)
            .frame(width: 18, height: 18)
            .background(CobaltColor.badgeBack, in: Circle())
            .padding(5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .allowsHitTesting(false)
    }
}
