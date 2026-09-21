// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NanoRuntime",
    platforms: [.iOS(.v17)],
    products: [.library(name: "NanoRuntime", targets: ["NanoRuntime"])],
    targets: [
        .binaryTarget(name: "CNano", path: "CNano.xcframework"),
        .target(name: "NanoRuntime", dependencies: ["CNano"])
    ]
)
