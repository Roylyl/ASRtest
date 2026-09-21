#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACTS="${SHERPA_ARTIFACTS:-$ROOT/.build/SourcePackages/artifacts}"
if [[ "${1:-}" == --help ]]; then
 cat <<'HELP'
Usage: bash Tests/run-standard-engine-smoke.sh English-16k.wav Chinese-16k.wav
SHERPA_ARTIFACTS defaults to <repository>/.build/SourcePackages/artifacts.
First resolve Swift packages with -clonedSourcePackagesDirPath .build/SourcePackages.
BUNDLED_MODELS_ROOT defaults to <repository>/ModelLibrary.
ASR_TEST_SIMULATOR selects a booted iOS simulator; default requires exactly one.
HELP
 exit 0
fi
[[ $# == 2 && -f "$1" && -f "$2" ]] || { echo 'Supply English and Chinese mono 16 kHz WAV files; use --help for usage.' >&2; exit 2; }
SIMULATOR_ARGS=(--booted)
if [[ -n "${ASR_TEST_SIMULATOR:-}" ]]; then SIMULATOR_ARGS+=(--udid "$ASR_TEST_SIMULATOR"); fi
SIMULATOR="$(python3 "$ROOT/Scripts/select-ios-simulator.py" "${SIMULATOR_ARGS[@]}")"
SHERPA="$ARTIFACTS/sherpa-onnx/SherpaOnnxIOSShared/sherpa-onnx.xcframework/ios-arm64_x86_64-simulator"
ORT="$ARTIFACTS/onnxruntime-libs/OnnxruntimeIOSShared/onnxruntime.xcframework/ios-arm64_x86_64-simulator"
if [[ ! -d "$SHERPA" || ! -d "$ORT" ]]; then
 echo "Missing package artifacts under $ARTIFACTS. Resolve packages with -clonedSourcePackagesDirPath .build/SourcePackages, or set SHERPA_ARTIFACTS." >&2
 exit 1
fi
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
xcrun simctl spawn "$SIMULATOR" "$ROOT/Tests/standard-engine-smoke" "$MODELS" "$1" "$2"
