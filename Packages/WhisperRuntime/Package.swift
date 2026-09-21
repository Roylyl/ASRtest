// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "WhisperRuntime", platforms: [.iOS(.v17)], products: [
    .library(name: "WhisperRuntime", targets: ["WhisperRuntime"])
], targets: [
    .binaryTarget(name: "whisper", path: "whisper.xcframework"),
    .target(name: "WhisperRuntime", dependencies: ["whisper"], linkerSettings: [.linkedFramework("Accelerate"), .linkedLibrary("c++")])
])
