import CobaltKit
import SwiftUI

/// Library filter for audio loudness leveling (`features.audio_leveling`, v10.1).
enum LibraryAudioFilter: String, Hashable, CaseIterable {
    case all
    case leveled
    case needsLook

    func admits(_ row: LibraryRow) -> Bool {
        switch self {
        case .all:
            return true
        case .leveled:
            return row.item.primaryAudio?.isLeveled == true
        case .needsLook:
            guard let audio = row.item.primaryAudio else { return false }
            return audio.needsAttention || audio.isRendering
        }
    }

    var title: String {
        switch self {
        case .all: return "All audio"
        case .leveled: return "Leveled"
        case .needsLook: return "Needs a look"
        }
    }

    var symbol: String {
        switch self {
        case .all, .leveled: return "waveform"
        case .needsLook: return "speaker.wave.3.fill"
        }
    }
}

/// Compact Liquid Glass chip next to `LibraryShareMenu` for filtering leveled or out-of-range videos.
/// Hidden automatically when no videos in the current view have loudness telemetry yet and the filter is `.all`.
struct LibraryAudioFilterMenu: View {
    let rows: [LibraryRow]
    @Binding var filter: LibraryAudioFilter

    private var counts: (leveled: Int, needsLook: Int) {
        var leveled = 0
        var needsLook = 0
        for row in rows {
            guard let audio = row.item.primaryAudio else { continue }
            if audio.isLeveled { leveled += 1 }
            else if audio.needsAttention || audio.isRendering { needsLook += 1 }
        }
        return (leveled, needsLook)
    }

    var body: some View {
        let c = counts
        if c.leveled > 0 || c.needsLook > 0 || filter != .all {
            Menu {
                Picker("Audio loudness", selection: $filter) {
                    Text(LibraryAudioFilter.all.title).tag(LibraryAudioFilter.all)
                    Label(Copy.Library2.menuRow(LibraryAudioFilter.leveled.title, c.leveled), systemImage: LibraryAudioFilter.leveled.symbol)
                        .tag(LibraryAudioFilter.leveled)
                    Label(Copy.Library2.menuRow(LibraryAudioFilter.needsLook.title, c.needsLook), systemImage: LibraryAudioFilter.needsLook.symbol)
                        .tag(LibraryAudioFilter.needsLook)
                }
                .pickerStyle(.inline)
            } label: {
                chipLabel(counts: c)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Audio loudness filter")
            .accessibilityLabel("Audio loudness filter")
            .accessibilityValue(filter.title)
            .haptic(.selection, trigger: filter)
        }
    }

    @ViewBuilder
    private func chipLabel(counts: (leveled: Int, needsLook: Int)) -> some View {
        let on = filter != .all
        let tint: Color = {
            switch filter {
            case .all: return Color(hex: 0x34d399)
            case .leveled: return Color(hex: 0x34d399)
            case .needsLook: return Color(hex: 0xf87171)
            }
        }()
        let activeCount = filter == .leveled ? counts.leveled : counts.needsLook

        HStack(spacing: 5) {
            Image(systemName: filter.symbol)
                .font(.system(size: 11, weight: .bold))
            if on {
                Text(Copy.Library2.shareChip(filter.title, count: activeCount))
                    .font(Font.cobalt(11.5, .semibold, relativeTo: .caption))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Image(systemName: Symbol.Library.descending)
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.6)
            }
        }
        .foregroundStyle(on ? CobaltColor.onText : tint)
        .padding(.horizontal, 11)
        .frame(minWidth: 38, minHeight: 30)
        .contentShape(Capsule())
        .libraryGlassPill(selected: on)
        .motion(Motion.chip, value: filter)
    }
}
