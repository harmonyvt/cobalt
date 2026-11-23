import CobaltKit
import SwiftUI

// The inspector's pages (apple/CONTRACT-EDITOR.md 15.1): project, clip, layer, sound, speed, crop, trim, effects. Each shows
// only its own controls; `EditorUI.page` (made to fit the selection by `EditorUI.Page.resolved`) says which. The controls are
// the ones the Mac inspector and the iPhone sheets had (`EditorControls.swift`), lifted into pages. No hint text.

/// One page of the inspector. The library page is the shell's (it is the bin, not a page of controls).
struct EditorInspectorPageView: View {
    let model: AppModel
    let session: EditSession
    let clipTrim: ClipTrimPreview
    let focus: EditorInspectorFocus
    let page: EditorUI.Page

    private var pitchEnabled: Bool { model.capabilities.limits.editPitch }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) { content }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .onChange(of: focus.section, initial: true) { _, section in
                guard let section else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(section, anchor: .top) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Editor.inspectorA11y)
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .project, .library:
            EditorProjectPage(session: session)
        case .clip:
            if let (_, clip) = session.selectedMain { EditorClipPage(session: session, clip: clip) }
        case .layer:
            if let overlay = session.selectedOverlay { EditorLayerPage(session: session, overlay: overlay) }
        case .sound:
            EditorSoundPage(session: session, pitchEnabled: pitchEnabled)
        case .speed:
            if let (_, clip) = session.selectedMain { EditorSpeedPage(session: session, clip: clip) }
        case .crop:
            if let (_, clip) = session.selectedMain { EditorCropPage(session: session, clip: clip) }
        case .trim:
            EditorTrimPage(session: session, clipTrim: clipTrim)
        case .effects:
            EditorEffectsPage(session: session)
        }
    }
}

// MARK: - project

/// Nothing selected: the canvas (shape), the quality (size and frame rate) and the layers.
private struct EditorProjectPage: View {
    let session: EditSession

    var body: some View {
        let canvas = session.timeline.canvas
        EditorSection(Copy.Editor.canvas) {
            EditorSegmented(
                options: EditCanvas.Shape.allCases.map { .init(value: $0, title: $0.rawValue) },
                selected: canvas.shape, onSelect: { EditorShellCanvas.set(session, shape: $0) })
        }
        EditorSection(Copy.Editor.quality) {
            EditorSegmented(
                options: EditorShellCanvas.qualities.map { .init(value: $0.id, title: $0.title) },
                selected: EditorShellCanvas.qualities.first { $0.matches(canvas) }?.id, columns: 2,
                onSelect: { id in
                    if let quality = EditorShellCanvas.qualities.first(where: { $0.id == id }) {
                        EditorShellCanvas.set(session, quality: quality)
                    }
                })
        }
        EditorLayersList(session: session)
    }
}

// MARK: - a main clip

/// A clip on lane 0: what is wrong with its file, its key (strength and edges) when it has one, and the lane tools.
private struct EditorClipPage: View {
    let session: EditSession
    let clip: EditClip

    @Environment(EditorHost.self) private var host

    private var laneClip: EditLaneClip? { session.timeline.clips.first { $0.id == clip.id } }
    private var isVideo: Bool { session.source(for: clip.item)?.kind == .video }

    var body: some View {
        EditorFileProblem(session: session, item: clip.item)
        if let key = laneClip?.key {
            EditorKeyControls(session: session, clipID: clip.id, key: key, background: laneClip?.background)
        }
        IconRow(alignment: .leading) {
            if isVideo {
                EditorInspectorButton(title: Copy.Editor.effects, symbol: Symbol.Editor.effects) {
                    EditorInspectorActions.openEffects(session: session, host: host, id: clip.id)
                }
            }
            if let laneClip {
                EditorInspectorButton(title: Copy.Editor.duplicateClip, symbol: Symbol.Editor.shellDuplicate) {
                    session.duplicateClip(id: clip.id)
                }
                EditorInspectorButton(
                    title: laneClip.hidden ? Copy.Editor.showThisClip : Copy.Editor.hideThisClip,
                    symbol: laneClip.hidden ? Symbol.Editor.layerHide : Symbol.Editor.layerShow) {
                    session.setClipHidden(id: clip.id, !laneClip.hidden)
                }
            }
        }
    }
}

