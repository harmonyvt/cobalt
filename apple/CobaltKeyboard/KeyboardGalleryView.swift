import CobaltKit
import SwiftUI

/// The keyboard gallery: a clear panel, square tiles, and one caption. No search field, no toolbar.
struct KeyboardGalleryView: View {
    let model: KeyboardGalleryModel

    /// Four columns once the panel is wider than 420.
    private static let widePanel: CGFloat = 420

    var body: some View {
        VStack(spacing: 0) {
            content
            if model.fullAccess, model.phase == .ready || model.notice != nil {
                caption
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }

    private var caption: some View {
        let text: String
        let color: Color
        switch model.notice {
        case .copied:
            text = KeyboardWords.copied
            color = CobaltColor.text
        case .failed(let message):
            text = message
            color = CobaltColor.errorText
        case nil:
            text = KeyboardWords.idle
            color = CobaltColor.caption
        }
        return Text(text)
            .font(Font.cobalt(12))
            .textCase(.lowercase)
            .foregroundStyle(color)
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
            case .ready: grid
            }
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
                    ForEach(model.posts) { post in
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

/// One face. The long press is exclusive of the tap, so a hold does not also copy the file.
private struct KeyboardTile: View {
    let post: LibraryPost
    let model: KeyboardGalleryModel

    private var face: Rendition? { KeyboardFace.of(post) }
    private var busy: Bool { model.busyID == post.id }

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { picture }
            .clipShape(RoundedRectangle(cornerRadius: Metrics.thumbRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Metrics.thumbRadius, style: .continuous))
            .gesture(
                LongPressGesture(minimumDuration: 0.45).onEnded { _ in hold() }
                    .exclusively(before: TapGesture().onEnded { copy() })
            )
            .onAppear { model.loadMoreIfNeeded(showing: post.id) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(KeyboardFace.label(post: post, face: face))
            .accessibilityHint(KeyboardWords.idle)
            .accessibilityAddTraits(busy ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { copy() }
            .accessibilityAction(named: Text("hold for the link")) { hold() }
    }

    private func hold() { model.onHold(post) }
    private func copy() { model.onCopy(post) }

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
            if let face, !KeyboardFace.isPicture(face) {
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
}
