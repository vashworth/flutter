// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "integration_test_macos",
    platforms: [
        .macOS("10.15"),
    ],
    products: [
        .library(name: "integration-test-macos", targets: ["integration_test_macos"]),
    ],
    dependencies: [
      .package(url: "https://github.com/flutter/flutterswiftpackage", "0.0.0"..."999.999.999"),
    ],
    targets: [
        .target(
            name: "integration_test_macos",
            dependencies: [
              .product(name: "Flutter", package: "flutterswiftpackage"),
            ],
            resources: [
                .process("Resources"),
            ]
        ),
    ]
)
