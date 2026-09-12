// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AmbientKit",
    platforms: [
        .macOS(.v13),
        .iOS(.v17)
    ],
    products: [
        .library(name: "AmbientKit", targets: ["AmbientKit"])
    ],
    targets: [
        .target(name: "AmbientKit"),
        .testTarget(name: "AmbientKitTests", dependencies: ["AmbientKit"])
    ]
)
