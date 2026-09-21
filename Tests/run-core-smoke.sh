#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACTS="${SHERPA_ARTIFACTS:-$ROOT/.build/SourcePackages/artifacts}"
if [[ "${1:-}" == --help ]]; then
 cat <<'HELP'
Usage: bash Tests/run-core-smoke.sh English-16k.wav Chinese-16k.wav
BUILD_ONLY=1 builds without running; WAV arguments are optional in this mode.
SHERPA_ARTIFACTS defaults to <repository>/.build/SourcePackages/artifacts.
First resolve Swift packages with -clonedSourcePackagesDirPath .build/SourcePackages.
ASR_TEST_SIMULATOR selects a booted iOS simulator; default requires exactly one.
ASR_NANO_SAMPLE can override the official Nano sample restored by build-nano.py.
HELP
 exit 0
fi
if [[ "${BUILD_ONLY:-0}" != 1 ]]; then
 [[ $# == 2 && -f "$1" && -f "$2" ]] || { echo 'Supply English and Chinese mono 16 kHz WAV files; use --help for usage.' >&2; exit 2; }
 SIMULATOR_ARGS=(--booted)
 if [[ -n "${ASR_TEST_SIMULATOR:-}" ]]; then SIMULATOR_ARGS+=(--udid "$ASR_TEST_SIMULATOR"); fi
 SIMULATOR="$(python3 "$ROOT/Scripts/select-ios-simulator.py" "${SIMULATOR_ARGS[@]}")"
fi
NANO_SAMPLE="${ASR_NANO_SAMPLE:-$ROOT/Vendor/Fun-ASR/runtime/llama.cpp/tests/sample.wav}"
SHERPA="$ARTIFACTS/sherpa-onnx/SherpaOnnxIOSShared/sherpa-onnx.xcframework/ios-arm64_x86_64-simulator"
ORT="$ARTIFACTS/onnxruntime-libs/OnnxruntimeIOSShared/onnxruntime.xcframework/ios-arm64_x86_64-simulator"
if [[ ! -d "$SHERPA" || ! -d "$ORT" ]]; then
 echo "Missing package artifacts under $ARTIFACTS. Resolve packages with -clonedSourcePackagesDirPath .build/SourcePackages, or set SHERPA_ARTIFACTS." >&2
 exit 1
fi
if [[ "${BUILD_ONLY:-0}" != 1 && ! -f "$NANO_SAMPLE" ]]; then
 echo 'Missing official Nano sample. Restore Nano sources with Scripts/build-nano.py or set ASR_NANO_SAMPLE to the same official sample.' >&2
 exit 1
fi
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
SIMCTL_CHILD_CFFIXED_USER_HOME="$WORK/Home" xcrun simctl spawn "$SIMULATOR" "$APP/CoreSmoke" "$1" "$2" "$WORK/Home" "$NANO_SAMPLE"
