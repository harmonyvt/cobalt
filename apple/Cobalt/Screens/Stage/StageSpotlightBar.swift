import CobaltKit
import SwiftUI

// The spotlight bar (APP-API-CONTRACT 30.11): the file in the spotlight and who put it there, then sound, pin, skip and pick
// (which opens the pool sheet, `StagePickSheet`), and a menu with the two canvas actions (shuffle, chaos). Pin, skip, pick and
// the canvas actions need the stage on air (the server answers `409 off_air` otherwise), so they are dimmed off air.

struct StageSpotlightBar: View {
    let stage: StageSettings
    let controller: StageController

    @Environment(\.shell) private var shell

    private var pinned: Bool { stage.spotlight?.isPinned(now: Date()) ?? false }
    private var busy: Bool { controller.isBusy("action") }

    var body: some View {
        StageCard {
            HStack(spacing: 12) {
                StageThumb(item: stage.spotlight?.item)
                VStack(alignment: .leading, spacing: 2) {
                    Text(caption)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                        .lineLimit(2)
                    Text(headline)
                        .font(CobaltType.bodySemibold)
                        .foregroundStyle(CobaltColor.text)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            buttons
            if !stage.onAir {
                Text(Copy.Stage.spotlightOffAir)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
            }
        }
    }

    private var caption: String {
        guard let spotlight = stage.spotlight else { return Copy.Stage.spotlight }
        if let name = spotlight.by { return Copy.Stage.spotlightBy(name) }
        return Copy.Stage.spotlightOwner
    }

    private var headline: String {
        guard let spotlight = stage.spotlight else { return Copy.Stage.spotlightNone }
        return spotlight.item.title
    }

    /// Icons only (their names show on a long press, hover on the Mac): the bar has no worded action.
    private var buttons: some View {
        IconRow(spacing: 10) {
            sound
            pin
            skip
            pick
            StageMenuButton(title: Copy.Stage.more, systemImage: Symbol.stageMore) {
                Button(Copy.Stage.shuffle, systemImage: Symbol.stageShuffle) { controller.perform(.shuffle, shell: shell) }
                Button(Copy.Stage.chaos, systemImage: Symbol.stageChaos) { controller.perform(.chaos, shell: shell) }
            }
            .disabled(!stage.onAir || busy)
        }
    }

    private var sound: some View {
        Button {
            controller.setSound(!stage.sound, shell: shell)
        } label: {
            Label(stage.sound ? Copy.Stage.soundOn : Copy.Stage.muted, systemImage: stage.sound ? Symbol.soundOn : Symbol.soundOff)
        }
        .buttonStyle(.cobaltIcon(state: controller.isBusy("sound") ? .working : .idle))
        .disabled(controller.isBusy("sound"))
        .accessibilityHint(Copy.Stage.soundA11yHint)
    }

    private var pin: some View {
        Button {
            controller.togglePin(pinned: pinned, shell: shell)
        } label: {
            Label(pinned ? Copy.Stage.pinned : Copy.Stage.pin, systemImage: pinned ? Symbol.stagePinned : Symbol.stagePin)
        }
        .buttonStyle(.cobaltIcon(prominent: pinned))
        .disabled(!stage.onAir || stage.spotlight == nil || busy)
    }

    private var skip: some View {
        Button { controller.perform(.skip, shell: shell) } label: { Label(Copy.Stage.skip, systemImage: Symbol.stageSkip) }
            .buttonStyle(.cobaltIcon())
            .disabled(!stage.onAir || stage.spotlight == nil || busy)
    }

    private var pick: some View {
        Button { controller.pickShown = true } label: { Label(Copy.Stage.pick, systemImage: Symbol.stagePick) }
            .buttonStyle(.cobaltIcon())
            .disabled(!stage.onAir || busy)
    }
}

/// A menu drawn like the `.cobaltIcon()` circles beside it (a `Menu` takes the menu and button styles, not a
/// `PrimitiveButtonStyle`): its symbol in a glass circle, its name for VoiceOver and the Mac's hover. The items keep words.
struct StageMenuButton<Items: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let items: () -> Items

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Menu {
            items()
        } label: {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(CobaltColor.text)
                .frame(width: 50, height: 50)
                .contentShape(.circle)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .glassEffect(isEnabled ? .regular.interactive() : .regular, in: .circle)
        .opacity(isEnabled ? 1 : 0.45)
        .frame(minWidth: Metrics.hit, minHeight: Metrics.hit)
        .iconName(title)
    }
}

// MARK: - the pick sheet

/// "pick for the spotlight": the pool's public files, 60 at a time, newest first as the server lists them. A tap puts the file
/// in the spotlight as the owner's own pick (`spotlight` action) and closes the sheet.
struct StagePickSheet: View {
    let controller: StageController

