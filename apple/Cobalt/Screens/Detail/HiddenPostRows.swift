import CobaltKit
import SwiftUI

// Hidden posts in a post's detail (APP-API-CONTRACT 37.5, 37.7): the `hidden by` row, the status change both link
// sections share, and the post-level hidden section for a gallery (whose link is the post's own switch, not a file's).

/// What `DetailController.setPostStatus` came to.
enum PostStatusResult {
    /// The server did not change the post: words are under the section.
    case failed
    /// The post took the status.
    case changed
    /// The post took the status but a file could not be switched (hidden, but a public copy is still on).
    case filesFailed

    var changed: Bool { self != .failed }

    /// What the shell's status line says for the new status.
    func words(for status: PostStatus) -> String {
        switch (self, status) {
        case (.filesFailed, .hidden): return Copy.Hidden.hiddenFileFailed
        case (.filesFailed, _): return Copy.Hidden.unhiddenFileFailed
        case (_, .hidden): return Copy.Hidden.hiddenStatus
        default: return Copy.Hidden.unhiddenStatus
        }
    }
}

extension DetailController {
    /// Gives the post the status (`hidden`, or `off` to unhide). The library moves the post between its list and the
    /// album once the server answered. `.failed` with words under the section (`visibilityFailed[key]`) when it did not.
    @discardableResult
    func setPostStatus(_ status: PostStatus, post: LibraryPost, key: String) async -> PostStatusResult {
        visibilityFailed[key] = nil
        let outcome = await model.library.setStatus(status, posts: [post])
        guard outcome.changed > 0 else {
            visibilityFailed[key] = status == .hidden ? Copy.Hidden.hideFailed : Copy.Hidden.unhideFailed
            return .failed
        }
        return outcome.fileFailures.isEmpty ? .changed : .filesFailed
    }
}

/// "hidden by": `you`, `rule: <the rule's value>` (`a rule` when the rule is gone) or `the chat`. The rules are read once
/// when a rule hid the post and none are loaded yet.
struct HiddenByRow: View {
    let model: AppModel
    let post: LibraryPost

    private var rule: HideRule? {
        post.hiddenRule.flatMap { id in model.hiddenRules.rules.first { $0.id == id } }
    }

    private var words: String {
        switch post.hiddenBy {
        case .chat: return Copy.Hidden.byChat
        case .rule: return Copy.Hidden.byRule(rule)
        case .you, nil: return Copy.Hidden.byYou
        }
    }

    var body: some View {
        LabeledContent {
            Text(words)
                .font(Font.cobalt(12.5)).foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing).lineLimit(2)
        } label: {
            Label(Copy.Hidden.hiddenBy, systemImage: post.hiddenBy == .rule ? Symbol.HiddenRules.rule : Symbol.HiddenRules.by)
        }
        .accessibilityElement(children: .combine)
        .task(id: post.hiddenRule) {
            guard post.hiddenBy == .rule, rule == nil, model.hiddenRules.rules.isEmpty else { return }
            await model.hiddenRules.load()
        }
    }
}

/// A gallery post's hidden state (its link is the post's own switch): hiding is a `hide this post…` row under the switch;
/// a hidden post shows this section in the switch's place, with who hid it and `unhide`.
struct HiddenPostSection: View {
    let controller: DetailController
    let post: LibraryPost

    @State private var asking = false
    @Environment(\.shell) private var shell

    private var model: AppModel { controller.model }
    private var changing: Bool { model.library.statusInFlight }
    private var key: String { DetailController.postKey + ".status" }

    var body: some View {
        Section {
            if post.hidden {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Copy.Hidden.row)
                        Text(Copy.Hidden.rowDetail).font(Font.cobalt(11.5)).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: Symbol.HiddenRules.hidden)
                }
                HStack(spacing: 10) {
                    HiddenByRow(model: model, post: post)
                    Button { asking = true } label: {
                        Label(Copy.Hidden.unhide, systemImage: Symbol.HiddenRules.unhide)
                    }
                    .buttonStyle(.cobaltIcon(.small))
                    .disabled(changing || controller.isDeleting)
                }
            } else {
                Button(Copy.Hidden.hidePost, systemImage: Symbol.HiddenRules.hidden) { asking = true }
                    .disabled(changing || controller.isDeleting)
            }
        } footer: {
            if let failed = controller.visibilityFailed[key] {
                Text(failed).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.errorText).lineSpacing(2)
            } else if changing {
                Text(Copy.Hidden.working).font(CobaltType.captionSmall).foregroundStyle(.secondary)
            } else if post.hidden {
                Text(Copy.Hidden.note).font(CobaltType.captionSmall).foregroundStyle(.secondary).lineSpacing(2)
            }
        }
        .motion(Motion.rows, value: post.hidden)
        .confirmationDialog(
            post.hidden ? Copy.Hidden.unhideTitle : Copy.Hidden.hideTitle, isPresented: $asking, titleVisibility: .visible
        ) {
            if post.hidden {
                Button(Copy.Hidden.unhide) { run(.off) }
            } else {
                Button(Copy.Hidden.hideConfirm, role: .destructive) { run(.hidden) }
            }
            Button(Copy.Hidden.cancel, role: .cancel) {}
        } message: {
            Text(post.hidden ? Copy.Hidden.unhideMessage : Copy.Hidden.hideMessage)
        }
    }

    private func run(_ status: PostStatus) {
        guard !changing else { return }
        Task {
            let result = await controller.setPostStatus(status, post: post, key: key)
            if result.changed { shell.showStatus(result.words(for: status)) }
        }
    }
}
