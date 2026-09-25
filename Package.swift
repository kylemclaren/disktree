// swift-tools-version: 6.2
//
// disktree for macOS: a treemap of what is using a volume.
//
// Three layers, so the parts that must be correct can be tested without a
// window: `DisktreeCore` scans, lays out, measures free space and removes;
// `DisktreeApp` is the state machine and the screens; `disktree` is only the
// entry point.

import PackageDescription

let package = Package(
    name: "disktree",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "disktree", targets: ["disktree"])
    ],
    targets: [
        .target(
            name: "DisktreeCore",
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .target(
            name: "DisktreeApp",
            dependencies: ["DisktreeCore"],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .executableTarget(
            name: "disktree",
            dependencies: ["DisktreeApp"],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "DisktreeCoreTests",
            dependencies: ["DisktreeCore"],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "DisktreeAppTests",
            dependencies: ["DisktreeApp", "DisktreeCore"],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
    ]
)