    @Environment(\.dismiss) private var dismiss
    @Environment(\.shell) private var shell

    private var store: StageStore { controller.store }

    var body: some View {
        NavigationStack {
            content
                .background(CobaltColor.bg)
                .navigationTitle(Copy.Stage.pickTitle)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .sheetCorner()
                .sheetClose { dismiss() }
        }
        .task { await store.loadPool() }
        #if os(macOS)
        .modifier(MacSheetSize())
        #else
        .presentationDetents([.large])
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if store.poolItems.isEmpty {
            switch store.poolState {
            case .idle, .loading:
                VStack(spacing: 10) {
                    ProgressView()
                    Text(Copy.Stage.pickLoading).font(CobaltType.caption).foregroundStyle(CobaltColor.caption)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let error):
                ContentUnavailableView {
                    Label(Copy.Stage.pickFailed, systemImage: Symbol.error).font(CobaltType.body)
                } description: {
                    Text(Copy.Stage.failedBody(error)).font(CobaltType.caption)
                } actions: {
                    Button(Copy.Stage.retry, systemImage: Symbol.retry) { Task { await store.loadPool() } }
                        .buttonStyle(.cobaltSecondary(fullWidth: false))
                }
            case .loaded:
                ContentUnavailableView {
                    Label(Copy.Stage.pickEmpty, systemImage: Symbol.stagePoolLibrary).font(CobaltType.body)
                }
            }
        } else {
            grid
        }
    }

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(Copy.Stage.pickCount(store.poolTotal))
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 12) {
                    ForEach(store.poolItems) { item in
                        PickTile(item: item) { controller.pickItem(item, shell: shell) }
                            .onAppear {
                                if item.id == store.poolItems.last?.id { Task { await store.loadMorePool() } }
                            }
                    }
                }
                footer
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch store.poolState {
        case .loading:
            ProgressView().frame(maxWidth: .infinity)
        case .failed:
            Button { Task { await store.loadMorePool() } } label: { Label(Copy.Stage.retry, systemImage: Symbol.retry) }
                .buttonStyle(.cobaltIcon(.small))
                .frame(maxWidth: .infinity)
        case .idle, .loaded:
            if store.poolHasMore {
                Button(Copy.Stage.pickMore) { Task { await store.loadMorePool() } }
                    .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

/// One file of the pool: a square picture with its code in the corner, then its title.
private struct PickTile: View {
    let item: StageItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                ZStack(alignment: .bottomLeading) {
                    Rectangle().fill(FrameGradient.fill(item.kind == .video ? 2 : 0))
                    if let url = item.thumbnail {
                        // always a picture (thumb, poster or the image itself); cached by the library's loader
                        RemoteStill(poster: RemotePoster(url: url, isVideo: false))
                    }
                    if let code = item.code {
                        Text(code)
                            .font(CobaltType.pill)
                            .foregroundStyle(CobaltColor.badgeInk)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(CobaltColor.badgeBack, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .padding(6)
                    }
                    if item.kind == .video {
                        Image(systemName: Symbol.stagePlay)
                            .font(.system(size: 10))
                            .foregroundStyle(CobaltColor.badgeInk)
                            .padding(6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
                Text(item.title)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Copy.Stage.pickItemA11y(title: item.title, kind: item.kind))
        .accessibilityHint(Copy.Stage.pickItemHint)
    }
}
