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
        .library(name: "TrackSource", targets: ["TrackSource"]),
        .library(name: "AudioEngineCore", targets: ["AudioEngineCore"]),
        .library(name: "PlaybackCoordinator", targets: ["PlaybackCoordinator"]),
        .library(name: "MixDiagnostics", targets: ["MixDiagnostics"])
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
        ),
        .target(
            name: "AudioEngineCore",
            dependencies: ["MixModels"],
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "PlaybackCoordinator",
            dependencies: ["MixModels", "TrackSource", "AudioEngineCore"],
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "MixDiagnostics",
            dependencies: ["MixModels", "AudioEngineCore", "PlaybackCoordinator"],
            swiftSettings: strictConcurrency
        )
    ],
    swiftLanguageModes: [.v6]
)
