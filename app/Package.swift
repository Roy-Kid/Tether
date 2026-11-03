// swift-tools-version: 6.2
import Foundation
import PackageDescription

// Nerve's own panel, on a Mac with Nerve checked out beside Tether. CI and the
// commit gate (`TETHER_HERMETIC`) have this repository alone, so the app
// links nothing from outside it there, and is checked that way.
let nervePath = "../../nerve/surfaces/tether"
let linksNerve = Context.environment["TETHER_HERMETIC"] == nil
    && FileManager.default.fileExists(atPath: Context.packageDirectory + "/" + nervePath)

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
        .package(path: "Packages/TetherPluginHost"),
        .package(path: "Plugins/Tmux"),
        .package(path: "Plugins/Files"),
        .package(path: "Plugins/Ports"),
    ] + (linksNerve ? [.package(path: nervePath)] : []),
    targets: [
        .executableTarget(
            name: "TetherApp",
            dependencies: [
                .product(name: "Tether", package: "swift"),
                .product(name: "TetherUI", package: "TetherFrontend"),
                .product(name: "TetherPluginHost", package: "TetherPluginHost"),
                .product(name: "TetherPluginKit", package: "TetherFrontend"),
                .product(name: "TmuxPlugin", package: "Tmux"),
                .product(name: "FilesPlugin", package: "Files"),
                .product(name: "PortsPlugin", package: "Ports"),
            ] + (linksNerve
                ? [.product(name: "NervePlugin", package: "tether", condition: .when(platforms: [.macOS]))]
                : []),
            // Said by the manifest, not guessed from a module left in `.build`
            // by a build that did link it.
            swiftSettings: linksNerve ? [.define("TETHER_NERVE", .when(platforms: [.macOS]))] : []
        ),
        .testTarget(name: "TetherAppTests", dependencies: [
            "TetherApp", .product(name: "TetherTestSupport", package: "TetherFrontend"),
        ])
    ]
)
