import CobaltKit
import Foundation

/// The window's paste and the menu bar's paste share this. A single new link, and any files, are
/// queued here. A review of several links is returned for the window to present: the menu bar never
/// draws that, it hands the same clipboard to the window.
@MainActor
enum PasteRouter {
    enum Effect: Equatable {
        case status(String)
        case queued(message: String?, ids: [Job.ID])
        case review(PasteReviewRequest)
        case openedStream(StreamAddress)
    }

    /// Returns an unambiguous live stream address when `items` contains no files and a single live-stream URL.
    /// Never matches ambiguous YouTube URLs (`watch?v=...`, `youtu.be/...`), VODs, clips, Shorts, or multi-link pastes.
    static func liveStream(in items: [PastedContent]) -> StreamAddress? {
        guard items.allSatisfy({ $0.fileURL == nil }) else { return nil }
        let raw = text(of: items)
        let links = LinkInfo.allLinks(in: raw, limit: 2)
        if links.count == 1 {
            if case .live(let address) = StreamAddress.classifySharedURL(links[0]) {
                return address
            }
            return nil
        }
        if links.isEmpty,
           let bare = StreamAddress.extractSharedURL(from: raw),
           case .live(let address) = StreamAddress.classifySharedURL(bare) {
            return address
        }
        return nil
    }

    static func plan(for items: [PastedContent], model: AppModel) -> MenuBarPastePlan {
        let files = items.compactMap(\.fileURL)
        let links = files.isEmpty ? LinkInfo.allLinks(in: text(of: items), limit: 1000) : []
        return MenuBarPaste.plan(fileCount: files.count, links: links) { model.queue.liveJob(for: $0) != nil }
    }

    static func perform(_ items: [PastedContent], via: JobVia, dropped: Bool, model: AppModel) -> Effect {
        if let stream = liveStream(in: items) {
            model.openStream(stream, mode: .open)
            return .openedStream(stream)
        }
        let files = items.compactMap(\.fileURL)
        let source: PasteReviewRequest.Source = dropped ? .dropped : .clipboard
        switch plan(for: items, model: model) {
        case .noLink:
            log(via: via, found: 0, kept: 0, duplicates: 0, model: model)
            return .status(dropped ? Copy.Jobs.nothingDropped : Copy.Jobs.noLink)
        case .alreadySaving:
            log(via: via, found: 1, kept: 0, duplicates: 1, model: model)
            return .status(Copy.Jobs.duplicate)
        case .saveLinks(let urls):
            log(via: via, found: urls.count, kept: urls.count, duplicates: 0, model: model)
            return commitLinks(urls, via: via, model: model)
        case .saveFiles:
            return commitFiles(files, via: via, model: model)
        case .needsAttention(.review):
            // the review's rows (already saved, saving now) are the sheet's, built the same way as before
            switch PasteIntake.outcome(for: text(of: items), source: source, model: model) {
            case .review(let request): return .review(request)
            case .one(let url):
                log(via: via, found: 1, kept: 1, duplicates: 0, model: model)
                return commitLinks([url], via: via, model: model)
            case .duplicate:
                log(via: via, found: 1, kept: 0, duplicates: 1, model: model)
                return .status(Copy.Jobs.duplicate)
            case .none:
                log(via: via, found: 0, kept: 0, duplicates: 0, model: model)
                return .status(dropped ? Copy.Jobs.nothingDropped : Copy.Jobs.noLink)
            }
        }
    }

    @discardableResult
    static func commitLinks(_ urls: [URL], via: JobVia, model: AppModel) -> Effect {
        model.selectedTab = .save
        let jobs = model.queue.add(urls.map(JobInput.link), via: via)
        let alongside = jobs.filter { $0.id != model.queue.focusedID }.count
        let message = alongside > 0 ? Copy.Jobs.savingAlongside(alongside) : nil
        return .queued(message: message, ids: jobs.map(\.id))
    }

    static func log(via: JobVia, found: Int, kept: Int, duplicates: Int, model: AppModel) {
        Telemetry.logPaste(
            via: via, links: found, kept: kept, duplicates: duplicates,
            concurrent: model.queue.live.count, line: model.queue.lineMode)
    }

    private static func commitFiles(_ urls: [URL], via: JobVia, model: AppModel) -> Effect {
        if urls.count == 1 {
            let job = model.importFile(urls[0], via: via)
            let ids = job.map { [$0.id] } ?? []
            let alongside = ids.filter { $0 != model.queue.focusedID }.count
            let message = alongside > 0 ? Copy.Jobs.uploadingAlongside(alongside) : nil
            return .queued(message: message, ids: ids)
        }
        model.selectedTab = .save
        let jobs = model.queue.add(urls.map { JobInput.file($0, photosAssetID: nil) }, via: via)
        for job in jobs {
            if case .uploading = job.pipeline.state {
                job.pipeline.setTitle(CapybaraUploadNames.random())
            }
        }
        return .queued(message: Copy.Jobs.uploadingAlongside(jobs.count), ids: jobs.map(\.id))
    }

    private static func text(of items: [PastedContent]) -> String {
        items.compactMap(\.text).joined(separator: "\n")
    }
}
