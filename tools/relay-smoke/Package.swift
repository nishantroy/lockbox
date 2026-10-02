// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "relay-smoke",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../../CompanionKit")
    ],
    targets: [
        .executableTarget(name: "relay-smoke", dependencies: ["CompanionKit"])
    ]
)
