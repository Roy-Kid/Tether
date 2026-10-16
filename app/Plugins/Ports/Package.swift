// swift-tools-version: 6.2
import PackageDescription

// Loopback ports where a terminal tab's shell is running, forwarded to this
// device. Everything ports the app shows lives here; the app reaches it only
// through TetherPluginKit.
let package = Package(
    name: "PortsPlugin",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "PortsPlugin", targets: ["PortsPlugin"])
    ],
    dependencies: [
        .package(path: "../../Packages/TetherFrontend"),
        .package(path: "../../../swift"),
    ],
    targets: [
        .target(
            name: "PortsPlugin",
            dependencies: [
                .product(name: "Tether", package: "swift"),
                .product(name: "TetherUI", package: "TetherFrontend"),
                .product(name: "TetherPluginKit", package: "TetherFrontend"),
            ]),
        .testTarget(name: "PortsPluginTests", dependencies: ["PortsPlugin"]),
    ]
)
