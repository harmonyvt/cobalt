import Foundation

/// Copy for the wallpaper maker (apple/CONTRACT-WALLPAPER.md). Lowercase, house style.
extension Copy {
    enum Wallpaper {
        static let menu = "make wallpaper…"
        static let title = "wallpaper"
        static let loading = "opening…"
        static let unreadable = "this file can't be made into a wallpaper"
        static let pickRange = "pick the 3 seconds"
        static let pickRangeHint = "it ends on the still the lock screen keeps"
        static let pictureNote = "a picture makes a still wallpaper"
        static let target = "make it for"
        static let lockScreen = "this iphone"
        static let lockScreenNote = "lock screen · live photo"
        static let duoPair = "both screens"
        static let duoPairNote = "one picture across the hinge"
        static let depth = "depth"
        static let showDepth = "show depth"
        static let showPicture = "show picture"
        static let subjectIn = "subject in"
        static let subjectOut = "subject out"
        static let findSubject = "find subject"
        static let undo = "undo"
        static let brushSize = "brush size"
        static let blur = "background blur"
        static let parallax = "drift"
        static let softness = "edge softness"
        static let noSubject = "no subject found. paint it in with the brush"
        static let make = "make it"
        static let making = "making…"
        static let saved = "saved to photos"
        static let savedAlbum = "saved to photos · capystore wallpapers"
        static let denied = "capystore can't add to photos. allow it in settings"
        static let failed = "couldn't make the wallpaper"
        static let openPhotos = "open photos"
        static let howTo = "in photos: open it, tap share, then use as wallpaper"
        static let iosDecides =
            "ios keeps its clock on top of a live photo, so keep the subject clear of it. a still lets ios lift the subject over the clock itself."
        static let close = "close"
    }
}

/// Symbols for the wallpaper maker.
extension Symbol {
    enum Wallpaper {
        static let menu = "photo.on.rectangle.angled"
        static let lockScreen = "iphone"
        static let duoPair = "rectangle.split.2x1"
        static let subjectIn = "paintbrush.pointed.fill"
        static let subjectOut = "eraser"
        static let findSubject = "wand.and.sparkles"
        static let undo = "arrow.uturn.backward"
        static let depth = "square.3.layers.3d"
        static let make = "photo.badge.arrow.down"
        static let openPhotos = "photo.on.rectangle"
        static let live = "livephoto"
    }
}
