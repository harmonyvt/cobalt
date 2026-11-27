import CobaltKit
import SwiftUI

// Fable Station 2: Stream Drafts shelf & reusable thumbnail / chat heat-bar components.
// Surfaced both inside Twitch (via the `drafts` pill) and on the Library's existing `edits` shelf.

enum TwitchClipPalette {
    static let regionA = Color(red: 0.96, green: 0.65, blue: 0.14) // amber #F5A623
    static let regionB = Color(red: 0.30, green: 0.64, blue: 1.00) // blue  #4DA3FF
    static let chatPurple = Color(red: 0.66, green: 0.44, blue: 1.00) // twitch purple #A970FF
    static let recRed = Color(red: 1.00, green: 0.27, blue: 0.23)
}

/// Off-main thumbnail view for a `TwitchClipDraft` (decodes `CGImage` inside `TwitchClipStorage`, never on `@MainActor`).
struct TwitchClipDraftThumbnail: View {
    let model: AppModel
    let draft: TwitchClipDraft
    var maxPixel: Int = 360

    @State private var cgImage: CGImage?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.14), Color(white: 0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            if let cgImage {
                Image(decorative: cgImage, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: Symbol.Twitch.splitFrame)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .clipped()
        .task(id: draft.thumbnailFileName ?? draft.id) {
            cgImage = await model.twitchClips.loadThumbnail(for: draft, maxPixelSize: maxPixel)
        }
    }
}

/// Compact per-second chat-activity heat bar strip with red gap stripes where live chat dropped.
struct TwitchClipHeatStrip: View {
    let density: [Int]
    let gaps: [RecordedChatGap]
    let duration: Double
    var height: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let h = max(4, geo.size.height)
            let peak = max(1, density.max() ?? 1)
            let bars = density.isEmpty ? [0] : density

            ZStack(alignment: .bottomLeading) {
                // Background track
                RoundedRectangle(cornerRadius: 3)
                    .fill(CobaltColor.elevated.opacity(0.75))

                // Per-second chat density bars
                HStack(alignment: .bottom, spacing: 1) {
                    ForEach(Array(bars.enumerated()), id: \.offset) { _, value in
                        let frac = value > 0 ? max(0.18, Double(value) / Double(peak)) : 0.06
                        RoundedRectangle(cornerRadius: 1)
                            .fill(value > 0 ? TwitchClipPalette.chatPurple.opacity(0.82) : CobaltColor.caption.opacity(0.18))
                            .frame(height: max(1.5, h * frac))
                    }
                }
                .padding(.horizontal, 1)

                // Red striped overlays for chat reconnect gaps (video is whole, chat dropped)
                if duration > 0 {
                    ForEach(Array(gaps.enumerated()), id: \.offset) { _, gap in
                        let x0 = CGFloat(max(0, min(1, gap.start / duration))) * w
                        let x1 = CGFloat(max(0, min(1, gap.end / duration))) * w
                        let gw = max(3, x1 - x0)
                        TwitchClipGapHatch()
                            .frame(width: gw, height: h)
                            .clipShape(.rect(cornerRadius: 2))
                            .offset(x: x0)
                    }
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// Subtle red diagonal hatch indicating a recorded chat reconnect gap.
struct TwitchClipGapHatch: View {
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(TwitchClipPalette.recRed.opacity(0.28)))
            var path = Path()
            let step: CGFloat = 6
            var x: CGFloat = -size.height
            while x < size.width + size.height {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += step
            }
            ctx.stroke(path, with: .color(TwitchClipPalette.recRed.opacity(0.85)), lineWidth: 1.5)
        }
    }
}

