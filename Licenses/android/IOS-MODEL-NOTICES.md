# 第三方来源与许可说明
核对日期：2026-09-21。本文记录ASRtest当前使用的代码、模型及预编译库的来源和已核实许可，不是完整的二进制依赖清单或法律审查结论。代码许可、模型权重许可和预编译库内各组件许可分别适用；“开源仓库”不代表所有文件均采用同一种许可。
除另有标注外，ASRtest原创源码、文档、测试、配置及项目自制界面资源采用仓库根目录的Apache License 2.0；该许可不覆盖第三方源码、预编译运行库、模型权重、商标或另有条款的媒体，也不代替其权利人授权。`shared/assets/ModelLibrary/`、`Vendor/` 和XCFramework均由本仓库直接保存，其中大型文件使用Git LFS；LFS跟踪不改变任何第三方许可或使用条款。
## 1. 代码与运行库
| 组件 | 本工程固定来源 | 许可与保留说明 |
|---|---|---|
| sherpa-onnx | `1.13.8` / `11afbd009a7f8c08f4bcf2fc1b265d0df4670fbf`，官方SPM shared产品 | Apache-2.0；原文为 `Licenses/sherpa-onnx-APACHE-2.0.txt`。保留上游署名；将来分发二进制时还需覆盖该构建中实际链接的第三方组件。 |
| ONNX Runtime | `csukuangfj/onnxruntime-libs` 包 `1.28.2` / `8ebc5ebf92190903c274a7621ba4c96a732335ec` | ONNX Runtime核心为MIT；使用的是该仓库发布的SPM构建。保留 `Licenses/ONNX-Runtime-MIT.txt` 和同版本 `ONNX-Runtime-ThirdPartyNotices.txt`。完整告知是上游版本清单，不代表其中所有组件都进入本iOS构建。 |
| whisper.cpp / GGML | `1.9.4` / `927cfce34f31707e17f2bff35c349632fb9e2c3a`，本地 `WhisperRuntime` | MIT；`Licenses/whisper.cpp-MIT.txt` 含ggml authors版权声明。原有CPU + Accelerate XCFramework保留在本地。 |
| Vosk C API | 本地 `apps/ios/Packages/VoskRuntime/Vosk-API.h` | 文件保留Alpha Cephei Inc. 2020–2021署名和Apache-2.0头部；补存 `Licenses/Vosk-API-APACHE-2.0.txt`。许可参考来自官方源码，不能据此推定当前二进制核心版本。 |
| Vosk社区预编译包 | `riderodd/react-native-vosk` / `970d3d5e49225a1ebc24decbfd2d9317a02e7660` 中 `ios/libvosk.xcframework` | 社区仓库的MIT文件已保留为 `Licenses/react-native-vosk-MIT.txt`。它不替代Vosk、Kaldi、OpenFst等底层组件自己的许可；当前包缺少可核验的核心revision和完整构建依赖清单，公开分发此二进制前须补齐或从可审计源码重建。 |
| Fun-ASR Nano原生移植 | `QwenAudio/Fun-ASR` / `0339018ba74a7defa3b6b6a96718d17b816be77b` | 该固定版本的本地根LICENSE是Apache-2.0，保存在 `Licenses/Fun-ASR-APACHE-2.0.txt`。适用范围包括抽取的原生推理代码；不据当前其他FunASR仓库的许可覆盖它。 |
| llama.cpp / GGML | `8086439a4cea94c71a5dfb8fe4ad1546aebd640f` | MIT；保留 `Licenses/llama.cpp-MIT.txt`。Nano构建使用Vendor中固定子模块。 |
| SenseVoice、FunASR项目参考 | 当前参考源码分别为 `ea15219509625e5d4c5143c37c86970135886b5d`、`1878d61dbe8942587acb1f5543ec77dc1ca1e73c` | 这两个参考版本的代码LICENSE为MIT，原文单列保存；本App的SenseVoice、Paraformer经sherpa-onnx推理，并未直接引入这两套Python运行时。代码许可不能作为权重许可。 |
固定源码地址：
- https://github.com/k2-fsa/sherpa-onnx/tree/11afbd009a7f8c08f4bcf2fc1b265d0df4670fbf
- https://github.com/csukuangfj/onnxruntime-libs/tree/8ebc5ebf92190903c274a7621ba4c96a732335ec
- https://github.com/ggml-org/whisper.cpp/tree/927cfce34f31707e17f2bff35c349632fb9e2c3a
- https://github.com/riderodd/react-native-vosk/tree/970d3d5e49225a1ebc24decbfd2d9317a02e7660
- https://github.com/alphacep/vosk-api
- https://github.com/QwenAudio/Fun-ASR/tree/0339018ba74a7defa3b6b6a96718d17b816be77b
- https://github.com/ggml-org/llama.cpp/tree/8086439a4cea94c71a5dfb8fe4ad1546aebd640f
## 2. 八组模型权重
以下为发布方模型卡或官方模型列表的声明。模型文件本体已经通过Git LFS纳入仓库；名称、下载来源、固定revision和逐文件SHA256在 `ModelsManifest.json` 中保留。量化、格式转换、LFS跟踪以及由sherpa-onnx加载，都不会自动改变原权重许可。
| 配置 | 已核实声明 | 说明 |
|---|---|---|
| Zipformer Small中英 | Apache-2.0 | 固定转换仓库模型卡标注该许可，注明原始模型来自 `pfluo/k2fsa-zipformer-chinese-english-mixed`。 |
| Whisper tiny multilingual | MIT | 固定ggml模型卡标注MIT；保留OpenAI原模型和whisper.cpp转换实现的署名与许可。 |
| Whisper base multilingual | MIT | 与tiny同一固定转换仓库，许可处理相同。 |
| Vosk small-cn-0.22 | Apache-2.0 | 官方模型列表针对这个准确名称明确列出该许可。保留模型原README。 |
| Vosk small-en-us-0.15 | Apache-2.0 | 官方列表明确列出该许可；原README带有Alpha Cephei Inc. 2020版权声明，保留原文。 |
| SenseVoiceSmall INT8 ONNX | 不能确认为Apache/MIT；原权重当前引用FunASR Model License | 本工程固定ONNX仓库README只有转换来源，没有独立许可声明；当前官方Small权重卡为 `license: other`，指向FunASR `MODEL_LICENSE`。保留所取协议原文，分发该旧ONNX副本前需进一步确认对应权重版本的授权范围。 |
| Paraformer Streaming INT8 ONNX | Apache-2.0 | 固定ONNX模型卡明确标注Apache-2.0；其所指向的ModelScope原模型README在核对日也标注Apache License 2.0。 |
| Fun-ASR-Nano Q4 | Apache-2.0 | 固定官方Nano GGUF模型卡和单独的FSMN-VAD GGUF模型卡均标注该许可。保留encoder/adaptor、配套Qwen3 ASR decoder与FSMN-VAD各自来源；不能把通用Qwen3文件任意替换后沿用此记录。 |
模型许可来源：
- Zipformer：https://huggingface.co/csukuangfj/k2fsa-zipformer-bilingual-zh-en-t/blob/e2382758de9a0219b4efe682b95af30b399db3b8/README.md
- Whisper tiny/base：https://huggingface.co/ggerganov/whisper.cpp/blob/5359861c739e955e79d9a303bcbc70fb988958b1/README.md
- Whisper原始模型许可证：https://github.com/openai/whisper/blob/86098128c0b4f24f0e2aa2994de830614b474227/LICENSE
- Vosk官方模型列表：https://alphacephei.com/vosk/models
- SenseVoice ONNX：https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/blob/2365baeacb507f821a0c8120fcee3d484dba7a07/README.md
- SenseVoiceSmall官方权重卡：https://huggingface.co/FunAudioLLM/SenseVoiceSmall/blob/3847d57b6bdf2dd8875cb1508d2af43d80a16bf7/README.md
- FunASR模型协议：https://github.com/modelscope/FunASR/blob/1878d61dbe8942587acb1f5543ec77dc1ca1e73c/MODEL_LICENSE
- Paraformer ONNX：https://huggingface.co/csukuangfj/sherpa-onnx-streaming-paraformer-bilingual-zh-en/blob/8e40c43232a1c5c66c82111efc5820d3accca11b/README.md
- Paraformer原模型：https://www.modelscope.cn/models/damo/speech_paraformer_asr_nat-zh-cn-16k-common-vocab8404-online/summary
- Nano GGUF：https://huggingface.co/FunAudioLLM/Fun-ASR-Nano-GGUF/blob/46e849502a867080d66d351b8dfb1018b607e509/README.md
- FSMN-VAD GGUF：https://huggingface.co/FunAudioLLM/fsmn-vad-GGUF/blob/6840bae4c5c92ee8c04faaf4db23dd0105098d7f/README.md
## 3. 本工程保留的移植来源
`apps/ios/Packages/NanoRuntime/Sources/CNano/nano_core.cpp` 由固定Fun-ASR CLI推理部分抽取，文件首行已有 `Adapted from Apache-2.0 QwenAudio/Fun-ASR` 及revision。`Scripts/prepare-nano-source.py` 记录可重现的修改：iOS C ABI接入、CPU线程与窗口限制、内存分配、取消回调和错误处理；`apps/ios/Packages/NanoRuntime/README.md` 记录具体移植差异。重生成文件时应保留修改标记，不能删除上游已有署名。
`apps/ios/Packages/NanoRuntime/Sources/CNano/funasr_vad.h` 为同一固定Fun-ASR版本 `runtime/llama.cpp/funasr-common/funasr_vad.h` 的原样副本，适用其Apache-2.0许可；当前没有本地修改。`nano_api.inc` 是本工程适配层。`apps/ios/Packages/VoskRuntime/Vosk-API.h` 保留上游Apache头部。其余Swift界面、调度与统一接口由原三个测试工程整合；原工程来源说明和第三方调用不构成对这些自有修改的重新授权。
## 4. 保留范围与后续分发
MIT组件复制或分发时应保留对应版权和许可原文；Apache-2.0组件须附许可证、保留适用署名、在修改文件中显著标记变化，并保留上游随附的适用NOTICE。`THIRD_PARTY_NOTICES.md` 是本工程的来源汇总，不替代上游NOTICE。
已保存的FunASR Model License 1.1要求注明出处、作者并保留模型名称，并含行为、终止和修订等条款。它不是Apache-2.0或MIT，也不能仅凭模型卡的“开源”字样概括为无条件授权。SenseVoice的固定转换副本与当前原模型协议的历史对应关系尚未核实。
当前仓库在本地保存完整App源码、模型、运行库与已列明的Vendor源码快照。公开仓库或分发含权重的App前，仍需确认贡献者对原创代码的发布权利，解决SenseVoice权重与Vosk预编译来源缺口，并核对实际打包二进制的传递依赖告知。将文件纳入Git LFS不会自动解决再分发义务；现有许可文件也尚不是App内的完整版权展示页面。
许可原文未改写，文件来源及SHA256见 `Licenses/sources.json`；模型声明的核对地址及文档摘要校验值见 `Licenses/model-license-evidence.json`。官方动态页面及协议以后可能变化；更新依赖或模型版本时应同步复核。
