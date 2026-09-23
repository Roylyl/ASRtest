#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACTS="${SHERPA_ARTIFACTS:-/Users/roylyl/Documents/ChatGPT/ln/android-validation/ios-build/SourcePackages/artifacts}"
SHERPA="$ARTIFACTS/sherpa-onnx/SherpaOnnxIOSShared/sherpa-onnx.xcframework/ios-arm64_x86_64-simulator"
ORT="$ARTIFACTS/onnxruntime-libs/OnnxruntimeIOSShared/onnxruntime.xcframework/ios-arm64_x86_64-simulator"
WHISPER="$ROOT/Packages/WhisperRuntime/whisper.xcframework/ios-arm64-simulator"
VOSK="$ROOT/Packages/VoskRuntime/libvosk.xcframework/ios-arm64_x86_64-simulator"
NANO="$ROOT/Packages/NanoRuntime/CNano.xcframework/ios-arm64-simulator"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
WORK="$ROOT/Tests/core-smoke"
APP="$WORK/CoreSmoke.app"
mkdir -p "$APP" "$WORK/Home" "$WORK/modules"
xcrun swiftc -emit-module -module-name NanoRuntime -swift-version 5 -sdk "$SDK" -target arm64-apple-ios17.0-simulator -F "$NANO" "$ROOT/Packages/NanoRuntime/Sources/NanoRuntime/NanoRuntime.swift" -emit-module-path "$WORK/modules/NanoRuntime.swiftmodule"
python3 "$ROOT/Tests/prepare-bundled-smoke.py" "$APP"
cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.roylyl.asrtest.coresmoke</string><key>CFBundleExecutable</key><string>CoreSmoke</string><key>CFBundleName</key><string>CoreSmoke</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
xcrun swiftc -swift-version 5 -O -sdk "$SDK" -target arm64-apple-ios17.0-simulator \
 -F "$SHERPA" -F "$ORT" -F "$WHISPER" -F "$NANO" -I "$WORK/modules" -I "$VOSK/Headers" \
 "$ROOT/ASRtest/EngineTypes.swift" "$ROOT/ASRtest/Engines/StandardEngines.swift" "$ROOT/ASRtest/Engines/NanoEngine.swift" \
 "$ROOT/ASRtest/ModelCatalog.swift" "$ROOT/ASRtest/ModelStore.swift" "$ROOT/ASRtest/SessionStore.swift" \
 "$ROOT/ASRtest/RecognitionBackend.swift" "$ROOT/Tests/CoreSmoke.swift" \
 -framework SherpaOnnxC -framework onnxruntime -framework whisper -framework CNano "$VOSK/libvosk.a" \
 -framework Accelerate -framework Foundation -framework AVFoundation -framework CoreML -framework CryptoKit -lc++ \
 -Xlinker -rpath -Xlinker "$NANO" -Xlinker -rpath -Xlinker "$SHERPA" -Xlinker -rpath -Xlinker "$ORT" -o "$APP/CoreSmoke"
if [[ "${BUILD_ONLY:-0}" == 1 ]]; then exit 0; fi
SIMCTL_CHILD_CFFIXED_USER_HOME="$WORK/Home" xcrun simctl spawn booted "$APP/CoreSmoke" "$1" "$2" "$WORK/Home" "$ROOT/Vendor/Fun-ASR/runtime/llama.cpp/tests/sample.wav"
