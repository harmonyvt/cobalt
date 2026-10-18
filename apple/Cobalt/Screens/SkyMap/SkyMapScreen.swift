import CobaltKit
import SwiftUI

/// The library as a sky map (APP-API-CONTRACT 21, `GET /library/map`): every post a star, close together = similar in
/// meaning, grouped into constellations with their keywords. The screen is the sky edge to edge with a quiet header over
/// it (title, `N posts · M constellations`, a thin bar while the stars arrange themselves), a close button, and the
/// states (loading, empty, failed). `SkyMapView` is the sky; the library presents this (`LibrarySkyMapPresenter`).
struct SkyMapScreen: View {
    let model: AppModel
    /// A star was opened: its post key. The library shows the post.
    let onOpen: (String) -> Void
    let onClose: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var camera = SkyCamera()
    @State private var attempt = 0

    private var sky: SkyMapModel { model.skyMap }

    var body: some View {
        let theme = SkyTheme.of(scheme)
        GeometryReader { geo in
            let safe = geo.safeAreaInsets
            let insets = SkyInsets(top: safe.top + 88, bottom: safe.bottom + 24, side: 28)
            // the sky runs under the status bar and the home indicator; the header stays inside the safe area
            ZStack(alignment: .topLeading) {
                SkyMapView(sky: sky, camera: camera, insets: insets, onOpen: onOpen)
                    .ignoresSafeArea()
                message(theme: theme)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                header(theme: theme)
                    .padding(.top, Platform.isMac ? 16 : 10)
                    .padding(.leading, 20)
                    .padding(.trailing, 16)
            }
        }
        .background { theme.bottom.color().ignoresSafeArea() }
        // loads when the map opens; leaving cancels the fetch or the layout (a settled sky is kept for next time)
        .task(id: attempt) { await sky.load() }
        .environment(\.colorScheme, scheme)
    }

    // MARK: header

    private func header(theme: SkyTheme) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Copy.SkyMap.title)
                    .font(Font.cobalt(18, .semibold, relativeTo: .title3))
                    .foregroundStyle(theme.label.color())
                    .accessibilityAddTraits(.isHeader)
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(theme.label.color(0.8))
                        .monospacedDigit()
                        .contentTransition(.opacity)
                }
                if case .laying(let progress) = sky.phase {
                    SkyProgressBar(progress: progress, theme: theme)
                        .frame(width: 168, height: 3)
                        .padding(.top, 2)
                        .accessibilityHidden(true)
                }
            }
            .allowsHitTesting(false)
            .motion(Motion.rows, value: lines)
            Spacer(minLength: 8)
            if !camera.viewport.isHome {
                Button { camera.home(animated: !reduceMotion) } label: {
                    Image(systemName: Symbol.SkyMap.reset)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.label.color())
                        .frame(width: 34, height: 34)
                        .background(theme.tip.color(theme.tipAlpha), in: Circle())
                        .overlay { Circle().strokeBorder(theme.line.color(theme.lineAlpha), lineWidth: 1) }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Copy.SkyMap.resetView)
                .help(Copy.SkyMap.resetHint)
                .transition(.opacity)
            }
            Button(action: onClose) {
                Image(systemName: Symbol.SkyMap.close)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.label.color())
                    .frame(width: 34, height: 34)
                    .background(theme.tip.color(theme.tipAlpha), in: Circle())
                    .overlay { Circle().strokeBorder(theme.line.color(theme.lineAlpha), lineWidth: 1) }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(Copy.SkyMap.close)
            .help(Copy.SkyMap.close)
        }
        .motion(Motion.rows, value: camera.viewport.isHome)
    }

    /// The second and third lines of the header, by phase.
    private var lines: [String] {
        switch sky.phase {
        case .idle, .loading:
            return [Copy.SkyMap.loading]
        case .laying:
            var out = [Copy.SkyMap.arranging, Copy.SkyMap.posts(sky.posts.count)]
            if sky.unmapped > 0 { out.append(Copy.SkyMap.unmapped(sky.unmapped)) }
            return out
        case .ready:
            var out = [Copy.SkyMap.counts(posts: sky.posts.count, constellations: sky.constellations.count)]
            if sky.unmapped > 0 { out.append(Copy.SkyMap.unmapped(sky.unmapped)) }
            return out
        case .failed, .empty:
            return []
        }
    }

    // MARK: states

    @ViewBuilder
    private func message(theme: SkyTheme) -> some View {
        switch sky.phase {
        case .idle, .loading:
            SkyMapMessage(kind: .loading, theme: theme, retry: {})
        case .empty:
            SkyMapMessage(kind: .empty, theme: theme, retry: {})
        case .failed(let text):
            SkyMapMessage(kind: .failed(text), theme: theme) { attempt += 1 }
        case .laying, .ready:
            EmptyView()
        }
    }
}

/// The thin bar under the header while the stars arrange themselves.
struct SkyProgressBar: View {
    let progress: Double
    let theme: SkyTheme

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.line.color(theme.lineAlpha))
                Capsule().fill(theme.label.color())
                    .frame(width: max(3, geo.size.width * min(1, max(0, progress))))
            }
        }
        .animation(.linear(duration: 0.12), value: progress)
    }
}

/// Loading, empty and failed, centred over the bare sky.
struct SkyMapMessage: View {
    enum Kind: Equatable {
        case loading, empty
        case failed(String)
    }

    let kind: Kind
    let theme: SkyTheme
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            switch kind {
            case .loading:
                ProgressView().tint(theme.label.color())
            case .empty:
                Image(systemName: Symbol.SkyMap.empty)
                    .font(.system(size: 26))
                    .foregroundStyle(theme.label.color(0.7))
                Text(Copy.SkyMap.emptyTitle)
                    .font(Font.cobalt(15, .semibold, relativeTo: .headline))
                    .foregroundStyle(theme.label.color())
                Text(Copy.SkyMap.emptyDetail)
                    .font(CobaltType.caption)
                    .foregroundStyle(theme.label.color(0.8))
                    .multilineTextAlignment(.center)
            case .failed(let text):
                Image(systemName: Symbol.SkyMap.failed)
                    .font(.system(size: 24))
                    .foregroundStyle(theme.label.color(0.7))
                Text(Copy.SkyMap.failedTitle)
                    .font(Font.cobalt(15, .semibold, relativeTo: .headline))
                    .foregroundStyle(theme.label.color())
                Text(text.lowercased())
                    .font(CobaltType.caption)
                    .foregroundStyle(theme.label.color(0.8))
                    .multilineTextAlignment(.center)
                Button(action: retry) {
                    Label(Copy.SkyMap.tryAgain, systemImage: Symbol.SkyMap.retry)
                        .font(CobaltType.buttonSmall)
                }
                .buttonStyle(.cobaltSecondary(fullWidth: false))
                .environment(\.colorScheme, theme.dark ? .dark : .light)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: 360)
        .accessibilityElement(children: .contain)
    }
}
