import CobaltKit
import SwiftUI

/// The right column (apple/CONTRACT-EDITOR.md 4.3, 272 pt): driven by the selection. A main clip shows trim, speed, crop and
/// fit, volume, `split at playhead` and `delete clip`; an overlay shows start, length, trim (video), position, size, opacity,
/// volume and `delete overlay`; with nothing selected it says so and summarises the project.
struct EditorInspector: View {
    let session: EditSession
    /// `limits.editPitch` of the server; false hides every pitch control.
    var pitchEnabled = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch session.selection {
                case .main:
                    if let (index, clip) = session.selectedMain { MainClipInspector(session: session, index: index, clip: clip, pitchEnabled: pitchEnabled) }
                    else { nothing }
                case .overlay:
                    if let overlay = session.selectedOverlay { OverlayInspector(session: session, overlay: overlay, pitchEnabled: pitchEnabled) }
                    else { nothing }
                case .none:
                    nothing
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .background(EditorColor.panel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Editor.inspectorA11y)
    }

    private var nothing: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Copy.Editor.nothingSelected)
                .font(Font.cobalt(12.5, .semibold, relativeTo: .subheadline))
                .foregroundStyle(CobaltColor.text)
            Text(Copy.Editor.summary(
                canvas: session.timeline.canvas.shape.rawValue, quality: session.qualityLine,
                duration: Copy.Editor.clock(session.timing.seconds), clips: session.timeline.main.count))
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
        }
    }
}

// MARK: - a main clip

/// `split at playhead`: the one part of the inspector that reads the playhead, so playing redraws only this button.
private struct MainClipSplitButton: View {
    let session: EditSession
    let clipID: String

    var body: some View {
        EditorInspectorButton(
            title: Copy.Editor.splitAtPlayhead, symbol: Symbol.Editor.split,
            isEnabled: session.canSplitAtPlayhead && session.clipUnderPlayhead?.clip.id == clipID
        ) { session.split(clip: clipID, atFrame: session.playhead) }
    }
}

private struct MainClipInspector: View {
    let session: EditSession
    let index: Int
    let clip: EditClip
    var pitchEnabled = true

    private var source: EditSource? { session.source(for: clip.item) }
    private var fps: Int { session.timeline.canvas.fps }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
    }

    @ViewBuilder
    private var content: some View {
        header
        missingNote
        trim
        EditorSection(Copy.Editor.speed, trailing: Copy.Editor.speedValue(clip.speed)) {
            EditorSpeedRow(
                speed: clip.speed, sourceSeconds: clip.out - clip.in,
                set: { session.setSpeed($0, clip: clip.id) }, onEnd: { session.endGesture() })
        }
        if pitchEnabled {
            EditorSection(Copy.Editor.pitch, trailing: Copy.Editor.pitchValue(clip.pitch)) {
                EditorPitchRow(
                    pitch: clip.pitch,
                    set: { session.setPitch($0, clip: clip.id) }, onEnd: { session.endGesture() })
            }
        }
        EditorSection(Copy.Editor.crop) {
            EditorCropRows(
                crop: clip.crop, fit: clip.fit, display: displaySize,
                onCrop: { session.setCrop($0, clip: clip.id); session.endGesture() },
                onFit: { session.setFit($0, clip: clip.id) },
                onEditCrop: { session.tool = .crop })
        }
        EditorSection(Copy.Editor.volume) {
            EditorVolumeRow(
                volume: clip.volume, muted: clip.muted,
                setVolume: { session.setVolume($0, clip: clip.id) }, setMuted: { session.setMuted($0, clip: clip.id) },
                onEnd: { session.endGesture() })
        }
        VStack(spacing: 8) {
            MainClipSplitButton(session: session, clipID: clip.id)
            EditorInspectorButton(title: Copy.Editor.deleteClip, symbol: Symbol.Editor.delete, destructive: true) {
                session.remove(.main(clip.id))
            }
        }
    }

    private var displaySize: CGSize? {
        guard let d = source?.display else { return nil }
        return CGSize(width: d.w, height: d.h)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Copy.Editor.clipN(index + 1))
                .font(Font.cobalt(12.5, .semibold, relativeTo: .subheadline))
                .foregroundStyle(CobaltColor.text)
            if let source {
                Text(source.display.map { Copy.Editor.fileLine(source.name, $0.w, $0.h) } ?? source.name)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var missingNote: some View {
        if session.isMissing(item: clip.item) {
            Label(Copy.Editor.missingClip, systemImage: Symbol.Editor.missing)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.errorText)
        } else if session.sourceFailures[clip.item] != nil {
            Label(Copy.Editor.sourceFailed, systemImage: Symbol.Editor.missing)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.errorText)
            Button(Copy.Editor.tryAgain, systemImage: Symbol.Editor.retry) { session.retrySource(clip.item) }
                .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
        }
    }

    private var trim: some View {
        EditorSection(Copy.Editor.trim) {
            VStack(spacing: 6) {
                EditorNumberField.time(
                    label: Copy.Editor.trimIn, value: clip.in, fps: fps,
                    commit: { session.trim(clip: clip.id, in: $0, out: nil) }, onEnd: { session.endGesture() })
                EditorNumberField.time(
                    label: Copy.Editor.trimOut, value: clip.out, fps: fps,
                    commit: { session.trim(clip: clip.id, in: nil, out: $0) }, onEnd: { session.endGesture() })
            }
        }
    }
}