/// Fable Station 2: Stream Drafts sheet accessible directly from Twitch while watching.
struct TwitchClipDraftsSheet: View {
    let model: AppModel
    var onOpenDraft: (TwitchClipDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var renaming: TwitchClipDraft?
    @State private var newName = ""
    @State private var sendingID: String?
    @State private var errorNote: String?

    private var store: TwitchClipDraftStore { model.twitchClips }

    var body: some View {
        NavigationStack {
            Group {
                if store.drafts.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            if let errorNote {
                                HStack(spacing: 8) {
                                    Image(systemName: Symbol.Twitch.warn)
                                        .foregroundStyle(CobaltColor.errorText)
                                    Text(errorNote)
                                        .font(CobaltType.captionSmall)
                                        .foregroundStyle(CobaltColor.errorText)
                                    Spacer()
                                }
                                .padding(10)
                                .background(CobaltColor.errorText.opacity(0.12), in: .rect(cornerRadius: 10))
                            }

                            ForEach(store.drafts) { draft in
                                draftRow(draft)
                            }
                        }
                        .padding(14)
                    }
                }
            }
            .background(CobaltColor.bg)
            .navigationTitle(Copy.Twitch.draftsTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Label(Copy.Twitch.close, systemImage: Symbol.Twitch.close)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 460)
        #endif
        .task {
            await store.boot()
            store.markAllSeen()
        }
        .alert(
            Copy.Twitch.renameDraftTitle,
            isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
        ) {
            TextField(Copy.Editor.renamePlaceholder, text: $newName)
            Button(Copy.Editor.rename.replacingOccurrences(of: "…", with: "")) {
                if let target = renaming {
                    store.rename(draftID: target.id, to: newName)
                }
                renaming = nil
            }
            Button(Copy.Editor.cancel, role: .cancel) { renaming = nil }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: Symbol.Twitch.drafts)
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(CobaltColor.caption)
            Text(Copy.Twitch.draftsEmptyTitle)
                .font(CobaltType.bodySemibold)
                .foregroundStyle(CobaltColor.text)
            Text(Copy.Twitch.draftsEmptyBody)
                .font(CobaltType.caption)
                .foregroundStyle(CobaltColor.caption)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func draftRow(_ draft: TwitchClipDraft) -> some View {
        let gapSeconds = Int(draft.totalChatGapSeconds.rounded())
        let isSending = sendingID == draft.id

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    openEditor(draft)
                } label: {
                    ZStack(alignment: .bottomTrailing) {
                        TwitchClipDraftThumbnail(model: model, draft: draft)
                            .frame(width: 112, height: 64)
                            .clipShape(.rect(cornerRadius: 8))

                        Text(Self.clock(draft.duration))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.75), in: .rect(cornerRadius: 4))
                            .padding(4)
                    }
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(draft.title)
                            .font(CobaltType.bodyMedium)
                            .foregroundStyle(CobaltColor.text)
                            .lineLimit(1)
                        if draft.isFresh {
                            Text(Copy.Twitch.draftNewBadge)
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(TwitchClipPalette.chatPurple, in: Capsule())
                        }
                        Spacer(minLength: 4)
                    }

                    HStack(spacing: 6) {
                        Text(draft.channel)
                            .foregroundStyle(CobaltColor.caption)
                        Text("·")
                            .foregroundStyle(CobaltColor.caption.opacity(0.5))
                        Text(draft.kind == .recording ? Copy.Twitch.draftKindRecording : Copy.Twitch.draftKindClip)
                            .foregroundStyle(draft.kind == .recording ? TwitchClipPalette.recRed : CobaltColor.caption)
                        if draft.chatLineCount > 0 {
                            Text("·")
                                .foregroundStyle(CobaltColor.caption.opacity(0.5))
                            Text(Copy.Twitch.chatLines(draft.chatLineCount))
                                .foregroundStyle(TwitchClipPalette.chatPurple)
                        }
                    }
                    .font(CobaltType.captionSmall)
                    .lineLimit(1)

                    TwitchClipHeatStrip(
                        density: draft.density,
                        gaps: draft.chatGaps,
                        duration: draft.duration,
                        height: 12
                    )
                    .padding(.top, 2)
                }
            }

            if gapSeconds > 0 {
                HStack(spacing: 6) {
                    Image(systemName: Symbol.Twitch.warn)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TwitchClipPalette.recRed)
                    Text(Copy.Twitch.chatDroppedWarning(gapSeconds))
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(TwitchClipPalette.recRed)
                }
            }

            HStack(spacing: 8) {
                Button {
                    openEditor(draft)
                } label: {
                    Label(Copy.Twitch.openInEditor, systemImage: Symbol.Twitch.splitFrame)
                        .font(CobaltType.captionSmall)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(CobaltColor.elevated, in: Capsule())
                        .foregroundStyle(CobaltColor.text)
                }
                .buttonStyle(.plain)

                if model.editor.isAvailable {
                    Button {
                        sendDirectlyToStudio(draft)
                    } label: {
                        HStack(spacing: 5) {
                            if isSending {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: Symbol.Twitch.sendToStudio)
                            }
                            Text(isSending ? Copy.Twitch.sendingToStudio : Copy.Twitch.sendToStudio)
                                .lineLimit(1)
                        }
                        .font(CobaltType.captionSmall)
                        .fontWeight(.semibold)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(TwitchClipPalette.chatPurple.opacity(0.18), in: Capsule())
                        .foregroundStyle(TwitchClipPalette.chatPurple)
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isExporting)
                }

                Spacer(minLength: 0)

                Menu {
                    Button(Copy.Twitch.renameDraft, systemImage: "pencil") {
                        newName = draft.title
                        renaming = draft
                    }
                    Button(Copy.Twitch.deleteDraft, systemImage: Symbol.delete, role: .destructive) {
                        store.delete(draftID: draft.id)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(CobaltColor.caption)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(CobaltColor.surface, in: .rect(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(CobaltColor.border.opacity(0.6), lineWidth: 1)
        )
    }

    private func openEditor(_ draft: TwitchClipDraft) {
        store.markSeen(draftID: draft.id)
        dismiss()
        onOpenDraft(draft)
    }

    private func sendDirectlyToStudio(_ draft: TwitchClipDraft) {
        errorNote = nil
        sendingID = draft.id
        Task {
            defer { sendingID = nil }
            do {
                _ = try await store.sendToStudio(draft: draft, editor: model.editor, openImmediately: true)
                dismiss()
            } catch {
                errorNote = error.localizedDescription
            }
        }
    }

    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
