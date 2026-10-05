import CobaltKit
import SwiftUI

/// The rename alert (CONTRACT-LIBRARY2 decision 5): `rename`, a field prefilled with the current title, the
/// message `leave it empty to use "<default>".` (plus `only on this iphone until the server is updated.` on a
/// fork whose server cannot keep it), `save` and `cancel`. The field holds at most 80 characters. Saving the
/// default text, or nothing, clears the custom title. Optimistic through `AppModel.rename`; a failure reverts it
/// and says `couldn't rename that. try again.` (the library's status line, or whatever `failed` does).
///
/// Used by the library's context menu and by the detail's title menu.
private struct RenameAlert: ViewModifier {
    let model: AppModel
    let item: MediaItem
    @Binding var isPresented: Bool
    var failed: (@MainActor (String) -> Void)?

    @State private var draft = ""
    @Environment(\.shell) private var shell

    private var localOnly: Bool {
        model.capabilities.library && !model.capabilities.titles && item.post != nil
    }

    private var message: String {
        var text = Copy.Library2.renameMessage(default: item.defaultTitleText)
        if localOnly { text += " " + Copy.Library2.renameLocalOnly }
        let count = draft.unicodeScalars.count
        if count >= 60 { text += "\n" + Copy.Library2.titleCount(count) }
        return text
    }

    func body(content: Content) -> some View {
        content
            .alert(Copy.Library2.renameTitle, isPresented: $isPresented) {
                TextField(Copy.Library2.titleField, text: $draft)
                    .accessibilityLabel(Copy.Library2.titleField)
                Button(Copy.Library2.save) { commit() }
                Button(Copy.Library2.cancel, role: .cancel) {}
            } message: {
                Text(message)
            }
            .onChange(of: isPresented) { _, now in
                if now { draft = item.titleText }
            }
            .onChange(of: draft) { _, text in
                let cut = RenameAlertText.capped(text)
                if cut != text { draft = cut }
            }
    }

    private func commit() {
        let text = draft
        let item = item
        let model = model
        let report = failed ?? { shell.showStatus($0) }
        Task {
            do {
                try await model.rename(item, to: text)
            } catch {
                report(Copy.Library2.renameFailed)
            }
        }
    }
}

enum RenameAlertText {
    /// At most 80 Unicode code points, cut on a `Character` boundary (never inside a grapheme), without trimming
    /// (the field is still being typed in).
    static func capped(_ text: String, limit: Int = MediaTitle.maxLength) -> String {
        guard text.unicodeScalars.count > limit else { return text }
        var out = ""
        var count = 0
        for character in text {
            let n = character.unicodeScalars.count
            if count + n > limit { break }
            out.append(character)
            count += n
        }
        return out
    }
}

extension View {
    /// The rename alert for one media; `isPresented` turns it on. (T's detail title menu uses this one.)
    func renameAlert(
        item: MediaItem, isPresented: Binding<Bool>, model: AppModel, failed: (@MainActor (String) -> Void)? = nil
    ) -> some View {
        modifier(RenameAlert(model: model, item: item, isPresented: isPresented, failed: failed))
    }

    /// The same, presented while `item` is non-nil (the library's context menu sets it).
    func renameAlert(item: Binding<MediaItem?>, model: AppModel) -> some View {
        modifier(RenameAlertForOptional(model: model, item: item))
    }
}

/// Holds the media being renamed across the alert's dismissal (the alert closes by clearing the binding).
private struct RenameAlertForOptional: ViewModifier {
    let model: AppModel
    @Binding var item: MediaItem?
    @State private var shown: MediaItem?
    @State private var presented = false

    func body(content: Content) -> some View {
        content
            .renameAlert(item: shown ?? placeholder, isPresented: $presented, model: model)
            .onChange(of: item?.id, initial: true) { _, id in
                if id != nil, let item {
                    shown = item
                    presented = true
                }
            }
            .onChange(of: presented) { _, now in
                if !now { item = nil }
            }
    }

    /// The alert needs a media before the first request; it is never shown with this one.
    private var placeholder: MediaItem {
        MediaItem(id: "", local: nil, post: nil, service: nil, ref: nil, link: nil, renditions: [
            Rendition(id: "video", kind: .video, createdAt: .distantPast)])
    }
}
