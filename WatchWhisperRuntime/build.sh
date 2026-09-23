#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
SRC="$ROOT/Vendor/whisper.cpp"
RUNTIME="$ROOT/WatchWhisperRuntime"
JOB=$(mktemp -d /tmp/asrtest-watch-whisper.XXXXXX)
for SPEC in 'watch-arm64_32 watchos arm64_32 arm64_32-apple-watchos10.0' 'watch-arm64 watchos arm64 arm64-apple-watchos10.0' 'sim-arm64 watchsimulator arm64 arm64-apple-watchos10.0-simulator' 'sim-x86_64 watchsimulator x86_64 x86_64-apple-watchos10.0-simulator'; do
  set -- ${(z)SPEC}
  NAME=$1 SDK=$2 ARCH=$3 TARGET=$4
  SDK_PATH=$(xcrun --sdk "$SDK" --show-sdk-path)
  cmake -S "$SRC" -B "$JOB/$NAME" -G Ninja \
    -DCMAKE_SYSTEM_NAME=watchOS -DCMAKE_OSX_SYSROOT="$SDK_PATH" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" -DCMAKE_OSX_DEPLOYMENT_TARGET=10.0 \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCMAKE_C_FLAGS=-D_DARWIN_C_SOURCE -DCMAKE_CXX_FLAGS=-D_DARWIN_C_SOURCE \
    -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=OFF \
    -DWHISPER_BUILD_SERVER=OFF -DGGML_METAL=OFF -DGGML_ACCELERATE=OFF -DGGML_BLAS=OFF
  cmake --build "$JOB/$NAME" --target whisper -j 6
  xcrun --sdk "$SDK" clang -target "$TARGET" -isysroot "$SDK_PATH" -D_DARWIN_C_SOURCE \
    -I"$SRC/include" -I"$SRC/ggml/include" -I"$RUNTIME/Headers" \
    -c "$RUNTIME/WatchWhisperBridge.c" -o "$JOB/$NAME-bridge.o"
  libtool -static -o "$JOB/$NAME.a" "$JOB/$NAME-bridge.o" \
    "$JOB/$NAME/src/libwhisper.a" "$JOB/$NAME/ggml/src/libggml.a" \
    "$JOB/$NAME/ggml/src/libggml-base.a" "$JOB/$NAME/ggml/src/libggml-cpu.a"
done
lipo -create "$JOB/watch-arm64_32.a" "$JOB/watch-arm64.a" -output "$JOB/watch-universal.a"
lipo -create "$JOB/sim-arm64.a" "$JOB/sim-x86_64.a" -output "$JOB/sim-universal.a"
xcodebuild -create-xcframework -library "$JOB/watch-universal.a" -headers "$RUNTIME/Headers" \
  -library "$JOB/sim-universal.a" -headers "$RUNTIME/Headers" -output "$JOB/WatchWhisper.xcframework"
if [[ -d "$RUNTIME/WatchWhisper.xcframework" ]]; then
  mv "$RUNTIME/WatchWhisper.xcframework" "$JOB/previous.xcframework"
fi
mv "$JOB/WatchWhisper.xcframework" "$RUNTIME/WatchWhisper.xcframework"
print "WatchWhisper.xcframework rebuilt. Previous artifact: $JOB/previous.xcframework"
