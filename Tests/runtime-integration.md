# ASR 运行库共存验证
验证日期：2026-09-20；仓库复核日期：2026-09-21。生成日志默认不进入 Git，下列命令可重新生成结果。本文只证明链接、模型初始化及已列出的推理路径，不代表真机麦克风、速度或准确率测试。
## 固定依赖
| 依赖 | 选用方式 | 版本或来源 |
|---|---|---|
| sherpa-onnx | 官方 SPM `sherpa-onnx-shared`，动态 XCFramework | 1.13.8，commit `11afbd009a7f8c08f4bcf2fc1b265d0df4670fbf` |
| ONNX Runtime | sherpa 官方包传递引入 `onnxruntime-ios-shared` | 1.28.2，commit `8ebc5ebf92190903c274a7621ba4c96a732335ec` |
| Whisper | 仓库内 `Packages/WhisperRuntime/whisper.xcframework` | whisper.cpp 1.9.4，CPU + Accelerate；逐文件身份见 `RuntimeArtifactsManifest.json` |
| Vosk | 仓库内 `Packages/VoskRuntime/libvosk.xcframework` | `react-native-vosk` commit `970d3d5e49225a1ebc24decbfd2d9317a02e7660` 所带社区二进制；Vosk 核心版本未知 |
| Fun-ASR-Nano | 仓库内 `Packages/NanoRuntime/CNano.xcframework` | Fun-ASR commit `0339018ba74a7defa3b6b6a96718d17b816be77b` 与 llama.cpp commit `8086439a4cea94c71a5dfb8fe4ad1546aebd640f` |
聚合包位于 `Packages/ASRRuntimes`，产品名为 `ASRRuntimes`，对 App 导出 `SherpaOnnxC`、`whisper` 和 `VoskC`；Nano 由独立 `NanoRuntime` 包导出。
## 结果与设计决定
- sherpa 和 Vosk 同时静态链接会产生 73 个重复符号，包括 OpenFst `SymbolTableImpl`。项目没有用忽略重复符号或 `-all_load` 绕过问题。
- 改用官方 shared sherpa 与 shared ONNX Runtime 后，arm64 iOS device 和 arm64 iOS Simulator 均通过链接。
- 2026-09-20 的 Simulator 共存测试在同一进程中依次创建并释放 Zipformer recognizer/stream、Whisper tiny context 和 Vosk English model/recognizer，返回 `ALL THREE RUNTIMES PASS`。
- 2026-09-21 从当前仓库执行无签名 generic iOS 构建成功。Device 结论仅为编译链接通过，尚未在物理 iPhone 上运行本验证程序。
## 复现
先让 SwiftPM 解析固定依赖。`Scripts/check-runtime-link.sh` 接受 `shared|static` 与 `simulator|device`；`RUN_SMOKE=1` 会在已启动的 arm64 Simulator 上运行真实模型初始化。
```sh
RUN_SMOKE=1 Scripts/check-runtime-link.sh shared simulator
Scripts/check-runtime-link.sh shared device
python3 Scripts/prepare-models.py --verify-only
python3 Scripts/prepare-runtimes.py --verify-only
python3 Scripts/prepare-runtimes.py --check-structure
```
动态框架仍需由最终 Xcode App 目标正确嵌入与签名。本验证不替代统一 App 的安装、真实录音和真机性能检查。
## 模型文件
八组模型均在 `ModelLibrary/<ID>` 中版本化，大文件由 Git LFS 保存。`ModelsManifest.json` 记录模型 ID、固定 revision、文件路径、字节数、SHA256 和来源 URL，App Bundle 中的同名清单必须与根清单逐字节一致。Xcode 工程把整个 `ModelLibrary` 作为文件夹资源内置，运行时直接从 Bundle 读取。
Vosk 官方归档没有独立官方 SHA256；清单保存本项目取得归档及解压文件的本地计算哈希，不能将它描述为发布方签名。全部模型和运行库的许可边界见 `THIRD_PARTY_NOTICES.md`。
