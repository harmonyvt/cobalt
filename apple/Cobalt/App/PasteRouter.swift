import CobaltKit

/// The window's paste and the menu bar's paste share this. A single new link, and several files, are
/// queued here. A review or a name-it sheet is returned for the window to present: the menu bar never
/// draws those, it hands the same clipboard to the window.
@MainActor
enum PasteRouter {
    enum Effect: Equatable {
        case status(String)
        case queued(message: String?, ids: [Job.ID])
        case review(PasteReviewRequest)
        case nameFile(URL)
    }

    static func plan(for items: [PastedContent], model: AppModel) -> MenuBarPastePlan {
        let files = items.compactMap(\.fileURL)
        let links = files.isEmpty ? LinkInfo.allLinks(in: text(of: items), limit: 1000) : []
        return MenuBarPaste.plan(fileCount: files.count, links: links) { model.queue.liveJob(for: $0) != nil }
    }

    static func perform(_ items: [PastedContent], via: JobVia, dropped: Bool, model: AppModel) -> Effect {
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
        case .needsAttention(.nameFile):
            return .nameFile(files[0])
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
        model.selectedTab = .save
        let jobs = model.queue.add(urls.map { JobInput.file($0, photosAssetID: nil) }, via: via)
        return .queued(message: Copy.Jobs.uploadingAlongside(jobs.count), ids: jobs.map(\.id))
    }

    private static func text(of items: [PastedContent]) -> String {
        items.compactMap(\.text).joined(separator: "\n")
    }
}
