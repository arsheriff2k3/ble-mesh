// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ble_mesh_chat",
    platforms: [
        .iOS("15.0"),
        .macOS("12.0"),
    ],
    products: [
        .library(name: "ble-mesh-chat", targets: ["ble_mesh_chat"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "ble_mesh_chat",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: []
        )
    ]
)