/// A file that is gone or would not come: errors that stop a render, with `try again` for the second.
private struct EditorFileProblem: View {
    let session: EditSession
    let item: String

    var body: some View {
        if session.isMissing(item: item) {
            Label(Copy.Editor.missingClip, systemImage: Symbol.Editor.missing)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.errorText)
        } else if session.sourceFailures[item] != nil {
            Label(Copy.Editor.sourceFailed, systemImage: Symbol.Editor.missing)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.errorText)
            Button { session.retrySource(item) } label: { Label(Copy.Editor.tryAgain, systemImage: Symbol.Editor.retry) }
                .buttonStyle(.cobaltIcon(.small))
        }
    }
}

/// Key strength (`similarity`) and edges (`blend`), live on the picture while a slider moves and written when it lets go
/// (one undo step), and the way on to the full effects page.
struct EditorKeyControls: View {
    let session: EditSession
    let clipID: String
    let key: EditChromaKey
    let background: EditOverlayBackground?

    @Environment(EditorHost.self) private var host
    @State private var similarity: Double?
    @State private var blend: Double?

    var body: some View {
        EditorSection(Copy.Editor.shellKeyStrength, trailing: Copy.Editor.trimmedNumber(similarity ?? key.similarity, places: 2)) {
            EditorSlider(
                value: Binding(get: { similarity ?? key.similarity }, set: { similarity = $0; preview() }),
                range: 0.01...0.6, step: 0.01, label: Copy.Editor.shellKeyStrength, onEnd: write)
        }
        EditorSection(Copy.Editor.shellKeyEdges, trailing: Copy.Editor.trimmedNumber(blend ?? key.blend, places: 2)) {
            EditorSlider(
                value: Binding(get: { blend ?? key.blend }, set: { blend = $0; preview() }),
                range: 0...0.5, step: 0.01, label: Copy.Editor.shellKeyEdges, onEnd: write)
        }
        IconRow(alignment: .leading) {
            EditorInspectorButton(title: Copy.Editor.effects, symbol: Symbol.Editor.effects) {
                EditorInspectorActions.openEffects(session: session, host: host, id: clipID)
            }
        }
    }

    private var current: EditChromaKey {
        EditChromaKey(color: key.color, similarity: similarity ?? key.similarity, blend: blend ?? key.blend, spill: key.spill)
    }

    private func preview() {
        guard let next = current.normalized() else { return }
        session.setEffectDraft(EditEffectDraft(overlayID: clipID, kind: .greenscreen, key: next, background: background))
    }

    private func write() {
        defer {
            similarity = nil
            blend = nil
        }
        guard let next = current.normalized(), next != key else {
            session.setEffectDraft(nil)
            return
        }
        session.applyGreenscreen(id: clipID, key: next, background: background, output: session.timeline.output)
    }
}

/// What the page buttons share with the tool row.
@MainActor
enum EditorInspectorActions {
    /// The effects menu for a video clip, as an inspector page.
    static func openEffects(session: EditSession, host: EditorHost, id: String) {
        if let clip = session.timeline.clips.first(where: { $0.id == id }) {
            LaneClipCommands.select(session, clip)
        } else {
            session.selection = .overlay(id)
        }
        host.ui.open(.effects, page: .effects)
        session.openEffects(id)
    }
}

// MARK: - a layer

/// A clip above lane 0 (an overlay): its layer, key, opacity, place, size, start and length.
private struct EditorLayerPage: View {
    let session: EditSession
    let overlay: EditOverlay

    @Environment(EditorHost.self) private var host
    @State private var croppingImage: EditSource?

