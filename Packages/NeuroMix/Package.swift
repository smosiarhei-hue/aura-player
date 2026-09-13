// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NeuroMix",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "NeuroMixEngine", targets: ["NeuroMixEngine"])
    ],
    dependencies: [],
    targets: [
        .target(name: "NeuroMixEngine", dependencies: [])
    ],
    swiftLanguageModes: [.v6]
)
