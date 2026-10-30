import CobaltKit
import SwiftUI

/// "mcp": how agents reach the capystore MCP (APP-API-CONTRACT 35.5). Off, the public URL (a client key in the
/// header: Claude Code), or a private link with the key inside it (claude.ai's connectors), which turns the public URL
/// off. Every switch asks first; turning the link on or rotating it shows the new link once, in a sheet, to copy.
/// Hidden without a key and on a server without the route.
struct McpSettingsSection: View {
    let model: AppModel

    private enum Load: Equatable {
        case loading, hidden, failed
        case ready(McpSettings)
    }

    private enum Pending: Equatable {
        case mode(McpSettings.Mode)
        case rotate
    }

    private struct Revealed: Identifiable {
        let url: String
        let isNew: Bool
        var id: String { url }
    }

    @State private var load: Load = .loading
    @State private var pending: Pending?
    @State private var working = false
    @State private var actionError: String?
    @State private var revealed: Revealed?
    @State private var copiedPublic = false

    private var current: McpSettings? {
        if case let .ready(s) = load { return s }
        return nil
    }

    var body: some View {
        if load != .hidden {
            Section {
                content
            } header: {
                Text(Copy.Mcp.group).font(CobaltType.caption).textCase(nil)
            } footer: {
                if let current {
                    Text(Copy.Mcp.footer(Self.name(current.mode))).font(CobaltType.captionSmall).lineSpacing(2)
                }
            }
            .task(id: model.settings.hasAPIKey) { await reload() }
            .confirmationDialog(dialogTitle, isPresented: dialogShown, titleVisibility: .visible) {
                Button(dialogAction, role: dialogDestructive ? .destructive : nil) { Task { await confirm() } }
                Button(Copy.Mcp.cancel, role: .cancel) { pending = nil }
            } message: {
                Text(dialogBody)
            }
            .sheet(item: $revealed) { r in
                McpLinkRevealSheet(url: r.url, isNew: r.isNew) { revealed = nil }
            }
            .haptic(.success, trigger: revealed?.id) { $0 != nil }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch load {
        case .loading, .hidden:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(Copy.Mcp.how).foregroundStyle(.secondary)
            }
        case .failed:
            Text(Copy.Mcp.loadFailed).font(Font.cobalt(12.5)).foregroundStyle(CobaltColor.errorText)
            Button(Copy.Mcp.retry, systemImage: Symbol.Mcp.rotate) { Task { await reload() } }
        case let .ready(s):
            Picker(selection: Binding(get: { s.mode }, set: { ask(.mode($0)) })) {
                modeRow(Copy.Mcp.off, Copy.Mcp.offDetail, Symbol.Mcp.off).tag(McpSettings.Mode.off)
                modeRow(Copy.Mcp.publicURL, Copy.Mcp.publicDetail, Symbol.Mcp.publicURL).tag(McpSettings.Mode.public)
                modeRow(Copy.Mcp.privateLink, Copy.Mcp.privateDetail, Symbol.Mcp.privateLink).tag(McpSettings.Mode.private)
            } label: {
                Text(Copy.Mcp.how)
            }
            .pickerStyle(.inline)
            .disabled(working)

            if s.mode == .public {
                LabeledContent {
                    Text(s.publicUrl).font(Font.cobalt(12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                } label: {
                    Label(Copy.Mcp.url, systemImage: Symbol.Mcp.publicURL)
                }
                Button(copiedPublic ? Copy.Mcp.copied : Copy.Mcp.copyURL, systemImage: Symbol.Mcp.copy) {
                    Pasteboard.copy(s.publicUrl)
                    copiedPublic = true
                }
                Text(Copy.Mcp.header).font(CobaltType.captionSmall).foregroundStyle(.secondary)
            }

            if s.mode == .private, let link = s.link {
                LabeledContent {
                    Text(link.hint).font(Font.cobalt(12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                } label: {
                    Label(Copy.Mcp.link, systemImage: Symbol.Mcp.privateLink)
                }
                fact(Copy.Mcp.lastUsed, Symbol.Mcp.lastUsed, link.lastUsedAt.map(Self.when) ?? Copy.Mcp.never)
                fact(Copy.Mcp.usedBy, Symbol.Mcp.usedBy, link.usedBy ?? "\u{2014}")
                fact(Copy.Mcp.requestsToday, Symbol.Mcp.requests, "\(link.callsToday)")
                fact(Copy.Mcp.made, Symbol.Mcp.made, Self.when(link.madeAt))
                Button(working ? Copy.Mcp.working : Copy.Mcp.rotate, systemImage: Symbol.Mcp.rotate) { ask(.rotate) }
                    .disabled(working)
                Text(Copy.Mcp.steps).font(CobaltType.captionSmall).foregroundStyle(.secondary)
            }

            if let actionError {
                Text(actionError).font(Font.cobalt(12.5)).foregroundStyle(CobaltColor.errorText)
            }
        }
    }

    private func modeRow(_ title: String, _ detail: String, _ symbol: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(Font.cobalt(11.5)).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol)
        }
    }

    private func fact(_ title: String, _ symbol: String, _ value: String) -> some View {
        LabeledContent {
            Text(value).font(Font.cobalt(12.5)).foregroundStyle(.secondary).lineLimit(1)
        } label: {
            Label(title, systemImage: symbol)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: the confirm

    private var dialogShown: Binding<Bool> {
        Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
    }

    private var leavingPrivate: Bool { current?.mode == .private }

    private var dialogTitle: String {
        switch pending {
        case .mode(.private): return Copy.Mcp.confirmPrivateTitle
        case .mode(.public): return leavingPrivate ? Copy.Mcp.confirmLeaveTitle : Copy.Mcp.confirmPublicTitle
        case .mode(.off): return Copy.Mcp.confirmOffTitle
        case .rotate: return Copy.Mcp.confirmRotateTitle
        case nil: return ""
        }
    }

    private var dialogBody: String {
        switch pending {
        case .mode(.private): return Copy.Mcp.confirmPrivateBody
        case .mode(.public): return leavingPrivate ? Copy.Mcp.confirmLeaveBody : Copy.Mcp.confirmPublicBody
        case .mode(.off): return Copy.Mcp.confirmOffBody
        case .rotate: return Copy.Mcp.confirmRotateBody
        case nil: return ""
        }
    }

    private var dialogAction: String {
        switch pending {
        case .mode(.private): return Copy.Mcp.confirmPrivateAction
        case .mode(.public): return leavingPrivate ? Copy.Mcp.confirmLeaveAction : Copy.Mcp.confirmPublicAction
        case .mode(.off): return Copy.Mcp.confirmOffAction
        case .rotate: return Copy.Mcp.confirmRotateAction
        case nil: return ""
        }
    }

    private var dialogDestructive: Bool {
        switch pending {
        case .mode(.off), .rotate: return true
        case .mode(.public): return leavingPrivate
        default: return false
        }
    }

    // MARK: actions

    private func ask(_ next: Pending) {
        guard !working else { return }
        if case let .mode(mode) = next, mode == current?.mode { return }
        actionError = nil
        pending = next
    }

    private func reload() async {
        guard model.settings.hasAPIKey else { load = .hidden; return }
        if current == nil { load = .loading }
        do {
            load = .ready(try await model.mcpSettings())
        } catch {
            load = Self.hides(error) ? .hidden : .failed
        }
    }

    private func confirm() async {
        guard let next = pending, !working else { return }
        pending = nil
        working = true
        defer { working = false }
        do {
            let change: McpChange
            switch next {
            case let .mode(mode): change = try await model.setMcpMode(mode)
            case .rotate: change = try await model.rotateMcpLink()
            }
            load = .ready(change.settings)
            copiedPublic = false
            if let url = change.linkUrl { revealed = Revealed(url: url, isNew: next == .rotate) }
        } catch {
            if case let .api(code, _)? = error as? CobaltError, code == "error.mcp.not_private" {
                actionError = Copy.Mcp.notPrivate
            } else {
                actionError = Copy.Mcp.failed
            }
            await reload()
        }
    }

    /// No route on this server (an older API, a plain cobalt), or nothing to ask without a key: hide the section.
    private static func hides(_ error: Error) -> Bool {
        if case .unsupported? = error as? PipelineFailure { return true }
        if case let .api(_, status)? = error as? CobaltError, status == 404 || status == 405 { return true }
        if case .noAPIKey? = error as? CobaltError { return true }
        return false
    }

    private static func name(_ mode: McpSettings.Mode) -> McpSettingsModeName {
        switch mode {
        case .off: return .off
        case .public: return .public
        case .private: return .private
        }
    }

    private static func when(_ date: Date) -> String {
        if abs(date.timeIntervalSinceNow) < 60 { return "just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date()).lowercased()
    }
}

/// The new private link, shown once: copy it, then done.
private struct McpLinkRevealSheet: View {
    let url: String
    let isNew: Bool
    let done: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? Copy.Mcp.revealTitleNew : Copy.Mcp.revealTitle).font(CobaltType.sheetTitle)
            Text(Copy.Mcp.revealWarning).font(CobaltType.body).foregroundStyle(.secondary)
            Text(url)
                .font(Font.cobalt(13))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(Copy.Mcp.steps).font(CobaltType.captionSmall).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button(copied ? Copy.Mcp.copied : Copy.Mcp.copyLink, systemImage: Symbol.Mcp.copy) {
                    Pasteboard.copy(url)
                    copied = true
                }
                .buttonStyle(.borderedProminent)
                .haptic(.success, trigger: copied) { $0 }
                Button(Copy.Mcp.done, action: done).buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(minWidth: 320, idealWidth: 460)
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
        .interactiveDismissDisabled(!copied)
    }
}

#if DEBUG
#Preview("settings · mcp") {
    PreviewHost(.happy, tab: .settings) { model in
        Form { McpSettingsSection(model: model) }.formStyle(.grouped)
    }
}
#endif
