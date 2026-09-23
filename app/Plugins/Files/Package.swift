// swift-tools-version: 6.2
import PackageDescription

// Files where a terminal tab's shell is running: a browser in the inspector,
// Quick Look, and transfers both ways. Everything files the app shows lives
// here; the app reaches it only through TetherPluginKit (Decisions/0012).
let package = Package(
    name: "FilesPlugin",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "FilesPlugin", targets: ["FilesPlugin"])
    ],
    dependencies: [
        .package(path: "../../Packages/TetherFrontend"),
        .package(path: "../../../swift"),
    ],
    targets: [
        .target(
            name: "FilesPlugin",
            dependencies: [
                .product(name: "Tether", package: "swift"),
                .product(name: "TetherUI", package: "TetherFrontend"),
                .product(name: "TetherPluginKit", package: "TetherFrontend"),
            ]),
        .testTarget(name: "FilesPluginTests", dependencies: ["FilesPlugin"]),
    ]
)
