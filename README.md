# ASRtest
ASRtest 是一个完全在本机运行的 iOS 语音识别测试工具，将多套 ASR 推理框架放在同一应用中，便于在相同设备和录音条件下比较识别结果与运行表现。版本为 **1.0.0**，采用原生三页 Tab Bar；支持的系统使用 Liquid Glass 控件。
应用包含“测试”“日志及模型信息”“设置”三个页面，支持模型切换、麦克风输入源选择、语言及适用参数设置、结果展示与本地测试记录。流式模型显示实时结果；非流式模型停止录音后转写。音频不会发送到服务器，应用没有云端 ASR、聊天或摘要功能。
## 模型与实现
| 配置 | 本地推理框架 | 当前应用提供的语言 | 识别方式 | 必要模型文件大小 |
|---|---|---|---|---:|
| Zipformer Small | sherpa-onnx | 中文、英文 | 流式 | 60.14 MB |
| Whisper tiny multilingual | whisper.cpp | 自动、中文、英文 | 停止后转写 | 77.69 MB |
| Whisper base multilingual | whisper.cpp | 自动、中文、英文 | 停止后转写 | 147.95 MB |
| Vosk small-cn-0.22 | Vosk | 中文 | 流式 | 68.29 MB |
| Vosk small-en-us-0.15 | Vosk | 英文 | 流式 | 70.90 MB |
| SenseVoiceSmall INT8 | sherpa-onnx Offline API | 自动、中文、英文、粤语、日语、韩语 | 停止后转写 | 239.55 MB |
| Paraformer Streaming INT8 | sherpa-onnx Online API | 中文、英文 | 流式 | 237.20 MB |
| Fun-ASR-Nano Q4 | Fun-ASR / llama.cpp / GGML 原生移植 | 自动、中文、英文、日语 | 停止后本地 VAD 分段与转写 | 955.27 MB |
大小按十进制 MB 计算，包含对应配置的必要文件，不代表安装大小或运行内存。八组模型合计 **1,857,000,819 字节，约 1.857 GB**。一次只加载一个模型；Nano 为实验性 iOS 移植，目标手机上的内存、温升和稳定性仍需验证。
当前每轮流式录音上限为 600 秒，非流式为 30 秒。这是测试工具的限制，不是模型能力上限。Whisper 支持的完整语言范围大于当前界面提供的选项。
## 本地备份与 Git 内容
此目录的本地备份已包含模型、三套本地 XCFramework 和 Nano 所需的上游源码，可以直接在这台 Mac 上继续构建。桌面原工程保持独立。
Git 默认只收录应用源码、Xcode 工程、包声明、模型及运行库清单、准备脚本、测试源码、说明和许可文件。以下内容保留在本地，但由 `.gitignore` 排除：

- `ModelLibrary/`：八组模型及配套词表。
- `Packages/**/*.xcframework`：Whisper、Vosk、Nano 预编译运行库。
- `Vendor/`：固定版本的第三方源码及嵌套仓库。
- 构建缓存、测试输出、录音、设备日志、个人签名配置和旧报告。

因此，**只克隆 Git 源码不会同时获得约 1.857 GB 的模型和本地运行库**。克隆后需按下文恢复资源。资源仍会在构建时打入 App Bundle，安装后无需下载或导入；电脑端的准备脚本不属于 App 的运行功能。仓库未配置 Git LFS。
## 打开和运行
环境：macOS、Apple Silicon、完整 Xcode。本版本使用 Xcode 27.1 / iOS 27.1 SDK 验证，部署目标 iOS 17.0；Liquid Glass API 在 iOS 26 及以上启用，较旧系统使用标准控件。当前本地运行库支持 arm64 iPhone 和 arm64 iOS Simulator，不提供 Intel Mac 的 x86_64 Simulator 完整组合。

1. 在工程根目录检查资源：
   ```sh
   python3 Scripts/prepare-models.py --verify-only
   python3 Scripts/prepare-runtimes.py --verify-only
   ```
