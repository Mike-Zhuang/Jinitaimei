// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TongjiUI",
    defaultLocalization: "zh-Hans",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "TongjiUI", targets: ["TongjiUI"]),
    ],
    dependencies: [
        .package(path: "../TongjiKit")
    ],
    targets: [
        .target(
            name: "TongjiUI",
            dependencies: ["TongjiKit"],
            path: "Sources/TongjiUI"
        ),
    ]
)
