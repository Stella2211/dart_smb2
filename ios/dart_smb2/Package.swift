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
            url: "https://github.com/Stella2211/dart_smb2/releases/download/libsmb2-r8/libsmb2_ios.xcframework.zip",
            checksum: "e306a3feaaf5e009450c2425833f5da7dad4586cc33a9dbe5d6f8233563936df"
        ),
    ]
)