    private var source: EditSource? { session.source(for: overlay.item) }
    private var fps: Int { session.timeline.canvas.fps }
    private var isVideo: Bool { source?.kind == .video }
    private var laneClip: EditLaneClip? { session.timeline.clips.first { $0.id == overlay.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .modifier(EditorImageCropPresenter(session: session, source: $croppingImage, replacing: overlay.id))
    }

    @ViewBuilder
    private var content: some View {
        EditorFileProblem(session: session, item: overlay.item)
        EditorOverlayLayerRows(
            session: session, overlay: overlay, removeBackground: { session.cutoutFor = overlay.id },
            crop: { croppingImage = source },
            openEffects: isVideo ? { EditorInspectorActions.openEffects(session: session, host: host, id: overlay.id) } : nil)
        if let key = overlay.key {
            EditorKeyControls(session: session, clipID: overlay.id, key: key, background: overlay.background)
        }
        EditorSection(Copy.Editor.opacity, trailing: "\(Int((overlay.opacity * 100).rounded()))%") {
            EditorSlider(
                value: Binding(get: { overlay.opacity }, set: { session.setOverlayOpacity(id: overlay.id, $0) }),
                range: 0.1...1, step: 0.01, label: Copy.Editor.opacity, onEnd: { session.endGesture() })
        }
        .id(EditorInspectorFocus.opacity)
        EditorSection(Copy.Editor.size) {
            EditorNumberField.percent(
                label: Copy.Editor.size, value: overlay.frame.w,
                commit: { setFrame(w: $0) }, onEnd: { session.endGesture() })
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
        EditorLayersList(session: session)
        IconRow(alignment: .leading) {
            if laneClip != nil {
                EditorInspectorButton(
                    title: overlay.hidden ? Copy.Editor.showThisClip : Copy.Editor.hideThisClip,
                    symbol: overlay.hidden ? Symbol.Editor.layerHide : Symbol.Editor.layerShow) {
                    session.setClipHidden(id: overlay.id, !overlay.hidden)
                }
                EditorInspectorButton(title: Copy.Editor.duplicateClip, symbol: Symbol.Editor.shellDuplicate) {
                    session.duplicateClip(id: overlay.id)
                }
            }
        }
    }

    /// The frame as the page edits it: position and width. A turn stays as the picture set it.
    private func setFrame(x: Double? = nil, y: Double? = nil, w: Double? = nil) {
        let f = overlay.frame
        session.setClipFrame(id: overlay.id, EditFrame(x: x ?? f.x, y: y ?? f.y, w: w ?? f.w, r: f.r))
    }
}

// MARK: - sound, speed, crop

private struct EditorSoundPage: View {
    let session: EditSession
    let pitchEnabled: Bool

    var body: some View {
        if let (_, clip) = session.selectedMain {
            EditorSection(Copy.Editor.volume) {
                EditorVolumeRow(
                    volume: clip.volume, muted: clip.muted,
                    setVolume: { session.setVolume($0, clip: clip.id) }, setMuted: { session.setMuted($0, clip: clip.id) },
                    onEnd: { session.endGesture() })
            }
            if pitchEnabled {
                EditorSection(Copy.Editor.pitch, trailing: Copy.Editor.pitchValue(clip.pitch)) {
                    EditorPitchRow(
                        pitch: clip.pitch, set: { session.setPitch($0, clip: clip.id) }, onEnd: { session.endGesture() })
                }
            }
        } else if let overlay = session.selectedOverlay {
            let isVideo = session.source(for: overlay.item)?.kind == .video
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
                        pitch: overlay.pitch, set: { session.setOverlayPitch($0, overlay: overlay.id) },
                        onEnd: { session.endGesture() })
                }
            }
        }
    }
}

private struct EditorSpeedPage: View {
    let session: EditSession
    let clip: EditClip

    var body: some View {
        EditorSection(Copy.Editor.speed, trailing: Copy.Editor.speedValue(clip.speed)) {
            EditorSpeedRow(
                speed: clip.speed, sourceSeconds: clip.out - clip.in,
                set: { session.setSpeed($0, clip: clip.id) }, onEnd: { session.endGesture() })
        }
    }
}

