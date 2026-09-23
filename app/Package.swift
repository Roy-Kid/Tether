// swift-tools-version: 6.2
import PackageDescription

// The app is a *consumer* of the SDK, not part of it. It lives in its own
// package and reaches Tether the way anyone else would — by depending on the
// published package, with no privileged access to the Rust source next door.
// If this can be built, so can someone else's app (spec §21).
let package = Package(
    name: "TetherApp",
    platforms: [.macOS(.v26), .iOS(.v26)],
    dependencies: [
        .package(path: "../swift"),
        .package(path: "Packages/TetherFrontend"),
        .package(path: "Plugins/Tmux"),
        .package(path: "Plugins/Files"),
        .package(path: "../../nerve/surfaces/tether"),
    ],
    targets: [
        .executableTarget(
            name: "TetherApp",
            dependencies: [
                .product(name: "Tether", package: "swift"),
                .product(name: "TetherUI", package: "TetherFrontend"),
                .product(name: "TetherPluginKit", package: "TetherFrontend"),
                .product(name: "TmuxPlugin", package: "Tmux"),
                .product(name: "FilesPlugin", package: "Files"),
                .product(
                    name: "NervePlugin", package: "tether",
                    condition: .when(platforms: [.macOS])),
            ]
        ),
        .testTarget(name: "TetherAppTests", dependencies: ["TetherApp"])
    ]
)
