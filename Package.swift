// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "OpenAVFoundationAppleCameraDriver",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "OpenAVFoundationAppleCameraDriver",
            targets: ["OpenAVFoundationAppleCameraDriver"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/1amageek/OpenAVFoundationDriver.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/1amageek/OpenCoreMedia.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/1amageek/OpenCoreVideo.git",
            branch: "main"
        )
    ],
    targets: [
        .target(
            name: "OpenAVFoundationAppleCameraDriver",
            dependencies: [
                "OpenCoreMedia",
                "OpenCoreVideo",
                .product(
                    name: "OpenAVFoundationDriver",
                    package: "OpenAVFoundationDriver"
                )
            ]
        ),
        .testTarget(
            name: "OpenAVFoundationAppleCameraDriverTests",
            dependencies: [
                "OpenAVFoundationAppleCameraDriver"
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
