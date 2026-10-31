import CobaltKit
import SwiftUI

// Share a chat as a web page (APP-API-CONTRACT 46): from a thread's menu. Not shared yet: what it does, the two settings
// and "make a link". Shared: the link (copy, share, open), how far the page goes (with "update" when newer messages came
// after it), the settings (each change saves at once), how often it was opened, a new link and stop sharing.

struct ChatShareSheet: View {
    let model: AppModel
    let threadID: String
    let done: () -> Void

    @Environment(\.shell) private var shell
    @Environment(\.hapticsEnabled) private var haptics
    @State private var loading = true
    @State private var working = false
    @State private var copied = 0
    @State private var media = true
    @State private var code = false
    @State private var confirmRotate = false
    @State private var confirmStop = false
    @State private var failure: String?

    private var store: ChatStore { model.chat }
    private var share: ChatShare? { store.shareOf(threadID) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Text(Copy.ChatSharing.title).font(CobaltType.sheetTitle)
                    Spacer(minLength: 0)
                    CloseButton(cancels: true, action: done)
                }
                if loading && share == nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(Copy.ChatSharing.loading).font(CobaltType.caption).foregroundStyle(.secondary)
                    }
                } else if let share {
                    shared(share)
                } else {
                    notShared
                }
                if let failure {
                    Text(failure).font(CobaltType.caption).foregroundStyle(.red)
                }
            }
            .padding(24)
        }
        .frame(minWidth: 320, idealWidth: 460)
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
        .task { await load() }
        .haptic(.success, trigger: copied, enabled: haptics)
        .confirmationDialog(Copy.ChatSharing.rotateTitle, isPresented: $confirmRotate, titleVisibility: .visible) {
            Button(Copy.ChatSharing.rotate) { run(Copy.ChatSharing.rotated) { try await store.rotateShare(threadID) } }
        } message: {
            Text(Copy.ChatSharing.rotateMessage)
        }
        .confirmationDialog(Copy.ChatSharing.stopTitle, isPresented: $confirmStop, titleVisibility: .visible) {
            Button(Copy.ChatSharing.stop, role: .destructive) { run(Copy.ChatSharing.stopped) { try await store.stopShare(threadID) } }
        } message: {
            Text(Copy.ChatSharing.stopMessage)
        }
    }

    // MARK: not shared

    private var notShared: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Copy.ChatSharing.intro).font(CobaltType.body).foregroundStyle(.secondary)
            settings
            Button {
                run(nil) { try await store.share(threadID, ChatShareChange(media: media, code: code)) }
            } label: {
                Label(working ? Copy.ChatSharing.making : Copy.ChatSharing.make, systemImage: Symbol.chatShare)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(working)
            Text(Copy.ChatSharing.note).font(CobaltType.captionSmall).foregroundStyle(.secondary)
        }
    }

    // MARK: shared

    private func shared(_ share: ChatShare) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(share.url.absoluteString)
                .font(Font.cobalt(13))
                .textSelection(.enabled)
                .lineLimit(2)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack(spacing: 8) {
                Button {
                    Pasteboard.copy(share.url.absoluteString)
                    copied += 1
                    shell.showStatus(Copy.ChatSharing.copied)
                } label: {
                    Label(Copy.ChatSharing.copy, systemImage: Symbol.chatShareCopy).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                ShareLink(item: share.url) {
                    Label(Copy.ChatSharing.menu, systemImage: "square.and.arrow.up").labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                Link(destination: share.url) {
                    Label(Copy.ChatSharing.open, systemImage: Symbol.chatShareOpen).labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)

            VStack(spacing: 0) {
                row(Copy.ChatSharing.upTo) {
                    HStack(spacing: 8) {
                        Text(Copy.ChatSharing.upToValue(share.messages)).foregroundStyle(.secondary)
                        if share.behind > 0 {
                            Button(Copy.ChatSharing.update, systemImage: Symbol.chatShareUpdate) {
                                run(Copy.ChatSharing.updated) { try await store.share(threadID, ChatShareChange(toLatest: true)) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(working)
                            .help(Copy.ChatSharing.behind(share.behind))
                        }
                    }
                }
                if share.behind > 0 {
                    Text(Copy.ChatSharing.behind(share.behind))
                        .font(CobaltType.captionSmall).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, 12).padding(.bottom, 8)
                }
                Divider()
                row(Copy.ChatSharing.opened) { Text(Copy.ChatSharing.openedValue(share.opened)).foregroundStyle(.secondary) }
            }
            .font(CobaltType.body)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            settings
                .onChange(of: media) { _, on in if on != share.media { save(ChatShareChange(media: on)) } }
                .onChange(of: code) { _, on in if on != share.code { save(ChatShareChange(code: on)) } }

            HStack(spacing: 8) {
                Button(Copy.ChatSharing.rotate, systemImage: Symbol.chatShareRotate) { confirmRotate = true }
                    .buttonStyle(.bordered)
                Spacer(minLength: 0)
                Button(Copy.ChatSharing.stop, systemImage: Symbol.chatShareStop, role: .destructive) { confirmStop = true }
                    .buttonStyle(.bordered)
            }
            .disabled(working)
            Text(Copy.ChatSharing.note).font(CobaltType.captionSmall).foregroundStyle(.secondary)
        }
    }

    private var settings: some View {
        VStack(spacing: 0) {
            Toggle(isOn: $media) { titled(Copy.ChatSharing.media, Copy.ChatSharing.mediaDetail) }
                .padding(12)
            Divider()
            Toggle(isOn: $code) { titled(Copy.ChatSharing.code, Copy.ChatSharing.codeDetail) }
                .padding(12)
        }
        .disabled(working)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func titled(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(CobaltType.body)
            Text(detail).font(CobaltType.captionSmall).foregroundStyle(.secondary)
        }
    }

    private func row<V: View>(_ title: String, @ViewBuilder value: () -> V) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            value()
        }
        .padding(12)
    }

    // MARK: actions

    private func load() async {
        defer { loading = false }
        do {
            let s = try await store.loadShare(threadID)
            media = s?.media ?? true
            code = s?.code ?? false
        } catch {
            failure = Self.words(for: error)
        }
    }

    private func save(_ change: ChatShareChange) {
        run(nil) { try await store.share(threadID, change) }
    }

    /// Runs one call, shows `status` when it lands and keeps the toggles in step with what the server answered.
    private func run(_ status: String?, _ call: @escaping () async throws -> Void) {
        guard !working else { return }
        working = true
        failure = nil
        Task {
            defer { working = false }
            do {
                try await call()
                if let status { shell.showStatus(status) }
            } catch {
                failure = Self.words(for: error)
            }
            if let s = share {
                media = s.media
                code = s.code
            }
        }
    }

    static func words(for error: Error) -> String {
        switch error {
        case CobaltError.api(let code, _) where code == "error.chat_share.empty": return Copy.ChatSharing.empty
        case CobaltError.api(let code, _) where code == "error.share.off": return Copy.ChatSharing.off
        case PipelineFailure.unsupported: return Copy.ChatSharing.off
        default: return Copy.ChatSharing.failed
        }
    }
}

#if DEBUG
#Preview("chat · share sheet") {
    PreviewHost(.happy, tab: .chat) { model in
        ChatShareSheet(model: model, threadID: model.chat.threads.first?.id ?? "", done: {})
    }
}
#endif
