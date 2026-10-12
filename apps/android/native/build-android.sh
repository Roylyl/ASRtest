#!/bin/bash
set -euo pipefail
ASR_NATIVE_ROOT="$(cd "$(dirname "$0")" && pwd)"
ASR_SDK="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
ASR_NDK="${ASR_NDK_PATH:-$ASR_SDK/ndk/29.0.14206865}"
ASR_CMAKE="${ASR_CMAKE_PATH:-$ASR_SDK/cmake/3.22.1/bin/cmake}"
ASR_NINJA="$ASR_SDK/cmake/3.22.1/bin/ninja"
ASR_OUTPUT="$ASR_NATIVE_ROOT/../app/src/main/jniLibs/arm64-v8a"
mkdir -p "$ASR_OUTPUT"
for ASR_RUNTIME in whisper nano; do
    "$ASR_CMAKE" -S "$ASR_NATIVE_ROOT/$ASR_RUNTIME" -B "$ASR_NATIVE_ROOT/build/$ASR_RUNTIME" -G Ninja \
        -DCMAKE_MAKE_PROGRAM="$ASR_NINJA" \
        -DCMAKE_TOOLCHAIN_FILE="$ASR_NDK/build/cmake/android.toolchain.cmake" \
        -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-26 -DANDROID_STL=c++_shared \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_SHARED_LINKER_FLAGS=-Wl,-z,max-page-size=16384 \
        -DGGML_CPU_ARM_ARCH="${ASR_ARM_ARCH:-armv8-a}"
    "$ASR_CMAKE" --build "$ASR_NATIVE_ROOT/build/$ASR_RUNTIME" --target "asr_$ASR_RUNTIME" -j "${ASR_BUILD_JOBS:-6}"
    cp "$ASR_NATIVE_ROOT/build/$ASR_RUNTIME/libasr_$ASR_RUNTIME.so" "$ASR_OUTPUT/"
    "$ASR_NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-strip" --strip-unneeded "$ASR_OUTPUT/libasr_$ASR_RUNTIME.so"
done
cp "$ASR_NDK/toolchains/llvm/prebuilt/darwin-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" "$ASR_OUTPUT/"
