import CobaltKit
import SwiftUI

// The trim settings of a run (quality, width, make webp, what was made from the video) used to be a native `.inspector`
// column here (`InspectorColumn`). They are the save page of the screen pane now: `PaneSavePage.swift`.

/// low / medium / high as a native segmented control.
struct QualityPicker: View {
    let settings: CobaltKit.Settings

    var body: some View {
        Picker(Copy.quality, selection: Binding(get: { settings.webpQuality }, set: { settings.webpQuality = $0 })) {
            ForEach(WebpQuality.allCases, id: \.self) { q in
                Text(Copy.qualityName(q)).tag(q)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel(Copy.quality)
    }
}
