import CobaltKit
import SwiftUI

#if DEBUG
// Previews and simulator evidence for the photos section (CONTRACT-SYNC.md section 6).

/// Every state the photos section draws, as a `PhotosSync.Status` over an access level. Used by the
/// `#Preview`s here and by the `-previewPhotos <access>:<state>` launch argument (CobaltApp.swift).
enum PhotosPreviewState: String, CaseIterable {
    case off, needsKeep, enabled, paused, adding, outOfSpace, gaveUp

    static func access(named name: String) -> PhotosSync.Access? {
        switch name {
        case "notAsked": return .notAsked
        case "album": return .album
        case "limited": return .libraryLimited
        case "addOnly": return .libraryAddOnly
        case "denied": return .denied
        default: return nil
        }
    }

    func status(_ access: PhotosSync.Access) -> PhotosSync.Status {
        switch self {
        case .off, .needsKeep: return .init(access: access, enabled: false)
        case .enabled: return .init(access: access, enabled: true, added: 12)
        case .paused: return .init(access: access, enabled: true, paused: true, added: 12)
        case .adding: return .init(access: access, enabled: true, added: 3, progress: .init(done: 3, total: 12))
        case .outOfSpace: return .init(access: access, enabled: true, added: 9, waiting: 4, problem: .outOfSpace)
        case .gaveUp: return .init(access: access, enabled: true, added: 9, gaveUp: 2)
        }
    }

    /// Puts `model` in this state: the photos status, and "keep videos on this iphone" for the two states that need it off.
    @MainActor
    func apply(to model: AppModel, access: PhotosSync.Access) {
        model.photosSync.setPreviewStatus(status(access))
        model.settings.keepVideosOnDevice = !(self == .paused || self == .needsKeep)
    }

    /// `-previewPhotos album:adding`; does nothing when the argument is absent or does not parse.
    @MainActor
    static func applyLaunchArgument(to model: AppModel) {
        guard let raw = UserDefaults.standard.string(forKey: "previewPhotos") else { return }
        let parts = raw.split(separator: ":").map(String.init)
        guard parts.count == 2, let access = access(named: parts[0]), let state = PhotosPreviewState(rawValue: parts[1]) else { return }
        state.apply(to: model, access: access)
    }
}

private struct PreviewRowLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.icon.frame(width: 24)
            configuration.title
        }
    }
}

/// One form with the photos section in each state, for one access level.
private struct PhotosSectionMatrix: View {
    @State private var models: [(state: PhotosPreviewState, model: AppModel)]

    init(_ access: PhotosSync.Access) {
        _models = State(initialValue: PhotosPreviewState.allCases.map { state in
            let model = AppModel.preview(.happy)
            state.apply(to: model, access: access)
            return (state, model)
        })
    }

    var body: some View {
        Form {
            ForEach(models, id: \.state) { entry in
                PhotosSettingsSection(model: entry.model)
            }
        }
        .formStyle(.grouped)
        .labelStyle(PreviewRowLabelStyle())
        .font(CobaltType.body)
    }
}

/// Launch evidence (`-previewPhotosOnly 1`): just the photos section, over the model the launch
/// arguments configured, so one screenshot shows one state.
struct PhotosSectionEvidence: View {
    let model: AppModel

    var body: some View {
        NavigationStack {
            Form { PhotosSettingsSection(model: model) }
                .formStyle(.grouped)
                .labelStyle(PreviewRowLabelStyle())
                .font(CobaltType.body)
                .navigationTitle(Copy.settings)
        }
    }
}

#Preview("photos · full access, every state") { PhotosSectionMatrix(.album) }
#Preview("photos · not asked yet") { PhotosSectionMatrix(.notAsked) }
#Preview("photos · limited access") { PhotosSectionMatrix(.libraryLimited) }
#Preview("photos · add-only access") { PhotosSectionMatrix(.libraryAddOnly) }
#Preview("photos · access off") { PhotosSectionMatrix(.denied) }
#Preview("photos · dark") { PhotosSectionMatrix(.album).preferredColorScheme(.dark) }
#Preview("photos · turn the album on (backfill dialog)") {
    PreviewHost(.happy, tab: .settings) { model in
        PhotosSectionEvidence(model: model)
            .onAppear { PhotosPreviewState.off.apply(to: model, access: .album) }
    }
}
#Preview("settings · album on, adding") {
    PreviewHost(.happy, tab: .settings) { model in
        SettingsScreen(model: model)
            .onAppear { PhotosPreviewState.adding.apply(to: model, access: .album) }
    }
}
#endif
