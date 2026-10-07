import CobaltKit
import SwiftUI

/// The words for a model state (CONTRACT-OFFLINE section 3), kept beside the screens that draw them so
/// `Copy+Offline.swift`, which the share extension and the widgets compile too, holds no model types.
enum OfflineWords {
    /// Why a download failed, in plain words.
    static func failure(_ failure: OfflineFailure) -> String {
        switch failure {
        case .gone: return Copy.Offline.gone
        case .unreachable: return Copy.failure(.unreachable)
        case .auth: return Copy.Offline.authRefused
        case .full: return Copy.Offline.full
        case .other: return Copy.Offline.downloadFailed
        }
    }

    /// Where a kept file is, as the Mac says it (CONTRACT-OFFLINE 13.10): in the folder it is in, waiting to move into it,
    /// or in a folder whose disk is away. Nil off the Mac, and for what is not kept.
    enum KeptPlace: Equatable {
        case inFolder(String)
        case waiting
        case notConnected(path: String)
    }

    /// The Mac's `KeptPlace` for a rendition's record; nil where the files app answers instead (iPhone, iPad).
    @MainActor
    static func keptPlace(of rendition: Rendition, model: AppModel) -> KeptPlace? {
        #if os(macOS)
        let folder = model.macFolder
        guard folder.isAvailable, let local = rendition.local, local.isOffline else { return nil }
        let status = folder.status
        if status.problem == .unreachable { return .notConnected(path: status.path) }
        if local.place == .cache { return .waiting }          // kept, still in the hidden files/ until it can move
        return .inFolder(folder.displayFolder(of: local) ?? status.path)
        #else
        return nil
        #endif
    }

    /// The line under the detail's toggle: where the file is and its size, progress, waiting, the failure, or
    /// that it is not here.
    static func status(_ state: RenditionOffline, place: KeptPlace? = nil) -> String {
        switch state {
        case .offline(let bytes):
            switch place {
            case .inFolder(let folder): return Copy.Offline.keptIn(folder, bytes: bytes)
            case .waiting: return Copy.Offline.waitingForFolder(bytes: bytes)
            case .notConnected(let path): return Copy.Folder.notConnected(path: path)
            case nil: return Copy.Offline.kept(bytes: bytes)
            }
        case .cached(let bytes): return Copy.Offline.cached(bytes: bytes)
        case .downloading(let progress): return Copy.Offline.downloading(bytes: progress.bytes, total: progress.total)
        case .waiting: return Copy.Offline.waiting
        case .failed(let failure): return Self.failure(failure)
        case .none: return Copy.Offline.missing
        case .unavailable: return Copy.Offline.unavailable
        }
    }

    /// 0...1 when the total is known and positive.
    static func fraction(_ progress: TransferProgress) -> Double? {
        guard let total = progress.total, total > 0 else { return nil }
        return min(1, max(0, Double(progress.bytes) / Double(total)))
    }

    /// The confirm of "remove offline copy": the server keeps its copy, or this is the only one.
    static func removeTitle(onlyCopy: Bool) -> String {
        onlyCopy ? Copy.Offline.onlyCopyTitle : Copy.Offline.removeCopyTitle
    }

    static func removeMessage(onlyCopy: Bool) -> String {
        onlyCopy ? Copy.Offline.onlyCopyMessage : Copy.Offline.removeCopyMessage
    }
}

/// The detail's "on this iphone" section for the selected tab (CONTRACT-OFFLINE decision 11): one toggle,
/// "keep offline", and one line under it that says where the file is and its size, the progress, that it waits for
/// the network, why it failed (with "try again"), or that it is not here. Switching it off asks first (the server
/// keeps a copy, or this is the only one). The toggle is disabled, not hidden, when there is nothing to download
/// the file from.
struct OfflineCopySection: View {
    let model: AppModel
    private let source: Source

    private enum Source {
        case rendition(MediaItem, Rendition)
        case record(StoredVideo)
    }

    /// The media and the tab on screen.
    init(model: AppModel, item: MediaItem, rendition: Rendition) {
        self.model = model
        source = .rendition(item, rendition)
    }

    /// A tab that has a record on this device: the section finds its media itself.
    init(model: AppModel, video: StoredVideo) {
        self.model = model
        source = .record(video)
    }

    var body: some View {
        if model.store.canKeep, let (item, rendition) = resolved {
            OfflineToggleSection(model: model, item: item, rendition: rendition)
        }
    }

    /// The tab the section is for, current: the model's record of the media wins over the value a view holds.
    private var resolved: (MediaItem, Rendition)? {
        switch source {
        case .rendition(let item, let rendition):
            return (item, rendition)
        case .record(let video):
            guard let local = model.store.media.first(where: { $0.renditions.contains { $0.id == video.id } }) else { return nil }
            let item = model.mediaItem(for: local)
            guard let rendition = item.renditions.first(where: { $0.local?.id == video.id }) else { return nil }
            return (item, rendition)
        }
    }
}

private struct OfflineToggleSection: View {
    let model: AppModel
    let item: MediaItem
    let rendition: Rendition
    @State private var confirmRemove = false

    private var state: RenditionOffline { model.offlineState(of: rendition) }

