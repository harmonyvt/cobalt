import CobaltKit
import SwiftUI

// "upload to 7tv" (APP-API-CONTRACT 57.9): a picture of the library (webp, gif, png, avif, jpeg) as a NEW emote of the linked
// 7TV account. The detail page's secondary row shows the icon (`SevenTvUploadIcon`) when the file is one 7TV takes and the
// account is linked and not signed out; `sevenTvUploadReady` reads the account once so the icon can know. The sheet: the name
// (from the post's title, spaces dropped), private and zero-width, an optional set (channel chips, then the set), "upload";
// then "processing on 7tv" until 7TV is done, the emote, "open on 7tv" and where it went. The fit (57.10): for webp, gif, png
// and jpeg a "size" row (auto, 128, 256, 512, 1000) and "crop…" (the picture crop sheet with one button, "use this crop"; the
// box only), and a "shape" row (as is, square 1:1, wide 2:1, extra wide 3:1: a wide emote is only a picture wider than tall,
// 7TV keeps up to 3:1, so a shape is the largest centred crop box of that ratio, and the crop sheet opens locked to it so the
// box can be moved; the size chips still set the longest side, and a line under them says the px 7TV gets); a big file is shrunk by the server, so it only gets a calm note; an avif that big is refused here. The answer's
// `fitted` shows as "sent as W×H · N frames · X kb".

/// The secondary-row icon. Nothing at all unless the file can go to 7TV and the account can upload.
struct SevenTvUploadIcon: View {
    let model: AppModel
    let file: LibraryFile?
    let title: String?

    @State private var upload: SevenTvUploadModel?

    private var visible: Bool {
        model.capabilities.stage && SevenTvEmoteRule.isUploadable(file) && model.sevenTv.canUpload
    }

    var body: some View {
        if visible, let file {
            DetailChoiceButton(title: Copy.SevenTv.uploadAction, symbol: Symbol.SevenTv.upload) {
                upload = model.sevenTv.uploader(file: file, title: title)
            }
            .sheet(item: $upload) { sheetModel in
                SevenTvUploadSheet(upload: sheetModel, picture: Self.picture(model: model, file: file))
            }
        }
    }

    /// The file's picture at full size for the crop sheet (the copy on this device, else a download), as the library's crop does.
    @MainActor
    static func picture(model: AppModel, file: LibraryFile) -> @MainActor () async throws -> CGImage {
        let rendition = Rendition(id: "f:\(file.id)", kind: .item(index: 0, type: .photo), file: file, createdAt: file.createdAt)
        return { try await model.cropPicture(of: rendition) }
    }
}

extension View {
    /// Reads the 7TV account once (when nothing has read it yet) on a page whose file could go to 7TV, so the secondary row
    /// knows whether to show "upload to 7tv".
    func sevenTvUploadReady(_ model: AppModel, file: LibraryFile?) -> some View {
        task(id: file?.id) { @MainActor in
            guard model.capabilities.stage, SevenTvEmoteRule.isUploadable(file), model.sevenTv.state == .idle else { return }
            await model.sevenTv.load()
        }
    }
}

// MARK: - the sheet

struct SevenTvUploadSheet: View {
    let upload: SevenTvUploadModel
    /// The picture for "crop…"; nil hides it (the size row still shows).
    var picture: (@MainActor () async throws -> CGImage)? = nil
    /// The 7tv tab's shared set models, for "add to a set…" (57.14); nil: the picker uses models of its own.
    var setModels: (@MainActor (String, String) -> SevenTvSetModel)? = nil

