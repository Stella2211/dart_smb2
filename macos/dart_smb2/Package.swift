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
            url: "https://github.com/Stella2211/dart_smb2/releases/download/libsmb2-r5/libsmb2_macos.xcframework.zip",
            checksum: "41d213540d7c5742fed06689eb48437b6032c2b484cb07a5391e77a90d4a2802"
        ),
    ]
)
