import CobaltKit
import SwiftUI

/// The keyboard gallery. Filters match the library. A tile with a video and a webp asks which to copy.
struct KeyboardGalleryView: View {
    let model: KeyboardGalleryModel

    private static let widePanel: CGFloat = 420

    var body: some View {
        VStack(spacing: 0) {
            if model.fullAccess, model.phase == .ready {
                chips
            }
            content
            if let id = model.chooserPostID, let post = model.posts.first(where: { $0.id == id }) {
                chooser(post)
            }
            if model.fullAccess, model.phase == .ready || model.notice != nil || model.transfer != nil {
                caption
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }

    private var chips: some View {
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
            .padding(.trailing, 52)
            .padding(.vertical, 4)
        }
        .scrollBounceBehavior(.basedOnSize)
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
                    message(Copy.Library2.nothingOfKind(model.kind, kept: false), color: CobaltColor.caption)
                } else {
                    grid
                }
            }
        }
    }

    private func chooser(_ post: LibraryPost) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.choices(for: post)) { choice in
                    ChoiceButton(title: choice.label) {
                        model.onCopy(post, choice)
                    } hold: {
                        model.onHold(post, choice)
                    }
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 4)
        }
        .scrollBounceBehavior(.basedOnSize)
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
            .refreshable { await model.refresh() }
        }
    }
}

private struct ChoiceButton: View {
    let title: String
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
            .accessibilityAction(named: Text("hold for the link")) { hold() }
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
