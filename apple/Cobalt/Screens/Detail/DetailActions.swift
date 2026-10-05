import CobaltKit
import SwiftUI

/// The buttons under the hero (CONTRACT-MEDIA 1.10, CONTRACT-ORBIT 2b): EXACTLY ONE prominent button for the
/// tab, then the secondary row (icon over word, 52 pt, like the focus's choices), then the state of whatever is
/// running or failed. What does not apply is not shown (plain cobalt has no webp, no link, no public share).
struct DetailActions: View {
    let controller: DetailController
    let item: MediaItem
    let rendition: Rendition
    /// Called after an action that leaves this screen ("another webp" lifts the planet into focus).
    var leave: () -> Void = {}

    @Environment(\.shell) private var shell
    @Environment(\.hapticsEnabled) private var haptics

    private var model: AppModel { controller.model }

    enum Choice: Hashable {
        case copyWebpLink, copyVideoLink, makeWebp, anotherWebp, publicShare, savePhotos, share
    }

    // MARK: the plan

    private var canMake: Bool { controller.canMakeWebp(item) }
    private var shareURL: URL? {
        if let url = rendition.local?.fileURL, FileManager.default.fileExists(atPath: url.path) { return url }
        return rendition.publicURL
    }
    private var videoLink: URL? { rendition.hosted?.url ?? rendition.publicURL }
    private var canSave: Bool { RenditionPhotos.canSave(rendition) }
    private var canHost: Bool {
        rendition.file != nil && rendition.hosted == nil && rendition.publicURL == nil && model.capabilities.studio
    }
    private var placed: Bool { controller.placement(of: rendition) != .none }

    /// One prominent choice and the secondary row, from what this tab can do.
    var plan: (primary: Choice?, secondary: [Choice]) {
        var secondary: [Choice] = []
        var primary: Choice?
        if rendition.isWebp {
            if rendition.publicURL != nil {
                primary = .copyWebpLink
            } else if canSave {
                primary = .savePhotos
            }
            if shareURL != nil { secondary.append(.share) }
            if canSave, primary != .savePhotos { secondary.append(.savePhotos) }
            if canMake { secondary.append(.anotherWebp) }
        } else {
            if canMake {
                primary = .makeWebp
                if videoLink != nil { secondary.append(.copyVideoLink) } else if canHost { secondary.append(.publicShare) }
                if canSave { secondary.append(.savePhotos) }
                if shareURL != nil { secondary.append(.share) }
            } else {
                // plain cobalt: nothing to convert; save is the one thing to do
                if canSave { primary = .savePhotos } else if videoLink != nil { primary = .copyVideoLink }
                if videoLink != nil, primary != .copyVideoLink { secondary.append(.copyVideoLink) }
                if shareURL != nil { secondary.append(.share) }
            }
        }
        return (primary, secondary)
    }

    // MARK: body

