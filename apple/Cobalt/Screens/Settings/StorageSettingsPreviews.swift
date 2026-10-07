import CobaltKit
import SwiftUI

#if DEBUG
// Previews for "on this mac" / "on this iphone": every state the section draws. The model's `MacFolder` and `SavePull` are
// the preview twins, so the buttons and the move question move them around without touching the disk or the network.

private enum StoragePreviewState: String, CaseIterable {
    case ready, otherFolder, moving, unreachable, notAllowed, wrongFolder, diskFull, noTrash, keepOff, refusedKey, noServer, neverChecked,
         pulling, waiting, diskLow

    /// "keep new saves offline" as the toggle shows it: off exactly where the pull row says it is paused for that, so a state's
    /// toggle and its row never disagree.
    var keepsNewSaves: Bool { self != .keepOff }

    var folder: MacFolder.Status {
        switch self {
        case .ready, .keepOff, .refusedKey, .noServer, .neverChecked, .pulling, .waiting, .diskLow: return .init()
        case .otherFolder: return .init(path: "/Volumes/Archive/videos/cobalt", isDefault: false)
        case .moving: return .init(path: "/Volumes/Archive/videos/cobalt", isDefault: false, moving: .init(done: 12, total: 24))
        case .unreachable: return .init(path: "/Volumes/Archive/cobalt", isDefault: false, problem: .unreachable)
        case .notAllowed: return .init(problem: .notAllowed)
        case .wrongFolder: return .init(path: "/Volumes/Archive/cobalt", isDefault: false, problem: .wrongFolder)
        case .diskFull: return .init(problem: .diskFull)
        case .noTrash: return .init(path: "/Volumes/Archive/cobalt", isDefault: false, problem: .noTrash)
        }
    }

    func pull(now: Date) -> SavePull.Status {
        let checked = now.addingTimeInterval(-120)
        switch self {
        case .ready, .otherFolder, .moving, .notAllowed, .wrongFolder, .diskFull, .noTrash: return .init(available: true, lastChecked: checked)
        case .unreachable: return .init(available: true, lastChecked: checked, paused: .folderUnreachable)
        case .keepOff: return .init(available: true, lastChecked: checked, paused: .keepOff)
        case .refusedKey: return .init(available: true, lastChecked: checked, paused: .auth)
        case .noServer: return .init(available: true, paused: .noServer)
        case .neverChecked: return .init(available: true)
        case .pulling: return .init(available: true, lastChecked: checked, pulling: 2)
        case .waiting: return .init(available: true, lastChecked: checked, paused: .waiting, waiting: 31)
        case .diskLow: return .init(available: true, lastChecked: checked, paused: .diskLow)
        }
    }
}

private struct StoragePreviewLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.icon.frame(width: 24)
            configuration.title
        }
    }
}

private struct StorageSectionMatrix: View {
    @State private var models: [(state: StoragePreviewState, model: AppModel)] = StoragePreviewState.allCases.map { state in
        let model = AppModel.preview(.offline)
        model.macFolder.setPreviewStatus(state.folder)
        model.savePull.setPreviewStatus(state.pull(now: Date()))
        model.settings.keepVideosOnDevice = state.keepsNewSaves
        return (state, model)
    }

    var body: some View {
        Form {
            ForEach(models, id: \.state) { entry in
                StorageSettingsSection(model: entry.model)
            }
        }
        .formStyle(.grouped)
        .labelStyle(StoragePreviewLabelStyle())
        .font(CobaltType.body)
    }
}

#Preview("on this mac · every state") { StorageSectionMatrix() }

/// The library's context menu for each row of the offline fixture (kept, partly kept, downloading, failed, nothing), as
/// buttons in the app's own window: what a right click lists on the Mac, with the folder in `folder`'s state.
@MainActor
private struct MacMenusDebug: View {
    @State private var model: AppModel

    init(folder: MacFolder.Status?) {
        let model = AppModel.preview(.offline)
        if let folder { model.macFolder.setPreviewStatus(folder) }
        _model = State(initialValue: model)
    }

    var body: some View {
        let controller = LibraryController(model: model)
        let rows = Array(model.libraryRows.prefix(6))
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), alignment: .top)], alignment: .leading, spacing: 18) {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        LibraryTitleText(row: row, size: 12).padding(.bottom, 4)
                        LibraryMenuItems(row: row, controller: controller)
                    }
                    .buttonStyle(.plain)
                    .labelStyle(.titleAndIcon)
                    .font(CobaltType.caption)
                    .padding(10)
                    .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(16)
        }
    }
}

/// `-previewStorage <state>` (with `-previewScenario offline -previewTab settings`): the settings tab shows just "on this
/// mac" in that state (`ready`, `otherFolder`, `moving`, `unreachable`, `notAllowed`, `wrongFolder`, `diskFull`, `noTrash`,
/// `keepOff`, `refusedKey`, `noServer`, `neverChecked`, `pulling`, `waiting`, `diskLow`), so a window screenshot has all of it in view. `detail`
/// and `menus` (each with `-<folder state>`, e.g. `menus-unreachable`) draw the detail's offline sections and the library's
/// context menus instead.
enum StorageDebug {
    static var state: String? { UserDefaults.standard.string(forKey: "previewStorage") }

    @MainActor
    static func apply(_ raw: String, to model: AppModel) {
        guard let state = StoragePreviewState(rawValue: raw) else { return }
        model.macFolder.setPreviewStatus(state.folder)
        model.savePull.setPreviewStatus(state.pull(now: Date()))
        model.settings.keepVideosOnDevice = state.keepsNewSaves
    }
}

struct StorageDebugScreen: View {
    let model: AppModel
    let state: String

    var body: some View {
        // `detail` / `detail-unreachable`: the detail's "on this mac" toggle and status line in every state of the fixture
        if state.hasPrefix("menus") {
            MacMenusDebug(folder: StoragePreviewState(rawValue: String(state.dropFirst("menus-".count)))?.folder)
        } else if state.hasPrefix("detail") {
            OfflineSectionsPreview(folder: StoragePreviewState(rawValue: String(state.dropFirst("detail-".count)))?.folder)
        } else {
            Form { StorageSettingsSection(model: model) }
                .formStyle(.grouped)
                .labelStyle(StoragePreviewLabelStyle())
                .font(CobaltType.body)
                .onAppear { StorageDebug.apply(state, to: model) }
        }
    }
}

#Preview("on this mac · in settings") {
    PreviewHost(.offline, tab: .settings) { model in
        SettingsScreen(model: model)
            .task {
                model.macFolder.setPreviewStatus(.init())
                model.savePull.setPreviewStatus(.init(available: true, lastChecked: Date().addingTimeInterval(-120)))
            }
    }
}
#endif