private struct EditorCropPage: View {
    let session: EditSession
    let clip: EditClip

    private var display: CGSize? {
        guard let d = session.source(for: clip.item)?.display else { return nil }
        return CGSize(width: d.w, height: d.h)
    }

    var body: some View {
        EditorSection(Copy.Editor.crop) {
            EditorCropRows(
                crop: clip.crop, fit: clip.fit, display: display,
                onCrop: { session.setCrop($0, clip: clip.id); session.endGesture() },
                onFit: { session.setFit($0, clip: clip.id) },
                onEditCrop: { session.tool = .crop })
        }
    }
}

// MARK: - trim

/// A main clip: its own picture and strip (drag the handles), in and out as numbers, set at the playhead. A video layer: in
/// and out as numbers.
private struct EditorTrimPage: View {
    let session: EditSession
    let clipTrim: ClipTrimPreview

    private var fps: Int { session.timeline.canvas.fps }

    var body: some View {
        if let (_, clip) = session.selectedMain {
            ClipTrimPicture(session: session, clip: clip, preview: clipTrim)
                .aspectRatio(Self.aspect(session, clip), contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 112)
            ClipTrimStrip(session: session, clip: clip, preview: clipTrim)
            VStack(spacing: 6) {
                EditorNumberField.time(
                    label: Copy.Editor.trimIn, value: clip.in, fps: fps,
                    commit: { session.trim(clip: clip.id, in: $0, out: nil) }, onEnd: { session.endGesture() })
                EditorNumberField.time(
                    label: Copy.Editor.trimOut, value: clip.out, fps: fps,
                    commit: { session.trim(clip: clip.id, in: nil, out: $0) }, onEnd: { session.endGesture() })
            }
            IconRow(alignment: .leading) {
                EditorInspectorButton(title: Copy.Editor.setInAtPlayhead, symbol: Symbol.Editor.shellSetIn) {
                    ClipTrimEditing.setIn(session: session, clip: clip.id, preview: clipTrim)
                }
                EditorInspectorButton(title: Copy.Editor.setOutAtPlayhead, symbol: Symbol.Editor.shellSetOut) {
                    ClipTrimEditing.setOut(session: session, clip: clip.id, preview: clipTrim)
                }
            }
        } else if let overlay = session.selectedOverlay, session.source(for: overlay.item)?.kind == .video {
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

    private static func aspect(_ session: EditSession, _ clip: EditClip) -> CGFloat {
        guard let display = session.source(for: clip.item)?.display, display.h > 0 else { return 16.0 / 9.0 }
        return CGFloat(display.w) / CGFloat(display.h)
    }
}

// MARK: - effects

/// The effects menu of the clip it was opened for, with a way back to its own page.
private struct EditorEffectsPage: View {
    let session: EditSession

    @Environment(EditorHost.self) private var host

    var body: some View {
        if let id = session.effectsFor, let overlay = session.effectOverlay(for: id) {
            HStack {
                Button { back() } label: { Label(Copy.Editor.shellBack, systemImage: Symbol.Editor.shellBack) }
                    .buttonStyle(.cobaltIcon(.small))
                    .help(Copy.Editor.shellBack)
                Spacer(minLength: 0)
            }
            EditorEffectsPanel(session: session, overlay: overlay)
        }
    }

    /// Back to the clip's own page; the drawer stays up.
    private func back() {
        session.closeEffects()
        host.ui.openTool = nil
        host.ui.page = .project
    }
}

// MARK: - copy and symbols the pages added

extension Copy.Editor {
    static let shellProject = "project"
    static let shellClip = "clip"
    static let shellLayer = "layer"
    static let shellKeyStrength = "strength"
    static let shellKeyEdges = "edges"
    static let shellBack = "back"
}

extension Symbol.Editor {
    static let shellDuplicate = "plus.square.on.square"
    static let shellSetIn = "arrow.right.to.line"
    static let shellSetOut = "arrow.left.to.line"
    static let shellBack = "chevron.backward"
}