    /// The crop sheet being shown, with where its box starts (from a shape chip: locked to the shape, at the box cut; from
    /// "crop…": the whole picture, free). The start travels with the sheet so it is never read stale.
    @State private var cropRequest: CropRequest?
    @State private var picker: SevenTvAddToSetModel?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.shell) private var shell

    private var sending: Bool {
        switch upload.phase {
        case .uploading: return true
        default: return false
        }
    }

    private var showsResult: Bool {
        switch upload.phase {
        case .processing, .done: return true
        default: return false
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if showsResult {
                    SevenTvUploadResultView(upload: upload, addToSet: openPicker) { dismiss() }
                } else {
                    SevenTvUploadForm(
                        upload: upload, sending: sending, canCrop: picture != nil, crop: { openCrop(start: nil) },
                        cropShape: { openCrop(start: Self.start(for: upload)) }, send: send)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 16)
        }
        #if os(macOS)
        .frame(width: 460, height: 600)
        #else
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        .background(CobaltColor.bg)
        .interactiveDismissDisabled(sending)
        .haptic(.success, trigger: upload.phase) { $0 == .done }
        .haptic(.error, trigger: upload.phase) { phase in
            if case .failed = phase { return true }
            return false
        }
        .sheet(item: $cropRequest) { request in
            if let picture {
                ImageCropSheet.sevenTv(upload: upload, load: picture, start: request.start) { cropRequest = nil }
            }
        }
        .sheet(item: $picker) { picker in
            SevenTvAddToSetSheet(picker: picker)
        }
        .onDisappear { upload.stop() }
    }

    private struct CropRequest: Identifiable {
        let id = UUID()
        let start: ImageCropStart?
    }

    private func openCrop(start: ImageCropStart?) {
        cropRequest = CropRequest(start: start)
    }

    /// The crop sheet's start for the shape picked: locked to its ratio, at the box already cut (so it can be moved).
    private static func start(for upload: SevenTvUploadModel) -> ImageCropStart {
        let aspect: ImageCropModel.Aspect
        switch upload.shape {
        case .square: aspect = .square
        case .wide: aspect = .twoToOne
        case .extraWide: aspect = .threeToOne
        case .asIs, nil: aspect = .free
        }
        return ImageCropStart(aspect: aspect, box: upload.crop)
    }

    /// "add to a set…": the emote this upload made, into any set of any channel the account edits (57.14).
    private func openPicker() {
        // the upload's own set is marked from the start; the tab's shared set models keep an open grid right
        picker = upload.addToSetPicker(setModel: setModels)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(Copy.SevenTv.uploadTitle)
                .font(Font.cobalt(18, .semibold, relativeTo: .title3))
                .foregroundStyle(CobaltColor.text)
                .accessibilityAddTraits(.isHeader)
            Text(Copy.SevenTv.uploadNew)
                .font(CobaltType.pill)
                .foregroundStyle(CobaltColor.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(CobaltColor.elevated, in: Capsule())
            Spacer(minLength: 0)
            CloseButton(cancels: !showsResult) { dismiss() }
        }
    }

    private func send() {
        Task {
            await upload.upload()
            if upload.result != nil { shell.showStatus(Copy.SevenTv.uploaded(upload.cleanName)) }
        }
    }
}

// MARK: the form

private struct SevenTvUploadForm: View {
    @Bindable var upload: SevenTvUploadModel
    let sending: Bool
    let canCrop: Bool
    let crop: () -> Void
    /// A shape was picked: open the crop sheet locked to it (so the box can be moved).
    let cropShape: () -> Void
    let send: () -> Void

    private var problem: String? {
        if case .failed(let error) = upload.phase { return Copy.SevenTv.message(for: error) }
        return nil
    }

