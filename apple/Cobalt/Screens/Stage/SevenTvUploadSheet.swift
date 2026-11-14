import CobaltKit
import SwiftUI

// "upload to 7tv" (APP-API-CONTRACT 57.9): a picture of the library (webp, gif, png, avif, jpeg) as a NEW emote of the linked
// 7TV account. The detail page's secondary row shows the icon (`SevenTvUploadIcon`) when the file is one 7TV takes and the
// account is linked and not signed out; `sevenTvUploadReady` reads the account once so the icon can know. The sheet: the name
// (from the post's title, spaces dropped), private and zero-width, an optional set (channel chips, then the set), "upload";
// then "processing on 7tv" until 7TV is done, the emote, "open on 7tv" and where it went.

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
                upload = model.sevenTv.uploader(fileID: file.id, bytes: file.bytes, title: title)
            }
            .sheet(item: $upload) { sheetModel in
                SevenTvUploadSheet(upload: sheetModel)
            }
        }
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
                    SevenTvUploadResultView(upload: upload) { dismiss() }
                } else {
                    SevenTvUploadForm(upload: upload, sending: sending, send: send)
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
        .onDisappear { upload.stop() }
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
    let send: () -> Void

    private var problem: String? {
        if case .failed(let error) = upload.phase { return Copy.SevenTv.message(for: error) }
        return nil
    }

    private var nameLooksWrong: Bool { !upload.cleanName.isEmpty && !upload.nameIsValid }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            nameField
            if upload.isTooBig {
                SevenTvUploadNote(text: Copy.SevenTv.tooBigNote, tint: CobaltColor.errorText)
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
        .animation(Motion.rows, value: upload.addToSet)
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
