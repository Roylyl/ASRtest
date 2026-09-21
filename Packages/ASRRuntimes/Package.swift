// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "ASRRuntimes",
    platforms: [.iOS(.v17)],
    products: [.library(name: "ASRRuntimes", targets: ["ASRRuntimes"])],
    dependencies: [
        .package(url: "https://github.com/k2-fsa/sherpa-onnx", exact: "1.13.8"),
        .package(path: "../WhisperRuntime"),
        .package(path: "../VoskRuntime")
    ],
    targets: [.target(name: "ASRRuntimes", dependencies: [
        // Shared sherpa + its pinned shared ONNX Runtime 1.28.2 avoid the
        // real OpenFst duplicate symbols found with the Vosk static archive.
        .product(name: "sherpa-onnx-shared", package: "sherpa-onnx"),
        .product(name: "WhisperRuntime", package: "WhisperRuntime"),
        .product(name: "VoskRuntime", package: "VoskRuntime")
    ], linkerSettings: [.linkedFramework("Accelerate"), .linkedLibrary("c++")])]
)
