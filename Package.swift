// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ICloudTestFramework",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "ICloudTestFramework", targets: ["ICloudTestFramework"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "ICloudTestFramework",
            path: "Sources/ICloudTestFramework"
        ),
        .testTarget(
            name: "ICloudTests",
            dependencies: ["ICloudTestFramework"],
            path: "Tests/ICloudTests"
        ),
    ]
)
