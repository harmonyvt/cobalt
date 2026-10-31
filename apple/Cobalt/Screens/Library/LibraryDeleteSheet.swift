import CobaltKit
import SwiftUI

/// The select panel's trash circle: a sheet listing the picks, each going whole by default. A post with more than one file
/// has `choose files`, a grid of its files to tick (a gallery's photos while one stays, what was made from it, a video's
/// webps); the video itself only goes with everything. One destructive button deletes what is ticked, for everyone
/// (`AppModel.delete(_:)`, the calls the detail's deletes use).
struct LibraryDeleteSheet: View {
    let picks: [MediaItem]
    let delete: ([DeletePick]) -> Void

    @State private var plans: [DeletePick]
    @State private var open: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    init(picks: [MediaItem], delete: @escaping ([DeletePick]) -> Void) {
        self.picks = picks
        self.delete = delete
        _plans = State(initialValue: picks.map { DeletePick(item: $0) })
        // one pick with files to choose opens on them
        _open = State(initialValue: picks.count == 1 && DeletePick(item: picks[0]).canChoose ? [picks[0].id] : [])
    }

    private var files: Int { plans.reduce(0) { $0 + $1.fileCount } }
    private var blocked: Bool { plans.contains { $0.plan == .keepOneItem } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(Copy.DeletePicks.message)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                        .padding(.horizontal, 4)
                    ForEach($plans, id: \.item.id) { $plan in
                        PickRow(plan: $plan, open: openBinding(plan.item.id))
                    }
                }
                .padding(16)
            }
            .safeAreaInset(edge: .bottom) { deleteButton }
            .navigationTitle(Copy.DeletePicks.title(picks.count))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Copy.Media.keep) { dismiss() }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #else
        .frame(minWidth: 460, minHeight: 520)
        #endif
    }

    private func openBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { open.contains(id) }, set: { on in
            withAnimation(Motion.rows) { if on { open.insert(id) } else { open.remove(id) } }
        })
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            let chosen = plans.filter { $0.plan != .nothing }
            dismiss()
            delete(chosen)
        } label: {
            Label(Copy.DeletePicks.button(files), systemImage: Symbol.Library.deleteEverything)
                .labelStyle(.titleAndIcon)
                .font(CobaltType.bodySemibold)
                .frame(maxWidth: .infinity, minHeight: 48)
                .foregroundStyle(Color.white)
                .background(CobaltColor.errorText, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(files == 0 || blocked)
        .opacity(files == 0 || blocked ? 0.4 : 1)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

/// One pick: its face, title and what goes; the circle ticks the whole post; `choose files` opens its files.
private struct PickRow: View {
    @Binding var plan: DeletePick
    @Binding var open: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(Motion.rows) { plan.toggleEverything() }
                } label: {
                    Image(systemName: tick(plan.plan == .everything, partly: plan.fileCount > 0))
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(plan.plan == .nothing ? CobaltColor.caption : CobaltColor.errorText)
                        .frame(width: 32, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Copy.DeletePicks.everything)
                .accessibilityAddTraits(plan.plan == .everything ? .isSelected : [])
                FacePicture(item: plan.item, maxPixel: 128, showsGlyph: false)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.item.titleText)
                        .font(CobaltType.bodySemibold)
                        .foregroundStyle(CobaltColor.text)
                        .lineLimit(1)
                    Text(Copy.DeletePicks.line(plan.plan, files: plan.fileCount, of: plan.choosable.count))
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(plan.plan == .keepOneItem ? CobaltColor.errorText : CobaltColor.caption)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 4)
                if plan.canChoose {
                    Button { open.toggle() } label: {
                        Label(Copy.DeletePicks.choose, systemImage: open ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.cobaltIcon(.small))
                }
            }
            if open, plan.canChoose {
                FileGrid(plan: $plan)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(CobaltColor.elevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func tick(_ on: Bool, partly: Bool) -> String {
        on ? "checkmark.circle.fill" : (partly ? "minus.circle.fill" : "circle")
    }
}

/// The post's files that can go one by one, each with a tick; a line says the video goes only with everything.
private struct FileGrid: View {
    @Binding var plan: DeletePick

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64, maximum: 84), spacing: 8)], spacing: 8) {
                ForEach(plan.choosable) { r in
                    let on = plan.isChosen(r.id)
                    Button {
                        withAnimation(Motion.rows) { plan.toggle(r.id) }
                    } label: {
                        VStack(spacing: 3) {
                            FileTile(rendition: r)
                                .frame(height: 72)
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(on ? CobaltColor.errorText : Color.clear, lineWidth: 2)
                                }
                                .overlay(alignment: .topTrailing) {
                                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 17, weight: .semibold))
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(Color.white, on ? CobaltColor.errorText : Color.black.opacity(0.35))
                                        .padding(3)
                                }
                                .opacity(on ? 1 : 0.6)
                            Text(r.itemLabel ?? r.tabName)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(CobaltColor.caption)
                                .lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(r.itemLabel ?? r.tabName)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            if plan.item.video != nil {
                Text(Copy.DeletePicks.videoGoesWithEverything)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
            }
        }
    }
}

/// A file's picture: the device's poster or file, else the server's poster or the file itself, else a glyph.
private struct FileTile: View {
    let rendition: Rendition

    var body: some View {
        ZStack {
            Rectangle().fill(CobaltColor.elevated)
            Image(systemName: rendition.isWebp || rendition.isAnimatedMade ? "sparkles" : "photo")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(CobaltColor.caption)
            picture
        }
    }

    @ViewBuilder
    private var picture: some View {
        let fm = FileManager.default
        let r = rendition
        if let poster = r.local?.posterURL, fm.fileExists(atPath: poster.path) {
            StillImage(url: poster)
        } else if let file = r.local?.fileURL, r.isStillPicture || r.isWebp, fm.fileExists(atPath: file.path) {
            StillImage(url: file)
        } else if let poster = r.posterURL {
            RemoteStill(poster: RemotePoster(url: HeroSource.resolve(poster), isVideo: false), maxPixel: 200)
        } else if let url = r.publicURL ?? r.file?.url {
            RemoteStill(poster: RemotePoster(url: HeroSource.resolve(url), isVideo: r.isMotionItem), maxPixel: 200)
        }
    }
}
