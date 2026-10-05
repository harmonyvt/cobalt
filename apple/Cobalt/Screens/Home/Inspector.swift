import CobaltKit
import SwiftUI

/// The trim settings, as a native `.inspector` column on iPad and the Mac: selection, quality,
/// "make webp", and what was made from this video. A grouped `Form`, so it takes the system's
/// inspector material and spacing.
struct InspectorColumn: View {
    let model: AppModel
    /// A made webp the owner tapped: its detail, on that tab, in a sheet.
    @State private var opened: OpenedRendition?

    private var pipeline: Pipeline { model.pipeline }
    private var settings: CobaltKit.Settings { model.settings }

    private var canMake: Bool {
        switch pipeline.state {
        case .ready: return true
        case .failed(let f): return f.keepsTrim
        default: return false
        }
    }

    /// The media this run belongs to, as the detail shows it: the device's and the library's webps of the
    /// run's video together (CONTRACT-MEDIA 5).
    private var media: MediaItem? {
        if let id = pipeline.mediaID, let local = model.store.media(id: id) { return model.mediaItem(for: local) }
        guard let sid = pipeline.sessionID else { return nil }
        if let local = model.store.media(session: sid) { return model.mediaItem(for: local) }
        if let post = model.library.posts.first(where: { $0.session?.id == sid }) { return model.mediaItem(for: post) }
        return nil
    }

    /// Webps already made from this video: every tab of the media but the video.
    private var made: [Rendition] { media?.webps ?? [] }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Label(Copy.selection, systemImage: Symbol.selection).font(CobaltType.caption).foregroundStyle(CobaltColor.caption)
                    LengthReadout(seconds: pipeline.trim.length, over: pipeline.trimOverLimit, font: CobaltType.readoutLarge)
                    Text(Copy.timecodeRange(pipeline.trim))
                        .font(CobaltType.caption).foregroundStyle(CobaltColor.caption).monospacedDigit()
                }
                .padding(.vertical, 4)
            }
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(Copy.quality, systemImage: Symbol.quality).font(CobaltType.caption).foregroundStyle(CobaltColor.caption)
                    QualityPicker(settings: settings)
                }
                .padding(.vertical, 2)
                LabeledContent {
                    Text(Copy.widthName(settings.webpWidth)).font(Font.cobalt(13)).foregroundStyle(CobaltColor.text)
                } label: {
                    Label(Copy.width, systemImage: Symbol.width).font(CobaltType.caption).foregroundStyle(CobaltColor.caption)
                }
            }
            Section {
                Button(Copy.makeWebp, systemImage: Symbol.makeWebp) { pipeline.makeWebp() }
                    .buttonStyle(.cobaltPrimary())
                    .disabled(!canMake)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            if !made.isEmpty || pipeline.result != nil {
                Section {
                    if let result = pipeline.result, made.isEmpty {
                        madeRow(size: Format.size(result.width, result.height), seconds: result.seconds,
                                bytes: result.bytes, url: result.url)
                    }
                    if let media {
                        ForEach(made) { webp in
                            renditionRow(webp, of: media)
                        }
                    }
                } header: {
                    Text(Copy.madeFromThisVideo).font(CobaltType.caption).textCase(nil)
                }
            }
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.inspectorA11y)
        .sheet(item: $opened) { open in
            NavigationStack {
                MediaDetail(model: model, item: open.item, initial: open.rendition)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { CloseButton { opened = nil } } }
            }
            #if os(macOS)
            .frame(minWidth: 900, minHeight: 640)
            #endif
        }
    }

    /// `webp 1 · 480×854 · 4.5 MB`: tapping opens the media's detail on this webp; the copy button stays.
    private func renditionRow(_ webp: Rendition, of media: MediaItem) -> some View {
        HStack(spacing: 10) {
            Button { opened = OpenedRendition(item: media, rendition: webp.id) } label: {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(FrameGradient.fill(1))
                        .frame(width: 44, height: 78)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(rowTitle(webp, of: media))
                            .font(Font.cobalt(12.5, .regular, relativeTo: .footnote)).foregroundStyle(CobaltColor.text)
                            .multilineTextAlignment(.leading)
                        Text(Copy.publicLink)
                            .font(CobaltType.caption).foregroundStyle(CobaltColor.caption)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let url = webp.publicURL {
                Button { Pasteboard.copy(url.absoluteString) } label: {
                    Image(systemName: Symbol.copyLink).frame(width: 32, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Copy.copyLink)
            }
        }
    }

    private func rowTitle(_ webp: Rendition, of media: MediaItem) -> String {
        [webp.tabName(of: media), DetailMeta.size(webp), webp.bytes.map { Format.bytes($0) }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// A webp that was just finished and is not stored yet: its numbers, and the link.
    private func madeRow(size: String, seconds: Double, bytes: Int64, url: URL?) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(FrameGradient.fill(1))
                .frame(width: 44, height: 78)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(size) · \(Format.seconds(seconds))")
                    .font(Font.cobalt(12.5, .regular, relativeTo: .footnote)).foregroundStyle(CobaltColor.text)
                Text("\(Format.bytes(bytes)) · \(Copy.publicLink)")
                    .font(CobaltType.caption).foregroundStyle(CobaltColor.caption)
                if let url {
                    Button(Copy.copyLink, systemImage: Symbol.copyLink) { Pasteboard.copy(url.absoluteString) }
                        .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                        .padding(.top, 4)
                }
            }
        }
    }
}

/// The tab an inspector row opens.
private struct OpenedRendition: Identifiable {
    let item: MediaItem
    let rendition: Rendition.ID
    var id: String { "\(item.id)/\(rendition)" }
}

/// low / medium / high as a native segmented control.
struct QualityPicker: View {
    let settings: CobaltKit.Settings

    var body: some View {
        Picker(Copy.quality, selection: Binding(get: { settings.webpQuality }, set: { settings.webpQuality = $0 })) {
            ForEach(WebpQuality.allCases, id: \.self) { q in
                Text(Copy.qualityName(q)).tag(q)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel(Copy.quality)
    }
}
