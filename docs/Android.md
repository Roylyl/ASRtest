# Android开发与自动评测
Android工程位于`apps/android/`，共用权重、演示音频和参考文字位于`shared/assets/`。以下命令除注明外从仓库根目录执行。
## 构建与运行
使用JDK17、Android SDK35。工程固定Gradle8.10.2、AGP8.7.3、Kotlin2.1.0，最低Android8.0，仅构建arm64-v8a。
```sh
./Scripts/build-android.sh
adb install -r -g apps/android/app/build/outputs/apk/debug/app-debug.apk
```
Android Studio打开`apps/android/`，将Gradle JDK设置为17；本地SDK路径保存在被Git忽略的`local.properties`。八组模型随APK集成，首次使用某组模型时复制到App私有目录，不通过网络下载。
## 自动评测
内置四段16kHz单声道演示音频为macOS本地合成语音，包含中文、数字、英文和中英混说。它们用于流程演示与初步比较；真实场景结论应使用真实录音及人工确认的参考文字。
先安装Debug APK并连接开启USB调试的手机，再执行：
```sh
cd apps/android
python3 scripts/run_benchmark.py --threads 2 --runs 3
```
可用`--models zipformer whisperTiny`限定模型，`--corpus zh_short`限定语料，多设备连接时通过`--serial`选择自己的设备。脚本按模型重新启动App，用同一批音频采集JSON/JSONL，生成逐条CSV、汇总CSV和Markdown报告。生成结果位于本地`evaluation/runs/`，不纳入源码仓库。
语料与计分说明见[evaluation/USAGE.md](../apps/android/evaluation/USAGE.md)。Vosk按中文、英文单语范围处理；失败、超时和跳过保留状态，不计为成功样本。
## 指标口径
|指标|定义|
|---|---|
|识别调用耗时|累计音频接收与最终识别调用，包含内部特征提取、解码及Nano VAD；不含模型加载、文件读取、UI等待和日志写入|
|RTF|识别调用耗时÷音频时长；汇总使用耗时总和÷音频时长总和|
|模型加载|创建识别器和加载权重的独立耗时|
|内存|整个App进程VmRSS每100ms采样；加载后基线与识别峰值分开记录；PSS仅为结束快照|
|CER/WER|中文和中英混合按字符编辑距离，英文按词编辑距离；统一忽略大小写、标点及空白|
|参数量|官方模型标称与文件存储元素数分开记录，不将文件大小直接当参数量|
|FLOPs/MIPS|完整ASR计算量与纯推理MIPS未取得；部分逻辑图统计和App指令窗口不能当作完整结果|
数字读法与ITN形式会影响严格CER；保留参考文字和转写原文。重复轮次重新创建识别器，但可能受文件缓存和分配器保留页面影响。内存包含运行库、UI和识别状态，不是模型独占内存；合成语料成绩也不能代表真实场景准确率。
## 原生运行库
Whisper与Nano预构建库位于`apps/android/app/src/main/jniLibs/arm64-v8a/`，Vosk0.3.47与JNA5.13.0依赖位于`apps/android/app/libs/`。sherpa Kotlin接口和识别适配位于`apps/android/app/src/main/java/com/roylyl/asrtest/engines/`。
重建Whisper与Nano需要Android NDK29和CMake：
```sh
./apps/android/native/build-android.sh
```
构建读取根`Vendor/whisper.cpp`与`Vendor/Fun-ASR/third_party/llama.cpp`，JNI封装在`apps/android/native/`。两套GGML分别封装到自己的共享库，避免符号与版本混用。可通过`ASR_NDK_PATH`、`ASR_CMAKE_PATH`、`ASR_BUILD_JOBS`和`ASR_ARM_ARCH`调整工具链。
详细来源与许可见[原生运行库说明](../apps/android/native/SOURCES.md)、[标准后端说明](../Licenses/android/ENGINE-DEPENDENCIES.md)和[根第三方说明](../THIRD_PARTY_NOTICES.md)。Android运行库不能使用iOS XCFramework替代。
