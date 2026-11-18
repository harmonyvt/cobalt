import CobaltKit
import SwiftUI

/// The effects menu for one overlay video. The owner picks the method; nothing is chosen for them.
/// Mac swaps the 272 pt inspector to this. iPhone presents it as a sheet. The controls are the same.
struct EditorEffectsPanel: View {
    let session: EditSession
    let overlay: EditOverlay

    @State private var method: EditEffectKind?
    @State private var color = EditChromaKey.green
    @State private var similarity = 0.2
    @State private var spill = 0.4
    @State private var feather = 0.05
    @State private var showMask = false
    @State private var split = true
    @State private var plate: Plate = .transparent
    @State private var plateColor = "#000000"
    @State private var output: EditKeyedOutput = .mp4
    @State private var nearFar = 0.5
    @State private var quote: RmbgQuote?
    @State private var busy = false
    @State private var error: String?

    private enum Plate: String, CaseIterable, Hashable {
        case transparent, colour, clip, blur
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            methods
            if let method { specifics(method) }
            if method != nil { shared }
            if let error {
                Text(error)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.errorText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let line = session.effectStatus {
                jobCard(line)
            }
        }
        .onAppear { restore() }
        .onChange(of: draftStamp) { _, _ in pushDraft() }
        .task(id: method) { await loadQuote() }
    }

    // MARK: methods

    private var methods: some View {
        EditorSection(Copy.Editor.effects, trailing: method == nil ? Copy.Editor.effectsPick : nil) {
            VStack(alignment: .leading, spacing: 6) {
                methodButton(.greenscreen, Copy.Editor.effectGreenscreen)
                methodButton(.depth, Copy.Editor.effectDepth)
                methodButton(.person, Copy.Editor.effectPerson)
                methodButton(.subject, Copy.Editor.effectSubject)
                methodButton(.removeBackground, Copy.Editor.effectRemoveBackground)
            }
        }
    }

