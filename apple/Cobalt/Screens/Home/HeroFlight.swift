import SwiftUI

// One continuous planet. From the moment the star becomes a picture until the planet is back in its band,
// the focus layer draws ONE hero view (poster, the playing video, the webp: one set of pixels) and moves
// it between poses: the star's dot, the planet's slot in band 0, the lifted hero. A pose is plain numbers
// (centre, size, corner radius, how much glass chrome it wears) that SwiftUI interpolates natively, and the
// hero re-derives everything from the interpolated pose every frame: the media is laid out ONCE at a fixed
// reference size and only scaled (a transform, never a relayout), clipped by the animating rounded rect,
// and aspect-filled to whatever size the rect has at that instant. Nothing is crossfaded: there is no
// second view for the picture to fade into.

/// Where the hero is, in the focus layer's coordinates, and what it wears.
struct HeroPose: Equatable {
    var cx: Double = 0
    var cy: Double = 0
    var w: Double = 0
    var h: Double = 0
    /// The outer rect's corner radius.
    var radius: Double = 0
    /// 0 = a bare picture in a band (the orbit's own look); 1 = the focused planet on its glass bezel.
    var chrome: Double = 0

    init() {}

    init(rect: CGRect, radius: CGFloat, chrome: Double) {
        cx = rect.midX
        cy = rect.midY
        w = rect.width
        h = rect.height
        self.radius = radius
        self.chrome = chrome
    }
}

extension HeroPose: VectorArithmetic {
    static var zero: HeroPose { HeroPose() }

    static func + (a: HeroPose, b: HeroPose) -> HeroPose {
        var r = HeroPose()
        r.cx = a.cx + b.cx; r.cy = a.cy + b.cy; r.w = a.w + b.w; r.h = a.h + b.h
        r.radius = a.radius + b.radius; r.chrome = a.chrome + b.chrome
        return r
    }

    static func - (a: HeroPose, b: HeroPose) -> HeroPose {
        var r = HeroPose()
        r.cx = a.cx - b.cx; r.cy = a.cy - b.cy; r.w = a.w - b.w; r.h = a.h - b.h
        r.radius = a.radius - b.radius; r.chrome = a.chrome - b.chrome
        return r
    }

    mutating func scale(by rhs: Double) {
        cx *= rhs; cy *= rhs; w *= rhs; h *= rhs; radius *= rhs; chrome *= rhs
    }

    var magnitudeSquared: Double {
        cx * cx + cy * cy + w * w + h * h + radius * radius + chrome * chrome
    }
}

/// Which pose the focus layer's planet is heading for.
enum FocusPhase: Equatable {
    /// Mounted but not shown yet (a resumed run: no star, the planet appears where it will be).
    case hidden
    /// The star's dot: the planet is born here.
    case born(CGRect)
    /// The planet's place in band 0 (global to the layer). `closing`: on its way back from the lift.
    case slot(CGRect, closing: Bool)
    /// Lifted into focus.
    case lifted
}
