// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhoneLockboxCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "PhoneLockboxCore", targets: ["PhoneLockboxCore"]),
        .library(name: "PhoneLockboxRuntime", targets: ["PhoneLockboxRuntime"])
    ],
    targets: [
        .target(
            name: "PhoneLockboxCore",
            dependencies: ["PhoneLockboxRuntime"],
            path: "PhoneLockbox/Policy"
        ),
        .testTarget(
            name: "PhoneLockboxCoreTests",
            dependencies: ["PhoneLockboxCore"],
            path: "CoreTests"
        ),
        .target(
            name: "PhoneLockboxRuntime",
            path: "Shared"
        ),
        .testTarget(
            name: "PhoneLockboxRuntimeTests",
            dependencies: ["PhoneLockboxRuntime"],
            path: "RuntimeTests"
        )
    ]
)
