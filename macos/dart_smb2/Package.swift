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
                "dart_smb2_lifecycle",
                .product(name: "FlutterFramework", package: "FlutterFramework"),
            ],
            path: "Sources/dart_smb2",
            resources: [
                .process("Resources")
            ]
        ),
        .target(
            name: "dart_smb2_lifecycle",
            path: "Sources/dart_smb2_lifecycle",
            publicHeadersPath: "include"
        ),
        .binaryTarget(
            name: "libsmb2",
            url: "https://github.com/Stella2211/dart_smb2/releases/download/libsmb2-r9/libsmb2_macos.xcframework.zip",
            checksum: "2cc70014ab1c300c13582273a47309a6c3b4bf2449b23761480951ddea32b50f"
        ),
    ]
)
