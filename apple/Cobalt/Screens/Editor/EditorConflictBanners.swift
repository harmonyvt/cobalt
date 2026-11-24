import CobaltKit
import SwiftUI

/// `conflictTitle` / `conflictBody` with `useTheirs` and `keepMine`, under the top bar while the server's copy moved on.
struct EditorConflictBanner: View {
    let session: EditSession

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: Symbol.Editor.missing)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(CobaltColor.errorText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(Copy.Editor.conflictTitle)
                    .font(CobaltType.bodyMedium)
                    .foregroundStyle(CobaltColor.text)
                Text(Copy.Editor.conflictBody)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            ButtonRow {
                Button(Copy.Editor.useTheirs) { Task { await session.resolveConflict(keepMine: false) } }
                    .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                Button(Copy.Editor.keepMine) { Task { await session.resolveConflict(keepMine: true) } }
                    .buttonStyle(.cobaltPrimary(fullWidth: false, compact: true))
            }
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(CobaltColor.error.opacity(0.12))
        .overlay(alignment: .bottom) { Rectangle().fill(EditorColor.line).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }
}

#if os(iOS)
/// `conflictTitle` / `conflictBody` with `useTheirs` and `keepMine`, stacked for a phone's width.
struct EditorPhoneConflictBanner: View {
    let session: EditSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: Symbol.Editor.missing)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(CobaltColor.errorText)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Copy.Editor.conflictTitle)
                        .font(CobaltType.bodyMedium)
                        .foregroundStyle(CobaltColor.text)
                    Text(Copy.Editor.conflictBody)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ButtonRow {
                Button(Copy.Editor.useTheirs) { Task { await session.resolveConflict(keepMine: false) } }
                    .buttonStyle(.cobaltSecondary(compact: true))
                Button(Copy.Editor.keepMine) { Task { await session.resolveConflict(keepMine: true) } }
                    .buttonStyle(.cobaltPrimary(compact: true))
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 10)
        .background(CobaltColor.error.opacity(0.12))
        .accessibilityElement(children: .contain)
    }
}
#endif

/// `renderLinkLost` with `reconnect`, under the top bar while two or more reads of the running render failed in a row
/// (`EditSession.renderPollState`). The render is on the server and keeps going; this screen only lost sight of it. Phone and
/// desktop share it (one line of text that wraps, one button).
struct EditorReconnectBanner: View {
    let session: EditSession

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: Symbol.Editor.missing)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(EditorColor.overlay)
                .accessibilityHidden(true)
            Text(Copy.Editor.renderLinkLost)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(Copy.Editor.reconnect) { session.reconnectRenderPoll() }
                .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                .fixedSize()
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 6)
        .background(EditorColor.overlay.opacity(0.16))
        .background(EditorColor.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(EditorColor.line).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }
}
