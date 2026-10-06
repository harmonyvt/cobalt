import CobaltKit
import SwiftUI

#if DEBUG
// Previews for the folder section: every state it draws. The model's `FolderSync` is the preview twin, so
// the toggle, the folder buttons and the backfill dialog move it around without touching the disk.

private enum FolderPreviewState: String, CaseIterable {
    case off, enabled, customFolder, saving, waiting, existing, folderMissing, notAllowed, diskFull, gaveUp

    var status: FolderSync.Status {
        switch self {
        case .off: return .init(enabled: false)
        case .enabled: return .init(enabled: true, saved: 12)
        case .customFolder: return .init(enabled: true, path: "/Volumes/Archive/videos/cobalt", isDefault: false, saved: 12)
        case .saving: return .init(enabled: true, saved: 3, waiting: 9, progress: .init(done: 3, total: 12))
        case .waiting: return .init(enabled: true, saved: 9, waiting: 3)
        case .existing: return .init(enabled: true, saved: 2, existing: 14)
        case .folderMissing: return .init(enabled: true, path: "/Volumes/Archive/cobalt", isDefault: false, saved: 12, waiting: 2, problem: .folderMissing)
        case .notAllowed: return .init(enabled: true, saved: 0, waiting: 5, problem: .notAllowed)
        case .diskFull: return .init(enabled: true, saved: 9, waiting: 4, problem: .diskFull)
        case .gaveUp: return .init(enabled: true, saved: 9, gaveUp: 2)
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
        model.folderSync.setPreviewStatus(state.status)
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