2. 打开 `ASRtest.xcodeproj`，使用共享 Scheme **ASRtest**。首次解析 sherpa-onnx / ONNX Runtime 的 SwiftPM 依赖需要网络。
3. 个人签名配置放在 Git 忽略的 `Config/Local.xcconfig`。本地备份已保留原设置；其他电脑可复制 `Config/Local.xcconfig.example` 为该文件，填写自己的 Team ID 和唯一 Bundle Identifier。共享默认配置在 `Config/Project.xcconfig`。
4. 选择 iPhone 或 arm64 iOS Simulator 后运行。允许麦克风权限，等待模型就绪，再开始录音。输入源支持自动刷新和手动刷新。

原生 ASR 推理不需要网络。真机签名、Xcode 下载依赖与 App 安装后的离线识别是不同环节。
## 克隆后的资源恢复
### 从完整本地备份恢复
保留完整工程目录作为模型和运行库的备份来源。在新的仓库目录中运行，路径替换成自己的完整备份：

```sh
cp -R "/path/to/full-backup/ModelLibrary" ./ModelLibrary
python3 Scripts/prepare-runtimes.py --from "/path/to/full-backup"
python3 Scripts/prepare-models.py --verify-only
python3 Scripts/prepare-runtimes.py --verify-only
```

复制前应确保目标 `ModelLibrary` 尚不存在，避免产生嵌套目录。`ModelsManifest.json` 记录权重来源、固定 revision、文件大小和 SHA256；`RuntimeArtifactsManifest.json` 记录本次备份运行库的文件指纹。校验失败时先核对资源版本，不能以更改哈希代替验证。
### 从上游重新准备
模型准备脚本可根据固定清单下载并校验文件；执行前先阅读 [第三方与模型许可说明](THIRD_PARTY_NOTICES.md)，尤其 SenseVoiceSmall 的模型专用条款。

```sh
python3 Scripts/prepare-models.py
```

运行库恢复与重建选项以 `python3 Scripts/prepare-runtimes.py --help` 为准。Vosk 当前优先从完整本地备份恢复，本仓库未提供社区预编译包的自动下载，也未完成该二进制的完整许可核查。Whisper 提供固定源码的构建脚本：

```sh
python3 Scripts/build-whisper.py --fetch
```

已有运行库时，需显式加 `--replace` 才会替换。该 Whisper 重建脚本在本次备份中只完成语法及命令帮助检查，未重新执行完整源构建；当前可用的本地备份仍使用已校验的原运行库。Nano 的固定版本构建入口为：

```sh
python3 Scripts/build-nano.py
```

Nano 重建需要 CMake，会取得固定版本 Fun-ASR 和 llama.cpp 源码，生成 iPhone 与 Simulator 切片。Whisper、Vosk 的具体恢复边界见运行库清单与脚本帮助。源码重编生成的文件不保证与原预编译包逐字节相同，不应把原包 SHA256 当作所有工具链的可重现构建承诺。新构建可用 `python3 Scripts/prepare-runtimes.py --check-structure` 检查切片、头文件和接口符号，但仍需重新编译 App 并验证识别；该检查不等同于功能或许可验证。
## 工程结构
```text
ASRtest/                 SwiftUI 页面、统一控制器、模型目录与各后端
ASRtest.xcodeproj/       App 与 UI 测试工程、共享 Scheme、SwiftPM 锁定文件
Config/                  共享配置、签名配置示例、Info.plist
Packages/                Swift 包、原生桥接代码和本地运行库
ModelLibrary/            全部内置模型（本地资源，不进入 Git）
ModelsManifest.json      模型来源、固定版本、逐文件校验值
RuntimeArtifactsManifest.json  本地运行库指纹与来源
Scripts/                 资源准备、构建与检查脚本
Tests/                   引擎、模型存储和 UI 检查源码
Licenses/                依赖及参考项目的上游许可和来源记录
THIRD_PARTY_NOTICES.md    第三方归属、修改说明及模型许可区别
```
`NativeASREngine` 提供共同接口；各后端保留自己的流式状态和结束方式。`RecognitionBackend` 处理音频转换、识别结果与记录，`ASRController` 管理录音和界面状态。识别及音频会话的主要操作在后台串行队列执行。
运行库固定版本：sherpa-onnx 1.13.8、ONNX Runtime 1.28.2、whisper.cpp 1.9.4。Vosk 使用固定社区仓库提交的预编译包，其内部 Vosk 核心版本未知。Nano 固定 Fun-ASR 与 llama.cpp 提交；详细来源及许可见 `THIRD_PARTY_NOTICES.md`。
## 测试与结果记录
记录保存在 App `Documents/Sessions`，包含模型、配置、语言、输入源、识别文字、音频时长、耗时、状态和错误。可以在 App 中导出，或通过 Finder 文件共享复制。麦克风原始音频只在内存中处理，不写入录音文件。
“识别调用耗时”只统计已定义的原生调用范围，排除录音等待、音频转换和界面更新，不能直接作为不同架构严格可比的 RTF；“停止后等待”反映结束录音后的等待体验；模型加载另行计时。
模型存储与界面检查：

