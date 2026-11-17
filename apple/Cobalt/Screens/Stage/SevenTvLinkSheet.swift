import CobaltKit
import SwiftUI

// The link sheet (APP-API-CONTRACT 57.1, mockup screen 4). 7TV has no sign-in for other apps, so linking moves the session
// token 7tv.app keeps into capystore once. Easiest: copy the bookmarklet, keep it as a bookmark, tap it on 7tv.app; it opens
// `cobalt-apple://7tv-link?token=…` and the app links (`AppModel.openSevenTvLink`). Or paste the token in a secure field; the
// field is cleared once linked. The token never leaves this sheet except to `POST /7tv/link`.

struct SevenTvLinkSheet: View {
    let store: SevenTvStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.shell) private var shell
    @State private var token = ""
    @State private var problem: String?
    @State private var copied = false
    @State private var copiedTick = 0

    private var canLink: Bool { !store.linking && SevenTvLink.looksLikeToken(SevenTvLink.clean(token)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                SevenTvLinkBookmarkBox(copied: copied, copy: copyBookmark)
                pasteBox
                Text(Copy.SevenTv.footer)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 16)
        }
        #if os(macOS)
        .frame(width: 460, height: 620)
        #else
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        .background(CobaltColor.bg)
        .interactiveDismissDisabled(store.linking)
        .haptic(.success, trigger: copiedTick)
        .haptic(.error, trigger: problem) { $0 != nil }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(Copy.SevenTv.linkTitle)
                .font(Font.cobalt(18, .semibold, relativeTo: .title3))
                .foregroundStyle(CobaltColor.text)
                .accessibilityAddTraits(.isHeader)
            Text(Copy.SevenTv.once)
                .font(CobaltType.pill)
                .foregroundStyle(CobaltColor.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(CobaltColor.elevated, in: Capsule())
            Spacer(minLength: 0)
            CloseButton(cancels: true) { dismiss() }
        }
    }

    private var pasteBox: some View {
        SevenTvLinkBox(title: Copy.SevenTv.orPaste) {
            Text(Copy.SevenTv.pasteHow)
                .font(CobaltType.caption)
                .foregroundStyle(CobaltColor.caption)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                SecureField(Copy.SevenTv.tokenField, text: $token)
                    .font(CobaltType.body)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit { link() }
                    .padding(.horizontal, 12)
                    .frame(minHeight: Metrics.hit)
                    .background(CobaltColor.elevated, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
                Text(Copy.SevenTv.tokenHint)
                    .font(CobaltType.badge)
                    .foregroundStyle(CobaltColor.caption)
            }
            if let problem {
                Text(problem)
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.errorText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(store.linking ? Copy.SevenTv.linking : Copy.SevenTv.linkButton, systemImage: Symbol.SevenTv.link) { link() }
                .buttonStyle(.cobaltPrimary(fullWidth: false, compact: true))
                .disabled(!canLink)
        }
    }

    private func copyBookmark() {
        Pasteboard.copy(SevenTvLink.bookmarklet)
        shell.showStatus(Copy.SevenTv.bookmarkCopied)
        copied = true
        copiedTick += 1
    }

    private func link() {
        guard canLink else { return }
        let pasted = token
        problem = nil
        Task {
            let result = await store.link(token: pasted)
            switch result {
            case .linked:
                token = ""                      // the field never keeps the token once linked
                dismiss()
            case .failed(let error):
                problem = Copy.SevenTv.message(for: error)
            }
        }
    }
}

/// The "easiest" box: why, the three steps, "copy the bookmark" and "open 7tv.app".
private struct SevenTvLinkBookmarkBox: View {
    let copied: Bool
    let copy: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        SevenTvLinkBox(title: Copy.SevenTv.easiest) {
            Text(Copy.SevenTv.why)
                .font(CobaltType.caption)
                .foregroundStyle(CobaltColor.caption)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                step(1, Copy.SevenTv.step1)
                step(2, Copy.SevenTv.step2)
                step(3, Copy.SevenTv.step3)
            }
            Text(Copy.SevenTv.bookmarkHow)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
                .fixedSize(horizontal: false, vertical: true)
            ButtonRow {
                Button(copied ? Copy.SevenTv.bookmarkCopied : Copy.SevenTv.copyBookmark,
                       systemImage: copied ? Symbol.checkmark : Symbol.SevenTv.bookmark) { copy() }
                    .buttonStyle(CobaltButtonStyle(kind: copied ? .done : .primary, fullWidth: false, compact: true))
                Button(Copy.SevenTv.openWebsite, systemImage: Symbol.SevenTv.website) { openURL(SevenTvLink.website) }
                    .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
            }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(n).")
                .font(CobaltType.caption)
                .foregroundStyle(CobaltColor.caption)
                .monospacedDigit()
            Text(text)
                .font(CobaltType.caption)
                .foregroundStyle(CobaltColor.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A box of the link sheet: a small grey title, then the content.
private struct SevenTvLinkBox<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
