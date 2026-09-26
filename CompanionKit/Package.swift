// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CompanionKit",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "CompanionKit", targets: ["CompanionKit"]),
        .executable(name: "CompanionVectorGen", targets: ["CompanionVectorGen"])
    ],
    targets: [
        .target(name: "CompanionKit"),
        .testTarget(name: "CompanionKitTests", dependencies: ["CompanionKit"]),
        // R5 relay golden-vector generator. Writes deterministic canonical
        // signing/JSON fixtures consumed by the TypeScript relay's test
        // suite (relay/test/fixtures). Depends only on the existing public
        // CompanionKit API; no CompanionKit source files are modified.
        .executableTarget(name: "CompanionVectorGen", dependencies: ["CompanionKit"])
    ]
)
