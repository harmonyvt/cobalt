@preconcurrency import AVFoundation
import CobaltKit
import CoreMedia
import SwiftUI

// Fable Station 3: Interactive Split-Frame (Region A / B) + Synced Chat Editor.
//
// Lets Harmony frame 16:9 Region A & B into a 9:16 portrait edit with live synced chat,
// then either:
//   1. `send to studio` (NO RENDER — uploads unrendered 16:9 clip + lightweight transparent chat GIF
//      and opens a real Cobalt Editor v2 project with Lane 0 = B, Lane 1 = A, Lane 2 = Chat), OR
//   2. `render` (exports a 9:16 1080×1920 composite MP4 straight to the Private Library).

struct TwitchClipEditorView: View {
    let model: AppModel
    let draftID: String

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var chatLog: RecordedChatLog?
    @State private var playhead: Double = 0
    @State private var isPlaying = false
    @State private var selectedRegion: TwitchClipRegionID = .a
    @State private var draggingSeam = false
    @State private var dragStartTarget: TwitchClipRegionTarget?
    @State private var dragStartCrop: NormalizedRect?
    @State private var dragStartPiP: TwitchClipPiPBox?
    @State private var isScrubbing = false
    @State private var renaming = false
    @State private var renameText = ""
    @State private var localNotice: String?
    @State private var localError: String?
    @State private var timeObserver: Any?
    @State private var endObserver: NSObjectProtocol?

    private var store: TwitchClipDraftStore { model.twitchClips }
    private var draft: TwitchClipDraft? { store.draft(id: draftID) }

    var body: some View {
        Group {
            if let draft {
                editorContent(draft)
            } else {
                VStack(spacing: 12) {
                    Text(Copy.Twitch.draftsEmptyTitle)
                        .font(CobaltType.bodySemibold)
                        .foregroundStyle(CobaltColor.text)
                    Button(Copy.Twitch.close) { dismiss() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(CobaltColor.bg)
            }
        }
        .task(id: draftID) {
            await loadDraftMedia()
        }
        .onDisappear {
            tearDownPlayer()
        }
        .alert(Copy.Twitch.renameDraftTitle, isPresented: $renaming) {
            TextField(Copy.Editor.renamePlaceholder, text: $renameText)
            Button(Copy.Editor.rename.replacingOccurrences(of: "…", with: "")) {
                store.rename(draftID: draftID, to: renameText)
            }
            Button(Copy.Editor.cancel, role: .cancel) {}
        }
    }

    // MARK: - Main Editor Layout

    private func editorContent(_ draft: TwitchClipDraft) -> some View {
        GeometryReader { geo in
            let isWide = geo.size.width >= 820
            VStack(spacing: 0) {
                topBar(draft)
                Divider().overlay(CobaltColor.border.opacity(0.6))

                statusBanner(for: draft)

                if isWide {
                    HStack(alignment: .top, spacing: 16) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                sourceFrameSection(draft)
                                presetStrip(draft)
                            }
                            .padding(14)
                        }
                        .frame(maxWidth: .infinity)

                        verticalPreviewColumn(draft, maxHeight: max(320, geo.size.height - 220))
                            .frame(width: min(300, max(230, geo.size.width * 0.28)))
                            .padding(.vertical, 12)

                        ScrollView {
                            chatInspector(draft)
                                .padding(14)
                        }
                        .frame(width: min(300, max(240, geo.size.width * 0.27)))
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(alignment: .top, spacing: 12) {
                                verticalPreviewColumn(draft, maxHeight: 330)
                                    .frame(width: min(190, geo.size.width * 0.45))
                                VStack(alignment: .leading, spacing: 10) {
                                    sourceFrameSection(draft)
                                    presetStrip(draft)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            chatInspector(draft)
                        }
                        .padding(12)
                    }
                }

                Divider().overlay(CobaltColor.border.opacity(0.6))
                timelineDock(draft)
            }
            .background(CobaltColor.bg)
        }
        #if os(macOS)
        .frame(minWidth: 940, minHeight: 680)
        #endif
    }

    // MARK: - Top Bar (Title + Send to Studio + Render)

    private func topBar(_ draft: TwitchClipDraft) -> some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Image(systemName: Symbol.Twitch.close)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(CobaltColor.text)
                    .frame(width: 32, height: 32)
                    .background(CobaltColor.elevated, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Copy.Twitch.close)

