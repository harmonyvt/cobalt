import CobaltKit
import SwiftUI

// "make video" (APP-API-CONTRACT section 45): a thread replayed as an MP4 by the editor's render containers. The thread's
// menu opens this sheet on the whole thread, a message's menu ("make video from here") on that message onwards. The sheet
// asks for the shape, the theme, the pacing and (with Hark) a message when it ends; the render then shows in the queue and
// opens its library post once it is done.

/// What the sheet is open on: a thread, from one of its messages or from the start.
struct ChatVideoRequest: Identifiable, Hashable {
    let threadID: String
    /// The first message the video shows; nil: the whole thread.
    let from: String?

    var id: String { "\(threadID)|\(from ?? "")" }
}

struct ChatVideoSheet: View {
    let controller: ChatController
    let request: ChatVideoRequest

    @Environment(\.dismiss) private var dismiss
    @Environment(\.shell) private var shell
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var options: ChatVideoOptions
    @State private var making = false
    @State private var problem: String?
    @State private var failTick = 0

    init(controller: ChatController, request: ChatVideoRequest) {
        self.controller = controller
        self.request = request
        _options = State(initialValue: ChatVideoOptions(from: request.from, notify: controller.model.capabilities.notifyBridge))
    }

    private var model: AppModel { controller.model }
    /// A reply is being written: the server would refuse (`error.chat.busy`).
    private var busy: Bool { model.chat.isBusy(request.threadID) }
    private var canMake: Bool { !making && !busy }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Text(request.from == nil ? Copy.Chat.videoTitle : Copy.Chat.videoFromTitle)
                    .font(Font.cobalt(16, .semibold, relativeTo: .headline))
                    .foregroundStyle(CobaltColor.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                CloseButton(cancels: true) { dismiss() }    // cancel is the sheet's close, top right
                    .disabled(making)
            }
            row(Copy.Chat.videoShape) {
                Picker(Copy.Chat.videoShape, selection: $options.shape) {
                    ForEach(ChatVideoShape.allCases, id: \.self) { shape in
                        Text(Copy.Chat.videoShapeName(shape)).tag(shape)
                    }
                }
            }
            row(Copy.Chat.videoTheme) {
                Picker(Copy.Chat.videoTheme, selection: $options.theme) {
                    ForEach(ChatVideoTheme.allCases, id: \.self) { theme in
                        Text(Copy.Chat.videoThemeName(theme)).tag(theme)
                    }
                }
            }
            row(Copy.Chat.videoSpeed) {
                Picker(Copy.Chat.videoSpeed, selection: $options.speed) {
                    ForEach(ChatVideoSpeed.allCases, id: \.self) { speed in
                        Text(Copy.Chat.videoSpeedName(speed)).tag(speed)
                    }
                }
            }
            if model.capabilities.notifyBridge {
                Toggle(isOn: $options.notify) {
                    Text(Copy.Chat.videoNotify).font(CobaltType.body).foregroundStyle(CobaltColor.text)
                }
                .toggleStyle(.switch)
                .tint(CobaltColor.success)
                .frame(minHeight: Metrics.hit)
            }
            Text(Copy.Chat.videoNote)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
                .fixedSize(horizontal: false, vertical: true)
            if let line = problem ?? (busy ? Copy.Chat.busy : nil) {
                Text(line)
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.errorText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            Button(Copy.Chat.makeVideo, systemImage: Symbol.chatVideo) { make() }
                .buttonStyle(.cobaltPrimary())
                .keyboardShortcut(.defaultAction)
                .disabled(!canMake)
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 12)
        #if os(macOS)
        .frame(width: 420)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        .background(CobaltColor.bg)
        .interactiveDismissDisabled(making)
        .haptic(.error, trigger: failTick)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(request.from == nil ? Copy.Chat.videoTitle : Copy.Chat.videoFromTitle)
    }

    /// One labelled segmented choice.
    private func row<Content: View>(_ label: String, @ViewBuilder picker: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
                .accessibilityHidden(true)
            picker()
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel(label)
        }
    }

    private func make() {
        guard canMake else { return }
        making = true
        problem = nil
        let threadID = request.threadID
        let chosen = options
        Task {
            defer { making = false }
            do {
                try await model.makeChatVideo(threadID: threadID, options: chosen)
                controller.doneTick += 1
                let model = self.model
                shell.showNote(StatusNote(
                    text: Copy.Chat.videoQueued, detail: Copy.Chat.videoQueuedDetail, actionTitle: Copy.Chat.videoOpenQueue
                ) { model.showQueue() })
                dismiss()
            } catch {
                problem = Copy.Chat.videoMessage(for: error)
                failTick += 1
            }
        }
    }
}