// MARK: - an overlay

private struct OverlayInspector: View {
    let session: EditSession
    let overlay: EditOverlay
    var pitchEnabled = true

    @State private var cutoutOf: EditSource?

    private var source: EditSource? { session.source(for: overlay.item) }
    private var fps: Int { session.timeline.canvas.fps }
    private var isVideo: Bool { source?.kind == .video }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .sheet(item: $cutoutOf) { picture in
                EditorCutoutSheet(session: session, source: picture, replacing: overlay.id) { cutoutOf = nil }
            }
    }

    @ViewBuilder
    private var content: some View {
        header
        if session.isMissing(item: overlay.item) {
            Label(Copy.Editor.missingClip, systemImage: Symbol.Editor.missing)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.errorText)
        }
        EditorOverlayLayerRows(session: session, overlay: overlay) { cutoutOf = source }
        EditorSection(Copy.Editor.start) {
            VStack(spacing: 6) {
                EditorNumberField.time(
                    label: Copy.Editor.start, value: overlay.at, fps: fps,
                    commit: { session.moveOverlay(id: overlay.id, toFrame: session.timing.frame(at: $0)) },
                    onEnd: { session.endGesture() })
                EditorNumberField.time(
                    label: Copy.Editor.length, value: overlay.length, fps: fps,
                    commit: { session.setOverlayLength(id: overlay.id, seconds: $0) }, onEnd: { session.endGesture() })
            }
        }
        if isVideo {
            EditorSection(Copy.Editor.trim) {
                VStack(spacing: 6) {
                    EditorNumberField.time(
                        label: Copy.Editor.trimIn, value: overlay.in, fps: fps,
                        commit: { session.trimOverlay(id: overlay.id, in: $0, out: nil) }, onEnd: { session.endGesture() })
                    EditorNumberField.time(
                        label: Copy.Editor.trimOut, value: overlay.out, fps: fps,
                        commit: { session.trimOverlay(id: overlay.id, in: nil, out: $0) }, onEnd: { session.endGesture() })
                }
            }
        }
        EditorSection(Copy.Editor.position) {
            VStack(spacing: 6) {
                EditorNumberField.percent(
                    label: Copy.Editor.positionX, value: overlay.frame.x,
                    commit: { setFrame(x: $0) }, onEnd: { session.endGesture() })
                EditorNumberField.percent(
                    label: Copy.Editor.positionY, value: overlay.frame.y,
                    commit: { setFrame(y: $0) }, onEnd: { session.endGesture() })
            }
        }
        EditorSection(Copy.Editor.size) {
            EditorNumberField.percent(
                label: Copy.Editor.size, value: overlay.frame.w,
                commit: { setFrame(w: $0) }, onEnd: { session.endGesture() })
        }
        EditorSection(Copy.Editor.opacity, trailing: "\(Int((overlay.opacity * 100).rounded()))%") {
            EditorSlider(
                value: Binding(get: { overlay.opacity }, set: { session.setOverlayOpacity(id: overlay.id, $0) }),
                range: 0.1...1, step: 0.01, label: Copy.Editor.opacity, onEnd: { session.endGesture() })
        }
        EditorSection(Copy.Editor.volume) {
            EditorVolumeRow(
                volume: overlay.volume, muted: overlay.muted,
                setVolume: { session.setOverlayVolume(id: overlay.id, $0) },
                setMuted: { session.setOverlayMuted(id: overlay.id, $0) },
                onEnd: { session.endGesture() }, silent: !isVideo)
        }
        if pitchEnabled && isVideo {
            EditorSection(Copy.Editor.pitch, trailing: Copy.Editor.pitchValue(overlay.pitch)) {
                EditorPitchRow(
                    pitch: overlay.pitch,
                    set: { session.setOverlayPitch($0, overlay: overlay.id) }, onEnd: { session.endGesture() })
            }
        }
        EditorInspectorButton(title: Copy.Editor.deleteOverlay, symbol: Symbol.Editor.delete, destructive: true) {
            session.remove(.overlay(overlay.id))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Copy.Editor.overlay)
                .font(Font.cobalt(12.5, .semibold, relativeTo: .subheadline))
                .foregroundStyle(CobaltColor.text)
            if let source {
                Text(source.display.map { Copy.Editor.fileLine(source.name, $0.w, $0.h) } ?? source.name)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func setFrame(x: Double? = nil, y: Double? = nil, w: Double? = nil) {
        let f = overlay.frame
        session.setOverlayFrame(id: overlay.id, EditFrame(x: x ?? f.x, y: y ?? f.y, w: w ?? f.w))
    }
}
