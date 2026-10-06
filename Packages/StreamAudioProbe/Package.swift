// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "StreamAudioProbe",
    platforms: [.iOS(.v18)],
    products: [.library(name: "StreamAudioProbe", targets: ["StreamAudioProbe"])],
    targets: [.target(name: "StreamAudioProbe", publicHeadersPath: "include",
        linkerSettings: [.linkedFramework("MediaToolbox"), .linkedFramework("AudioToolbox"), .linkedFramework("CoreMedia")])]
)
