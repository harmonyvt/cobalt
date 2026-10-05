import CobaltKit
import Observation
import SwiftUI
import UIKit

// The quick card as a full-screen overlay (CONTRACT-SHARE-QUICK.md section 2a, owner 2026-10-05): the
// extension is presented `.overFullScreen` with a clear background, a blur fades in over the app you
// were in, the card drops out of the Dynamic Island, and once the server holds the save the card morphs
// back into a black capsule at the island and merges into it. It is a visual hand-off only: a real Live
// Activity cannot be started from a share extension (section 0, F1 to F3).

/// How the controller is presenting the extension, for the root view. `overlay` is what the controller
/// asked for (`.overFullScreen`); it turns false when the host still put the extension in a sheet, and
/// then the compact sheet card is used instead.
@MainActor @Observable
final class ShareStage {
    var overlay: Bool
    /// The window's top safe-area inset (where the island is), from UIKit.
    var safeTop: CGFloat = 0
    var safeBottom: CGFloat = 0

    init(overlay: Bool) { self.overlay = overlay }
}

/// The root view: the overlay, or the sheet (card or full) when the host presents a sheet.
struct ShareStageView: View {
    let model: ShareModel
    let stage: ShareStage
    var onFit: ((CGFloat) -> Void)?

    var body: some View {
        if stage.overlay {
            QuickOverlay(model: model, stage: stage)
        } else {
            ShareContainer(model: model, onFit: onFit)
        }
    }
}

/// Where the Dynamic Island is, or where a stand-in pill goes on a device without one.
enum IslandGeometry {
    /// iPhone 14 Pro and later in portrait: a 126 x 37 pt capsule, 11 pt from the top, centred. Those
    /// devices have a top safe-area inset of 59 to 62 pt; notch devices 44 to 50, home-button ones 20.
    static func rect(width: CGFloat, safeTop: CGFloat) -> CGRect {
        if safeTop >= 51 {
            return CGRect(x: (width - 126) / 2, y: 11, width: 126, height: 37)
        }
        let h: CGFloat = 28
        return CGRect(x: (width - 96) / 2, y: max(4, (safeTop - h) / 2), width: 96, height: h)
    }

    static func hasIsland(safeTop: CGFloat) -> Bool { safeTop >= 51 }
}

struct QuickOverlay: View {
    let model: ShareModel
    let stage: ShareStage

    /// hidden: a clear capsule at the island (where the card comes from and goes back to).
    enum Phase: Equatable { case hidden, card, island, gone }

