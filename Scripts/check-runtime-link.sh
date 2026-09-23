#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACTS="${SHERPA_ARTIFACTS:-/Users/roylyl/Documents/ChatGPT/ln/android-validation/ios-build/SourcePackages/artifacts}"
MODE="${1:-static}"
PLATFORM="${2:-simulator}"
if [[ "$MODE" == shared ]]; then SUFFIX=Shared; else SUFFIX=; fi
if [[ "$PLATFORM" == simulator ]]; then
 SDK=iphonesimulator; TARGET=arm64-apple-ios17.0-simulator; SLICE=ios-arm64_x86_64-simulator; WHISPER_SLICE=ios-arm64-simulator; VOSK_SLICE=ios-arm64_x86_64-simulator
else
 SDK=iphoneos; TARGET=arm64-apple-ios17.0; SLICE=ios-arm64; WHISPER_SLICE=ios-arm64; VOSK_SLICE=ios-arm64_armv7_armv7s
fi
SHERPA="$ARTIFACTS/sherpa-onnx/SherpaOnnxIOS$SUFFIX/sherpa-onnx.xcframework/$SLICE"
ORT="$ARTIFACTS/onnxruntime-libs/OnnxruntimeIOS$SUFFIX/onnxruntime.xcframework/$SLICE"
WHISPER="$ROOT/Packages/WhisperRuntime/whisper.xcframework/$WHISPER_SLICE"
VOSK="$ROOT/Packages/VoskRuntime/libvosk.xcframework/$VOSK_SLICE"
OUT="$ROOT/Tests/runtime-link-$MODE-$PLATFORM"
xcrun --sdk "$SDK" clang -target "$TARGET" -isysroot "$(xcrun --sdk "$SDK" --show-sdk-path)" \
 "$ROOT/Tests/runtime-link-smoke.c" -F "$SHERPA" -F "$ORT" -F "$WHISPER" -I "$VOSK/Headers" \
 -framework SherpaOnnxC -framework onnxruntime -framework whisper "$VOSK/libvosk.a" \
 -framework Accelerate -framework Foundation -framework CoreML -lc++ \
 -Wl,-rpath,"$SHERPA" -Wl,-rpath,"$ORT" -o "$OUT"
echo "LINK PASS $MODE $PLATFORM: $OUT"
if [[ "$PLATFORM" == simulator && "${RUN_SMOKE:-0}" == 1 ]]; then
 xcrun simctl spawn booted "$OUT" "$ROOT/ModelLibrary"
fi
