# ASR 运行库共存验证
历史验证日期：2026-09-20。文中日志保留在完整本地备份，默认不进入 Git；新克隆需要按下方命令重新生成。此记录只说明链接及本地模型初始化情况，不代表真机麦克风、速度或准确率测试。
## 最终依赖
| 依赖 | 选用方式 | 版本或来源 |
|---|---|---|
| sherpa-onnx | 官方 SPM `sherpa-onnx-shared`，动态 XCFramework | 精确 1.13.8，commit `11afbd009a7f8c08f4bcf2fc1b265d0df4670fbf` |
| ONNX Runtime | sherpa 官方包传递引入 `onnxruntime-ios-shared` | 精确 1.28.2，commit `8ebc5ebf92190903c274a7621ba4c96a732335ec` |
| Whisper | 原 ASRtest2IOS 本地 `WhisperRuntime` | whisper.cpp 1.9.4，CPU + Accelerate；原二进制未修改 |
| Vosk | 原 ASRtest3IOS 本地 `VoskRuntime` | 社区 XCFramework，Vosk 核心版本未知；原二进制未修改 |
聚合包位于 `Packages/ASRRuntimes`，产品名 `ASRRuntimes`，对应用导出 `SherpaOnnxC`、`whisper`、`VoskC`。
## 结果
- 原静态 sherpa 与静态 Vosk 真实链接失败：73 个重复符号，包括 OpenFst 的 `SymbolTableImpl`，见 `runtime-static-link.log`。没有忽略重复符号或使用 `-all_load`。
- 换用官方 shared sherpa 与 shared ONNX Runtime 后，arm64 iOS device 和 arm64 iOS Simulator 均链接成功，见 `runtime-shared-device.log`、`runtime-shared-simulator.log`。
- Simulator 同一进程顺序完成 Zipformer recognizer/stream、Whisper tiny context、Vosk English model/recognizer 的实际创建和释放，返回码 0，输出 `ALL THREE RUNTIMES PASS`。
- Device 结果仅为编译链接通过，未在用户 iPhone 上执行此验证程序。
## 复现
先确认 SPM 已解析并缓存官方二进制。`Scripts/check-runtime-link.sh` 接受 `shared|static` 与 `simulator|device` 两个参数；可用环境变量 `SHERPA_ARTIFACTS` 指定 Xcode 的 `SourcePackages/artifacts` 目录。`RUN_SMOKE=1` 时在已经启动的 Simulator 上运行真实模型初始化。
```sh
RUN_SMOKE=1 Scripts/check-runtime-link.sh shared simulator
Scripts/check-runtime-link.sh shared device
python3 Scripts/prepare-models.py --verify-only
```
动态框架仍需由最终 Xcode 应用目标正确嵌入与签名；本验证不替代统一 App 的构建和安装检查。
## 模型文件
原有五个模型从桌面的三个原工程复制，保留文件内容；SenseVoice Small INT8 与 Streaming Paraformer INT8 从 sherpa 官方文档所指的 Hugging Face 仓库下载。ONNX 文件逐个对比固定 revision 的 LFS SHA256，词表对比同 revision 的 Git blob SHA1，并为 App 另生成 SHA256。
`ModelsManifest.json` 保存每个模型 ID、版本、文件路径、字节数、SHA256 和来源 URL。模型源位于工程 `ModelLibrary/<ID>` 目录，准备脚本负责校验或补齐这些文件；当前 Xcode 工程将整个 `ModelLibrary` 作为文件夹资源加入 App Bundle，八组模型默认全部内置，运行时直接从 Bundle 读取。Vosk 的官方归档没有独立官方 SHA256，本地清单保留原下载归档和解压文件的哈希，不能将其描述为官方签名。