    private var nameLooksWrong: Bool { !upload.cleanName.isEmpty && !upload.nameIsValid }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            nameField
            sizeNotes
            if upload.fittable {
                SevenTvUploadFitRow(upload: upload, canCrop: canCrop, crop: crop, cropShape: cropShape)
                    .disabled(sending)
            }
            VStack(alignment: .leading, spacing: 4) {
                SevenTvUploadToggle(title: Copy.SevenTv.privateToggle, note: Copy.SevenTv.privateNote, isOn: $upload.isPrivate)
                SevenTvUploadToggle(title: Copy.SevenTv.zeroWidthToggle, note: Copy.SevenTv.zeroWidthNote, isOn: $upload.zeroWidth)
                SevenTvUploadToggle(title: Copy.SevenTv.addToSetToggle, note: nil, isOn: $upload.addToSet)
            }
            .disabled(sending)
            if upload.addToSet {
                SevenTvUploadSetPicker(upload: upload)
                    .disabled(sending)
            }
            if let problem {
                SevenTvUploadNote(text: problem, tint: CobaltColor.errorText)
            }
            Button(sending ? Copy.SevenTv.uploading : Copy.SevenTv.uploadButton, systemImage: Symbol.SevenTv.upload) {
                send()
            }
            .buttonStyle(.cobaltPrimary())
            .symbolEffect(.pulse, isActive: sending)
            .disabled(!upload.canUpload)
        }
        .onChange(of: upload.name) { upload.edit() }
        .onChange(of: upload.size) { upload.edit() }
        .animation(Motion.rows, value: upload.addToSet)
        .animation(Motion.rows, value: upload.crop)
    }

    /// Too big and not shrinkable (red), too big but shrunk by the server (calm), a shape 7TV drops (red).
    @ViewBuilder
    private var sizeNotes: some View {
        if upload.isTooBig {
            SevenTvUploadNote(text: upload.isOverBytes ? Copy.SevenTv.tooBigNote : Copy.SevenTv.tooWideNote, tint: CobaltColor.errorText)
        } else if upload.willShrink {
            SevenTvUploadNote(
                text: upload.isOverBytes ? Copy.SevenTv.shrinkBytesNote : Copy.SevenTv.shrinkSideNote, tint: CobaltColor.caption)
        }
        if upload.needsCrop {
            SevenTvUploadNote(text: Copy.SevenTv.needsCropNote, tint: CobaltColor.errorText)
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(Copy.SevenTv.emoteName, text: $upload.name)
                .font(CobaltType.body)
                .foregroundStyle(CobaltColor.text)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit { if upload.canUpload { send() } }
                .disabled(sending)
                .padding(.horizontal, 12)
                .frame(minHeight: Metrics.hit)
                .background(CobaltColor.elevated, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
                .accessibilityHint(Text(Copy.SevenTv.nameRule))
            Text(Copy.SevenTv.nameRule)
                .font(CobaltType.badge)
                .foregroundStyle(nameLooksWrong ? CobaltColor.errorText : CobaltColor.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The fit (57.10): the shape chips (a centred box of that shape, which the crop sheet can move), the size chips (the longest
/// side; auto = the server's choice), what 7TV will get in px, then "crop…" or the crop set.
private struct SevenTvUploadFitRow: View {
    @Bindable var upload: SevenTvUploadModel
    let canCrop: Bool
    let crop: () -> Void
    let cropShape: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            shapeRow
            HStack(spacing: 10) {
                Text(Copy.SevenTv.sizeLabel)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(SevenTvEmoteRule.sizeChoices, id: \.self) { choice in
                            SevenTvChip(title: Copy.SevenTv.sizeChoice(choice), selected: upload.size == choice) {
                                upload.size = choice
                            }
                        }
                    }
                }
                .accessibilityLabel(Text(Copy.SevenTv.sizeA11y))
            }
            Text(Copy.SevenTv.sizeNote)
                .font(CobaltType.badge)
                .foregroundStyle(CobaltColor.caption)
                .fixedSize(horizontal: false, vertical: true)
            if let out = upload.outputPixels {
                Text(Copy.SevenTv.outputLine(out.width, out.height))
                    .font(CobaltType.captionSmall.monospacedDigit())
                    .foregroundStyle(CobaltColor.text)
                    .accessibilityIdentifier("sevenTvOutputLine")
            }
            if canCrop {
                cropRow
            }
        }
    }

    private var shapeRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(Copy.SevenTv.shapeLabel)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(SevenTvEmoteShape.allCases, id: \.self) { choice in
                            SevenTvChip(title: Copy.SevenTv.shapeChoice(choice), selected: upload.shape == choice) {
                                pick(choice)
                            }
                        }
                    }
                }
                .accessibilityLabel(Text(Copy.SevenTv.shapeA11y))
            }
            .disabled(!upload.canPickShape)
            Text(upload.canPickShape ? Copy.SevenTv.shapeNote : Copy.SevenTv.shapeNeedsSize)
                .font(CobaltType.badge)
                .foregroundStyle(CobaltColor.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A new shape cuts its centred box and opens the crop sheet on it; the shape already picked opens the sheet on the box as
    /// it is now (so a moved box is not put back in the middle). "as is" only clears.
    private func pick(_ choice: SevenTvEmoteShape) {
        if choice == upload.shape, choice != .asIs {
            if canCrop, upload.crop != nil { cropShape() }
            return
        }
        upload.pickShape(choice)
        if choice != .asIs, canCrop, upload.crop != nil { cropShape() }
    }

    private var cropText: String {
        if let px = upload.cropPixels { return Copy.SevenTv.cropLine(px.width, px.height) }
        return Copy.SevenTv.cropSet
    }

    @ViewBuilder
    private var cropRow: some View {
        if upload.crop != nil {
            HStack(spacing: 10) {
                Image(systemName: Symbol.SevenTv.crop)
                    .foregroundStyle(CobaltColor.caption)
                    .accessibilityHidden(true)
                Text(cropText)
                    .font(CobaltType.captionSmall.monospacedDigit())
                    .foregroundStyle(CobaltColor.text)
                Button(Copy.SevenTv.clearCrop, systemImage: Symbol.SevenTv.clearCrop) { upload.useCrop(nil) }
                    .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                Spacer(minLength: 0)
            }
            .frame(minHeight: Metrics.hit)
        } else {
            Button(Copy.SevenTv.cropAction, systemImage: Symbol.SevenTv.crop) { crop() }
                .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
        }
    }
}

