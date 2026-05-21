// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TongjiKit",
    defaultLocalization: "zh-Hans",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "TongjiKit", targets: ["TongjiKit"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "TongjiKit",
            path: "Sources/TongjiKit"
        ),
    ]
)
