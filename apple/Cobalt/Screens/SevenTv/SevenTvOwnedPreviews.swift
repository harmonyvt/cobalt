#if DEBUG
import CobaltKit
import SwiftUI

// `#Preview`s of "your emotes on 7tv" and "add to a set…" (APP-API-CONTRACT 57.14) on the preview server
// (`PreviewSevenTv.swift`): the list loaded (two uploads from the library, five made on 7tv.app: one processing, one private, one
// zero-width, one named like an emote `main` has), empty (`-previewSevenTvOwned empty`), failed (`.stageFail`, the older "your uploads"
// list stands in); the picker with three channels, a full set, a private emote (own channel only), a processing one, and the name
// clash it opens. Emote pictures come from 7TV's CDN, so most stay blank in a canvas without network.

#Preview("7tv owned · loaded", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.happy, tab: .sevenTv) { model in
        NavigationStack { SevenTvScreen(model: model, tier: .compact, segment: .upload) }
    }
}
#Preview("7tv owned · loaded, dark", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.happy, tab: .sevenTv) { model in
        NavigationStack { SevenTvScreen(model: model, tier: .compact, segment: .upload) }
    }
    .preferredColorScheme(.dark)
}
#Preview("7tv owned · empty", traits: .fixedLayout(width: 390, height: 640)) {
    OwnedMode("empty") {
        PreviewHost(.happy, tab: .sevenTv) { model in
            NavigationStack { SevenTvScreen(model: model, tier: .compact, segment: .upload) }
        }
    }
}
#Preview("7tv owned · failed", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.stageFail, tab: .sevenTv) { model in
        NavigationStack { SevenTvScreen(model: model, tier: .compact, segment: .upload) }
    }
}
#Preview("7tv owned · AX3 text", traits: .fixedLayout(width: 390, height: 1100)) {
    PreviewHost(.happy, tab: .sevenTv) { model in
        NavigationStack { SevenTvScreen(model: model, tier: .compact, segment: .upload) }
    }
    .dynamicTypeSize(.accessibility3)
}
#Preview("7tv owned · mac", traits: .fixedLayout(width: 1180, height: 760)) {
    PreviewHost(.happy, tab: .sevenTv) { model in
        NavigationStack {
            SevenTvScreen(model: model, tier: .wide, segment: .upload)
        }
    }
}

/// Sets the preview server's `previewSevenTvOwned` flag while its content shows (the flag is read when the list is asked for).
private struct OwnedMode<Content: View>: View {
    let mode: String
    @ViewBuilder let content: () -> Content
    @State private var ready = false

    init(_ mode: String, @ViewBuilder content: @escaping () -> Content) {
        self.mode = mode
        self.content = content
    }

    var body: some View {
        Group {
            if ready { content() } else { Color.clear }
        }
        .task {
            UserDefaults.standard.set(mode, forKey: "previewSevenTvOwned")
            ready = true
        }
        .onDisappear { UserDefaults.standard.removeObject(forKey: "previewSevenTvOwned") }
    }
}

// MARK: - the picker

/// Loads the account and its owned emotes, makes the picker for the one named `emote`, and shows its sheet. `pick`: the set
/// (by name) to add to first, so the sheet opens with the result line and the set marked.
private struct LoadedPicker: View {
    let model: AppModel
    let emote: String
    var pick: String?
    var clashing = false
    /// The channel (by name) picked first.
    var channel: String?

    @State private var picker: SevenTvAddToSetModel?
    @State private var clash: (SevenTvAddToSetModel, SevenTvSetModel, SevenTvNameClash)?

    var body: some View {
        Group {
            if let clash {
                SevenTvClashSheet(emoteSet: clash.1, clash: clash.2)
            } else if let picker {
                SevenTvAddToSetSheet(picker: picker)
            } else {
                Color.clear
            }
        }
        .task {
            await model.sevenTv.load()
            await model.sevenTv.loadOwned()
            guard let owned = model.sevenTv.owned.first(where: { $0.name == emote }) else { return }
            let made = model.sevenTv.addToSetPicker(for: owned)
            await made.prepare()
            if let channel, let found = made.channels.first(where: { $0.name == channel }) { await made.pickChannel(found.id) }
            if clashing {
                guard let row = made.sets.first(where: { $0.live }), let target = made.setModel(for: row),
                      case .clash(let found) = await made.add(to: row) else { return }
                clash = (made, target, found)
                return
            }
            if let pick, let row = made.sets.first(where: { $0.name == pick }) { _ = await made.add(to: row) }
            picker = made
        }
    }
}

#Preview("7tv add to a set · channels and sets", traits: .fixedLayout(width: 390, height: 720)) {
    PreviewHost(.happy, tab: .sevenTv) { model in
        LoadedPicker(model: model, emote: "peepoSpin")
    }
}
#Preview("7tv add to a set · added, dark", traits: .fixedLayout(width: 390, height: 720)) {
    PreviewHost(.happy, tab: .sevenTv) { model in
        LoadedPicker(model: model, emote: "peepoSpin", pick: "christmas")
    }
    .preferredColorScheme(.dark)
}
#Preview("7tv add to a set · a full set", traits: .fixedLayout(width: 390, height: 640)) {
    PreviewHost(.happy, tab: .sevenTv) { model in
        LoadedPicker(model: model, emote: "peepoSpin", channel: "mochi_vt")
    }
}
#Preview("7tv add to a set · private, own channel only", traits: .fixedLayout(width: 390, height: 640)) {
    PreviewHost(.happy, tab: .sevenTv) { model in
        LoadedPicker(model: model, emote: "catBonk")
    }
}
#Preview("7tv add to a set · still processing", traits: .fixedLayout(width: 390, height: 640)) {
    PreviewHost(.happy, tab: .sevenTv) { model in
        LoadedPicker(model: model, emote: "coffeeSteam")
    }
}
#Preview("7tv add to a set · name clash", traits: .fixedLayout(width: 390, height: 640)) {
    PreviewHost(.happy, tab: .sevenTv) { model in
        LoadedPicker(model: model, emote: "Clap", clashing: true)
    }
}
#Preview("7tv add to a set · AX3 text", traits: .fixedLayout(width: 390, height: 1100)) {
    PreviewHost(.happy, tab: .sevenTv) { model in
        LoadedPicker(model: model, emote: "peepoSpin")
    }
    .dynamicTypeSize(.accessibility3)
}
#Preview("7tv add to a set · mac", traits: .fixedLayout(width: 460, height: 600)) {
    PreviewHost(.happy, tab: .sevenTv) { model in
        LoadedPicker(model: model, emote: "peepoSpin")
    }
}
#endif
