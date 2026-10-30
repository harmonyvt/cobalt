import CobaltKit
import SwiftUI

/// A post's link, three ways (APP-API-CONTRACT 36.6, mockup "iphone · a post's link"): `off` (only you), `public link`
/// (anyone with the link), `private link` (a key in the link, rotate any time). It takes the place of the public/private
/// switch (`VisibilitySection`) while the server has `features.private_links`, on the iPhone, the iPad and the Mac.
///
/// Private shows the link with a lock, `copy private link`, how often it was opened and when its key was made, and a red
/// `rotate key…`. Every change but off → public asks first: turning private on says the public link stops and the file
/// leaves the public media address, and when the file is in public gallery links it offers to make those private too.
/// Turning private on and rotating copy the new link, with the status line and the success haptic.
struct FileLinkSection: View {
    let controller: DetailController
    let rendition: Rendition

    private enum Ask: Identifiable, Equatable {
        /// Turn the private link on; `links` are the public gallery links the file is in.
        case turnOn(links: [String])
        case rotate
        case off
        case toPublic
        /// Hide the post (APP-API-CONTRACT 37); `links` are the public gallery links it leaves.
        case hide(links: Int)
        case unhide

        var id: String {
            switch self {
            case .turnOn: return "turnOn"
            case .rotate: return "rotate"
            case .off: return "off"
            case .toPublic: return "toPublic"
            case .hide: return "hide"
            case .unhide: return "unhide"
            }
        }
    }

    /// The four rows: the three links and `hidden`.
    private enum Choice: Hashable {
        case off, `public`, `private`, hidden

        init(_ link: FileLink) {
            switch link {
            case .off: self = .off
            case .public: self = .public
            case .private: self = .private
            }
        }
    }

    @State private var asking: Ask?
    @State private var copied = false
    @Environment(\.shell) private var shell
    @Environment(\.hapticsEnabled) private var haptics

    private var model: AppModel { controller.model }
    private var store: ShareSetStore { model.shareSets }
    private var changing: Bool { model.isChangingVisibility(rendition) || model.library.statusInFlight }
    private var current: FileLink { model.fileLink(of: rendition) }
    /// The library post this file is in (a hidden one is in the album); nil when the library does not list it.
    private var post: LibraryPost? {
        let ids = Set([rendition.file?.id, rendition.hosted?.id].compactMap { $0 })
        guard !ids.isEmpty else { return nil }
        let holds: (LibraryPost) -> Bool = { $0.files.contains { ids.contains($0.id) } }
        return model.library.posts.first(where: holds) ?? model.library.hiddenPosts.first(where: holds)
    }
    /// The server has hidden posts and the library lists this one: the `hidden` row is offered.
    private var canHide: Bool { model.capabilities.hidden && post != nil }
    private var isHidden: Bool { canHide && post?.hidden == true }
    private var privateURL: URL? { model.privateURL(of: rendition) }

