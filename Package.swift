// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MagicDock",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "MagicDockCore", targets: ["MagicDockCore"]),
        .executable(name: "MagicDock", targets: ["MagicDock"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-testing.git",
            revision: "5ee435b15ad40ec1f644b5eb9d247f263ccd2170"
        )
    ],
    targets: [
        .target(
            name: "MagicDockCore",
            linkerSettings: [
                .linkedFramework("CryptoKit"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("Network"),
            ]
        ),
        .executableTarget(
            name: "MagicDock",
            dependencies: ["MagicDockCore"],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "MagicDockCoreTests",
            dependencies: [
                "MagicDockCore",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
