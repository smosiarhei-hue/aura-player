// swift-tools-version: 6.0
// Path: Packages/AutoMixV2/Package.swift

import PackageDescription

let strictConcurrency: [SwiftSetting] = [
    .unsafeFlags(["-strict-concurrency=complete"])
]

let package = Package(
    name: "AutoMixV2",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "MixModels", targets: ["MixModels"]),
        .library(name: "TrackSource", targets: ["TrackSource"])
    ],
    targets: [
        .target(
            name: "MixModels",
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "TrackSource",
            dependencies: ["MixModels"],
            swiftSettings: strictConcurrency
        )
    ],
    swiftLanguageModes: [.v6]
)
