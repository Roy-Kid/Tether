// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "TetherFrontend", platforms: [.macOS(.v26), .iOS(.v26)], products: [
    .library(name: "TetherUI", targets: ["TetherUI"]),
    .library(name: "TetherPluginKit", targets: ["TetherPluginKit"]),
    // For test targets only: what a test process needs before it touches a window.
    .library(name: "TetherTestSupport", targets: ["TetherTestSupport"])
], dependencies: [.package(path: "../../../swift")], targets: [
    .target(name: "TetherUI", dependencies: [.product(name: "Tether", package: "swift")]),
    .target(name: "TetherPluginKit", dependencies: ["TetherUI", .product(name: "Tether", package: "swift")]),
    .target(name: "TetherTestSupport"),
    .testTarget(name: "TetherPluginKitTests", dependencies: ["TetherPluginKit"]),
    .testTarget(name: "TetherUITests", dependencies: ["TetherUI", "TetherTestSupport"])
])
