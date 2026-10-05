import CobaltKit
import SwiftUI

/// "photos": the album the videos cobalt keeps on this phone are added to, once each
/// (CONTRACT-SYNC.md decisions 7 to 11, section 6). Driven by `model.photosSync.status`: this view
/// only draws it and forwards the owner's choices. iPhone and iPad; on the Mac `isAvailable` is
/// false and nothing is drawn.
struct PhotosSettingsSection: View {
    let model: AppModel

    @Environment(\.openURL) private var openURL
    /// The toggle reads on while the permission prompt is up; a refusal snaps it back.
    @State private var enabling = false
    /// "also add the N videos already in cobalt?": N while the once-only dialog is open.
    @State private var backfillCount: Int?

    private var sync: PhotosSync { model.photosSync }
    private var status: PhotosSync.Status { sync.status }
    private var keepsVideos: Bool { model.settings.keepVideosOnDevice }

    var body: some View {
        if sync.isAvailable {
            Section {
                albumToggle
                if status.enabled {
                    webpsToggle
                }
                if showsStatusRow {
                    statusRow
                }
                if showsOpenSettings {
                    Button(Copy.Sync.openSettings, systemImage: Symbol.Sync.openSettings, action: openSystemSettings)
                }
            } header: {
                Text(Copy.Sync.photosGroup).font(CobaltType.caption).textCase(nil)
            } footer: {
                Text(footerText).font(CobaltType.captionSmall).lineSpacing(2)
            }
            #if DEBUG
            // `-previewPhotosTurnOn 1`: the owner turning the toggle on, for evidence taken without a tap
            .task {
                guard UserDefaults.standard.bool(forKey: "previewPhotosTurnOn") else { return }
                try? await Task.sleep(for: .seconds(1))
                turnOn()
            }
            #endif
        }
    }

    // MARK: rows

    private var albumToggle: some View {
        Toggle(isOn: Binding(
            get: { status.enabled || enabling },
            set: { on in
                if on { turnOn() } else { sync.disable() }
            })) {
            Label(Copy.Sync.albumToggle, systemImage: Symbol.Sync.album)
        }
        // with keep off there is nothing to fill the album from; an enabled one stays operable so it can be turned off
        .disabled(!keepsVideos && !status.enabled)
        .confirmationDialog(
            backfillCount.map { Copy.Sync.backfillTitle($0) } ?? "",
            isPresented: Binding(
                get: { backfillCount != nil },
                set: { if !$0 { answerBackfill(false) } }),
            titleVisibility: .visible
        ) {
            Button(backfillCount.map { Copy.Sync.backfillAdd($0) } ?? "") { answerBackfill(true) }
            // not `.cancel`: from iOS 26 a dialog anchored to its row drops its cancel button, and this is a real answer
            Button(Copy.Sync.backfillSkip) { answerBackfill(false) }
        }
    }

    private var webpsToggle: some View {
        Toggle(isOn: Binding(
            get: { model.settings.photosSyncWebps },
            set: { sync.setIncludeWebps($0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Label(Copy.Sync.includeWebps, systemImage: Symbol.Sync.webps)
                // gate G-W (core lane, 2026-10-04): PhotoKit stores a webp as a still, not animated
                Text(Copy.Sync.webpStill).font(CobaltType.captionSmall).foregroundStyle(.secondary)
            }
        }
    }

    private var statusRow: some View {
        let line = PhotosStatusLine(status)
        return VStack(alignment: .leading, spacing: 8) {
            LabeledContent {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(line.text)
                        .foregroundStyle(line.textIsProblem ? CobaltColor.errorText : Color.secondary)
                        .monospacedDigit()
                    if let extra = line.extra {
                        Text(extra).foregroundStyle(CobaltColor.errorText)
                    }
                }
                .font(Font.cobalt(12.5))
                .multilineTextAlignment(.trailing)
            } label: {
                Label(Copy.Sync.albumRow, systemImage: line.showsProblemIcon ? Symbol.Sync.problem : Symbol.Sync.albumStatus)
            }
            if let progress = status.progress, progress.total > 0, !status.paused, status.access != .denied {
                ProgressView(value: Double(min(progress.done, progress.total)), total: Double(progress.total))
                    .progressViewStyle(.linear)
                    .tint(CobaltColor.text)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: what shows when

    /// The status shows once the album is on, and after a refusal (the owner needs to see why and where to fix it).
    private var showsStatusRow: Bool { status.enabled || status.access == .denied }

    private var showsOpenSettings: Bool {
        guard status.enabled || status.access == .denied else { return false }
        switch status.access {
        case .libraryLimited, .libraryAddOnly, .denied: return true
        case .unavailable, .notAsked, .album: return false
        }
    }

    private var footerText: String {
        if !keepsVideos, !status.enabled { return Copy.Sync.footerNeedsKeep }
        switch status.access {
        case .libraryLimited: return Copy.Sync.footerLimited
        case .libraryAddOnly: return Copy.Sync.footerAddOnly
        case .denied: return Copy.Sync.footerDenied
        case .unavailable, .notAsked, .album: return Copy.Sync.footerAlbum
        }
    }

    // MARK: actions

    private func turnOn() {
        guard !enabling else { return }
        enabling = true
        Task {
            let outcome = await sync.enable()
            enabling = false
            if case .on(let existing) = outcome, existing > 0 { backfillCount = existing }
        }
    }

    /// The once-only question. Idempotent: a button and the dialog's own dismissal can both land here.
    private func answerBackfill(_ include: Bool) {
        guard backfillCount != nil else { return }
        backfillCount = nil
        Task { await sync.includeExisting(include) }
    }

    private func openSystemSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        #endif
    }
}

/// What the album row says, by the contract's priority: paused, access off, adding, out of space,
/// limited / add-only, the count (with what waits), then what could not be added.
struct PhotosStatusLine {
    let text: String
    /// A second line: what could not be added, when the first line is about something else.
    let extra: String?
    /// The first line itself is the trouble (out of space, access off, nothing could be added).
    let textIsProblem: Bool
    var showsProblemIcon: Bool { textIsProblem || extra != nil }

    init(_ s: PhotosSync.Status) {
        let gaveUp = s.gaveUp > 0 ? Copy.Sync.gaveUp(s.gaveUp) : nil
        if s.paused {
            self.init(Copy.Sync.paused, nil, false)
        } else if s.access == .denied {
            self.init(Copy.Sync.accessOff, nil, true)
        } else if let progress = s.progress {
            self.init(Copy.Sync.adding(progress.done, of: progress.total), gaveUp, false)
        } else if s.problem == .outOfSpace {
            self.init(Copy.Sync.outOfSpace(s.waiting), gaveUp, true)
        } else if s.access == .libraryLimited {
            self.init(Copy.Sync.libraryLimited, gaveUp, false)
        } else if s.access == .libraryAddOnly {
            self.init(Copy.Sync.libraryAddOnly, gaveUp, false)
        } else if s.added == 0, s.waiting == 0, let gaveUp {
            self.init(gaveUp, nil, true)
        } else {
            let count = Copy.Sync.albumCount(s.added) + (s.waiting > 0 ? " · " + Copy.Sync.waiting(s.waiting) : "")
            self.init(count, gaveUp, false)
        }
    }

    private init(_ text: String, _ extra: String?, _ textIsProblem: Bool) {
        self.text = text
        self.extra = extra
        self.textIsProblem = textIsProblem
    }
}
