#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACTS="${SHERPA_ARTIFACTS:-/Users/roylyl/Documents/ChatGPT/ln/android-validation/ios-build/SourcePackages/artifacts}"
SHERPA="$ARTIFACTS/sherpa-onnx/SherpaOnnxIOSShared/sherpa-onnx.xcframework/ios-arm64_x86_64-simulator"
ORT="$ARTIFACTS/onnxruntime-libs/OnnxruntimeIOSShared/onnxruntime.xcframework/ios-arm64_x86_64-simulator"
WHISPER="$ROOT/Packages/WhisperRuntime/whisper.xcframework/ios-arm64-simulator"
VOSK="$ROOT/Packages/VoskRuntime/libvosk.xcframework/ios-arm64_x86_64-simulator"
MODELS="${BUNDLED_MODELS_ROOT:-$ROOT/ModelLibrary}"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun swiftc -swift-version 5 -O -sdk "$SDK" -target arm64-apple-ios17.0-simulator \
 -F "$SHERPA" -F "$ORT" -F "$WHISPER" -I "$VOSK/Headers" \
 "$ROOT/ASRtest/EngineTypes.swift" "$ROOT/ASRtest/Engines/StandardEngines.swift" "$ROOT/Tests/StandardEngineSmoke.swift" \
 -framework SherpaOnnxC -framework onnxruntime -framework whisper "$VOSK/libvosk.a" \
 -framework Accelerate -framework Foundation -framework AVFoundation -framework CoreML -lc++ \
 -Xlinker -rpath -Xlinker "$SHERPA" -Xlinker -rpath -Xlinker "$ORT" -o "$ROOT/Tests/standard-engine-smoke"
xcrun simctl spawn booted "$ROOT/Tests/standard-engine-smoke" "$MODELS" "$1" "$2"