    @State private var phase: Phase = .hidden
    @State private var cardHeight: CGFloat = 0
    @State private var panelHeight: CGFloat = 0
    /// When the card finished dropping in: it stays readable at least `minDwell` before the morph.
    @State private var cardInAt: Date?
    @State private var morphing = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.shareReducesMotion) private var forcedReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || forcedReduceMotion }

    /// Morph timings (the hand-off waits for all of them: `quickHoldSeconds`).
    static let checkBeat: Double = 0.35
    static let morphDuration: Double = 0.5
    static let mergeDuration: Double = 0.25
    /// The card is on screen at least this long, even when the server answers at once.
    static let minDwell: Double = 0.9
    /// The hand-off's upper bound: the view calls `finishQuickHold()` as soon as the morph is over.
    static let holdCeiling: Double = 4

    private var expanded: Bool { if case .expanded = model.quick { return true } else { return false } }
    private var failed: Bool { if case .failed = model.quick { return true } else { return false } }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let island = IslandGeometry.rect(width: width, safeTop: stage.safeTop)
            let cardWidth = min(width - 20, 480)
            let card = CGRect(
                x: (width - cardWidth) / 2, y: max(stage.safeTop, island.maxY) + 8,
                width: cardWidth, height: max(cardHeight, 1))
            ZStack(alignment: .topLeading) {
                blur
                if expanded {
                    panel(size: geo.size)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    morphingCard(card: card, island: island)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .onAppear {
            model.quickHoldSeconds = Self.holdCeiling
        }
        .task {
            // the card is measured first (hidden at the island), then drops out of it
            try? await Task.sleep(for: .milliseconds(40))
            withAnimation(reduceMotion ? .easeOut(duration: 0.25) : .spring(duration: 0.45, bounce: 0.22)) { phase = .card }
            cardInAt = .now
            ShareDebugLog.log("overlay card in")
            if model.quick == .holding { await morphIntoIsland() }   // the server answered before the card was up
        }
        .onChange(of: model.quick) { _, quick in
            if quick == .holding, cardInAt != nil { Task { await morphIntoIsland() } }
        }
    }

    // MARK: blur

    private var blurOn: Bool { phase == .card || expanded }

    private var blur: some View {
        Rectangle()
            .fill(.regularMaterial)
            .opacity(blurOn ? 1 : 0)
            .animation(.easeOut(duration: 0.25), value: blurOn)
            .contentShape(Rectangle())
            .onTapGesture { tappedOutside() }
            .accessibilityLabel(Copy.closeA11y)
            .accessibilityAddTraits(.isButton)
            .accessibilityHidden(!(failed || expanded))
    }

    /// Tap outside the card: closes a failed card or the expanded sheet; a card that is still working
    /// is left alone (it closes itself in a moment).
    private func tappedOutside() {
        guard failed || expanded else { return }
        Task { _ = await model.close() }
    }

    // MARK: the card, the island

    @ViewBuilder
    private func morphingCard(card: CGRect, island: CGRect) -> some View {
        let atIsland = phase != .card
        let r = atIsland ? island : card
        let radius = atIsland ? island.height / 2 : 30
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            Color.clear
                .glassEffect(.regular, in: shape)
                .opacity(atIsland ? 0 : 1)
            shape.fill(.black)
                .opacity(phase == .island ? 1 : 0)
            QuickCardView(model: model, onFit: { h in if abs(h - cardHeight) >= 1 { cardHeight = h } })
                .frame(width: card.width)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(atIsland ? 0 : 1)
                .frame(width: r.width, height: r.height)
        }
        .frame(width: r.width, height: r.height)
        .clipShape(shape)
        .scaleEffect(phase == .gone ? 0.82 : 1)
        .opacity(phase == .hidden || phase == .gone ? 0 : 1)
        .position(x: r.midX, y: r.midY)
        .accessibilityHidden(atIsland)
    }

    /// "cobalt has it": the check shows for a beat, the card becomes a black capsule over the island,
    /// the blur goes, and the capsule sinks into the island. Reduce Motion: everything fades.
    private func morphIntoIsland() async {
        guard phase == .card, !morphing else { return }
        morphing = true
        let shown = cardInAt.map { Date.now.timeIntervalSince($0) } ?? 0
        let beat = max(Self.checkBeat, Self.minDwell - shown)
        ShareDebugLog.log("overlay morph start (card up \(String(format: "%.2f", shown)) s, check \(String(format: "%.2f", beat)) s)")
        try? await Task.sleep(for: .seconds(beat))
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.3)) { phase = .gone }
            try? await Task.sleep(for: .seconds(0.3))
        } else {
            withAnimation(.spring(duration: Self.morphDuration, bounce: 0.18)) { phase = .island }
            try? await Task.sleep(for: .seconds(Self.morphDuration))
            withAnimation(.easeIn(duration: Self.mergeDuration)) { phase = .gone }
            try? await Task.sleep(for: .seconds(Self.mergeDuration))
        }
        ShareDebugLog.log("overlay merged into island")
        await model.finishQuickHold()
    }

    // MARK: the full sheet, drawn by the overlay

    /// Expanded (asked, or a run only the full sheet can finish): the sheet's content in a bottom panel
    /// over the blur, as tall as it is (up to 88% of the screen, then it scrolls).
    private func panel(size: CGSize) -> some View {
        let maxH = size.height * 0.88
        let h = min(maxH, max(panelHeight, 120) + stage.safeBottom)
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            ShareRootView(model: model, onFit: { panelHeight = $0 })
                .padding(.bottom, stage.safeBottom)
                .frame(height: h)
                .background(CobaltColor.bg)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 34, topTrailingRadius: 34, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 20, y: -4)
        }
        .frame(width: size.width, height: size.height)
    }
}

/// The overlay's log lines (`[sharequick]`), debug builds only.
enum ShareDebugLog {
    static func log(_ message: String) {
        #if DEBUG
        NSLog("[sharequick] %@", message)
        #endif
    }
}

#if DEBUG
private struct OverlayHost: View {
    @State private var model: ShareModel
    @State private var stage = ShareStage(overlay: true)
    private let scenario: PreviewScenario

    init(_ scenario: PreviewScenario) {
        _model = State(initialValue: ShareModel.preview(scenario, quick: true))
        self.scenario = scenario
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [.orange, .pink, .indigo], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            ShareStageView(model: model, stage: stage)
        }
        .onAppear { stage.safeTop = 62 }
        .task { model.pipeline.start(link: URL(string: scenario.pasteText)!) }
    }
}

#Preview("overlay · into the island") { OverlayHost(.coldStart) }
#Preview("overlay · failed") { OverlayHost(.privatePost) }
#endif