            Button {
                renameText = draft.title
                renaming = true
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(draft.title)
                            .font(CobaltType.bodySemibold)
                            .foregroundStyle(CobaltColor.text)
                            .lineLimit(1)
                        Image(systemName: "pencil")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(CobaltColor.caption)
                    }
                    Text("\(draft.channel) · \(TwitchClipDraftsSheet.clock(draft.duration)) · \(Copy.Twitch.chatLines(draft.chatLineCount))")
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            if model.editor.isAvailable {
                Button {
                    triggerSendToStudio(draft)
                } label: {
                    HStack(spacing: 6) {
                        if case .sendingToStudio(let id, _) = store.exportState, id == draft.id {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: Symbol.Twitch.sendToStudio)
                                .font(.system(size: 12, weight: .semibold))
                        }
                        Text(Copy.Twitch.sendToStudio)
                            .font(CobaltType.captionSmall)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(TwitchClipPalette.chatPurple.opacity(0.20), in: Capsule())
                    .overlay(Capsule().stroke(TwitchClipPalette.chatPurple.opacity(0.55), lineWidth: 1))
                    .foregroundStyle(TwitchClipPalette.chatPurple)
                }
                .buttonStyle(.plain)
                .disabled(store.isExporting)
                .help(Copy.Twitch.sendToStudioSub)
                .accessibilityIdentifier("twitch.clip.sendToStudio")
            }

