import CobaltKit
import SwiftUI

// The tools (apple/CONTRACT-EDITOR.md 15.1): icons only, 44 pt targets, never captions. A bottom row (compact, tall) or a 64 pt
// rail left of the picture (wide), the same view either way. What does not fit goes behind `more`; nothing scrolls.

/// Where the inspector should scroll to when a tool opens a page "at" something (the picture's `opacity` tool). Held by the
/// shell and read by the tools (which set it) and the inspector (which scrolls to it).
@MainActor @Observable
final class EditorInspectorFocus {
    static let opacity = "opacity"
    var section: String?
}

/// One tool of the row: what it is, whether it can be used, whether its page is the open one.
private struct EditorToolItem: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var enabled = true
    var on = false
    var destructive = false
    let action: () -> Void
}

/// - nothing selected: add clip, add layer, canvas, effects, post;
/// - a clip: trim, split, speed, crop, sound, remove green, effects, delete (the ones that do not apply to a layer or a
///   picture are left out), the rest behind `more` when the row is short;
/// - a clip picked on the picture (15.3): fit to canvas, turn 90°, bring up, send down, opacity, reset, delete;
/// - any selection ends in `done`, which lets go of it.
///
/// Opening a tool opens its inspector page (the drawer when compact or tall).
struct EditorShellTools: View {
    let model: AppModel
    let session: EditSession
    let rail: Bool
    let focus: EditorInspectorFocus

    @Environment(EditorHost.self) private var host
    @State private var splitTick = 0
    @State private var tick = 0
    /// The playhead as the buttons see it, set by `EditorPlayheadSpotReader` when it changes.
    @State private var spot: EditorPlayheadSpot?
    @State private var postTarget: PostFrameTarget?

    private var ui: EditorUI { host.ui }
    private var hasSelection: Bool { session.selection != .none }

    var body: some View {
        GeometryReader { geo in
            let items = self.items
            let fit = EditorToolFit.split(items: items.count, done: hasSelection, length: rail ? geo.size.height : geo.size.width)
            let stack = rail ? AnyLayout(VStackLayout(spacing: EditorToolFit.spacing)) : AnyLayout(HStackLayout(spacing: EditorToolFit.spacing))
            stack {
                ForEach(items.prefix(fit.shown)) { item in slot(button(item)) }
                if fit.more { slot(moreMenu(Array(items.dropFirst(fit.shown)))) }
                if hasSelection {
                    if rail { Spacer(minLength: 0) }
                    slot(doneButton)
                }
            }
            .padding(rail ? .vertical : .horizontal, EditorToolFit.edge)
            .frame(width: geo.size.width, height: geo.size.height, alignment: rail ? .top : .center)
        }
        .background(EditorColor.bar)
        .overlay(alignment: rail ? .trailing : .top) {
            Rectangle().fill(EditorColor.line).frame(width: rail ? 1 : nil, height: rail ? nil : 1)
        }
        .background { EditorPlayheadSpotReader(session: session) { spot = $0 } }
        .haptic(.impact(weight: .light), trigger: splitTick)
        .haptic(.selection, trigger: tick)
        .sheet(item: $postTarget) { current in
            PostFrameSheet(model: model, target: current)
                .cobaltRoot(model: model)
        }
        .modifier(PostToolAutoOpen(model: model, open: openPost))
        .accessibilityElement(children: .contain)
    }

    /// Each tool takes a 44 pt slot (the whole width of the row shared out evenly when there is room).
    private func slot<V: View>(_ view: V) -> some View {
        view.frame(minWidth: Metrics.hit, maxWidth: .infinity, minHeight: Metrics.hit)
    }

    private func button(_ item: EditorToolItem) -> some View {
        Button(role: item.destructive ? .destructive : nil, action: item.action) { Label(item.title, systemImage: item.symbol) }
            .buttonStyle(.cobaltIcon(.small, tint: item.destructive ? CobaltColor.errorText : nil, prominent: item.on))
            .disabled(!item.enabled)
            .accessibilityAddTraits(item.on ? .isSelected : [])
            .help(item.title)
    }

    private var doneButton: some View {
        Button { letGo() } label: { Label(Copy.Editor.shellLetGo, systemImage: Symbol.Editor.shellLetGo) }
            .buttonStyle(.cobaltIcon(.small, tint: CobaltColor.linkBlue))
            .help(Copy.Editor.shellLetGo)
    }

