# ASRtest Android
Android端侧ASR应用源码。模型与iOS共用仓库根目录的`shared/assets/ModelLibrary/`，原生运行库为Android独立构建。
- [项目介绍与快速开始](../../README.md)
- [Android开发、自动评测与指标](../../docs/Android.md)
- [原生运行库来源](native/SOURCES.md)
- [标准后端来源及许可](../../Licenses/android/ENGINE-DEPENDENCIES.md)

Android Studio打开本目录，将Gradle JDK设置为JDK17。也可从仓库根目录运行：
```sh
./Scripts/build-android.sh
adb install -r -g apps/android/app/build/outputs/apk/debug/app-debug.apk
```
最低Android8.0，仅支持arm64-v8a。版本1.0.0，模型与识别均在手机本地运行。
