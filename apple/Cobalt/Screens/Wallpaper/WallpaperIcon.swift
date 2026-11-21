import CobaltKit
import SwiftUI

/// `make wallpaper` as an icon in the detail's button row (apple/CONTRACT-WALLPAPER.md 2), for videos, webps, gifs and
/// pictures alike. iPhone and iPad only: on the Mac it draws nothing.
struct WallpaperIcon: View {
    let model: AppModel
    let rendition: Rendition

    #if os(iOS)
    @State private var pick: WallpaperPick?
    #endif

    var body: some View {
        #if os(iOS)
        if WallpaperPick.canMake(rendition) {
            DetailChoiceButton(title: Copy.Wallpaper.button, symbol: Symbol.Wallpaper.menu) {
                pick = WallpaperPick(rendition: rendition)
            }
            .modifier(WallpaperPresenter(model: model, target: $pick))
        }
        #endif
    }
}
