<div align="center">

<img src="ASRtest/Assets.xcassets/AppIcon.appiconset/AppIcon.png" alt="ASRtest 应用图标" width="120" height="120">

# ASRtest

**面向 iOS 的多引擎端侧语音识别验证工具**

[![Release](https://img.shields.io/github/v/release/Roylyl/ASRtest?display_name=tag&include_prereleases&sort=semver&style=flat-square)](https://github.com/Roylyl/ASRtest/releases)
[![Downloads](https://img.shields.io/github/downloads/Roylyl/ASRtest/total?style=flat-square)](https://github.com/Roylyl/ASRtest/releases)
[![Stars](https://img.shields.io/github/stars/Roylyl/ASRtest?style=flat-square)](https://github.com/Roylyl/ASRtest/stargazers)
[![Forks](https://img.shields.io/github/forks/Roylyl/ASRtest?style=flat-square)](https://github.com/Roylyl/ASRtest/forks)
[![Open Issues](https://img.shields.io/github/issues/Roylyl/ASRtest?style=flat-square)](https://github.com/Roylyl/ASRtest/issues)
[![License](https://img.shields.io/github/license/Roylyl/ASRtest?style=flat-square)](LICENSE)
[![Repo Size](https://img.shields.io/github/repo-size/Roylyl/ASRtest?style=flat-square)](https://github.com/Roylyl/ASRtest)
[![Last Commit](https://img.shields.io/github/last-commit/Roylyl/ASRtest?style=flat-square)](https://github.com/Roylyl/ASRtest/commits/main)
[![Repository checks](https://github.com/Roylyl/ASRtest/actions/workflows/repository-checks.yml/badge.svg)](https://github.com/Roylyl/ASRtest/actions/workflows/repository-checks.yml)
[![Platform](https://img.shields.io/badge/platform-iOS%2017%2B-blue?style=flat-square)](#系统要求与构建)

[项目概览](#项目概览) · [功能特性](#功能特性) · [界面预览](#界面预览) · [模型矩阵](#模型矩阵) · [快速开始](#快速开始) · [构建](#系统要求与构建) · [验证](#校验与测试) · [许可](#许可证与公开发布状态)

</div>

> [!IMPORTANT]
> 当前完整资源 revision 是本地发布候选，尚未作为公共 Release 推送。SenseVoiceSmall 固定 ONNX 权重的历史许可对应关系，以及 Vosk 社区预编译库的完整传递依赖告知仍待确认；在这些问题解决前，不应公开发布当前完整资源集合。Git LFS 只负责存储，不代表取得或授予再分发权。

## 项目概览

ASRtest 是一个完全本地运行的 iOS 端侧语音识别测试工具。它把多套 ASR 推理框架放在统一的录音、结果、计时、日志和模型切换界面中，方便在相同设备与输入条件下进行验证。当前应用版本为 **1.0.0**，最低支持 iOS 17；iOS 26 及以上使用系统 Liquid Glass，较旧系统使用原生兼容样式。

应用只有三个页面：测试、日志及模型信息、设置。流式模型显示实时结果，非流式模型在停止录音后转写。音频和识别记录留在设备本地，不使用云端 ASR、聊天、摘要或服务器推理。

## 功能特性

- **八组本地 ASR 配置**：统一接入 sherpa-onnx、whisper.cpp、Vosk，以及 Fun-ASR / llama.cpp / GGML 原生移植。
- **统一测试工作流**：在同一套录音、结果、计时、日志、模型信息和设置界面中比较不同后端。
- **流式与非流式覆盖**：流式模型实时显示结果，非流式模型在停止录音后转写。
- **资源可验证**：模型与本地运行库分别由清单记录来源、固定 revision、字节数和 SHA256，并在运行前校验。
- **本地优先**：安装后的语音识别不访问网络；录音与识别记录保留在设备本地。
- **自动化检查入口**：包含仓库元数据、模型存储、标准后端、统一核心和界面导航检查脚本。

## 界面预览

<table>
  <tr>
    <td align="center"><img src="Preview/ui-test-light.png" alt="浅色测试页" width="240"><br><sub>测试页 · 浅色</sub></td>
    <td align="center"><img src="Preview/ui-test-dark.png" alt="深色测试页" width="240"><br><sub>测试页 · 深色</sub></td>
    <td align="center"><img src="Preview/ui-model-selector-light.png" alt="模型选择器" width="240"><br><sub>模型选择</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="Preview/ui-logs-light.png" alt="日志页" width="240"><br><sub>日志与模型信息</sub></td>
    <td align="center"><img src="Preview/ui-settings-light.png" alt="设置页" width="240"><br><sub>设置</sub></td>
    <td align="center"><img src="Preview/ui-progress.png" alt="模型加载进度" width="240"><br><sub>模型加载进度</sub></td>
  </tr>
</table>

## 模型矩阵

| 配置 | 推理框架 | App 提供的语言选项 | 方式 | 必要模型大小 |
|---|---|---|---|---:|
| Zipformer Small | sherpa-onnx | 中文、英文 | 流式 | 60.14 MB |
| Whisper tiny multilingual | whisper.cpp | 自动、中文、英文 | 停止后转写 | 77.69 MB |
| Whisper base multilingual | whisper.cpp | 自动、中文、英文 | 停止后转写 | 147.95 MB |
| Vosk small-cn-0.22 | Vosk | 中文 | 流式 | 68.29 MB |
| Vosk small-en-us-0.15 | Vosk | 英文 | 流式 | 70.90 MB |
| SenseVoiceSmall INT8 | sherpa-onnx Offline API | 自动、中文、英文、粤语、日语、韩语 | 停止后转写 | 239.55 MB |
| Paraformer Streaming INT8 | sherpa-onnx Online API | 中文、英文 | 流式 | 237.20 MB |
| Fun-ASR-Nano Q4 | Fun-ASR / llama.cpp / GGML 原生移植 | 自动、中文、英文、日语 | 停止后本地 VAD 分段与转写 | 955.27 MB |

八组模型的 42 个运行文件合计 **1,857,000,819 字节**。仓库还包含 Whisper、Vosk、Nano 的 iPhone 与 arm64 Simulator 运行库，以及固定版本的 Vendor 源码快照。模型和编译后的运行库使用 Git LFS；构建缓存、个人签名、设备日志和录音不会进入版本控制。

一次只加载一个模型。当前每轮流式录音上限为 600 秒，非流式为 30 秒，这是测试工具的限制。Nano 是实验性 iOS 移植；物理 iPhone 上的峰值内存、耗电、温升和长时间稳定性仍需实测。

## 快速开始

先安装 [Git LFS](https://git-lfs.com/)，再克隆并拉取大文件：

```sh
git lfs install
git clone https://github.com/Roylyl/ASRtest.git
cd ASRtest
git lfs pull
python3 Scripts/prepare-models.py --verify-only
python3 Scripts/prepare-runtimes.py --verify-only
```

模型、XCFramework 和 Vendor 源码均属于仓库版本内容；克隆后由 Git LFS 取得对应对象。`ModelsManifest.json` 记录模型来源、固定 revision、字节数和 SHA256；`RuntimeArtifactsManifest.json` 记录运行库指纹与来源。校验失败时应查明文件或版本差异，不能仅修改清单哈希。

## 系统要求与构建

需要 Apple Silicon Mac、完整 Xcode 和 iOS 17 以上 SDK。本项目使用 Xcode 27.1 / iOS 27.1 SDK 完成当前检查；本地运行库提供 arm64 iPhone 和 Apple Silicon 上的 arm64 iOS Simulator 切片，不提供 Intel Simulator 的完整组合。

1. 复制个人配置：

   ```sh
   cp Config/Local.xcconfig.example Config/Local.xcconfig
   ```

   在 `Config/Local.xcconfig` 中填写自己的 Team ID 和唯一 Bundle Identifier。该文件被 Git 忽略。

2. 打开 `ASRtest.xcodeproj`，选择共享 Scheme **ASRtest**。SwiftPM 会按 `Package.resolved` 解析 sherpa-onnx 1.13.8 与 ONNX Runtime 1.28.2；首次解析需要网络。

3. 选择 iPhone 或 arm64 iOS Simulator 运行。允许麦克风权限，等待当前模型加载完成，再开始录音。

安装后的 ASR 推理不访问网络。Xcode 下载依赖、开发者签名与 App 离线识别是不同环节。

## 架构与目录

```text
ASRtest/                       SwiftUI、录音控制、模型目录与识别后端
ASRtest.xcodeproj/             App/UI 测试工程与共享 Scheme
Config/                        共享配置、签名示例和 Info.plist
Packages/                      Swift 包、桥接源码及三套本地 XCFramework
ModelLibrary/                  八组内置模型（Git LFS）
Vendor/                        固定版本第三方源码快照及来源清单
ModelsManifest.json            模型来源、版本和逐文件校验值
RuntimeArtifactsManifest.json  本地运行库来源与逐文件校验值
Scripts/                       资源校验、可选重建和检查脚本
Tests/                         引擎、存储与 UI 测试源码
Licenses/                      依赖及参考项目的许可和来源记录
THIRD_PARTY_NOTICES.md          第三方归属、修改与模型许可边界
```

`NativeASREngine` 统一加载、开始、接收音频、结束和释放接口；具体后端保留自身的流式状态和结束方式。`RecognitionBackend` 负责音频转换、结果及测试记录，`ASRController` 管理录音与界面状态。主要识别和音频会话工作在后台串行队列执行。

Vendor 是去除嵌套 Git 元数据的固定源码快照，版本和原仓库见 `Vendor/SOURCES.md`。构建仍以 Xcode 工程和 SwiftPM 声明为准，Vendor 中的审阅副本不会被重复链接。

## 校验与测试

检查模型、运行库身份及基本打包结构：

```sh
python3 Scripts/check-repository.py
python3 Scripts/prepare-models.py --verify-only
python3 Scripts/prepare-runtimes.py --verify-only
python3 Scripts/prepare-runtimes.py --check-structure
```

检查模型存储和界面导航：

```sh
bash Scripts/run-model-store-smoke.sh
bash Scripts/run-ui-smoke.sh
```

UI 检查需要唯一一个已启动的 arm64 iOS Simulator；可用 `ASR_UI_SIMULATOR` 指定设备。它会检查三个页面、八组模型入口、Whisper tiny 与 Zipformer 的真实切换，以及浅色和深色显示，不会启动录音。

标准后端和统一核心回归入口分别为：

```sh
Tests/run-standard-engine-smoke.sh /absolute/english.wav /absolute/mixed-zh-en.wav
Tests/run-core-smoke.sh /absolute/english.wav /absolute/mixed-zh-en.wav
```

输入应为 16 kHz 单声道 WAV。Simulator 结果验证调用路径和生命周期，不代表真机准确率、耗时、内存或温升。

Whisper 和 Nano 提供固定源码重建脚本：

```sh
python3 Scripts/build-whisper.py --replace
python3 Scripts/build-nano.py
```

源码重编产物不保证与既有二进制逐字节相同。重建后必须重新编译 App、检查导出接口并运行实际推理测试。Vosk 当前使用固定社区预编译包，其内部核心 revision 和完整静态依赖清单仍待补齐。

## 贡献

提交改动前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md) 和 [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)。新增或替换模型、运行库时，必须同时更新来源、不可变版本、许可、大小、SHA256 和适用测试。安全问题见 [SECURITY.md](SECURITY.md)。

## 许可证与公开发布状态

除另有标注外，ASRtest 原创源码、文档、测试、配置及项目自制界面资源采用 [Apache License 2.0](LICENSE)。该许可不覆盖仓库中的第三方源码、预编译运行库、模型权重、商标和另有条款的媒体；第三方内容继续适用其各自许可或使用条款，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)、`Licenses/` 以及 Vendor 内保留的许可文件。

当前完整资源 revision 是本地发布候选，尚未作为公共 release 推送。SenseVoiceSmall 固定 ONNX 权重的历史许可对应关系，以及 Vosk 社区预编译库的完整传递依赖告知仍待确认；解决前不应公开发布当前完整资源集合。Git LFS 只负责存储，不代表取得或授予再分发权。

主要上游项目：

- sherpa-onnx：https://github.com/k2-fsa/sherpa-onnx
- whisper.cpp：https://github.com/ggml-org/whisper.cpp
- Vosk：https://github.com/alphacep/vosk-api
- SenseVoice：https://github.com/QwenAudio/SenseVoice
- FunASR / Paraformer：https://github.com/modelscope/FunASR
- Fun-ASR / Nano：https://github.com/QwenAudio/Fun-ASR
