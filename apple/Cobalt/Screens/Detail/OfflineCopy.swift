import CobaltKit
import SwiftUI

/// "Remove offline copy": `OfflineStore.evict(_:)` drops this entry's file and keeps its poster,
/// flipbook and record (what the limit does to the oldest), so the planet stays on the orbit and
/// "download again" takes its place. Nil, so the button is not shown, while a running pipeline is
/// reading or playing the file (the store would refuse).
@MainActor
enum OfflineHooks {
    static func evict(model: AppModel, video: StoredVideo) -> (@MainActor () async -> Bool)? {
        guard !model.store.isInUse(video.id) else { return nil }
        return { await model.store.evict(video.id) }
    }
}

/// The detail's "on this iphone" section, for the selected rendition: whether the file is here, its size, and
/// the two actions (remove the file, keep the record; download it again once the storage limit evicted it).
struct OfflineCopySection: View {
    let model: AppModel
    let video: StoredVideo
    @State private var confirmRemove = false
    @State private var failure: PipelineFailure?
    @State private var onDisk: Bool?

    private var current: StoredVideo { model.store.videos.first { $0.id == video.id } ?? video }
    /// Bytes so far while `LibraryModel.redownload` runs for this entry; nil otherwise.
    private var progress: TransferProgress? { model.library.redownloads[video.id] }
    private var busy: Bool { progress != nil }
    private var evict: (@MainActor () async -> Bool)? { OfflineHooks.evict(model: model, video: current) }
    private var isWebp: Bool { video.kind == .webp }

    private func typeLabel(_ entry: StoredVideo) -> String {
        if entry.kind == .webp { return "webp" }
        let ext = entry.fileURL?.pathExtension.lowercased() ?? ""
        return ext.isEmpty || ext.count > 5 ? "mp4" : ext
    }

    var body: some View {
        let entry = current
        let here = onDisk ?? (entry.fileURL != nil)
        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    Text(here ? Copy.Offline.bytes(entry.bytes) : "")
                        .font(Font.cobalt(12.5)).foregroundStyle(.secondary).monospacedDigit()
                    DetailTypeBadge(label: typeLabel(entry))
                }
            } label: {
                Label(here ? Copy.Offline.onDevice : Copy.Offline.missing, systemImage: here ? Symbol.offlineOn : Symbol.offlineMissing)
            }
            if here {
                if evict != nil {
                    Button(Copy.Offline.removeCopy, systemImage: Symbol.removeOffline, role: .destructive) { confirmRemove = true }
                        .confirmationDialog(
                            isWebp ? Copy.Media.removeWebpTitle : Copy.Offline.removeTitle,
                            isPresented: $confirmRemove, titleVisibility: .visible
                        ) {
                            Button(Copy.remove, role: .destructive) { remove() }
                            Button(Copy.keep, role: .cancel) {}
                        } message: {
                            Text(isWebp ? Copy.Media.removeWebpMessage : Copy.Offline.removeMessage)
                        }
                }
            } else if model.settings.keepVideosOnDevice {
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        fetch(entry)
                    } label: {
                        Label(busy ? Copy.Offline.downloading : Copy.Offline.downloadAgain, systemImage: Symbol.downloadAgain)
                            .symbolEffect(.pulse, isActive: busy)
                    }
                    .disabled(busy)
                    if let progress {
                        if let total = progress.total, total > 0 {
                            ProgressView(value: min(Double(progress.bytes), Double(total)), total: Double(total))
                                .progressViewStyle(.linear)
                                .tint(CobaltColor.text)
                        } else {
                            ProgressView().progressViewStyle(.linear).tint(CobaltColor.text)
                        }
                    }
                    if let failure {
                        Text(Copy.Offline.failure(failure)).font(Font.cobalt(12.5)).foregroundStyle(CobaltColor.errorText)
                    }
                }
            }
        } header: {
            Text(Copy.Storage.group).font(CobaltType.caption).textCase(nil)
        }
        .labelStyle(DetailRowLabelStyle())
        .font(CobaltType.body)
        .task(id: entry.fileURL) {
            onDisk = entry.fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        }
    }

    private func remove() {
        guard let evict else { return }
        Task {
            // The evicted state at once; the task keyed on the file confirms it from the store.
            if await evict() { onDisk = false }
        }
    }

    private func fetch(_ entry: StoredVideo) {
        failure = nil
        Task {
            do {
                try await model.library.redownload(entry)
            } catch let error as PipelineFailure {
                failure = error
            } catch {
                failure = .unreachable
            }
        }
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
