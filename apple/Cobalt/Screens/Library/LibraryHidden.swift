import CobaltKit
import SwiftUI

// The views of the hidden album (APP-API-CONTRACT 37.7): the locked card, the note over the grid, the empty state, the
// cover for the app switcher, and the `status…` menu the select panel and the Mac's context menu share.

/// What the album shows until the owner passes the lock: a lock, `hidden is locked`, what is in there, and the button
/// that asks again (`view with face id`, `view with touch id`, or `unlock`). The system sheet is asked for once when
/// this appears (`LibraryController.promptIfNeeded`).
struct HiddenLockedCard: View {
    let controller: LibraryController

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: Symbol.HiddenAlbum.lock)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(CobaltColor.caption)
                    .frame(width: 72, height: 72)
                    .background(CobaltColor.elevated, in: Circle())
                    .accessibilityHidden(true)
                Text(Copy.HiddenAlbum.lockedTitle)
                    .font(Font.cobalt(17, .semibold, relativeTo: .headline))
                    .foregroundStyle(CobaltColor.text)
                Text(Copy.HiddenAlbum.lockedNote)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                if controller.lockFailed {
                    Text(Copy.HiddenAlbum.lockFailed)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.errorText)
                }
                Button {
                    Task { await controller.unlockHidden() }
                } label: {
                    HStack(spacing: 8) {
                        if controller.unlocking { ProgressView().controlSize(.small) }
                        Text(Copy.HiddenAlbum.viewWith(controller.lockMethod))
                    }
                }
                .buttonStyle(.cobaltPrimary(fullWidth: false))
                .disabled(controller.unlocking)
                .accessibilityHint(Copy.HiddenAlbum.lockedA11yHint)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 56)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onAppear {
            controller.lockMethod = HiddenLock.method()
            controller.promptIfNeeded()
        }
    }
}

/// The line over the grid: `6 hidden · badge says who hid it`.
struct HiddenAlbumNote: View {
    let count: Int

    var body: some View {
        Text(Copy.HiddenAlbum.note(count))
            .font(CobaltType.captionSmall)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .contentTransition(.numericText())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(.bar)
            .accessibilityAddTraits(.isHeader)
    }
}

/// `nothing hidden`, with what lands here.
struct HiddenAlbumEmpty: View {
    var body: some View {
        ContentUnavailableView {
            Label(Copy.HiddenAlbum.empty, systemImage: Symbol.HiddenAlbum.empty)
                .font(CobaltType.body)
        } description: {
            Text(Copy.HiddenAlbum.emptyNote)
                .font(CobaltType.captionSmall)
        }
    }
}

/// Over an open album while the app is not active (the app switcher takes its snapshot then): the album is not
/// in it. iPhone and iPad only; on the Mac an inactive window is just another window being clicked.
struct HiddenCover: View {
    var body: some View {
        ZStack {
            CobaltColor.bg.ignoresSafeArea()
            Image(systemName: Symbol.HiddenAlbum.lock)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(CobaltColor.caption)
        }
        .accessibilityHidden(true)
    }
}

/// `HiddenCover` over whatever this is applied to, while the album is open and the app is not active. Applied outermost on
/// the library screen, and again inside the pushed detail and the inspector, which are not under the screen's own overlay.
struct HiddenCoverModifier: ViewModifier {
    let controller: LibraryController
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.overlay {
            #if os(iOS)
            if controller.albumOpen, scenePhase != .active { HiddenCover() }
            #endif
        }
    }
}

/// Outermost on the library screen: a post that became hidden (from its detail, a menu, another device) leaves the pushed
/// detail, the inspector and every sheet holding it; and the app switcher's cover goes over everything, the pushed detail
/// and the inspector included.
struct LibraryHiddenWatchers: ViewModifier {
    let model: AppModel
    let controller: LibraryController

    func body(content: Content) -> some View {
        content
            .onChange(of: model.library.hiddenVersion) { controller.closeHiddenDetails() }
            .onChange(of: controller.albumOpen) { controller.closeHiddenDetails() }
            .hiddenCover(controller)
    }
}

extension View {
    func hiddenCover(_ controller: LibraryController) -> some View { modifier(HiddenCoverModifier(controller: controller)) }
}

/// The corner badge of a hidden post: who hid it (`you`, `rule`, `chat`).
struct HiddenByBadge: View {
    let by: HiddenBy

    var body: some View {
        Text(Copy.HiddenAlbum.by(by))
            .font(Font.cobalt(9.5, .medium, relativeTo: .caption2))
            .foregroundStyle(CobaltColor.badgeInk)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(CobaltColor.badgeBack, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.75))
            .accessibilityLabel(Copy.HiddenAlbum.byA11y(by))
    }
}

extension LibraryRow {
    /// The row is one of the album's.
    var isHidden: Bool { item.post?.hidden == true }

    /// Who hid the post, when the row is one of the album's.
    var hiddenBy: HiddenBy? {
        guard let post = item.post, post.hidden else { return nil }
        return post.hiddenBy
    }
}

/// The `status…` menu's items: hidden, off, public link, private link (private only on a server with private links).
/// Every status is offered whatever the posts are now; the server reports what it could not change.
struct StatusMenuItems: View {
    let model: AppModel
    let act: (PostStatus) -> Void

    var body: some View {
        Button(Copy.HiddenAlbum.statusHidden, systemImage: Symbol.HiddenAlbum.hidden) { act(.hidden) }
        Button(Copy.HiddenAlbum.statusOff, systemImage: Symbol.HiddenAlbum.off) { act(.off) }
        Button(Copy.HiddenAlbum.statusPublic, systemImage: Symbol.HiddenAlbum.publicLink) { act(.public) }
        if model.capabilities.privateLinks {
            Button(Copy.HiddenAlbum.statusPrivate, systemImage: Symbol.HiddenAlbum.privateLink) { act(.private) }
        }
    }
}

extension View {
    /// The confirm of a `status…` choice that needs one: `hide 3 posts?` and `make 3 posts public?`.
    func statusConfirm(controller: LibraryController) -> some View {
        modifier(StatusConfirm(controller: controller))
    }
}

private struct StatusConfirm: ViewModifier {
    @Bindable var controller: LibraryController

    func body(content: Content) -> some View {
        content.confirmationDialog(
            title, isPresented: presented, titleVisibility: .visible, presenting: controller.asking
        ) { ask in
            Button(ask.status == .hidden ? Copy.HiddenAlbum.hideConfirm : Copy.HiddenAlbum.publicConfirm,
                   role: ask.status == .hidden ? .destructive : nil) {
                controller.confirmStatus(ask)
            }
            Button(Copy.HiddenAlbum.cancel, role: .cancel) {}
        } message: { ask in
            Text(ask.status == .hidden ? Copy.HiddenAlbum.hideMessage(ask.posts.count) : Copy.HiddenAlbum.publicMessage(ask.posts.count))
        }
    }

    private var title: String {
        guard let ask = controller.asking else { return "" }
        return ask.status == .hidden ? Copy.HiddenAlbum.hideTitle(ask.posts.count) : Copy.HiddenAlbum.publicTitle(ask.posts.count)
    }

    private var presented: Binding<Bool> {
        Binding(get: { controller.asking != nil }, set: { if !$0 { controller.asking = nil } })
    }
}
