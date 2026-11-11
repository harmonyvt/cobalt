// swift-tools-version: 6.2
import PackageDescription

// Pure Swift for the library's sync glow: which state is showing, the uniform block the Metal
// shader reads, and the numbers its look is held to. No Metal, UIKit or AppKit, so `swift test` in
// this directory runs anywhere. The shader and the view live in the app target and need a Mac.
let package = Package(
    name: "SyncGlowKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SyncGlowKit", targets: ["SyncGlowKit"]),
    ],
    targets: [
        .target(name: "SyncGlowKit"),
        .testTarget(name: "SyncGlowKitTests", dependencies: ["SyncGlowKit"]),
    ]
)
