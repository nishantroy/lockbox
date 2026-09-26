// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CompanionKit",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "CompanionKit", targets: ["CompanionKit"])
    ],
    targets: [
        .target(name: "CompanionKit"),
        .testTarget(name: "CompanionKitTests", dependencies: ["CompanionKit"])
    ]
)
