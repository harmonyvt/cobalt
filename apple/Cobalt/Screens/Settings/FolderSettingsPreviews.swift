import CobaltKit
import SwiftUI

#if DEBUG
// Previews for the folder section: every state it draws. The model's `MacFolder` is the preview twin, so the buttons and
// the move question move it around without touching the disk.

private enum FolderPreviewState: String, CaseIterable {
    case enabled, customFolder, adopting, moving, unreachable, notAllowed, wrongFolder, diskFull

    var status: MacFolder.Status {
        switch self {
        case .enabled: return .init()
        case .customFolder: return .init(path: "/Volumes/Archive/videos/cobalt", isDefault: false)
        case .adopting: return .init(adopting: true)
        case .moving: return .init(path: "/Volumes/Archive/videos/cobalt", isDefault: false, moving: .init(done: 12, total: 24))
        case .unreachable: return .init(path: "/Volumes/Archive/cobalt", isDefault: false, problem: .unreachable)
        case .notAllowed: return .init(problem: .notAllowed)
        case .wrongFolder: return .init(path: "/Volumes/Archive/cobalt", isDefault: false, problem: .wrongFolder)
        case .diskFull: return .init(problem: .diskFull)
        }
    }
}

private struct FolderPreviewLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.icon.frame(width: 24)
            configuration.title
        }
    }
}

private struct FolderSectionMatrix: View {
    @State private var models: [(state: FolderPreviewState, model: AppModel)] = FolderPreviewState.allCases.map { state in
        let model = AppModel.preview(.happy)
        model.macFolder.setPreviewStatus(state.status)
        return (state, model)
    }

    var body: some View {
        Form {
            ForEach(models, id: \.state) { entry in
                FolderSettingsSection(model: entry.model)
            }
        }
        .formStyle(.grouped)
        .labelStyle(FolderPreviewLabelStyle())
        .font(CobaltType.body)
    }
}

#Preview("folder · every state") { FolderSectionMatrix() }
#endif
