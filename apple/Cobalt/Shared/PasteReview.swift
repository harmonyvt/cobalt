import CobaltKit
import CoreTransferable
import SwiftUI

// Pasting anywhere (CONTRACT-PARALLEL section 4). What a paste or a drop of text comes to, the review that two or
// more links get, and the one `Transferable` that ⌘V and a drop on the window both read.
//
// Compiled into the share extension too (`Cobalt/Shared`): nothing here may name an app-only type (`shell`,
// `Pasteboard`). The app presents the review sheet from `AppShell`.

// MARK: - what arrived

/// What was pasted or dropped, as the system hands it over. A file is an upload, a web link and text are read for links.
/// Declaration order is the order the system tries: a link dragged from Safari offers both its URL and its text, and
/// the URL wins.
enum PastedContent: Transferable {
    case file(URL)
    case link(URL)
    case text(String)

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(importing: { (url: URL) in url.isFileURL ? PastedContent.file(url) : .link(url) })
        ProxyRepresentation(importing: { (text: String) in PastedContent.text(text) })
    }

    var fileURL: URL? {
        if case .file(let url) = self { return url }
        return nil
    }

    /// The text to look for links in: a web link is its own text.
    var text: String? {
        switch self {
        case .file: return nil
        case .link(let url): return url.absoluteString
        case .text(let text): return text
        }
    }
}

// MARK: - the review

/// One link in the review: what it is, whether cobalt already has it, and whether it is ticked.
struct PasteReviewRow: Identifiable, Equatable {
    enum Status: Equatable {
        case new
        /// The store or the loaded library has it, saved on that date.
        case saved(Date)
        /// A job in this app is saving it right now: it cannot be ticked.
        case live
    }

    let url: URL
    let info: LinkInfo
    let status: Status
    var ticked: Bool

    var id: String { url.absoluteString }
    var canTick: Bool { status != .live }
}

/// Two or more links found: the review sheet's contents. Never made for fewer than two.
struct PasteReviewRequest: Identifiable, Equatable {
    enum Source: Equatable { case clipboard, dropped }

    let id = UUID()
    let source: Source
    /// How many links the text held before the cap of 20.
    let found: Int
    var rows: [PasteReviewRow]

    var title: String { Copy.Jobs.reviewTitle(count: rows.count, dropped: source == .dropped) }
    var capNote: String? { found > rows.count ? Copy.Jobs.reviewCap(shown: rows.count, found: found) : nil }
    var tickedURLs: [URL] { rows.filter(\.ticked).map(\.url) }
}

/// What a paste (or a drop of text) came to.
enum PasteOutcome: Equatable {
    /// No link in it: a status line, nothing queued.
    case none
    /// One link that a job is already saving: "already saving that one."
    case duplicate(URL)
    /// One link: added at once.
    case one(URL)
    /// Two or more: the review first.
    case review(PasteReviewRequest)
}

@MainActor
enum PasteIntake {
    /// At most this many links per paste (CONTRACT-PARALLEL 4.2).
    static let cap = 20

    /// Reads `text` for links. The API's rule per link, repeats folded.
    static func outcome(for text: String?, source: PasteReviewRequest.Source, model: AppModel) -> PasteOutcome {
        guard let text, !text.isEmpty else { return .none }
        // everything the text holds, so the review can say "the first 20 of 34 links"
        let all = LinkInfo.allLinks(in: text, limit: 1000)
        guard !all.isEmpty else { return .none }
        if all.count == 1 {
            let url = all[0]
            return model.queue.liveJob(for: url) != nil ? .duplicate(url) : .one(url)
        }
        let known = savedLinks(in: model)
        let rows: [PasteReviewRow] = all.prefix(cap).compactMap { url in
            guard let info = LinkInfo(url) else { return nil }
            let status: PasteReviewRow.Status
            if model.queue.liveJob(for: url) != nil {
                status = .live
            } else if let saved = known[key(url)] {
                status = .saved(saved)
            } else {
                status = .new
            }
            return PasteReviewRow(url: url, info: info, status: status, ticked: status == .new)
        }
        return .review(PasteReviewRequest(source: source, found: all.count, rows: rows))
    }

    /// A link as the store and the library keep it, folded the way people paste it: host in lower case, no fragment,
    /// no trailing slash.
    static func key(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        parts.fragment = nil
        while parts.path.count > 1, parts.path.hasSuffix("/") { parts.path.removeLast() }
        if parts.path == "/" { parts.path = "" }
        return parts.string ?? url.absoluteString
    }

