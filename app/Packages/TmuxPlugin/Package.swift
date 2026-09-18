// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "TmuxPlugin", platforms: [.macOS(.v26), .iOS(.v26)], products: [
    .library(name: "TmuxPlugin", targets: ["TmuxPlugin"])
], dependencies: [.package(path: "../TetherFrontend"), .package(path: "../../../swift")], targets: [
    .target(name: "TmuxPlugin", dependencies: [
        .product(name: "Tether", package: "swift"),
        .product(name: "TetherUI", package: "TetherFrontend"),
        .product(name: "TetherPluginKit", package: "TetherFrontend")
    ])
])
