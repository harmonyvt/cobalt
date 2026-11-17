import CobaltKit
import SwiftUI

// "link 7tv" (APP-API-CONTRACT 57.12): 7TV's own login page in a web view with a data store of its own. After the login the
// token 7tv.app keeps in `localStorage` goes to `POST /7tv/link` and the sheet says "linked as <name>" and closes. "other ways
// to link" opens the older sheet (bookmarklet, paste) on top. The address bar shows the page's host and a close button.

struct SevenTvLoginSheet: View {
    let store: SevenTvStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var model: SevenTvLoginModel
    @State private var otherWays = false

    /// `previewPhase`: previews show this state over a placeholder instead of a real page.
    init(store: SevenTvStore, previewPhase: SevenTvLoginModel.Phase? = nil) {
        self.store = store
        _model = State(initialValue: SevenTvLoginModel(store: store, preview: previewPhase))
    }

    private var working: Bool { model.phase == .linking }

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            ZStack {
                page
                status
            }
            footer
        }
        .background(CobaltColor.bg)
        #if os(macOS)
        .frame(width: 520, height: 720)
        #else
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        #endif
        .interactiveDismissDisabled(working)
        .sheet(isPresented: $otherWays) { SevenTvLinkSheet(store: store) }
        .haptic(.error, trigger: model.phase) { if case .failed = $0 { true } else { false } }
        .task {
            model.openExternally = { openURL($0) }
            model.close = { dismiss() }
            await model.watch()
        }
    }

    // MARK: the pieces

    private var addressBar: some View {
        HStack(spacing: 8) {
            Image(systemName: Symbol.SevenTv.secure)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CobaltColor.caption)
                .accessibilityHidden(true)
            Text(model.host)
                .font(CobaltType.bodyMedium)
                .foregroundStyle(CobaltColor.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)
            if model.isLoading && !model.isPreview {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Copy.SevenTv.loginLoading)
            }
            Spacer(minLength: 8)
            CloseButton(cancels: true) { dismiss() }
                .disabled(working)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var page: some View {
        if model.isPreview {
            VStack(spacing: 8) {
                Image(systemName: Symbol.SevenTv.tab)
                    .font(.system(size: 34))
                Text(Copy.SevenTv.loginPlaceholder)
                    .font(CobaltType.caption)
            }
            .foregroundStyle(CobaltColor.caption)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CobaltColor.surface)
        } else {
            SevenTvLoginWebView(model: model)
                .accessibilityLabel(Copy.SevenTv.loginPageA11y)
        }
    }

    /// Over the page while a token is being checked, after the link, and when it failed.
    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .browsing:
            EmptyView()
        case .linking:
            statusCard {
                ProgressView()
                Text(Copy.SevenTv.linking)
                    .font(CobaltType.bodyMedium)
                    .foregroundStyle(CobaltColor.text)
            }
        case .linked(let name):
            statusCard {
                Image(systemName: Symbol.checkmark)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(CobaltColor.success)
                Text(Copy.SevenTv.loginLinked(name))
                    .font(CobaltType.bodyMedium)
                    .foregroundStyle(CobaltColor.text)
            }
        case .failed(let error):
            statusCard {
                Image(systemName: Symbol.SevenTv.warn)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(CobaltColor.errorText)
                Text(Copy.SevenTv.message(for: error))
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.text)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(Copy.SevenTv.retry, systemImage: Symbol.SevenTv.retry) { model.retry() }
                    .buttonStyle(.cobaltPrimary(fullWidth: false, compact: true))
            }
        }
    }

    private func statusCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack {
            CobaltColor.bg.opacity(0.9)
            VStack(spacing: 10, content: content)
                .padding(20)
                .frame(maxWidth: 280)
                .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .accessibilityElement(children: .combine)
        .transition(.opacity)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Text(Copy.SevenTv.loginNote)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(Copy.SevenTv.otherWays, systemImage: Symbol.SevenTv.otherWays) { otherWays = true }
                .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                .disabled(working)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 14)
    }
}