extension ImageCropSheet {
    /// From "upload to 7tv": the file's picture and one button, "use this crop", which keeps the box for the upload (the server
    /// crops it, 57.10). Turning, flipping and removing the background are not sent, so a crop with any of them is refused.
    @MainActor
    static func sevenTv(
        upload: SevenTvUploadModel, load: @escaping @MainActor () async throws -> CGImage, start: ImageCropStart? = nil,
        close: @escaping () -> Void
    ) -> ImageCropSheet {
        let use = ImageCropAction(title: Copy.SevenTv.useCrop, symbol: Symbol.SevenTv.crop) { spec, picture in
            guard spec.rotate == 0, spec.flip == .none, !spec.cutout else {
                throw ImageCropError.other(Copy.SevenTv.cropBoxOnly)
            }
            upload.useCrop(spec.crop, width: picture?.width, height: picture?.height)
        }
        let serverCan: @MainActor (Bool) -> Bool = { _ in false }
        return ImageCropSheet(
            name: upload.cleanName, load: load, serverCan: serverCan, note: Copy.SevenTv.cropNote,
            aspects: ImageCropModel.Aspect.sevenTv, start: start, primary: use, secondary: nil, close: close)
    }
}

/// A switch with its name and a line under it.
private struct SevenTvUploadToggle: View {
    let title: String
    let note: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(CobaltType.bodySemibold)
                if let note {
                    Text(note)
                        .font(CobaltType.badge)
                        .foregroundStyle(CobaltColor.caption)
                }
            }
        }
        .toggleStyle(.switch)
        .tint(CobaltColor.success)
        .frame(minHeight: Metrics.hit)
    }
}

