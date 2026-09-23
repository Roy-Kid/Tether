// swift-tools-version: 6.2
import PackageDescription

// The first built-in plugin, and the one that keeps the plugin seam honest:
// everything tmux the app shows lives here, and the app reaches it only
// through TetherPluginKit (Decisions/0012).
let package = Package(
    name: "TmuxPlugin",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "TmuxPlugin", targets: ["TmuxPlugin"])
    ],
    dependencies: [
        .package(path: "../../Packages/TetherFrontend"),
        .package(path: "../../../swift"),
    ],
    targets: [
        .target(
            name: "TmuxPlugin",
            dependencies: [
                .product(name: "Tether", package: "swift"),
                .product(name: "TetherUI", package: "TetherFrontend"),
                .product(name: "TetherPluginKit", package: "TetherFrontend"),
            ]),
        .testTarget(name: "TmuxPluginTests", dependencies: ["TmuxPlugin"]),
    ]
)
