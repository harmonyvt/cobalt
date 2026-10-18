import Foundation

/// One of the 256 numbers of a post's embedding, as a star of the fingerprint.
public struct SkyFingerprintStar: Sendable, Equatable {
    /// Centre in the unit square (a 16 x 16 field, row by row).
    public var x: Double
    public var y: Double
    /// Radius as a fraction of the square's side.
    public var radius: Double
    /// True above zero (cool blue), false below (warm amber).
    public var positive: Bool
    /// |value| over the largest |value|, 0...1: the star's brightness (the web draws it at opacity `0.25 + 0.75 * strength`
    /// and, at night, adds a glow when it is over 0.35).
    public var strength: Double

    public init(x: Double, y: Double, radius: Double, positive: Bool, strength: Double = 0) {
        self.x = x
        self.y = y
        self.radius = radius
        self.positive = positive
        self.strength = strength
    }
}

/// A post's embedding as a field of stars, a port of the web's `fingerprint` (page.html 1905): the first 256 numbers
/// as a 16 x 16 grid, size and brightness = how big the number is, cool above zero, warm below.
public enum SkyFingerprint {
    public static let side = 16

    /// The web draws it on a 208 px square (16 cells of 13 px): the star radius is `0.6 + 2.6 * strength` of those pixels.
    private static let canvas = 208.0

    /// One star per component, up to 256, in order. Positions are cell centres in the unit square.
    public static func stars(for vector: [Float]) -> [SkyFingerprintStar] {
        let count = min(side * side, vector.count)
        let peak = vector.reduce(Float(0)) { max($0, abs($1)) }
        return (0..<count).map { i in
            let strength = peak > 0 ? Double(abs(vector[i]) / peak) : 0
            return SkyFingerprintStar(
                x: (Double(i % side) + 0.5) / Double(side), y: (Double(i / side) + 0.5) / Double(side),
                radius: (0.6 + 2.6 * strength) / canvas, positive: vector[i] >= 0, strength: strength)
        }
    }
}
