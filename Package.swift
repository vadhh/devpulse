// swift-tools-version:5.5
import PackageDescription

// Builds the widget binary with plain Command Line Tools (no Xcode).
// build.sh wraps the dylib into DevPulse.pock.
let package = Package(
    name: "DevPulse",
    platforms: [.macOS(.v11)],
    products: [
        .library(name: "DevPulse", type: .dynamic, targets: ["DevPulse"])
    ],
    dependencies: [
        .package(url: "https://github.com/pock/pockkit.git", branch: "master")
    ],
    targets: [
        .target(
            name: "DevPulse",
            dependencies: [.product(name: "PockKit", package: "pockkit")],
            path: "DevPulse/Sources"
        )
    ]
)