    /// What did not fit. Menu rows carry their words (a menu is a list, not a row of captions).
    private func moreMenu(_ rest: [EditorToolItem]) -> some View {
        Menu {
            ForEach(rest) { item in
                Button(role: item.destructive ? .destructive : nil, action: item.action) { Label(item.title, systemImage: item.symbol) }
                    .disabled(!item.enabled)
            }
        } label: {
            EditorShellMenuIcon(name: Copy.Editor.shellMore, symbol: Symbol.Editor.shellMore)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .iconName(Copy.Editor.shellMore)
    }

    // MARK: the tools

    private var items: [EditorToolItem] {
        switch session.selection {
        case .none: return noSelectionTools
        case .main(let id), .overlay(let id):
            return ui.pickedOnPicture ? pictureTools(id) : clipTools(id)
        }
    }

    private var noSelectionTools: [EditorToolItem] {
        var list: [EditorToolItem] = [
            EditorToolItem(id: "addClip", title: Copy.Editor.addClip, symbol: Symbol.Editor.add, on: addIsOpen(.addClip)) { add(.addClip) },
            EditorToolItem(id: "addLayer", title: Copy.Editor.shellAddLayer, symbol: Symbol.Editor.shellAddLayer, on: addIsOpen(.addLayer)) { add(.addLayer) },
            EditorToolItem(id: "canvas", title: Copy.Editor.canvas, symbol: Symbol.Editor.canvas, on: ui.openTool == .canvas) { open(.canvas, .project) },
            EditorToolItem(
                id: "effects", title: Copy.Editor.effects, symbol: Symbol.Editor.effects,
                enabled: LaneClipCommands.videoClipID(session) != nil, on: session.effectsFor != nil) { openEffects() },
        ]
        if model.canMakePostFrames {
            list.append(EditorToolItem(
                id: "post", title: Copy.PostFrame.toolPost, symbol: Symbol.PostFrame.frame, on: postTarget != nil) { openPost() })
        }
        return list
    }

    private func clipTools(_ id: String) -> [EditorToolItem] {
        let isMain: Bool
        if case .main = session.selection { isMain = true } else { isMain = false }
        let kind = kindOf(id)
        let video = kind == .video
        var list: [EditorToolItem] = []
        if isMain || video {
            list.append(EditorToolItem(id: "trim", title: Copy.Editor.toolTrim, symbol: Symbol.Editor.trim, on: ui.openTool == .trim) { open(.trim, .trim) })
        }
        list.append(EditorToolItem(id: "split", title: Copy.Editor.toolSplit, symbol: Symbol.Editor.split, enabled: splitReady(id)) { split(id) })
        if isMain {
            list.append(EditorToolItem(id: "speed", title: Copy.Editor.toolSpeed, symbol: Symbol.Editor.speed, on: ui.openTool == .speed) { open(.speed, .speed) })
            list.append(EditorToolItem(id: "crop", title: Copy.Editor.toolCrop, symbol: Symbol.Editor.toolCrop, on: ui.openTool == .crop) { crop() })
        } else if kind != .video, session.canCropImage || session.canCutout {
            list.append(EditorToolItem(id: "crop", title: Copy.Editor.toolCrop, symbol: Symbol.Editor.toolCrop, on: ui.openTool == .crop) { open(.crop, .layer) })
        }
        if video {
            list.append(EditorToolItem(id: "sound", title: Copy.Editor.shellSound, symbol: Symbol.Editor.volume, on: ui.openTool == .sound) { open(.sound, .sound) })
            list.append(EditorToolItem(
                id: "removeGreen", title: Copy.Editor.shellRemoveGreen, symbol: Symbol.Editor.shellRemoveGreen,
                enabled: session.canRemoveGreen(clipID: id), on: ui.openTool == .removeGreen) { removeGreen(id) })
            list.append(EditorToolItem(id: "effects", title: Copy.Editor.effects, symbol: Symbol.Editor.effects, on: session.effectsFor != nil) { openEffects() })
        }
        list.append(EditorToolItem(id: "delete", title: Copy.Editor.deleteClipShort, symbol: Symbol.Editor.delete, destructive: true) { delete() })
        return list
    }

    private func pictureTools(_ id: String) -> [EditorToolItem] {
        let lane = session.laneOfClip(id: id) ?? 0
        let canFrame = session.frameBox(ofClip: id) != nil
        return [
            EditorToolItem(id: "fit", title: Copy.Editor.shellFitToCanvas, symbol: Symbol.Editor.shellFitToCanvas, enabled: canFrame) {
                tick += 1
                session.fitClipToCanvas(id: id)
            },
            EditorToolItem(id: "turn", title: Copy.Editor.shellTurn90, symbol: Symbol.Editor.shellTurn90, enabled: canFrame) {
                tick += 1
                session.turnClip90(id: id)
            },
            EditorToolItem(id: "up", title: Copy.Editor.layerUp, symbol: Symbol.Editor.layerUp, enabled: lane + 1 < EditLanes.laneLimit) {
                tick += 1
                session.moveClipLayerKeepingSelection(id: id, by: 1)
            },
            EditorToolItem(id: "down", title: Copy.Editor.layerDown, symbol: Symbol.Editor.layerDown, enabled: lane > 0) {
                tick += 1
                session.moveClipLayerKeepingSelection(id: id, by: -1)
            },
            // any lane on a version 2 timeline (APP-API-CONTRACT 69.1); lane 0 not on a server that saves only version 1
            EditorToolItem(
                id: "opacity", title: Copy.Editor.opacity, symbol: Symbol.Editor.shellOpacity, enabled: session.canSetClipOpacity(id: id),
                on: ui.openTool == nil && focus.section == EditorInspectorFocus.opacity && ui.drawer != .closed) { openOpacity() },
            EditorToolItem(id: "reset", title: Copy.Editor.cropReset, symbol: Symbol.Editor.cropReset, enabled: canFrame) {
                tick += 1
                session.resetClipFrame(id: id)
            },
            EditorToolItem(id: "delete", title: Copy.Editor.deleteClipShort, symbol: Symbol.Editor.delete, destructive: true) { delete() },
        ]
    }

    private func kindOf(_ id: String) -> EditSourceKind? {
        let item = session.timeline.clips.first { $0.id == id }?.item
            ?? session.timeline.main.first { $0.id == id }?.item ?? session.timeline.overlay.first { $0.id == id }?.item
        return item.flatMap { session.source(for: $0)?.kind }
    }

    // MARK: split

    private var currentSpot: EditorPlayheadSpot { spot ?? EditorPlayheadSpot(session) }

    /// The selected clip has the playhead strictly inside it. (Version 1: the main clip under the playhead.)
    private func splitReady(_ id: String) -> Bool {
        guard session.timeline.isV2 else { return currentSpot.canSplit }
        return LaneClipCommands.containsPlayhead(session, id)
    }

    private func split(_ id: String) {
        guard splitReady(id) else { return }
        if session.timeline.isV2 {
            session.split(clip: id, atFrame: session.playhead)
        } else {
            session.splitAtPlayhead()
        }
        splitTick += 1
    }

    // MARK: actions

    /// iOS: the add sheet (a presentation, 15.1). The Mac: the library takes the inspector's place (drag in or double-click).
    private func add(_ tool: EditorUI.Tool) {
        focus.section = nil
        #if os(iOS)
        ui.open(tool, page: nil)
        #else
        if ui.openTool == tool, ui.page == .library {
            ui.closeTool()
            return
        }
        ui.open(tool, page: .library)
        #endif
    }

    private func addIsOpen(_ tool: EditorUI.Tool) -> Bool { ui.openTool == tool }

    private func open(_ tool: EditorUI.Tool, _ page: EditorUI.Page) {
        focus.section = nil
        if ui.openTool == tool, ui.drawer != .closed || rail {
            ui.closeTool()
            return
        }
        ui.open(tool, page: page)
    }

    /// A main clip: the crop frame on the picture (the crop tool) and the crop rows. A picture layer: its crop is in the page.
    private func crop() {
        focus.section = nil
        if ui.openTool == .crop {
            if session.tool == .crop { session.tool = .select }
            ui.closeTool()
            return
        }
        if session.selectedMain != nil { session.tool = .crop }
        ui.open(.crop, page: .crop)
    }

    /// Opens the clip's (or layer's) own page at its opacity.
    private func openOpacity() {
        focus.section = EditorInspectorFocus.opacity
        ui.openTool = nil
        ui.show(session.selectedOverlay != nil ? .layer : .clip)
    }

    private func removeGreen(_ id: String) {
        focus.section = nil
        guard session.removeGreen(clipID: id) else { return }
        tick += 1
        // the clip may have moved up off lane 0 (main to layer): its own page is the one to show
        ui.open(.removeGreen, page: session.selectedOverlay != nil ? .layer : .clip)
    }

    private func openEffects() {
        focus.section = nil
        guard let id = LaneClipCommands.videoClipID(session) else { return }
        if let clip = session.timeline.clips.first(where: { $0.id == id }) {
            LaneClipCommands.select(session, clip)
        } else {
            session.selection = .overlay(id)
        }
        ui.open(.effects, page: .effects)
        session.openEffects(id)
    }

    private func openPost() {
        guard let target = PostFrameTarget.editor(session) else {
            host.show(session.timeline.main.isEmpty ? Copy.PostFrame.noClip : Copy.PostFrame.notOnServer)
            return
        }
        postTarget = target
    }

    private func delete() {
        session.remove(session.selection)
        letGo()
    }

    /// `done`: lets go of the selection, the crop frame, the effects menu, the picture tools and the open tool.
    private func letGo() {
        focus.section = nil
        if session.tool == .crop { session.tool = .select }
        if session.effectsFor != nil { session.closeEffects() }
        session.selection = .none
        ui.pickedOnPicture = false
        ui.closeTool()
    }
}

// MARK: - copy and symbols the tools added

extension Copy.Editor {
    static let shellMore = "more"
    static let shellRemoveGreen = "remove green"
    static let shellFitToCanvas = "fit to canvas"
    static let shellTurn90 = "turn 90°"
}

extension Symbol.Editor {
    static let shellMore = "ellipsis"
    static let shellRemoveGreen = "wand.and.rays"
    static let shellFitToCanvas = "arrow.down.right.and.arrow.up.left"
    static let shellTurn90 = "rotate.right"
    static let shellOpacity = "circle.lefthalf.filled"
}