/// "add to a set": the channels the account may edit as chips, then the picked channel's sets.
private struct SevenTvUploadSetPicker: View {
    @Bindable var upload: SevenTvUploadModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if upload.channels.isEmpty {
                SevenTvUploadNote(text: Copy.SevenTv.noEditableChannels, tint: CobaltColor.caption)
            } else {
                channelChips
                setRow
            }
        }
        .task { await upload.prepareSets() }
    }

    private var channelChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(upload.channels) { channel in
                    SevenTvChip(title: channel.name, selected: channel.id == upload.channelID) {
                        Task { await upload.pickChannel(channel.id) }
                    }
                }
            }
        }
        .accessibilityLabel(Text(Copy.SevenTv.channelsA11y))
    }

    @ViewBuilder
    private var setRow: some View {
        switch upload.setsState {
        case .loading, .idle:
            Text(Copy.SevenTv.loadingSets)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
        case .failed(let error):
            SevenTvUploadNote(text: Copy.SevenTv.message(for: error), tint: CobaltColor.errorText)
        case .loaded:
            if upload.sets.isEmpty {
                SevenTvUploadNote(text: Copy.SevenTv.noSets, tint: CobaltColor.caption)
            } else {
                HStack(spacing: 12) {
                    Text(Copy.SevenTv.setLabel)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                    Picker(Copy.SevenTv.setLabel, selection: $upload.setID) {
                        ForEach(upload.sets) { row in
                            Text(Copy.SevenTv.setChoice(row.name, live: row.live)).tag(Optional(row.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    Spacer(minLength: 0)
                }
                .frame(minHeight: Metrics.hit)
            }
        }
    }
}

// MARK: the result

private struct SevenTvUploadResultView: View {
    let upload: SevenTvUploadModel
    let addToSet: () -> Void
    let close: () -> Void

    @Environment(\.openURL) private var openURL

    private var processing: Bool { upload.phase == .processing }

    private var statusLine: String {
        if processing { return Copy.SevenTv.processing }
        return upload.timedOut ? Copy.SevenTv.stillProcessing : Copy.SevenTv.ready
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                picture
                VStack(alignment: .leading, spacing: 2) {
                    Text(upload.result?.name ?? upload.cleanName)
                        .font(Font.cobalt(16, .semibold, relativeTo: .headline))
                        .foregroundStyle(CobaltColor.text)
                        .lineLimit(1)
                    Text(statusLine)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(processing || upload.timedOut ? CobaltColor.caption : CobaltColor.success)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
            }
            if processing {
                SevenTvUploadNote(text: Copy.SevenTv.processingNote, tint: CobaltColor.caption)
            }
            placement
            if let fitted = upload.result?.fitted {
                SevenTvUploadNote(
                    text: Copy.SevenTv.sentAs(width: fitted.width, height: fitted.height, frames: fitted.frames, bytes: fitted.bytes),
                    tint: CobaltColor.caption)
            }
            if upload.result != nil, !upload.channels.isEmpty {
                Button(Copy.SevenTv.addToSetAction, systemImage: Symbol.SevenTv.addToSet, action: addToSet)
                    .buttonStyle(.cobaltSecondary(compact: true))
            }
            buttons
        }
        .animation(Motion.rows, value: upload.phase)
    }

    @ViewBuilder
    private var picture: some View {
        let frame = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Group {
            if let emote = upload.emote, !emote.pending, emote.previewURL != nil {
                EmotePicture(url: emote.previewURL, animated: emote.animated, side: 56)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 56, height: 56)
                    .accessibilityLabel(Text(Copy.SevenTv.processing))
            }
        }
        .padding(4)
        .background(CobaltColor.surface, in: frame)
    }

    @ViewBuilder
    private var placement: some View {
        if let name = upload.addedSetName {
            SevenTvUploadNote(text: Copy.SevenTv.addedTo(name), tint: CobaltColor.success)
        } else if upload.result?.added != nil {
            SevenTvUploadNote(text: Copy.SevenTv.addedToSet, tint: CobaltColor.success)
        } else if let refusal = upload.result?.addError {
            SevenTvUploadNote(text: Copy.SevenTv.addFailed(Copy.SevenTv.message(for: refusal)), tint: CobaltColor.errorText)
        }
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            if let page = upload.result?.pageURL {
                Button(Copy.SevenTv.openOn7tv, systemImage: Symbol.SevenTv.website) { openURL(page) }
                    .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
            }
            Spacer(minLength: 0)
            Button(Copy.SevenTv.done, systemImage: Symbol.checkmark) { close() }
                .buttonStyle(.cobaltPrimary(fullWidth: false, compact: true))
        }
    }
}

/// A line of caption text in a colour.
private struct SevenTvUploadNote: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(CobaltType.caption)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }
}
