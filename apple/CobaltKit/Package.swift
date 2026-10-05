// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CobaltKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "CobaltKit", targets: ["CobaltKit"]),
    ],
    targets: [
        .target(name: "CobaltKit"),
        .testTarget(
            name: "CobaltKitTests", dependencies: ["CobaltKit"],
            // live-states.json: the parity fixture, byte-identical to the API's copy (CONTRACT-LIVE.md 2.4)
            resources: [.copy("Fixtures")]),
    ]
)