    /// On while the file is kept, or on its way (a download or a wait for the network).
    private var isOn: Bool {
        switch state {
        case .offline, .downloading, .waiting: return true
        case .cached, .failed, .none, .unavailable: return false
        }
    }

    private var isOffline: Bool {
        if case .offline = state { return true }
        return false
    }

    /// A running pipeline is reading or playing the file: the store would refuse to remove it.
    private var inUse: Bool { rendition.local.map { model.store.isInUse($0.id) } ?? false }

    private var disabled: Bool {
        if case .unavailable = state { return true }
        return isOffline && inUse
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { isOn },
            set: { on in
                if on {
                    model.keepOffline(item, rendition: rendition)
                } else if isOffline {
                    confirmRemove = true
                } else {
                    model.stopDownloading(item, rendition: rendition)
                }
            })
    }

    var body: some View {
        let state = state
        let onlyCopy = model.isOnlyCopy(rendition)
        Section {
            Toggle(isOn: binding) {
                HStack(spacing: 8) {
                    Label(Copy.Offline.keep, systemImage: Symbol.keepOffline)
                    Spacer(minLength: 4)
                    DetailTypeBadge(label: OfflineWords.typeLabel(rendition))
                }
            }
            .disabled(disabled)
            .confirmationDialog(
                OfflineWords.removeTitle(onlyCopy: onlyCopy), isPresented: $confirmRemove, titleVisibility: .visible
            ) {
                Button(Copy.remove, role: .destructive) { remove() }
                Button(Copy.keep, role: .cancel) {}
            } message: {
                Text(OfflineWords.removeMessage(onlyCopy: onlyCopy))
            }
            VStack(alignment: .leading, spacing: 8) {
                statusLine(state)
                if case .downloading(let progress) = state {
                    if let fraction = OfflineWords.fraction(progress) {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .tint(CobaltColor.text)
                            .padding(.leading, 34)
                            .accessibilityHidden(true)
                    } else {
                        ProgressView().progressViewStyle(.linear).tint(CobaltColor.text)
                            .padding(.leading, 34).accessibilityHidden(true)
                    }
                }
                if case .failed = state {
                    Button(Copy.tryAgain, systemImage: Symbol.retry) { model.keepOffline(item, rendition: rendition) }
                }
            }
        } header: {
            Text(Copy.Storage.group).font(CobaltType.caption).textCase(nil)
        }
        .labelStyle(DetailRowLabelStyle())
        .font(CobaltType.body)
    }

    @ViewBuilder
    private func statusLine(_ state: RenditionOffline) -> some View {
        let failed: Bool = {
            if case .failed = state { return true }
            return false
        }()
        Text(OfflineWords.status(state, place: OfflineWords.keptPlace(of: rendition, model: model)))
            .font(Font.cobalt(12.5))
            .foregroundStyle(failed ? CobaltColor.errorText : Color.secondary)
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 34)
    }

    private func remove() {
        Task { await model.removeOfflineCopy(item, rendition: rendition) }
    }
}

extension OfflineWords {
    /// `webp`, or the video's container (`mp4`, `mov`, ...): the small badge beside the toggle.
    static func typeLabel(_ rendition: Rendition) -> String {
        if rendition.isWebp { return "webp" }
        let candidates = [rendition.local?.fileURL?.pathExtension, rendition.local?.name.split(separator: ".").last.map(String.init)]
        for ext in candidates.compactMap({ $0?.lowercased() }) where !ext.isEmpty && ext.count <= 5 { return ext }
        for contentType in [rendition.file?.contentType, rendition.hosted?.contentType] {
            switch contentType?.lowercased() {
            case "video/quicktime": return "mov"
            case "image/gif": return "gif"
            case "image/png": return "png"
            case "image/jpeg": return "jpg"
            case "image/heic", "image/heif": return "heic"
            default: break
            }
        }
        return "mp4"
    }
}

/// Icon first in a fixed column, like the settings rows.
private struct DetailRowLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.icon.frame(width: 24)
            configuration.title
        }
    }
}

#if DEBUG
/// The section for every state of the offline fixture, one under the other. `folder` is the Mac folder's state while it
/// draws (the disk away, say); `StorageDebug` shows it in the app's own window.
@MainActor
struct OfflineSectionsPreview: View {
    @State private var model: AppModel

    init(folder: MacFolder.Status? = nil) {
        let model = AppModel.preview(.offline)
        if let folder { model.macFolder.setPreviewStatus(folder) }
        _model = State(initialValue: model)
    }

    var body: some View {
        let items = (model.store.media.map { model.mediaItem(for: $0) } + model.library.posts.map { model.mediaItem(for: $0) })
        let seen = items.reduce(into: [MediaItem]()) { out, item in if !out.contains(where: { $0.id == item.id }) { out.append(item) } }
        Form {
            ForEach(seen) { item in
                OfflineCopySection(model: model, item: item, rendition: item.face)
            }
        }
        .formStyle(.grouped)
    }
}
#Preview("offline · every state", traits: .fixedLayout(width: 390, height: 1400)) {
    OfflineSectionsPreview()
}
#endif