    /// Every link the app already has a save for (this device's store and the loaded library), with when it was saved
    /// (the earliest when both have it).
    static func savedLinks(in model: AppModel) -> [String: Date] {
        var out: [String: Date] = [:]
        func note(_ link: URL?, _ date: Date) {
            guard let link else { return }
            let k = key(link)
            if let have = out[k], have <= date { return }
            out[k] = date
        }
        for media in model.store.media { note(media.link, media.original?.createdAt ?? media.latestAt) }
        for post in model.library.posts { note(post.link, post.createdAt) }
        return out
    }

    /// "just now", "3 hours ago", "yesterday", "2 weeks ago".
    static func when(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now).lowercased()
    }
}

// MARK: - the sheet

/// "3 links on your clipboard": one row per link, the new ones ticked, links cobalt already has unticked with when it
/// saved them, "save N" (return) and "cancel" (escape). A Mac sheet 440 pt wide; an iPhone bottom sheet at the
/// medium detent.
struct PasteReviewSheet: View {
    @State private var request: PasteReviewRequest
    let cancel: () -> Void
    let save: ([URL]) -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    init(request: PasteReviewRequest, cancel: @escaping () -> Void, save: @escaping ([URL]) -> Void) {
        _request = State(initialValue: request)
        self.cancel = cancel
        self.save = save
    }

    private var count: Int { request.rows.filter(\.ticked).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(request.title)
                    .font(Font.cobalt(16, .semibold, relativeTo: .headline))
                    .foregroundStyle(CobaltColor.text)
                    .accessibilityAddTraits(.isHeader)
                Text(request.capNote.map { "\($0) · \(Copy.Jobs.reviewNote)" } ?? Copy.Jobs.reviewNote)
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach($request.rows) { $row in
                        ReviewRow(row: $row)
                        if row.id != request.rows.last?.id { Divider().overlay(CobaltColor.hairline) }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .scrollBounceBehavior(.basedOnSize)
            ButtonRow {
                Button(Copy.Jobs.reviewCancel) { cancel() }
                    .buttonStyle(.cobaltSecondary())
                    .keyboardShortcut(.cancelAction)
                Button(Copy.Jobs.reviewSave(count)) { save(request.tickedURLs) }
                    .buttonStyle(.cobaltPrimary())
                    .keyboardShortcut(.defaultAction)
                    .disabled(count == 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 12)
        #if os(macOS)
        .frame(width: 440, height: min(520, 190 + CGFloat(request.rows.count) * 52))
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityLabel(request.title)
    }
}

/// One link: a tick box, `service · ref`, and under it new / already saved · when / saving now. A link a job is
/// saving right now cannot be ticked.
private struct ReviewRow: View {
    @Binding var row: PasteReviewRow

    private var status: String {
        switch row.status {
        case .new: return Copy.Jobs.reviewNew
        case .saved(let date): return Copy.Jobs.reviewSaved(when: PasteIntake.when(date))
        case .live: return Copy.Jobs.reviewLive
        }
    }

    var body: some View {
        Button {
            if row.canTick { row.ticked.toggle() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: row.ticked ? Symbol.tickOn : Symbol.tickOff)
                    .font(.system(size: 20))
                    .foregroundStyle(row.ticked ? CobaltColor.text : CobaltColor.caption)
                    .opacity(row.canTick ? 1 : 0.4)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 0) {
                        Text(row.info.service).foregroundStyle(CobaltColor.text)
                        Text(" · \(row.info.ref)").foregroundStyle(CobaltColor.caption)
                    }
                    .font(CobaltType.bodyMedium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    Text(status)
                        .font(CobaltType.caption)
                        .foregroundStyle(CobaltColor.caption)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .frame(minHeight: Metrics.hit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!row.canTick)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.info.service) · \(row.info.ref)")
        .accessibilityValue("\(status), \(row.ticked ? Copy.Jobs.reviewA11yTicked : Copy.Jobs.reviewA11yUnticked)")
        .accessibilityAddTraits(row.canTick ? [.isButton] : [.isButton, .isStaticText])
    }
}

#if DEBUG
#Preview("paste review · 3 links, one saved") {
    let urls = [
        "https://www.tiktok.com/@harbour/video/7301122334455",
        "https://x.com/someone/status/1792233445566",
        "https://www.instagram.com/reel/Cx9fKq2LbPd/",
    ].compactMap(URL.init(string:))
    let rows = urls.enumerated().compactMap { i, url -> PasteReviewRow? in
        guard let info = LinkInfo(url) else { return nil }
        let status: PasteReviewRow.Status = i == 1 ? .saved(Date().addingTimeInterval(-3 * 86_400)) : (i == 2 ? .live : .new)
        return PasteReviewRow(url: url, info: info, status: status, ticked: status == .new)
    }
    return PasteReviewSheet(request: PasteReviewRequest(source: .clipboard, found: 3, rows: rows), cancel: {}, save: { _ in })
        .background(CobaltColor.bg)
}
#endif
