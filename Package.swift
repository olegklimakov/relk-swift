// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Relk",
    defaultLocalization: "en",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "RelkKit", targets: ["RelkKit"]),
    ],
    targets: [
        .target(
            name: "RelkKit",
            resources: [.process("Resources")]
        ),
    ]
)