    var body: some View {
        Section {
            if isHidden {
                hiddenRows
            } else {
                Picker(selection: Binding(get: { Choice(current) }, set: { choose($0) })) {
                    choiceRow(Copy.PrivateLinks.off, Copy.PrivateLinks.offDetail, Symbol.PrivateLinks.off).tag(Choice.off)
                    choiceRow(Copy.PrivateLinks.publicLink, Copy.PrivateLinks.publicDetail, Symbol.PrivateLinks.publicLink)
                        .tag(Choice.public)
                    choiceRow(Copy.PrivateLinks.privateLink, Copy.PrivateLinks.privateDetail, Symbol.PrivateLinks.privateLink)
                        .tag(Choice.private)
                    if canHide {
                        choiceRow(Copy.Hidden.row, Copy.Hidden.rowDetail, Symbol.HiddenRules.hidden).tag(Choice.hidden)
                    }
                } label: {
                    Text(Copy.PrivateLinks.section)
                }
                .pickerStyle(.inline)
                .disabled(changing || controller.isDeleting)
            }

            if isHidden, let post {
                HiddenByRow(model: model, post: post)
                Button(Copy.Hidden.unhide, systemImage: Symbol.HiddenRules.unhide) { ask(.unhide) }
                    .disabled(changing || controller.isDeleting)
            }

            if !isHidden, current == .private, let url = privateURL {
                LabeledContent {
                    Text(Self.display(url))
                        .font(Font.cobalt(12))
                        .foregroundStyle(CobaltColor.linkBlue)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } label: {
                    Label(Copy.PrivateLinks.link, systemImage: Symbol.PrivateLinks.lock)
                }
                Button(copied ? Copy.PrivateLinks.copied : Copy.PrivateLinks.copy,
                       systemImage: copied ? Symbol.PrivateLinks.copied : Symbol.PrivateLinks.copy) {
                    copy(url, status: Copy.Media.copied)
                }
                .symbolBounce(on: copied)
                if let link = model.privateLink(of: rendition) {
                    fact(Copy.PrivateLinks.opened, Symbol.PrivateLinks.opened, Copy.PrivateLinks.openedCount(link.opened))
                    fact(Copy.PrivateLinks.keyMade, Symbol.PrivateLinks.made, Self.when(link.createdAt))
                }
                Button(Copy.PrivateLinks.rotate, systemImage: Symbol.PrivateLinks.rotate, role: .destructive) { ask(.rotate) }
                    .foregroundStyle(CobaltColor.errorText)
                    .disabled(changing)
            }
        } footer: {
            Text(footnote.text)
                .font(CobaltType.captionSmall)
                .foregroundStyle(footnote.isProblem ? CobaltColor.errorText : Color.secondary)
                .lineSpacing(2)
        }
        .motion(Motion.rows, value: current)
        .motion(Motion.rows, value: isHidden)
        .motion(Motion.rows, value: footnote.text)
        .confirmationDialog(
            title(asking), isPresented: askingShown, titleVisibility: .visible, presenting: asking
        ) { ask in
            buttons(ask)
        } message: { ask in
            Text(message(ask))
        }
        .task(id: rendition.id) { await loadLinks() }
        .haptic(.success, trigger: controller.privateLinkCopied, enabled: haptics)
        .haptic(.error, trigger: controller.visibilityFailed[rendition.id], enabled: haptics) { $0 != nil }
    }

