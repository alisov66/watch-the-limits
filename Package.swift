// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WatchTheLimits",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "WatchTheLimits", targets: ["WatchTheLimits"])],
    targets: [
        .target(name: "UsageCore"),
        .executableTarget(name: "WatchTheLimits", dependencies: ["UsageCore"], resources: [.copy("Resources/Figma"), .copy("Resources/PanelColors.bundle")]),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"]),
        .testTarget(name: "WatchTheLimitsTests", dependencies: ["WatchTheLimits", "UsageCore"])
    ]
)
