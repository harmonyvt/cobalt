import CobaltKit
import SwiftUI
import UIKit

/// What the extension shows: the quick card while `model.quick` says so, the full sheet otherwise
/// (CONTRACT-SHARE-QUICK.md). Both report their height to the controller, which sizes the system
/// sheet to it; the card asks for an undimmed, grabber-less sheet so the app underneath stays in view.
struct ShareContainer: View {
    let model: ShareModel
    var onFit: ((CGFloat) -> Void)?

    var body: some View {
        if model.quick.showsCard {
            QuickCardView(model: model, onFit: onFit)
                .transition(.opacity)
        } else {
            ShareRootView(model: model, onFit: onFit)
                .transition(.opacity)
        }
    }
}

/// The quick card: a ring, "saving to cobalt", the link, an expand control. It closes by itself once
/// the server holds the save; on a failure it stays with the reason, try again and open cobalt.
///
/// No background of its own: the system sheet behind it is the card (Liquid Glass at a small detent). So
/// its text and ring use the hierarchical styles (`.primary`, `.secondary`, `.tertiary`), which stay legible
/// on glass over any app; the fixed caption grey did not in dark mode (simulator evidence, 2026-10-05).
struct QuickCardView: View {
    let model: ShareModel
    var onFit: ((CGFloat) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.shareReducesMotion) private var forcedReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || forcedReduceMotion }

    private var pipeline: Pipeline { model.pipeline }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                QuickRing(state: ringState, reduceMotion: reduceMotion)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(CobaltType.bodySemibold)
                        .foregroundStyle(isFailed ? AnyShapeStyle(CobaltColor.errorText) : AnyShapeStyle(.primary))
                        .contentTransition(.opacity)
                    Text(subtitle)
                        .font(CobaltType.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(isFailed ? 3 : 1)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                trailing
            }
            if case .failed = model.quick { failedActions }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.4) { model.expand() }
        .accessibilityAction(named: ShareCopy.quickExpandA11y) { model.expand() }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onFit?($0) }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .onChange(of: model.quick) { _, quick in announce(quick) }
        .sensoryFeedback(.success, trigger: model.quick == .holding) { _, now in now }
        .sensoryFeedback(.error, trigger: isFailed) { _, now in now }
    }

    // MARK: pieces

    private var isFailed: Bool { if case .failed = model.quick { return true } else { return false } }

    private var ringState: QuickRing.Shown {
        switch model.quick {
        case .holding: return .done
        case .failed: return .failed
        default:
            if case .saving(let bytes?, let total?, _) = pipeline.state, total > 0 {
                return .fraction(min(1, Double(bytes) / Double(total)))
            }
            return .spinning
        }
    }

    private var title: String {
        switch model.quick {
        case .holding: return ShareCopy.quickHeld
        case .failed: return ShareCopy.quickFailed
        default: return ShareCopy.quickSaving
        }
    }

    private var subtitle: String {
        switch model.quick {
        case .holding:
            return model.capabilities.notifyBridge ? ShareCopy.quickNotify : ShareCopy.quickOpenLater
        case .failed(let f):
            return Copy.failure(f)
        default:
            return model.quickTitle ?? ShareCopy.quickChecking
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch model.quick {
        case .failed:
            CloseButton { Task { _ = await model.close() } }
        case .holding:
            EmptyView()
        default:
            Button { model.expand() } label: {
                Image(systemName: ShareSymbol.expand)
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .accessibilityLabel(ShareCopy.quickExpandA11y)
        }
    }

    private var failedActions: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                if case .link = pipeline.input {
                    Button(Copy.tryAgain, systemImage: Symbol.retry) { model.retryQuick() }
                        .buttonStyle(.cobaltPrimary(compact: true))
                }
                Button(ShareCopy.quickOpenCobalt, systemImage: Symbol.openApp) { Task { await model.openCobalt() } }
                    .buttonStyle(.cobaltSecondary(compact: true))
            }
        }
    }

    /// VoiceOver hears the hand-off and the failure once each (the ring is hidden from it).
    private func announce(_ quick: QuickShare) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        switch quick {
        case .holding: UIAccessibility.post(notification: .announcement, argument: "\(ShareCopy.quickHeld). \(subtitle)")
        case .failed(let f): UIAccessibility.post(notification: .announcement, argument: "\(ShareCopy.quickFailed). \(Copy.failure(f))")
        default: break
        }
    }
}

/// The card's 28 pt ring: spinning while the server is being asked, filling with the save's bytes when
/// it reports them, a check when the server holds the save, an exclamation mark on a failure. Reduce
/// Motion: no spin (a static quarter arc).
struct QuickRing: View {
    enum Shown: Equatable { case spinning, fraction(Double), done, failed }
    let state: Shown
    var reduceMotion = false
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            Circle().stroke(.tertiary, lineWidth: 2.5)
            switch state {
            case .spinning:
                if reduceMotion {
                    arc(0.25)
                } else {
                    TimelineView(.animation) { context in
                        let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1
                        arc(0.28).rotationEffect(.degrees(turn * 360))
                    }
                }
            case .fraction(let f):
                arc(max(0.04, f)).animation(.easeOut(duration: 0.3), value: f)
            case .done:
                Circle().fill(.primary)
                Image(systemName: Symbol.checkmark)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(CobaltColor.onText)
                    .transition(.scale.combined(with: .opacity))
            case .failed:
                Image(systemName: ShareSymbol.failed)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(CobaltColor.errorText)
            }
        }
        .frame(width: size, height: size)
        .animation(.snappy(duration: 0.25), value: state)
        .accessibilityHidden(true)
    }

    private func arc(_ to: Double) -> some View {
        Circle()
            .trim(from: 0, to: to)
            .stroke(.primary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .rotationEffect(.degrees(-90))
    }
}

#if DEBUG
private struct QuickHost: View {
    @State private var model: ShareModel
    private let pinned: QuickShare?
    private let scenario: PreviewScenario

    init(_ scenario: PreviewScenario, pinned: QuickShare? = nil) {
        _model = State(initialValue: ShareModel.preview(scenario, quick: true))
        self.pinned = pinned
        self.scenario = scenario
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.gray.opacity(0.3).ignoresSafeArea()
            ShareContainer(model: model)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
                .padding(10)
        }
        .task {
            model.pipeline.start(link: URL(string: scenario.pasteText)!)
            if let pinned { model.previewQuick(pinned) }
        }
    }
}

#Preview("quick · saving") { QuickHost(.coldStart, pinned: .working) }
#Preview("quick · cobalt has it") { QuickHost(.coldStart, pinned: .holding) }
#Preview("quick · failed") { QuickHost(.privatePost) }
#Preview("quick · live") { QuickHost(.coldStart) }
#endif
