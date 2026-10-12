# Android原生ASR运行库来源
本目录从现有ASRtest的固定源码复用Whisper与Fun-ASR-Nano推理实现，重新构建Androidarm64-v8a共享库，不使用iOS二进制。
|组件|来源|许可与改动|
|---|---|---|
|Whisper|https://github.com/ggml-org/whisper.cpp；源码快照位于仓库根目录Vendor/whisper.cpp|MIT，保留原LICENSE。新增whisper/whisper_jni.cpp桥接，使用CPU及贪心解码，保持现有iOS的主要识别设置。|
|Fun-ASR-Nano音频编码及转写|https://github.com/QwenAudio/Fun-ASR/tree/0339018ba74a7defa3b6b6a96718d17b816be77b/runtime/llama.cpp|Apache-2.0，保留LICENSE-Fun-ASR。nano_core.cpp、nano_api.inc、funasr_vad.h、asr_nano.h直接复用apps/ios/Packages/NanoRuntime/Sources/CNano中的适配实现。新增nano_jni.cpp，不改原模型结构。|
|Nano的llama.cpp/GGML|https://github.com/ggml-org/llama.cpp/tree/8086439a4cea94c71a5dfb8fe4ad1546aebd640f|MIT，保留LICENSE-llama.cpp及仓库根目录Vendor/Fun-ASR/third_party/llama.cpp/LICENSE。源码快照与原iOS项目一致。|
|C++运行库|AndroidNDK29.0.14206865中的libc++_shared.so|保留AndroidNDK的NOTICE说明；由native/build-android.sh复制对应arm64库。|
两套GGML分别静态链接到libasr_whisper.so与libasr_nano.so。动态导出仅保留各自JNI函数，避免不同版本的GGML符号互相覆盖。
运行输入为16kHz单声道Float32，单次最长30秒。Whisper和Nano在停止录音后生成最终文字；Nano保留本地FSMN-VAD、最长10秒分段、512token上下文及1—4线程设置。没有云端回退。
在apps/android目录执行构建命令：
```bash
./native/build-android.sh
```
默认CPU指令基线armv8-a、AndroidAPI26、共享库16KB页对齐。可通过ASR_NDK_PATH、ASR_CMAKE_PATH、ASR_BUILD_JOBS、ASR_ARM_ARCH调整工具链和构建设置。预构建库位于app/src/main/jniLibs/arm64-v8a。
调用create/transcribe/close必须在同一串行识别线程；cancel可从UI线程调用。句柄使用注册表和共享生命周期，取消与关闭并发时不会访问释放后的指针。原生推理错误抛出IllegalStateException，主动取消抛出CancellationException。