    private func choiceRow(_ title: String, _ detail: String, _ symbol: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(Font.cobalt(11.5)).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol)
        }
    }

    /// A hidden post: `hidden` is the one checked row, the others are greyed with "unhide first" (a tap asks to unhide).
    @ViewBuilder
    private var hiddenRows: some View {
        hiddenRow(Copy.PrivateLinks.off, Copy.Hidden.unhideFirst, Symbol.PrivateLinks.off, on: false)
        hiddenRow(Copy.PrivateLinks.publicLink, Copy.Hidden.unhideFirst, Symbol.PrivateLinks.publicLink, on: false)
        hiddenRow(Copy.PrivateLinks.privateLink, Copy.Hidden.unhideFirst, Symbol.PrivateLinks.privateLink, on: false)
        hiddenRow(Copy.Hidden.row, Copy.Hidden.rowDetail, Symbol.HiddenRules.hidden, on: true)
    }

    private func hiddenRow(_ title: String, _ detail: String, _ symbol: String, on: Bool) -> some View {
        Button {
            if !on { ask(.unhide) }
        } label: {
            HStack {
                choiceRow(title, detail, symbol)
                Spacer(minLength: 8)
                if on {
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(on ? Color.primary : Color.secondary)
        .disabled(changing || controller.isDeleting)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private func fact(_ title: String, _ symbol: String, _ value: String) -> some View {
        LabeledContent {
            Text(value).font(Font.cobalt(12.5)).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
        } label: {
            Label(title, systemImage: symbol)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: choosing

    private func choose(_ choice: Choice) {
        guard !changing else { return }
        let want: FileLink
        switch choice {
        case .hidden:
            let links = model.publicSets(containing: rendition).count
            ask(.hide(links: links))
            return
        case .off: want = .off
        case .public: want = .public
        case .private: want = .private
        }
        guard want != current else { return }
        switch want {
        case .private:
            let links = model.publicSets(containing: rendition).map(\.id)
            ask(.turnOn(links: links))
        case .public:
            if current == .private {
                ask(.toPublic)
            } else {
                Task { await controller.setFileLink(rendition, to: .public) }
            }
        case .off:
            ask(.off)
        }
    }

    private func ask(_ next: Ask) {
        guard !changing else { return }
        asking = next
    }

    private var askingShown: Binding<Bool> {
        Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })
    }

    private func title(_ ask: Ask?) -> String {
        switch ask {
        case .turnOn: return Copy.PrivateLinks.turnOnTitle
        case .rotate: return Copy.PrivateLinks.rotateTitle
        case .off: return Copy.PrivateLinks.offTitle
        case .toPublic: return Copy.PrivateLinks.toPublicTitle
        case .hide: return Copy.Hidden.hideTitle
        case .unhide: return Copy.Hidden.unhideTitle
        case nil: return ""
        }
    }

    private func message(_ ask: Ask) -> String {
        switch ask {
        case .turnOn(let links):
            return links.isEmpty ? Copy.PrivateLinks.turnOnMessage : Copy.PrivateLinks.turnOnMessage(inLinks: links.count)
        case .rotate: return Copy.PrivateLinks.rotateMessage
        case .off: return Copy.PrivateLinks.offMessage
        case .toPublic: return Copy.PrivateLinks.toPublicMessage
        case .hide(let links): return links > 0 ? Copy.Hidden.hideMessage(inLinks: links) : Copy.Hidden.hideMessage
        case .unhide: return Copy.Hidden.unhideMessage
        }
    }

    @ViewBuilder
    private func buttons(_ ask: Ask) -> some View {
        switch ask {
        case .turnOn(let links):
            if links.isEmpty {
                Button(Copy.PrivateLinks.turnOn) { turnOn(alsoMakePrivate: []) }
            } else {
                Button(Copy.PrivateLinks.alsoLinks) { turnOn(alsoMakePrivate: links) }
                Button(Copy.PrivateLinks.leaveOut) { turnOn(alsoMakePrivate: []) }
            }
            Button(Copy.PrivateLinks.cancel, role: .cancel) {}
        case .rotate:
            Button(Copy.PrivateLinks.rotateConfirm, role: .destructive) {
                Task {
                    if let link = await controller.rotateFileLink(rendition) { copy(link.url, status: Copy.PrivateLinks.copiedNewKey) }
                }
            }
            Button(Copy.PrivateLinks.cancel, role: .cancel) {}
        case .off:
            Button(Copy.PrivateLinks.offConfirm, role: .destructive) {
                Task { await controller.setFileLink(rendition, to: .off) }
            }
            Button(Copy.PrivateLinks.cancel, role: .cancel) {}
        case .toPublic:
            Button(Copy.PrivateLinks.toPublicConfirm, role: .destructive) {
                Task { await controller.setFileLink(rendition, to: .public) }
            }
            Button(Copy.PrivateLinks.cancel, role: .cancel) {}
        case .hide:
            Button(Copy.Hidden.hideConfirm, role: .destructive) { setStatus(.hidden) }
            Button(Copy.Hidden.cancel, role: .cancel) {}
        case .unhide:
            Button(Copy.Hidden.unhide) { setStatus(.off) }
            Button(Copy.Hidden.cancel, role: .cancel) {}
        }
    }

    private func turnOn(alsoMakePrivate links: [String]) {
        Task {
            if let link = await controller.setFileLink(rendition, to: .private, alsoMakePrivate: links) {
                copy(link.url, status: Copy.PrivateLinks.copiedPrivate)
            }
        }
    }

    /// The link on the pasteboard, the status over the shell, the success haptic, and "copied" for a moment.
    private func copy(_ url: URL, status: String) {
        Pasteboard.copy(url.absoluteString)
        shell.showStatus(status)
        controller.privateLinkCopied += 1
        copied = true
        let token = controller.privateLinkCopied
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            if controller.privateLinkCopied == token { copied = false }
        }
    }

    /// Hides the post, or brings it back as only you (APP-API-CONTRACT 37): the library moves it between its list and
    /// the album once the server answers; a refusal is words under the section.
    private func setStatus(_ status: PostStatus) {
        guard let post, !changing else { return }
        Task {
            let result = await controller.setPostStatus(status, post: post, key: rendition.id)
            if result.changed { shell.showStatus(result.words(for: status)) }
        }
    }

    /// The links (for the public gallery links the file is in) and the private links' numbers, once per detail.
    private func loadLinks() async {
        guard model.capabilities.privateLinks else { return }
        if store.state == .idle {
            await store.refresh()
        } else if !store.privateLoaded {
            try? await store.refreshPrivate()
        }
    }

    // MARK: words

    /// The request in flight, a failure, or what the state means.
    private var footnote: (text: String, isProblem: Bool) {
        if changing { return (Copy.PrivateLinks.working, false) }
        if let failed = controller.visibilityFailed[rendition.id] { return (failed, true) }
        if isHidden { return (Copy.Hidden.note, false) }
        switch current {
        case .private: return (Copy.PrivateLinks.footnote, false)
        case .public: return (Copy.Media.publicOn, false)
        case .off:
            if controller.visibilityCacheNote.contains(rendition.id) {
                return ("\(Copy.Media.publicOff) \(Copy.Media.cacheNote)", false)
            }
            return (Copy.Media.publicOff, false)
        }
    }

    /// `share.capybaraharmony.com/p/…` without the scheme.
    static func display(_ url: URL) -> String {
        (url.host ?? "") + url.path
    }

    static func when(_ date: Date) -> String {
        if abs(date.timeIntervalSinceNow) < 60 { return "just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date()).lowercased()
    }
}

// MARK: - the controller's side

extension DetailController {
    /// Moves the rendition's link (APP-API-CONTRACT 36.6). Answers the private link when one was turned on (the view
    /// copies it); a failure is words under the section.
    @discardableResult
    func setFileLink(_ r: Rendition, to target: FileLink, alsoMakePrivate setIDs: [String] = []) async -> PrivateLink? {
        guard !model.isChangingVisibility(r) else { return nil }
        visibilityFailed[r.id] = nil
        visibilityCacheNote.remove(r.id)
        do {
            return try await model.setFileLink(r, to: target, alsoMakePrivate: setIDs)
        } catch {
            visibilityFailed[r.id] = Self.linkWords(error, turningOn: target == .private)
            return nil
        }
    }

    /// A new key for the rendition's private link; the view copies it.
    func rotateFileLink(_ r: Rendition) async -> PrivateLink? {
        guard !model.isChangingVisibility(r) else { return nil }
        visibilityFailed[r.id] = nil
        do {
            return try await model.rotateFileLink(r)
        } catch PrivateLinkError.notFound {
            visibilityFailed[r.id] = Copy.PrivateLinks.gone
            return nil
        } catch {
            visibilityFailed[r.id] = Self.linkWords(error, turningOn: false, rotating: true)
            return nil
        }
    }

    static func linkWords(_ error: Error, turningOn: Bool, rotating: Bool = false) -> String {
        switch error {
        case PrivateLinkError.notToggleable: return Copy.PrivateLinks.notToggleable
        case PrivateLinkError.unavailable: return Copy.PrivateLinks.unavailable
        case PrivateLinkError.notFound: return Copy.PrivateLinks.gone
        default: break
        }
        if let failure = error as? PipelineFailure, [.keyInvalid, .keyMissing, .unreachable].contains(failure) {
            return Copy.failure(failure)
        }
        if rotating { return Copy.PrivateLinks.rotateFailed }
        return turningOn ? Copy.PrivateLinks.turnOnFailed : Copy.PrivateLinks.changeFailed
    }
}
