// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "VoskRuntime", platforms: [.iOS(.v17)], products: [
    .library(name: "VoskRuntime", targets: ["VoskRuntime"])
], targets: [
    .binaryTarget(name: "VoskC", path: "libvosk.xcframework"),
    .target(name: "VoskRuntime", dependencies: ["VoskC"], linkerSettings: [.linkedFramework("Accelerate"), .linkedLibrary("c++")])
])
