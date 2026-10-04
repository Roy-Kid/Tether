// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TetherPluginHost",
  platforms: [.macOS(.v26), .iOS(.v26)],
  products: [
    .library(name: "TetherPluginHost", targets: ["TetherPluginHost"])
  ],
  dependencies: [
    .package(path: "../TetherFrontend")
  ],
  targets: [
    .target(
      name: "TetherPluginHost",
      dependencies: [
        .product(name: "TetherUI", package: "TetherFrontend")
      ]
    ),
    .testTarget(name: "TetherPluginHostTests", dependencies: ["TetherPluginHost"]),
  ]
)
