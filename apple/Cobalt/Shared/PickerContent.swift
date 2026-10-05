import CobaltKit
import SwiftUI

/// "select what to save": the picker for a post with more than one thing in it. Used by the home
/// sheet and, inline, by the share sheet.
struct PickerContent: View {
    let pipeline: Pipeline
    let items: [PickerItem]
    /// "webp" only on a fork with studio and upload, and only on videos and gifs.
    let webpAvailable: Bool
    @Environment(\.hapticsEnabled) private var haptics

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(Copy.pickerTitle)
                    .font(CobaltType.sheetTitle)
                    .foregroundStyle(CobaltColor.text)
                    .accessibilityAddTraits(.isHeader)
                Text(Copy.pickerNote)
                    .font(Font.cobalt(12.5, .regular, relativeTo: .footnote))
                    .foregroundStyle(CobaltColor.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(items) { item in cell(item) }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            VStack(spacing: 10) {
                Button(pipeline.photos == .done ? Copy.savedPhotos : Copy.saveAll(items.count),
                       systemImage: pipeline.photos == .done ? Symbol.checkmark : Symbol.savePhotos) {
                    pipeline.saveAllPickerItemsToPhotos()
                }
                .buttonStyle(pipeline.photos == .done ? .cobaltDone() : .cobaltPrimary())
                .symbolBounce(on: pipeline.photos == .done)
                .disabled(pipeline.photos == .working)
                Text(Copy.pickerFooter)
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.caption)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .haptic(.success, trigger: pipeline.photos, enabled: haptics) { $0 == .done }
        .haptic(.error, trigger: pipeline.photos, enabled: haptics) { if case .failed = $0 { return true } else { return false } }
    }

    private func cell(_ item: PickerItem) -> some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                Rectangle().fill(FrameGradient.fill(item.type == .photo ? 1 : 0))
                if let thumb = item.thumb {
                    AsyncImage(url: thumb) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() }
                    }
                }
                Text(Copy.badge(item.type))
                    .font(Font.cobalt(11, .medium, relativeTo: .caption2))
                    .foregroundStyle(CobaltColor.badgeInk)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(8)
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
            .accessibilityHidden(true)
            ButtonRow {
                Button(Copy.save, systemImage: Symbol.savePhotos) { pipeline.choose(item, .save) }
                    .buttonStyle(.cobaltPrimary())
                    .accessibilityLabel("\(Copy.save) \(Copy.badge(item.type)) \(item.id + 1)")
                if webpAvailable && item.canWebp {
                    Button(Copy.webp, systemImage: Symbol.makeWebp) { pipeline.choose(item, .webp) }
                        .buttonStyle(.cobaltSecondary())
                        .accessibilityLabel("\(Copy.webp) \(Copy.badge(item.type)) \(item.id + 1)")
                }
            }
            .disabled(pipeline.photos == .working)
        }
    }
}
