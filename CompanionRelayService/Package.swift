// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CompanionRelayService",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "CompanionRelayService", targets: ["CompanionRelayService"])
    ],
    dependencies: [
        .package(path: "../CompanionKit")
    ],
    targets: [
        .target(name: "CompanionRelayService", dependencies: [
            .product(name: "CompanionKit", package: "CompanionKit")
        ]),
        .testTarget(name: "CompanionRelayServiceTests", dependencies: ["CompanionRelayService"])
    ]
)