    private func methodButton(_ kind: EditEffectKind, _ title: String) -> some View {
        Button {
            method = kind
            error = nil
        } label: {
            HStack {
                Text(title)
                    .font(Font.cobalt(12.5, .medium, relativeTo: .caption))
                Spacer(minLength: 8)
                if method == kind {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .foregroundStyle(CobaltColor.text)
            .padding(.horizontal, 10)
            .frame(minHeight: Platform.isMac ? 30 : 38)
            .background(method == kind ? CobaltColor.elevated : EditorColor.field, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(method == kind ? .isSelected : [])
    }

    // MARK: one method

    @ViewBuilder
    private func specifics(_ method: EditEffectKind) -> some View {
        switch method {
        case .greenscreen:
            EditorSection(Copy.Editor.effectColour) {
                HStack(spacing: 8) {
                    swatch(Copy.Editor.effectGreen, EditChromaKey.green)
                    swatch(Copy.Editor.effectBlue, EditChromaKey.blue)
                }
            }
            EditorSection(Copy.Editor.effectSimilarity, trailing: Copy.Editor.trimmedNumber(similarity, places: 2)) {
                EditorSlider(value: $similarity, range: 0.01...0.6, step: 0.01, label: Copy.Editor.effectSimilarity)
            }
            EditorSection(Copy.Editor.effectSpill, trailing: Copy.Editor.trimmedNumber(spill, places: 2)) {
                EditorSlider(value: $spill, range: 0...1, step: 0.01, label: Copy.Editor.effectSpill)
            }
        case .depth:
            EditorSection(Copy.Editor.effectDepth, trailing: nearFar < 0.5 ? Copy.Editor.effectNear : Copy.Editor.effectFar) {
                EditorSlider(value: $nearFar, range: 0...1, step: 0.01, label: Copy.Editor.effectDepth)
            }
            Text(Copy.Editor.effectDepthStub)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
                .fixedSize(horizontal: false, vertical: true)
        case .person, .subject:
            Text(method == .person ? "on this device · a person" : "on this device · the subject in front")
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
        case .removeBackground:
            Text(quoteLine)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
                .fixedSize(horizontal: false, vertical: true)
            EditorSection(Copy.Editor.effectSpill, trailing: Copy.Editor.trimmedNumber(spill, places: 2)) {
                EditorSlider(value: $spill, range: 0...1, step: 0.01, label: Copy.Editor.effectSpill)
            }
        }
    }

    private var quoteLine: String {
        if let quote {
            if quote.tooLong { return Copy.Editor.effectTooLong }
            return Copy.Editor.effectQuote(quote.seconds, quote.estimateUSD)
        }
        return "\(Copy.Editor.effectPrice) · \(Copy.Editor.effectSixty)"
    }

    private func swatch(_ title: String, _ hex: String) -> some View {
        Button {
            color = hex
        } label: {
            Text(title)
                .font(Font.cobalt(12, .medium, relativeTo: .caption))
                .foregroundStyle(CobaltColor.text)
                .frame(maxWidth: .infinity, minHeight: Platform.isMac ? 28 : 36)
                .background(color == hex ? CobaltColor.elevated : EditorColor.field, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(color == hex ? .isSelected : [])
    }

    // MARK: shared

    private var shared: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(Copy.Editor.effectSplit, isOn: $split)
                .font(Font.cobalt(12, .regular, relativeTo: .caption))
                .tint(CobaltColor.text)
            EditorSection(Copy.Editor.effectSoften, trailing: Copy.Editor.trimmedNumber(feather, places: 2)) {
                EditorSlider(value: $feather, range: 0...0.5, step: 0.01, label: Copy.Editor.effectSoften)
            }
            EditorSegmented(
                options: [
                    .init(value: false, title: Copy.Editor.effectResult),
                    .init(value: true, title: Copy.Editor.effectMask),
                ],
                selected: showMask, onSelect: { showMask = $0 })
            EditorSection(Copy.Editor.effectBackground) {
                EditorSegmented(
                    options: [
                        .init(value: Plate.transparent, title: Copy.Editor.effectTransparent),
                        .init(value: Plate.colour, title: Copy.Editor.effectColourPlate),
                        .init(value: Plate.clip, title: Copy.Editor.effectClip),
                        .init(value: Plate.blur, title: Copy.Editor.effectBlur),
                    ],
                    selected: plate, columns: 2, onSelect: { plate = $0 })
                if plate == .blur {
                    Text(Copy.Editor.effectBlurNote)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            EditorSection(Copy.Editor.effectOutput) {
                EditorSegmented(
                    options: EditKeyedOutput.allCases.map { .init(value: $0, title: $0.rawValue) },
                    selected: output, columns: 4, onSelect: { output = $0 })
            }
            Button(Copy.Editor.effectApply) { Task { await apply() } }
                .buttonStyle(.cobaltPrimary())
                .disabled(busy || method == .depth || (method == .removeBackground && quote?.tooLong == true))
        }
    }

    private func jobCard(_ line: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(line)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.text)
                .fixedSize(horizontal: false, vertical: true)
            ProgressView()
                .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CobaltColor.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    // MARK: draft and apply

    private var draftStamp: String {
        "\(method?.rawValue ?? "")|\(color)|\(similarity)|\(spill)|\(feather)|\(showMask)|\(split)|\(plate.rawValue)|\(plateColor)"
    }

    private var backgroundChoice: EditOverlayBackground? {
        switch plate {
        case .transparent: return nil
        case .colour: return .color(plateColor)
        case .clip: return .clip
        case .blur: return .blur
        }
    }

    private func restore() {
        if let key = overlay.key?.normalized() {
            method = .greenscreen
            color = key.color
            similarity = key.similarity
            spill = key.spill
            feather = key.blend
        }
        switch overlay.background {
        case .color(let hex): plate = .colour; plateColor = hex
        case .clip: plate = .clip
        case .blur: plate = .blur
        case nil: break
        }
        if let stored = session.timeline.output { output = stored }
        pushDraft()
    }

    private func pushDraft() {
        guard method == .greenscreen,
              let key = EditChromaKey(color: color, similarity: similarity, blend: feather, spill: spill).normalized() else {
            if session.effectDraft?.overlayID == overlay.id { session.setEffectDraft(nil) }
            return
        }
        session.setEffectDraft(EditEffectDraft(
            overlayID: overlay.id, kind: .greenscreen, key: key, background: backgroundChoice,
            showMask: showMask, split: split))
    }

    private func loadQuote() async {
        guard method == .removeBackground else { quote = nil; return }
        quote = await session.backgroundQuote(for: overlay.id)
    }

    private func apply() async {
        guard let method, !busy else { return }
        busy = true
        defer { busy = false }
        switch method {
        case .greenscreen:
            guard let key = EditChromaKey(color: color, similarity: similarity, blend: feather, spill: spill).normalized() else {
                error = "pick a key colour"
                return
            }
            session.applyGreenscreen(id: overlay.id, key: key, background: backgroundChoice, output: output)
            error = nil
        case .depth:
            error = await session.applyCut(id: overlay.id, kind: .depthCut, soften: feather)
        case .person:
            error = await session.applyCut(id: overlay.id, kind: .personCut, soften: feather / 0.5)
        case .subject:
            error = await session.applyCut(id: overlay.id, kind: .subjectCut, soften: feather / 0.5)
        case .removeBackground:
            error = await session.removeVideoBackground(id: overlay.id, spill: spill)
        }
    }
}

// MARK: - layers

/// Every overlay layer, with show/hide (`hidden`, sent only when the server says so) and lock (this device only).
struct EditorLayersList: View {
    let session: EditSession

    private var tracks: [Int] {
        let used = session.timeline.overlay.map(\.track)
        let top = max(used.max() ?? 0, 0)
        guard session.overlayTrackLimit > 1 else { return used.isEmpty ? [] : [0] }
        return Array(0...min(session.overlayTrackLimit - 1, top))
    }

    var body: some View {
        if !tracks.isEmpty {
            EditorSection(Copy.Editor.layers) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(tracks, id: \.self) { track in row(track) }
                    if !session.sendsHidden {
                        Text(Copy.Editor.layerHiddenNote)
                            .font(CobaltType.captionSmall)
                            .foregroundStyle(CobaltColor.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(Copy.Editor.layerLockNote)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                }
            }
        }
    }

    private func row(_ track: Int) -> some View {
        let hidden = session.layerHidden(track)
        let locked = session.isTrackLocked(track)
        return HStack(spacing: 8) {
            Text(Copy.Editor.layerName(track))
                .font(Font.cobalt(12, .medium, relativeTo: .caption))
                .foregroundStyle(hidden ? CobaltColor.caption : CobaltColor.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                session.setLayerHidden(track, !hidden)
            } label: {
                Label(hidden ? Copy.Editor.layerShow : Copy.Editor.layerHide, systemImage: hidden ? Symbol.Editor.layerHide : Symbol.Editor.layerShow)
            }
            .buttonStyle(.cobaltIcon(.small))
            Button {
                session.setTrackLocked(track, !locked)
            } label: {
                Label(locked ? Copy.Editor.layerUnlock : Copy.Editor.layerLock, systemImage: locked ? Symbol.Editor.layerLock : Symbol.Editor.layerUnlock)
            }
            .buttonStyle(.cobaltIcon(.small))
        }
        .padding(.horizontal, 8)
        .frame(minHeight: Platform.isMac ? 30 : 38)
        .background(EditorColor.field, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// The note under the canvas when too many videos overlap. The render on the server is unaffected.
struct EditorPreviewCrowdedNote: View {
    let session: EditSession

    var body: some View {
        if session.previewCrowded {
            Text(Copy.Editor.previewCrowded)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .accessibilityLabel(Copy.Editor.previewCrowded)
        }
    }
}
