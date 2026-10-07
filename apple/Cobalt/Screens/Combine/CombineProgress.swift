import CobaltKit
import SwiftUI

/// What the sheet shows once a make is asked for: waiting (for the save, for the server's line), making with a bar, done
/// with where the file landed, or failed with the settings kept (board `Gallery-Combine`). The make is a job of the
/// queue, so closing the sheet at any of these never stops it.
struct CombineProgress: View {
    let combine: CombineModel
    let phase: CombinePhase

    var body: some View {
        switch phase {
        case .edit:
            EmptyView()
        case .afterSave(let m, let done, let total):
            working(
                head: Copy.Gallery.afterTheSave(done, of: total), sub: Copy.Combine.afterSaveSub, fraction: nil, make: m)
        case .sending(let m):
            working(head: Copy.Combine.sendingHead, sub: Copy.Combine.sendingSub, fraction: nil, make: m)
        case .queued(let m, let ahead):
            let place = ahead + 1
            working(
                head: "\(Copy.Combine.waitingForTheServer) · \(Copy.Jobs.line(place))",
                sub: Copy.Combine.queuedSub, fraction: nil, make: m, line: place)
        case .making(let m, let fraction):
            working(
                head: Copy.Gallery.making(CombineOutput(m).what, Int((fraction * 100).rounded())),
                sub: Copy.Combine.makingSub(server: combine.serverText), fraction: fraction, make: m)
        case .done(let m, let result):
            done(m, result)
        case .failed(let m, let failure):
            failed(m, failure)
        }
    }

    // MARK: waiting and making

    private func working(head: String, sub: String, fraction: Double?, make: GalleryMake, line: Int? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(head).font(CobaltType.bodySemibold)
            if let line, case .slideshow(let plan) = make, plan.format == .webp, line == 2 {
                Text(Copy.Jobs.lineDetail(place: line, webpNext: true))
                    .font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption)
            }
            Text(sub)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
                .fixedSize(horizontal: false, vertical: true)
            StoryBar(fraction: fraction)
            Text(combine.summary)
                .font(CobaltType.captionSmall)
                .monospacedDigit()
                .foregroundStyle(CobaltColor.caption)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: done

    private func done(_ m: GalleryMake, _ result: MadeResult) -> some View {
        let names = CombineModel.names(of: m)
        return VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(Copy.Gallery.addedAsTab(names.tab)).font(CobaltType.bodySemibold)
            } icon: {
                Image(systemName: Symbol.checkmark).foregroundStyle(CobaltColor.success)
            }
            if combine.keepsOnDevice {
                note(Copy.Combine.inFolder(title: combine.title, file: names.file, folder: combine.app.macFolder.status.path))
            }
            note(doneNumbers(m, result))
            note(Copy.Combine.oneSwitch)
            note(Copy.Combine.tabsSoFar(combine.tabsSoFar(adding: names.tab)))
            Button(Copy.Gallery.makeAnother) { combine.backToEditing() }
                .buttonStyle(.cobaltPrimary())
                .padding(.top, 6)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    /// The real numbers of the file that came back (the estimate said "about").
    private func doneNumbers(_ m: GalleryMake, _ result: MadeResult) -> String {
        let size = result.bytes.map(Copy.Gallery.size)
        switch m {
        case .slideshow:
            return ["length \(Copy.Gallery.length(result.seconds ?? combine.length))", size].compactMap { $0 }.joined(separator: " · ")
        case .image:
            let dims = result.width.flatMap { w in result.height.map { "\(w) × \($0)" } }
            return [dims, size].compactMap { $0 }.joined(separator: " · ")
        }
    }

    // MARK: failed

    private func failed(_ m: GalleryMake, _ failure: PipelineFailure) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Copy.Combine.failed(failure, what: CombineOutput(m).what))
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.errorText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
            ButtonRow {
                Button(Copy.tryAgain, systemImage: Symbol.Gallery.retry) { combine.retry() }
                    .buttonStyle(.cobaltPrimary())
                Button(Copy.Combine.changeSettings) { combine.backToEditing() }
                    .buttonStyle(.cobaltSecondary())
            }
        }
        .padding(.vertical, 4)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(CobaltType.captionSmall)
            .foregroundStyle(CobaltColor.caption)
            .fixedSize(horizontal: false, vertical: true)
    }
}
