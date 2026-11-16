// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CayoteLink",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CayoteKit", targets: ["CayoteKit"]),
        .executable(name: "cayote", targets: ["cayote"]),
        .executable(name: "CayoteLinkApp", targets: ["CayoteLinkApp"]),
    ],
    targets: [
        .target(name: "CayoteKit"),
        .executableTarget(name: "cayote", dependencies: ["CayoteKit"]),
        .executableTarget(name: "CayoteLinkApp", dependencies: ["CayoteKit"]),
        // Plain executable instead of a test target: the Command Line Tools
        // toolchain cannot build XCTest / swift-testing bundles.
        .executableTarget(name: "CayoteSelfTest", dependencies: ["CayoteKit"]),
    ]
)
