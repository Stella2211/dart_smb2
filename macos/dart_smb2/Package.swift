// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "dart_smb2",
    platforms: [
        .macOS("12.0")
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
            url: "https://github.com/Stella2211/dart_smb2/releases/download/libsmb2-r8/libsmb2_macos.xcframework.zip",
            checksum: "32485b887d79584632db5403be37ba9bdb1d17d4e96036db2d2217c9264facf9"
        ),
    ]
)
