import SwiftUI

/// How far the library's top bar has folded away: the iPhone's search field, the kind and share chips, the album note
/// and the loading and search lines (everything in the screen's top inset; the toolbar buttons are the system's).
///
/// The bar follows the finger: scrolling down slides it up under the navigation bar point for point, scrolling back
/// brings it down again from anywhere in the library, and at the very top it is always fully open. When the scroll
/// stops halfway, it settles open or folded, whichever is nearer.
///
/// The bar keeps its full height in layout and only moves on screen. The scroll view's top inset therefore never
/// changes while the bar folds, so the scroll offset this reads is never moved by the fold itself (no feedback loop);
/// the tiles simply show through where the bar was.
@MainActor @Observable
final class LibraryBarFold {
    /// Points the bar has slid up: 0 open, `height` folded.
    private(set) var offset: CGFloat = 0
    /// The bar's full height (measured).
    var height: CGFloat = 0 {
        didSet { if offset > height { offset = height } }
    }
    /// Held open while the search field has the keyboard.
    var held = false {
        didSet { if held, offset > 0 { withAnimation(Motion.card) { offset = 0 } } }
    }

    /// The last distance from the top the scroll view reported; nil until the next report after a reset.
    @ObservationIgnored private var lastDistance: CGFloat?

    /// 0 open ... 1 folded.
    var progress: CGFloat { height > 0 ? min(max(offset / height, 0), 1) : 0 }

    /// The scroll view's distance from its top (`contentOffset.y + contentInsets.top`; 0 at rest at the top).
    func scrolled(to distance: CGFloat) {
        defer { lastDistance = distance }
        guard let last = lastDistance, !held, height > 0 else { return }
        // follow the finger, never past fully open or fully folded, and never folded further than the scroll has gone
        // (so the top of the library always shows the whole bar)
        let next = min(max(offset + (distance - last), 0), height, max(distance, 0))
        if next != offset { offset = next }
    }

    /// The scroll came to rest: a half-folded bar settles open or folded, whichever is nearer.
    func settle(reduceMotion: Bool) {
        guard offset > 0, offset < height else { return }
        let fold = offset > height / 2 && (lastDistance ?? 0) >= height
        withAnimation(reduceMotion ? Motion.fade : Motion.card) { offset = fold ? height : 0 }
    }

    /// A different scroll view (view mode, phase): open, and forget the old one's position.
    func reset() {
        lastDistance = nil
        if offset != 0 { offset = 0 }
    }
}

extension View {
    /// Reports this scroll view's movement to the library's top bar so it folds with the scroll.
    func libraryBarFold(_ fold: LibraryBarFold) -> some View {
        modifier(LibraryBarFoldReporter(fold: fold))
    }
}

private struct LibraryBarFoldReporter: ViewModifier {
    let fold: LibraryBarFold
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, distance in
                fold.scrolled(to: distance)
            }
            .onScrollPhaseChange { _, phase in
                if phase == .idle { fold.settle(reduceMotion: reduceMotion) }
            }
            .onAppear { fold.reset() }
    }
}

/// The top bar's fold on screen: measures the bar, slides it up by the fold and clips it at its own top edge, so it
/// tucks under the navigation bar. The rows' `.bar` backgrounds reach up under the navigation bar while open; once the
/// bar moves, a strip of the same material holds that place so the navigation bar does not change.
struct LibraryBarFoldEffect: ViewModifier {
    let fold: LibraryBarFold

    func body(content: Content) -> some View {
        let offset = fold.offset
        let moving = offset > 0
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fold.height = $0 }
            .offset(y: -offset)
            .opacity(1 - fold.progress * 0.5)
            // while open nothing is clipped (exactly the bar as it always was)
            .mask(alignment: .top) {
                Rectangle()
                    .padding(.top, moving ? 0 : -1000)
                    .padding([.horizontal, .bottom], -1000)
            }
            .background(alignment: .top) {
                if moving {
                    Color.clear.frame(height: 0).background(.bar)
                }
            }
            .accessibilityHidden(fold.progress >= 1)
    }
}

/// `.searchable` where the system's field is used (iPad, Mac); nothing on the iPhone, which has `LibrarySearchField`.
struct LibrarySearchable: ViewModifier {
    @Binding var text: String
    let placement: SearchFieldPlacement
    let prompt: String
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $text, placement: placement, prompt: prompt)
        } else {
            content
        }
    }
}

#if os(iOS)
/// The iPhone's search field, in the top bar so it folds away with the chips (the system's drawer search field
/// stays put in the navigation bar). Same binding and prompt as the iPad's and Mac's `.searchable`.
struct LibrarySearchField: View {
    @Binding var text: String
    let prompt: String
    let fold: LibraryBarFold
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .focused($focused)
                .submitLabel(.search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { focused = false }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Copy.Search.clearField)
                .transition(.opacity)
            }
        }
        .font(CobaltType.body)
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .motion(Motion.copy, value: text.isEmpty)
        .onChange(of: focused) { _, now in fold.held = now }
        // The bar outlives this field only by identity: if anything above rebuilds it while it has the keyboard
        // (`fold.held`), the new field takes the keyboard back at once instead of dropping it mid-word.
        .onAppear { if fold.held, !focused { focused = true } }
        .accessibilityElement(children: .contain)
    }
}
#endif
