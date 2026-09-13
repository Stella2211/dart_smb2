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
            url: "https://github.com/Stella2211/dart_smb2/releases/download/libsmb2-r9/libsmb2_ios.xcframework.zip",
            checksum: "b230d3bd9cb313b59847f9f1df5737f9b32d7073d908e16880fa7822abe932e9"
        ),
    ]
)
