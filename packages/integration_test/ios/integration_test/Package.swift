// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.
//
//  Generated file. Do not edit.
//

import PackageDescription

let package = Package(
    name: "integration_test",
    platforms: [
        .iOS("12.0"),
    ],
    products: [
        .library(name: "integration_test", targets: ["integration_test"]),
    ],
    dependencies: [
    ],
    targets: [
        .target(
            name: "integration_test",
            dependencies: [],
            resources: [
                .process("Resources"),
            ],
            cSettings: [
                .headerSearchPath("include/integration_test"),
            ]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