```sh
bash Scripts/run-model-store-smoke.sh
bash Scripts/run-ui-smoke.sh
```

先启动一个 arm64 iOS Simulator。UI 脚本检查三个页面、八个模型入口、Whisper tiny 与 Zipformer 切换和浅深色显示，不启动录音。模拟器选择和输出位置见 `Tests/UITests/README.md`。
标准引擎及统一核心的样本回归分别使用 `Tests/run-standard-engine-smoke.sh`、`Tests/run-core-smoke.sh`，参数依次为英文和中英混说 WAV 的绝对路径（16 kHz 单声道）。默认运行库缓存为 `.build/SourcePackages/artifacts`；可通过 `SHERPA_ARTIFACTS` 指定 Xcode 实际使用的缓存目录。用 `BUNDLED_MODELS_ROOT` 指定已构建 App 内的 `ModelLibrary`，可直接检查成品资源。核心回归的 Nano 样本来自固定版本 Vendor 源码，相关目录需已恢复。
桌面版本此前已完成八组模型本地文件推理、重复会话、取消与异常恢复、日志写入、文件校验和 UI 检查。历史结果只代表当时的代码与环境；本次仓库整理的验证另见 [备份检查说明](Documentation/BackupValidation.md)。物理 iPhone 的麦克风、准确率、内存、耗电、温升和长时间稳定性仍需实测，不能用模拟器耗时替代手机结论。
## 版权、许可与来源
这是多项目的整合测试工程，**不拥有第三方框架、模型及其派生代码的原始版权**。原作者声明和许可原文保存在 `Licenses/` 及相关包目录，来源、固定提交和本地修改见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
本仓库尚未为新增的应用整合代码指定统一的 MIT、Apache 或其他开源许可。新增代码的权属和对外许可应由相应权利人确定；这不改变第三方内容自身的许可。不要将框架代码许可直接等同于模型权重许可，也不要把“本地测试通过”理解为“已完成再分发许可核查”。
SenseVoiceSmall 的源模型使用专门的模型许可；当前 ONNX 转换副本的许可说明存在缺口。Vosk 社区二进制的内部核心版本及完整依赖清单也尚未完全确认。因此权重、预编译包与 Vendor 默认不进入 Git；如另行发布包含这些资源的 App 或二进制，需要保留其适用声明并进一步核对对应条款。详细区别和核对来源见第三方说明。
项目链接：

- sherpa-onnx：https://github.com/k2-fsa/sherpa-onnx
- whisper.cpp：https://github.com/ggml-org/whisper.cpp
- Vosk：https://github.com/alphacep/vosk-api
- SenseVoice：https://github.com/QwenAudio/SenseVoice
- FunASR / Paraformer：https://github.com/modelscope/FunASR
- Fun-ASR / Nano：https://github.com/QwenAudio/Fun-ASR