            Button {
                triggerRender(draft)
            } label: {
                HStack(spacing: 6) {
                    if case .rendering(let id, _, _) = store.exportState, id == draft.id {
                        ProgressView().controlSize(.mini).tint(.white)
                    } else {
                        Image(systemName: Symbol.Twitch.renderExport)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Text(Copy.Twitch.renderVideo)
                        .font(CobaltType.captionSmall)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(CobaltColor.linkBlue, in: Capsule())
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(store.isExporting)
            .accessibilityIdentifier("twitch.clip.render")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func statusBanner(for draft: TwitchClipDraft) -> some View {
        switch store.exportState {
        case .sendingToStudio(let id, let stage) where id == draft.id:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(stage)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(TwitchClipPalette.chatPurple)
                Spacer()
                Text(Copy.Twitch.sendToStudioSub)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(TwitchClipPalette.chatPurple.opacity(0.12))

        case .rendering(let id, let progress, let stage) where id == draft.id:
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(stage)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.text)
                    Spacer()
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(CobaltColor.linkBlue)
                }
                ProgressView(value: progress)
                    .tint(CobaltColor.linkBlue)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(CobaltColor.linkBlue.opacity(0.10))

        case .failed(let id, let message) where id == draft.id:
            HStack(spacing: 8) {
                Image(systemName: Symbol.Twitch.warn)
                    .foregroundStyle(CobaltColor.errorText)
                Text(message)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.errorText)
                Spacer()
                Button(Copy.Twitch.close) { store.clearExportState() }
                    .font(CobaltType.captionSmall)
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(CobaltColor.errorText.opacity(0.12))

        case .done(let id, let message) where id == draft.id:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(CobaltColor.success)
                Text(message)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.success)
                Spacer()
                Button(Copy.Twitch.close) { store.clearExportState() }
                    .font(CobaltType.captionSmall)
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(CobaltColor.success.opacity(0.12))

        default:
            if let localError {
                HStack(spacing: 8) {
                    Image(systemName: Symbol.Twitch.warn)
                        .foregroundStyle(CobaltColor.errorText)
                    Text(localError)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.errorText)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(CobaltColor.errorText.opacity(0.12))
            } else if let localNotice {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(CobaltColor.success)
                    Text(localNotice)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.success)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(CobaltColor.success.opacity(0.12))
            }
        }
    }

    // MARK: - 16:9 Source Frame Picker (Region A & B Aspect-Locked Boxes)

    private func sourceFrameSection(_ draft: TwitchClipDraft) -> some View {
        let srcAspect = max(0.5, draft.sourceAspect)
        let showsA = draft.edit.layout != .single

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if showsA {
                    regionLegendChip(.a, label: Copy.Twitch.regionALabel, color: TwitchClipPalette.regionA)
                }
                regionLegendChip(.b, label: Copy.Twitch.regionBLabel, color: TwitchClipPalette.regionB)
                Spacer(minLength: 0)
            }

            GeometryReader { geo in
                let size = geo.size
                ZStack(alignment: .topLeading) {
                    if let player {
                        EditorPlayerView(player: player)
                            .allowsHitTesting(false)
                    } else {
                        TwitchClipDraftThumbnail(model: model, draft: draft, maxPixel: 720)
                    }

                    // Draw unselected box first, selected box on top for clean drag targeting.
                    let order: [TwitchClipRegionID] = showsA
                        ? (selectedRegion == .a ? [.b, .a] : [.a, .b])
                        : [.b]
                    ForEach(order, id: \.self) { region in
                        let crop = TwitchClipTimelineBridge.cropRect(
                            for: region,
                            config: draft.edit,
                            sourceAspect: srcAspect
                        )
                        regionBox(
                            region: region,
                            crop: crop,
                            frameSize: size,
                            draft: draft,
                            isSelected: selectedRegion == region
                        )
                    }
                }
                .clipShape(.rect(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(CobaltColor.border.opacity(0.8), lineWidth: 1)
                )
            }
            .aspectRatio(srcAspect, contentMode: .fit)

            Text(Copy.Twitch.sourcePickerHint)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
        }
    }

    private func regionLegendChip(_ region: TwitchClipRegionID, label: String, color: Color) -> some View {
        let active = selectedRegion == region
        return Button {
            selectedRegion = region
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(label)
                    .font(CobaltType.captionSmall)
                    .fontWeight(active ? .semibold : .regular)
                    .foregroundStyle(active ? CobaltColor.text : CobaltColor.caption)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(active ? color.opacity(0.18) : CobaltColor.elevated.opacity(0.65), in: Capsule())
            .overlay(Capsule().stroke(active ? color.opacity(0.75) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func regionBox(
        region: TwitchClipRegionID,
        crop: NormalizedRect,
        frameSize: CGSize,
        draft: TwitchClipDraft,
        isSelected: Bool
    ) -> some View {
        let color = region == .a ? TwitchClipPalette.regionA : TwitchClipPalette.regionB
        let boxW = max(24, CGFloat(crop.w) * frameSize.width)
        let boxH = max(24, CGFloat(crop.h) * frameSize.height)
        let boxX = CGFloat(crop.x) * frameSize.width
        let boxY = CGFloat(crop.y) * frameSize.height

        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(color.opacity(isSelected ? 0.16 : 0.08))
                .overlay(
                    Rectangle()
                        .stroke(color, lineWidth: isSelected ? 2.5 : 1.5)
                )

            // Corner badge A / B
            Text(region.rawValue)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color, in: .rect(cornerRadius: 4))
                .padding(4)

            // Bottom-right aspect-locked resize handle
            Circle()
                .fill(color)
                .overlay(Circle().stroke(.black.opacity(0.6), lineWidth: 1.5))
                .frame(width: 16, height: 16)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
                .position(x: boxW - 2, y: boxH - 2)
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            selectedRegion = region
                            let startCrop = dragStartCrop ?? crop
                            if dragStartCrop == nil { dragStartCrop = crop }
                            let deltaW = Double(value.translation.width) / max(1, Double(frameSize.width))
                            let nextTarget = TwitchClipTimelineBridge.resizedTarget(
                                from: startCrop,
                                deltaWidth: deltaW,
                                region: region,
                                config: draft.edit,
                                sourceAspect: draft.sourceAspect
                            )
                            store.updateEdit(draftID: draft.id) { edit in
                                edit.setTarget(nextTarget, for: region)
                            }
                        }
                        .onEnded { _ in
                            dragStartCrop = nil
                        }
                )
        }
        .frame(width: boxW, height: boxH)
        .offset(x: boxX, y: boxY)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    selectedRegion = region
                    let start = dragStartTarget ?? draft.edit.target(for: region)
                    if dragStartTarget == nil { dragStartTarget = start }
                    let dx = Double(value.translation.width) / max(1, Double(frameSize.width))
                    let dy = Double(value.translation.height) / max(1, Double(frameSize.height))
                    store.updateEdit(draftID: draft.id) { edit in
                        var target = start
                        target.cx = min(1, max(0, start.cx + dx))
                        target.cy = min(1, max(0, start.cy + dy))
                        edit.setTarget(target, for: region)
                    }
                }
                .onEnded { _ in
                    dragStartTarget = nil
                }
        )
    }

    // MARK: - Layout Preset Strip + Swap A ⇅ B

    private func presetStrip(_ draft: TwitchClipDraft) -> some View {
        let edit = draft.edit
        return VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    presetChip(
                        Copy.Twitch.layoutSplit5050,
                        active: edit.layout == .split && abs(edit.splitRatio - 0.50) < 0.01
                    ) {
                        store.updateEdit(draftID: draft.id) {
                            $0.layout = .split
                            $0.splitRatio = 0.50
                        }
                    }
                    presetChip(
                        Copy.Twitch.layoutSplit4060,
                        active: edit.layout == .split && abs(edit.splitRatio - 0.40) < 0.01
                    ) {
                        store.updateEdit(draftID: draft.id) {
                            $0.layout = .split
                            $0.splitRatio = 0.40
                        }
                    }
                    presetChip(
                        Copy.Twitch.layoutSplit3565,
                        active: edit.layout == .split && abs(edit.splitRatio - 0.35) < 0.01
                    ) {
                        store.updateEdit(draftID: draft.id) {
                            $0.layout = .split
                            $0.splitRatio = 0.35
                        }
                    }
                    presetChip(
                        Copy.Twitch.layoutPiP,
                        active: edit.layout == .pip
                    ) {
                        store.updateEdit(draftID: draft.id) { $0.layout = .pip }
                    }
                    presetChip(
                        Copy.Twitch.layoutSingle,
                        active: edit.layout == .single
                    ) {
                        store.updateEdit(draftID: draft.id) { $0.layout = .single }
                        selectedRegion = .b
                    }

                    if edit.layout == .split {
                        Button {
                            store.updateEdit(draftID: draft.id) { $0.topRegion = $0.topRegion.other }
                        } label: {
                            Label(Copy.Twitch.swapRegions, systemImage: Symbol.Twitch.swapVertical)
                                .font(CobaltType.captionSmall)
                                .fontWeight(.semibold)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(CobaltColor.elevated, in: Capsule())
                                .foregroundStyle(CobaltColor.text)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func presetChip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(CobaltType.captionSmall)
                .fontWeight(active ? .semibold : .regular)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(active ? CobaltColor.linkBlue.opacity(0.22) : CobaltColor.elevated, in: Capsule())
                .overlay(Capsule().stroke(active ? CobaltColor.linkBlue : .clear, lineWidth: 1))
                .foregroundStyle(active ? CobaltColor.linkBlue : CobaltColor.text)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Live 9:16 Vertical Preview (Split Seam + PiP Drag + Synced Chat Overlay)

    private func verticalPreviewColumn(_ draft: TwitchClipDraft, maxHeight: CGFloat) -> some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let size = geo.size
                let edit = draft.edit
                let slots = TwitchClipTimelineBridge.slots(for: edit)
                let bandH = TwitchClipTimelineBridge.bandHeight(for: edit)
                let videoAreaH = size.height * CGFloat(1.0 - bandH)

                ZStack(alignment: .topLeading) {
                    Color.black

                    // Render each live cropped video slot (B then A)
                    ForEach(slots, id: \.region) { slot in
                        let crop = TwitchClipTimelineBridge.cropRect(
                            for: slot.region,
                            config: edit,
                            sourceAspect: draft.sourceAspect
                        )
                        let slotW = CGFloat(slot.rect.w) * size.width
                        let slotH = CGFloat(slot.rect.h) * size.height
                        let slotX = CGFloat(slot.rect.x) * size.width
                        let slotY = CGFloat(slot.rect.y) * size.height

                        croppedVideoSlot(
                            crop: crop,
                            slotSize: CGSize(width: slotW, height: slotH),
                            draft: draft
                        )
                        .clipShape(.rect(cornerRadius: slot.isPiP ? 10 : 0))
                        .overlay {
                            if slot.isPiP {
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(TwitchClipPalette.regionA, lineWidth: 2)
                            }
                        }
                        .offset(x: slotX, y: slotY)
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    guard slot.isPiP else { return }
                                    let start = dragStartPiP ?? edit.pip
                                    if dragStartPiP == nil { dragStartPiP = start }
                                    let dx = Double(value.translation.width) / max(1, Double(size.width))
                                    let dy = Double(value.translation.height) / max(1, Double(size.height))
                                    store.updateEdit(draftID: draft.id) { cfg in
                                        cfg.pip.x = min(0.98 - cfg.pip.w, max(0.02, start.x + dx))
                                        cfg.pip.y = min(0.85, max(0.02, start.y + dy))
                                    }
                                }
                                .onEnded { _ in
                                    dragStartPiP = nil
                                }
                        )
                    }

                    // Dedicated bottom chat band background
                    if bandH > 0 {
                        Rectangle()
                            .fill(Color(white: 0.08))
                            .frame(width: size.width, height: size.height - videoAreaH)
                            .offset(y: videoAreaH)
                    }

                    // Interactive Split Seam (snaps to 35 / 40 / 50 / 60 / 65%)
                    if edit.layout == .split {
                        let seamY = videoAreaH * CGFloat(edit.splitRatio)
                        ZStack {
                            Rectangle()
                                .fill(.white.opacity(draggingSeam ? 0.95 : 0.45))
                                .frame(width: size.width, height: draggingSeam ? 2.5 : 1.5)

                            HStack(spacing: 4) {
                                Image(systemName: "line.3.horizontal")
                                    .font(.system(size: 9, weight: .bold))
                                if draggingSeam {
                                    let pct = Int((edit.splitRatio * 100).rounded())
                                    Text("\(pct)/\(100 - pct)")
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                }
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.72), in: Capsule())
                        }
                        .frame(width: size.width, height: 28)
                        .contentShape(Rectangle())
                        .offset(y: seamY - 14)
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    draggingSeam = true
                                    let raw = Double(value.location.y) / max(1, Double(videoAreaH))
                                    let snapped = TwitchClipTimelineBridge.snapSplitRatio(raw)
                                    store.updateEdit(draftID: draft.id) { $0.splitRatio = snapped }
                                }
                                .onEnded { _ in
                                    draggingSeam = false
                                }
                        )
                    }

                    // Live Synced Chat Overlay
                    if edit.chat.enabled {
                        let chatRect = TwitchClipTimelineBridge.chatOverlayRect(for: edit)
                        liveChatOverlay(draft: draft, config: edit.chat)
                            .frame(
                                width: CGFloat(chatRect.w) * size.width,
                                height: CGFloat(chatRect.h) * size.height,
                                alignment: .bottomLeading
                            )
                            .offset(
                                x: CGFloat(chatRect.x) * size.width,
                                y: CGFloat(chatRect.y) * size.height
                            )
                            .allowsHitTesting(false)
                    }
                }
                .clipShape(.rect(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(CobaltColor.border.opacity(0.9), lineWidth: 1)
                )
            }
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .frame(maxHeight: maxHeight)

            if draft.edit.layout == .split {
                Text(Copy.Twitch.seamHint)
                    .font(.system(size: 10))
                    .foregroundStyle(CobaltColor.caption)
                    .multilineTextAlignment(.center)
            }
        }
    }

    @ViewBuilder
    private func croppedVideoSlot(crop: NormalizedRect, slotSize: CGSize, draft: TwitchClipDraft) -> some View {
        let safeW = max(0.01, crop.w)
        let safeH = max(0.01, crop.h)
        let fullW = slotSize.width / CGFloat(safeW)
        let fullH = slotSize.height / CGFloat(safeH)
        let offsetX = -CGFloat(crop.x) * fullW
        let offsetY = -CGFloat(crop.y) * fullH

        ZStack(alignment: .topLeading) {
            if let player {
                EditorPlayerView(player: player)
                    .frame(width: fullW, height: fullH)
                    .offset(x: offsetX, y: offsetY)
            } else {
                TwitchClipDraftThumbnail(model: model, draft: draft, maxPixel: 720)
                    .frame(width: fullW, height: fullH)
                    .offset(x: offsetX, y: offsetY)
            }
        }
        .frame(width: max(1, slotSize.width), height: max(1, slotSize.height), alignment: .topLeading)
        .clipped()
    }

    @ViewBuilder
    private func liveChatOverlay(draft: TwitchClipDraft, config: TwitchClipChatConfig) -> some View {
        let log = chatLog ?? RecordedChatLog(channel: draft.channel, duration: draft.duration, entries: [])
        let tt = playhead - config.syncOffset
        let inGap = log.isInGap(at: tt)
        let maxLines = config.placement == .band ? 4 : 5
        let entries = inGap ? [] : log.visibleEntries(at: playhead, syncOffset: config.syncOffset, maxLines: maxLines)
        let fontSize = CGFloat(10.5 * config.scale)

        VStack(alignment: .leading, spacing: 3) {
            Spacer(minLength: 0)
            if inGap {
                HStack(spacing: 4) {
                    Circle().fill(TwitchClipPalette.recRed).frame(width: 6, height: 6)
                    Text(Copy.Twitch.chatDroppedHere)
                        .font(.system(size: max(9, fontSize * 0.9), weight: .semibold))
                        .foregroundStyle(TwitchClipPalette.recRed)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.black.opacity(0.65), in: Capsule())
            } else {
                ForEach(entries) { entry in
                    chatOverlayLine(entry: entry, config: config, fontSize: fontSize)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .background {
            if config.look == .liquidGlass && config.placement != .band && (!entries.isEmpty || inGap) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(.white.opacity(0.18), lineWidth: 0.75)
                    )
            }
        }
    }

    private func chatOverlayLine(entry: RecordedChatEntry, config: TwitchClipChatConfig, fontSize: CGFloat) -> some View {
        let nameColor = Color(rgb24: entry.resolvedColorRGB)
        return HStack(alignment: .firstTextBaseline, spacing: 3) {
            if config.showBadges {
                ForEach(entry.badges.prefix(2), id: \.id) { badge in
                    AsyncImage(url: badge.url) { img in
                        img.resizable().scaledToFit()
                    } placeholder: {
                        Color.clear
                    }
                    .frame(width: fontSize, height: fontSize)
                }
            }
            Text("\(entry.displayName):")
                .font(.system(size: fontSize, weight: .bold))
                .foregroundStyle(nameColor)
                .lineLimit(1)
            Text(entry.plainText)
                .font(.system(size: fontSize, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
        }
        .shadow(
            color: config.look == .clearText ? .black.opacity(0.95) : .black.opacity(0.35),
            radius: config.look == .clearText ? 2 : 1,
            x: 0,
            y: 1
        )
    }

    // MARK: - Chat Inspector

    private func chatInspector(_ draft: TwitchClipDraft) -> some View {
        let chat = draft.edit.chat
        let gapSeconds = Int(draft.totalChatGapSeconds.rounded())

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(Copy.Twitch.chatLayer, systemImage: Symbol.Twitch.chat)
                    .font(CobaltType.bodySemibold)
                    .foregroundStyle(CobaltColor.text)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { chat.enabled },
                    set: { enabled in store.updateEdit(draftID: draft.id) { $0.chat.enabled = enabled } }
                ))
                .labelsHidden()
            }

            if gapSeconds > 0 {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: Symbol.Twitch.warn)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TwitchClipPalette.recRed)
                    Text(Copy.Twitch.chatDroppedWarning(gapSeconds))
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(TwitchClipPalette.recRed)
                }
                .padding(8)
                .background(TwitchClipPalette.recRed.opacity(0.12), in: .rect(cornerRadius: 8))
            }

            Group {
                // Placement: bottom / seam / top / band
                VStack(alignment: .leading, spacing: 6) {
                    Text("placement")
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                    HStack(spacing: 6) {
                        placementChip(draft, .bottom, Copy.Twitch.chatPlacementBottom)
                        placementChip(draft, .seam, Copy.Twitch.chatPlacementSeam)
                        placementChip(draft, .top, Copy.Twitch.chatPlacementTop)
                        placementChip(draft, .band, Copy.Twitch.chatPlacementBand)
                    }
                }

                // Look: liquid glass / clear text
                VStack(alignment: .leading, spacing: 6) {
                    Text("look")
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                    HStack(spacing: 6) {
                        lookChip(draft, .liquidGlass, Copy.Twitch.chatLookGlass)
                        lookChip(draft, .clearText, Copy.Twitch.chatLookClear)
                    }
                }

                // Size slider (80% – 160%)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(Copy.Twitch.chatSize)
                            .font(CobaltType.captionSmall)
                            .foregroundStyle(CobaltColor.caption)
                        Spacer()
                        Text("\(Int((chat.scale * 100).rounded()))%")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(CobaltColor.text)
                    }
                    Slider(
                        value: Binding(
                            get: { chat.scale },
                            set: { v in store.updateEdit(draftID: draft.id) { $0.chat.scale = v } }
                        ),
                        in: 0.8...1.6,
                        step: 0.05
                    )
                    .tint(TwitchClipPalette.chatPurple)
                }

                // 7TV emotes / badges / paints chips
                HStack(spacing: 6) {
                    featureChip(Copy.Twitch.chatEmotes, active: chat.showEmotes) {
                        store.updateEdit(draftID: draft.id) { $0.chat.showEmotes.toggle() }
                    }
                    featureChip(Copy.Twitch.chatBadges, active: chat.showBadges) {
                        store.updateEdit(draftID: draft.id) { $0.chat.showBadges.toggle() }
                    }
                    featureChip(Copy.Twitch.chatPaints, active: chat.showPaints) {
                        store.updateEdit(draftID: draft.id) { $0.chat.showPaints.toggle() }
                    }
                }

                // Sync Nudge (±0.5 s)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(Copy.Twitch.chatSyncNudge, systemImage: Symbol.Twitch.syncNudge)
                            .font(CobaltType.captionSmall)
                            .foregroundStyle(CobaltColor.caption)
                        Spacer()
                        Button {
                            store.updateEdit(draftID: draft.id) { $0.chat.syncOffset = 0 }
                        } label: {
                            Text(Self.signedSeconds(chat.syncOffset))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(abs(chat.syncOffset) < 0.01 ? CobaltColor.caption : TwitchClipPalette.chatPurple)
                        }
                        .buttonStyle(.plain)
                    }
                    HStack(spacing: 8) {
                        Button {
                            store.updateEdit(draftID: draft.id) {
                                $0.chat.syncOffset = max(-5.0, (($0.chat.syncOffset - 0.5) * 2).rounded() / 2)
                            }
                        } label: {
                            Text("-0.5 s")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(CobaltColor.elevated, in: .rect(cornerRadius: 8))
                                .foregroundStyle(CobaltColor.text)
                        }
                        .buttonStyle(.plain)

                        Button {
                            store.updateEdit(draftID: draft.id) {
                                $0.chat.syncOffset = min(5.0, (($0.chat.syncOffset + 0.5) * 2).rounded() / 2)
                            }
                        } label: {
                            Text("+0.5 s")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(CobaltColor.elevated, in: .rect(cornerRadius: 8))
                                .foregroundStyle(CobaltColor.text)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .disabled(!chat.enabled)
            .opacity(chat.enabled ? 1 : 0.45)
        }
        .padding(12)
        .background(CobaltColor.surface, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(CobaltColor.border.opacity(0.6), lineWidth: 1))
    }

    private func placementChip(_ draft: TwitchClipDraft, _ placement: TwitchClipChatPlacement, _ label: String) -> some View {
        let active = draft.edit.chat.placement == placement
        return Button {
            store.updateEdit(draftID: draft.id) { $0.chat.placement = placement }
        } label: {
            Text(label)
                .font(CobaltType.captionSmall)
                .fontWeight(active ? .semibold : .regular)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(active ? TwitchClipPalette.chatPurple.opacity(0.22) : CobaltColor.elevated, in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(active ? TwitchClipPalette.chatPurple : .clear, lineWidth: 1))
                .foregroundStyle(active ? TwitchClipPalette.chatPurple : CobaltColor.text)
        }
        .buttonStyle(.plain)
    }

    private func lookChip(_ draft: TwitchClipDraft, _ look: TwitchClipChatLook, _ label: String) -> some View {
        let active = draft.edit.chat.look == look
        return Button {
            store.updateEdit(draftID: draft.id) { $0.chat.look = look }
        } label: {
            Text(label)
                .font(CobaltType.captionSmall)
                .fontWeight(active ? .semibold : .regular)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(active ? TwitchClipPalette.chatPurple.opacity(0.22) : CobaltColor.elevated, in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(active ? TwitchClipPalette.chatPurple : .clear, lineWidth: 1))
                .foregroundStyle(active ? TwitchClipPalette.chatPurple : CobaltColor.text)
        }
        .buttonStyle(.plain)
    }

    private func featureChip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: active ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(active ? TwitchClipPalette.chatPurple.opacity(0.20) : CobaltColor.elevated, in: Capsule())
                .foregroundStyle(active ? TwitchClipPalette.chatPurple : CobaltColor.caption)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 3-Lane Scrubbable Timeline (Chat + A + B)

    private func timelineDock(_ draft: TwitchClipDraft) -> some View {
        let duration = max(0.5, draft.duration)
        let frac = min(1, max(0, playhead / duration))

        return VStack(spacing: 8) {
            // Transport row
            HStack(spacing: 10) {
                Button {
                    togglePlayback(duration: duration)
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(CobaltColor.linkBlue, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? Copy.Twitch.pause : Copy.Twitch.play)

                Text("\(Self.preciseClock(playhead)) / \(Self.preciseClock(duration))")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(CobaltColor.text)

                Spacer()

                Button("-5s") { seek(to: max(0, playhead - 5), duration: duration) }
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .buttonStyle(.plain)
                    .foregroundStyle(CobaltColor.caption)

                Button("+5s") { seek(to: min(duration, playhead + 5), duration: duration) }
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .buttonStyle(.plain)
                    .foregroundStyle(CobaltColor.caption)
            }

            // 3 Lanes: Lane 2 Chat, Lane 1 A, Lane 0 B + draggable playhead
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(Copy.Twitch.laneChat)
                        .foregroundStyle(draft.edit.chat.enabled ? TwitchClipPalette.chatPurple : CobaltColor.caption.opacity(0.4))
                    Text(Copy.Twitch.regionA)
                        .foregroundStyle(draft.edit.layout == .single ? CobaltColor.caption.opacity(0.35) : TwitchClipPalette.regionA)
                    Text(Copy.Twitch.regionB)
                        .foregroundStyle(TwitchClipPalette.regionB)
                }
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .frame(width: 32)

                GeometryReader { geo in
                    let w = max(1, geo.size.width)
                    ZStack(alignment: .leading) {
                        VStack(spacing: 4) {
                            // Lane 2: Chat heat strip + gap stripes
                            TwitchClipHeatStrip(
                                density: draft.density,
                                gaps: draft.chatGaps,
                                duration: duration,
                                height: 16
                            )
                            .opacity(draft.edit.chat.enabled ? 1 : 0.3)

                            // Lane 1: Region A bar
                            RoundedRectangle(cornerRadius: 4)
                                .fill(TwitchClipPalette.regionA.opacity(draft.edit.layout == .single ? 0.14 : 0.42))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(TwitchClipPalette.regionA.opacity(draft.edit.layout == .single ? 0.25 : 0.8), lineWidth: 1)
                                )
                                .frame(height: 14)

                            // Lane 0: Region B bar
                            RoundedRectangle(cornerRadius: 4)
                                .fill(TwitchClipPalette.regionB.opacity(0.42))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(TwitchClipPalette.regionB.opacity(0.85), lineWidth: 1)
                                )
                                .frame(height: 14)
                        }

                        // Playhead needle
                        Rectangle()
                            .fill(.white)
                            .frame(width: 2)
                            .shadow(color: .black.opacity(0.6), radius: 2)
                            .offset(x: CGFloat(frac) * (w - 2))
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                isScrubbing = true
                                let targetFrac = min(1, max(0, Double(value.location.x) / Double(w)))
                                seek(to: targetFrac * duration, duration: duration)
                            }
                            .onEnded { _ in
                                isScrubbing = false
                            }
                    )
                }
                .frame(height: 52)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(CobaltColor.surface)
    }

    // MARK: - Playback & Export Actions

    private func loadDraftMedia() async {
        await store.boot()
        guard let draft = store.draft(id: draftID) else { return }
        store.markSeen(draftID: draft.id)
        chatLog = await store.loadChatLog(for: draft)

        tearDownPlayer()
        let url = store.videoURL(for: draft)
        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.actionAtItemEnd = .pause
        let interval = CMTime(seconds: 1.0 / 20.0, preferredTimescale: 600)
        timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak newPlayer] time in
            Task { @MainActor in
                guard !isScrubbing else { return }
                let sec = time.seconds
                if sec.isFinite, sec >= 0 {
                    playhead = sec
                }
                if let p = newPlayer {
                    isPlaying = p.rate > 0.01
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            Task { @MainActor in
                isPlaying = false
            }
        }
        player = newPlayer
    }

    private func tearDownPlayer() {
        if let obs = timeObserver, let player {
            player.removeTimeObserver(obs)
        }
        timeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
    }

    private func togglePlayback(duration: Double) {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if playhead >= duration - 0.1 {
                seek(to: 0, duration: duration)
            }
            player.play()
            isPlaying = true
        }
    }

    private func seek(to seconds: Double, duration: Double) {
        let clamped = min(duration, max(0, seconds))
        playhead = clamped
        let cm = CMTime(seconds: clamped, preferredTimescale: 600)
        player?.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func triggerSendToStudio(_ draft: TwitchClipDraft) {
        localError = nil
        localNotice = nil
        player?.pause()
        isPlaying = false
        Task {
            do {
                _ = try await store.sendToStudio(draft: draft, editor: model.editor, openImmediately: true)
                dismiss()
            } catch {
                localError = error.localizedDescription
            }
        }
    }

    private func triggerRender(_ draft: TwitchClipDraft) {
        localError = nil
        localNotice = nil
        player?.pause()
        isPlaying = false
        Task {
            do {
                _ = try await store.renderAndUpload(draft: draft)
                await model.library.refresh()
                localNotice = Copy.Twitch.savedPrivate
            } catch {
                localError = error.localizedDescription
            }
        }
    }

    private static func preciseClock(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let m = Int(clamped) / 60
        let s = clamped - Double(m * 60)
        return String(format: "%d:%04.1f", m, s)
    }

    private static func signedSeconds(_ s: Double) -> String {
        if abs(s) < 0.01 { return "0.0 s" }
        return String(format: "%+.1f s", s)
    }
}

private extension Color {
    init(rgb24 rgb: UInt32) {
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }
}