    var body: some View {
        let plan = plan
        let locked = controller.isDeleting
        VStack(spacing: 12) {
            GlassEffectContainer(spacing: 0) {
                VStack(spacing: 8) {
                    if let primary = plan.primary { primaryButton(primary) }
                    if !plan.secondary.isEmpty { secondaryRow(plan.secondary) }
                }
            }
            .disabled(locked)
            status
        }
        .haptic(.success, trigger: controller.copiedID, enabled: haptics) { $0 != nil }
        .haptic(.error, trigger: controller.notice, enabled: haptics) { $0 != nil }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    // MARK: primary

    @ViewBuilder
    private func primaryButton(_ choice: Choice) -> some View {
        switch choice {
        case .copyWebpLink:
            let done = controller.copiedID == rendition.id
            DetailPrimary(
                title: done ? Copy.Media.copied : Copy.Media.copyWebpLink, symbol: Symbol.Media.copyLink,
                doneSymbol: Symbol.Media.copied, done: done
            ) { if let url = rendition.publicURL { controller.copy(url, for: rendition.id) } }
        case .copyVideoLink:
            let done = controller.copiedID == rendition.id
            DetailPrimary(
                title: done ? Copy.Media.copied : Copy.Media.copyVideoLink, symbol: Symbol.Media.copyLink,
                doneSymbol: Symbol.Media.copied, done: done
            ) { if let url = videoLink { controller.copy(url, for: rendition.id) } }
        case .makeWebp, .anotherWebp:
            DetailPrimary(
                title: item.webpCount > 0 ? Copy.Media.makeAnotherWebp : Copy.Media.makeAWebp,
                symbol: Symbol.Media.makeWebp
            ) { makeWebp() }
        case .savePhotos:
            savePrimary
        case .publicShare, .share:
            EmptyView()
        }
    }

    /// "save to photos" as the one prominent button (plain cobalt, a webp with no public link): once the file
    /// is in the owner's photos it says where, and stops being a button.
    @ViewBuilder
    private var savePrimary: some View {
        let state = controller.photos[rendition.id] ?? .idle
        switch controller.placement(of: rendition) {
        case .inAlbum:
            DetailPrimary(title: Copy.Sync.inAlbum, symbol: Symbol.Sync.inPhotos, doneSymbol: Symbol.Sync.inPhotos, done: true, inert: true) {}
        case .inLibrary:
            DetailPrimary(title: Copy.Sync.inLibrary, symbol: Symbol.Sync.inPhotos, doneSymbol: Symbol.Sync.inPhotos, done: true, inert: true) {}
        case .none:
            DetailPrimary(
                title: Self.saveTitle(done: state == .done), symbol: Self.saveSymbol,
                doneSymbol: Symbol.checkmark, done: state == .done, working: state == .working
            ) { Task { await controller.savePhotos(rendition) } }
        }
    }

    private static func saveTitle(done: Bool) -> String {
        #if os(macOS)
        return done ? Copy.saved : Copy.saveAs
        #else
        return done ? Copy.savedPhotos : Copy.Media.savePhotos
        #endif
    }

    private static var saveSymbol: String {
        #if os(macOS)
        return Symbol.saveAs
        #else
        return Symbol.Media.savePhotos
        #endif
    }

    // MARK: secondary

    private func secondaryRow(_ items: [Choice]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { ForEach(items, id: \.self) { secondary($0, .stacked) } }
            VStack(spacing: 8) {
                ForEach(Array(stride(from: 0, to: items.count, by: 2)), id: \.self) { i in
                    HStack(spacing: 8) {
                        ForEach(Array(items[i..<min(i + 2, items.count)]), id: \.self) { secondary($0, .stacked) }
                    }
                }
            }
            VStack(spacing: 8) { ForEach(items, id: \.self) { secondary($0, .inline) } }
        }
    }

    @ViewBuilder
    private func secondary(_ choice: Choice, _ layout: DetailChoiceLayout) -> some View {
        switch choice {
        case .share:
            if let url = shareURL {
                ShareLink(item: url) {
                    DetailChoiceLabel(title: Copy.Media.share, symbol: Symbol.Media.share, layout: layout)
                }
                .detailChoiceStyle()
            }
        case .savePhotos:
            let state = controller.photos[rendition.id] ?? .idle
            switch controller.placement(of: rendition) {
            case .inAlbum:
                DetailChoiceButton(title: Copy.Sync.inAlbum, symbol: Symbol.Sync.inPhotos, inert: true, layout: layout) {}
            case .inLibrary:
                DetailChoiceButton(title: Copy.Sync.inLibrary, symbol: Symbol.Sync.inPhotos, inert: true, layout: layout) {}
            case .none:
                DetailChoiceButton(
                    title: Self.saveTitle(done: state == .done), symbol: state == .done ? Symbol.checkmark : Self.saveSymbol,
                    working: state == .working, layout: layout
                ) { Task { await controller.savePhotos(rendition) } }
            }
        case .anotherWebp:
            DetailChoiceButton(title: Copy.Media.anotherWebp, symbol: Symbol.Media.makeWebp, layout: layout) { makeWebp() }
        case .publicShare:
            DetailChoiceButton(
                title: Copy.Media.publicShare, symbol: Symbol.Media.publicShare,
                working: controller.hosting == .working, layout: layout
            ) { Task { await controller.publicShare(rendition) } }
        case .copyVideoLink:
            let done = controller.copiedID == rendition.id
            DetailChoiceButton(
                title: done ? Copy.Media.copied : Copy.Media.copyVideoLink,
                symbol: done ? Symbol.Media.copied : Symbol.Media.copyLink, layout: layout
            ) { if let url = videoLink { controller.copy(url, for: rendition.id) } }
        case .copyWebpLink, .makeWebp:
            EmptyView()
        }
    }

    // MARK: state under the actions

