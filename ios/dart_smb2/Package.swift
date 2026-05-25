// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "dart_smb2",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "dart-smb2", targets: ["dart_smb2"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
    ],
    targets: [
        .target(
            name: "dart_smb2",
            dependencies: [
                "libsmb2",
                .product(name: "FlutterFramework", package: "FlutterFramework"),
            ],
            path: "Sources/dart_smb2",
            resources: [
                .process("Resources")
            ]
        ),
        .binaryTarget(
            name: "libsmb2",
            url: "https://github.com/ales-drnz/dart_smb2/releases/download/libsmb2-r5/libsmb2_ios.xcframework.zip",
            checksum: "a4fa68099a348fabd0753904732152dd3d5809447d6b0df9c75ba335383554c3"
        ),
    ]
)
