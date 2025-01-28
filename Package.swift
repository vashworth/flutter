// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Flutter",
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "Flutter",
            targets: ["Flutter"]),
    ],
    targets: [
        .binaryTarget(name: "Flutter", url: "https://storage.googleapis.com/flutter_infra_release/flutter/432843a0f3dd88c7c84a9cfb77c3e9b4b36e3e1e/ios/artifacts.zip", checksum: "3c958a5e93e4fa9d9c291c1b48bd775e936206caf544b4797caf2073be0f2d39")
    ]
)