    @ViewBuilder
    private var status: some View {
        let phase = controller.phase
        VStack(spacing: 8) {
            switch phase {
            case .deleting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(Copy.Media.deleting).font(Font.cobalt(12, .regular, relativeTo: .footnote)).foregroundStyle(CobaltColor.caption)
                }
                .accessibilityElement(children: .combine)
            case .failed:
                problem(Copy.Media.deleteFailed, retry: true)
            case .partial(let remaining):
                problem(Copy.Media.deletePartial(remaining: remaining), retry: true)
            case .busy:
                problem(Copy.Media.deleteBusy, retry: false)
            case .idle:
                if let notice = controller.notice {
                    problem(notice, retry: false)
                } else if controller.canDeleteEverything(item), controller.isBusy(item) {
                    // delete everything is off while this media's own run is going
                    Text(Copy.Media.deleteBusy)
                        .font(Font.cobalt(11.5, .regular, relativeTo: .caption)).foregroundStyle(CobaltColor.caption)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .motion(Motion.rows, value: phase)
        .frame(maxWidth: .infinity)
    }

    private func problem(_ text: String, retry: Bool) -> some View {
        VStack(spacing: 8) {
            Text(text)
                .font(Font.cobalt(12, .regular, relativeTo: .caption))
                .foregroundStyle(CobaltColor.errorText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
            if retry {
                Button(Copy.Media.tryAgain, systemImage: Symbol.Media.retry) {
                    Task {
                        if case .popWithStatus(let message) = await controller.tryAgain(item) {
                            shell.showStatus(message)
                            leave()
                        }
                    }
                }
                .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: actions

    /// "make another webp": the focus flow with the trim open, not an editor in here (CONTRACT-MEDIA 1.11).
    /// The detail pops first so the zoom carries back into the planet.
    private func makeWebp() {
        shell.makeWebp(item)
        leave()
    }
}

// MARK: - buttons

/// An icon over its word (`stacked`), or beside it (`inline`, the fallback when the words do not fit side by
/// side). The word is one line, always: it sets the choice's width instead of wrapping.
enum DetailChoiceLayout { case stacked, inline }

/// The compact secondary choice: 52 pt tall in both layouts so a row is even.
struct DetailChoiceLabel: View {
    let title: String
    let symbol: String
    var working = false
    var layout: DetailChoiceLayout = .stacked

    private var word: some View {
        Text(title)
            .font(Font.cobalt(11.5, .medium, relativeTo: .caption))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var icon: some View {
        Image(systemName: symbol)
            .font(.system(size: layout == .stacked ? 19 : 17, weight: .medium))
            .frame(height: 22)
            .symbolEffect(.pulse, isActive: working)
    }

    var body: some View {
        Group {
            switch layout {
            case .stacked: VStack(spacing: 3) { icon; word }
            case .inline: HStack(spacing: 8) { icon; word }
            }
        }
        .foregroundStyle(CobaltColor.text)
        .padding(.horizontal, layout == .stacked ? 8 : 14)
        .frame(maxWidth: .infinity, minHeight: 52)
        .contentShape(.capsule)
    }
}

extension View {
    /// The secondary choice's skin: a glass capsule on iOS, the platform's bordered button on the Mac (a glass
    /// button over a grouped form washes out there).
    @ViewBuilder
    func detailChoiceStyle(inert: Bool = false) -> some View {
        #if os(macOS)
        self.buttonStyle(.bordered).controlSize(.large).buttonBorderShape(.capsule)
        #else
        self.buttonStyle(.plain).glassEffect(inert ? .regular : .regular.interactive(), in: .capsule)
        #endif
    }
}

struct DetailChoiceButton: View {
    let title: String
    let symbol: String
    var working = false
    /// A statement, not an action ("in your cobalt album"): never tappable.
    var inert = false
    var layout: DetailChoiceLayout = .stacked
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            DetailChoiceLabel(title: title, symbol: symbol, working: working, layout: layout)
        }
        .detailChoiceStyle(inert: inert)
        .disabled(working)
        .allowsHitTesting(!inert)
        .accessibilityRemoveTraits(inert ? .isButton : [])
    }
}

/// THE prominent button: the system's `.glassProminent` (cobalt's monochrome tint), full width. It turns green
/// with a checkmark once it has done its job (copied, saved).
struct DetailPrimary: View {
    let title: String
    let symbol: String
    var doneSymbol = Symbol.checkmark
    var done = false
    var working = false
    /// A statement, not an action ("in your cobalt album"): the done style, never tappable.
    var inert = false
    let action: () -> Void

    var body: some View {
        Group {
            if done {
                Button(title, systemImage: doneSymbol, action: action).buttonStyle(.cobaltDone())
                    .allowsHitTesting(!inert)
                    .accessibilityRemoveTraits(inert ? .isButton : [])
            } else {
                Button(title, systemImage: symbol, action: action).buttonStyle(.cobaltPrimary())
            }
        }
        .symbolBounce(on: done)
        .symbolEffect(.pulse, isActive: working)
        .disabled(working)
    }
}
