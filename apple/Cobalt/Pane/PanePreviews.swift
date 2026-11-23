#if DEBUG
import CobaltKit
import SwiftUI

// `#Preview`s of the pane's content primitive in every shape (tall, wide, split on a wide and a tall Duo, the bar),
// at AX3 text, loading and gone; and the whole host on the preview server: an iPhone (sheet), a wide Duo, an iPad
// column, with a page open.

private struct SamplePage: View {
    var body: some View {
        PanePage(
            title: "the harbour, before the wind came up and everyone left",
            subtitle: "video · 0:42 · saved from tiktok",
            actions: [PaneAction("share", systemImage: "square.and.arrow.up") {}],
            more: [PaneAction("rename", systemImage: "pencil") {},
                   PaneAction("delete", systemImage: "trash", role: .destructive) {}],
            progress: 0.42
        ) {
            LinearGradient(colors: [CobaltColor.frameTop, CobaltColor.frameBottom], startPoint: .top, endPoint: .bottom)
                .aspectRatio(9 / 16, contentMode: .fit)
        } controls: {
            PaneActionGrid([
                PaneAction("copy link", systemImage: "link", needsServer: true) {},
                PaneAction("make webp", systemImage: "photo.stack", needsServer: true) {},
                PaneAction("edit", systemImage: "scissors") {},
                PaneAction("save to photos", systemImage: "square.and.arrow.down") {},
            ])
        } body: {
            Text("tags · harbour · wind · evening")
                .font(CobaltType.caption)
                .foregroundStyle(CobaltColor.caption)
                .padding(.horizontal, 16)
        } shelf: {
            PaneCard("transcript") { Text("…and then the whole pier just emptied.").font(CobaltType.body) }
            PaneCard("links") { Text("in 2 links").font(CobaltType.body) }
            PaneCard("names") { Text("harbour, evening").font(CobaltType.body) }
        }
    }
}

private struct ShapeHost<Content: View>: View {
    let shape: PaneShape
    var hinge: PaneHinge?
    var state: PaneState = .screen
    @ViewBuilder let content: Content
    @State private var pane = Pane(route: PaneRoute(item: .post("p1"), state: .screen))

    var body: some View {
        // the page alone in its shape (the header is the host's: see the host previews below)
        content
            .environment(\.paneShape, shape)
            .environment(\.paneHinge, hinge)
            .environment(\.paneHeaderHeight, PaneChrome.headerHeight)
            .background(CobaltColor.bg)
            .environment(pane)
            .onAppear { if state == .span { pane.span() } }
    }
}

#Preview("page · tall", traits: .fixedLayout(width: 440, height: 900)) {
    ShapeHost(shape: .tall) { SamplePage() }
}
#Preview("page · tall, dark, AX3", traits: .fixedLayout(width: 440, height: 900)) {
    ShapeHost(shape: .tall) { SamplePage() }
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility3)
}
#Preview("page · wide", traits: .fixedLayout(width: 1000, height: 560)) {
    ShapeHost(shape: .wide, state: .span) { SamplePage() }
}
#Preview("page · split, wide duo", traits: .fixedLayout(width: 1080, height: 800)) {
    ShapeHost(shape: .split(.media), hinge: PaneHinge(axis: .vertical, position: 540), state: .span) { SamplePage() }
}
#Preview("page · split, tall duo", traits: .fixedLayout(width: 640, height: 900)) {
    ShapeHost(shape: .split(.media), hinge: PaneHinge(axis: .horizontal, position: 450), state: .span) { SamplePage() }
}
#Preview("page · bar", traits: .fixedLayout(width: 402, height: 64)) {
    SamplePage()
        .environment(\.paneShape, .bar)
        .environment(Pane())
}
#Preview("page · loading", traits: .fixedLayout(width: 440, height: 900)) {
    ShapeHost(shape: .tall) { PaneLoadingPage() }
}
#Preview("page · gone", traits: .fixedLayout(width: 440, height: 600)) {
    ShapeHost(shape: .tall) { PaneGonePage() }
}
#Preview("page · offline", traits: .fixedLayout(width: 440, height: 900)) {
    ShapeHost(shape: .tall) { SamplePage().environment(\.paneOffline, true) }
}

private struct HostPreview: View {
    let item: PaneItem
    var state: PaneState = .screen
    @State private var pane = Pane()

    var body: some View {
        PreviewHost(.happy, tab: .library) { model in
            PaneHost(model: model) {
                NavigationStack { LinksScreen(model: model) }
            }
        }
        .environment(pane)
        .onAppear {
            pane.open(item)
            if state == .span { pane.span() }
        }
    }
}

#Preview("host · iphone, sheet", traits: .fixedLayout(width: 402, height: 874)) {
    HostPreview(item: .link("l1"))
}
#Preview("host · ipad column", traits: .fixedLayout(width: 1376, height: 1032)) {
    HostPreview(item: .stream("ninja"))
}
#Preview("host · spanned", traits: .fixedLayout(width: 1376, height: 1032)) {
    HostPreview(item: .booruPost(4821), state: .span)
}
#endif
