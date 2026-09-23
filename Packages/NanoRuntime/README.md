# NanoRuntime

Native, offline Fun-ASR-Nano for the ASRtest iOS app. The Swift package exports
`NanoRuntime`; its dynamic `CNano.xcframework` contains arm64 iPhone and arm64 iOS
Simulator slices. No Python, process spawning, server, network inference, or
model download is used by the app at runtime.

The app adapter is `ASRtest/Engines/NanoEngine.swift` and implements
`NativeASREngine`. Pass the directory containing the three GGUF files to `load`.
`accept` buffers 16 kHz mono Float32 samples. `finish` performs local VAD and ASR
and returns only newly finalized segments. This version performs transcription
after recording stops; it does not expose speculative live partial text.

## Source and model pins

- [QwenAudio/Fun-ASR](https://github.com/QwenAudio/Fun-ASR/tree/0339018ba74a7defa3b6b6a96718d17b816be77b/runtime/llama.cpp):
  `0339018ba74a7defa3b6b6a96718d17b816be77b`, Apache-2.0.
- [llama.cpp](https://github.com/ggml-org/llama.cpp/tree/8086439a4cea94c71a5dfb8fe4ad1546aebd640f):
  `8086439a4cea94c71a5dfb8fe4ad1546aebd640f`, MIT.
- [Official Nano GGUF](https://huggingface.co/FunAudioLLM/Fun-ASR-Nano-GGUF/tree/46e849502a867080d66d351b8dfb1018b607e509):
  `46e849502a867080d66d351b8dfb1018b607e509`.
- [Official FSMN-VAD GGUF](https://huggingface.co/FunAudioLLM/fsmn-vad-GGUF/tree/6840bae4c5c92ee8c04faaf4db23dd0105098d7f):
  `6840bae4c5c92ee8c04faaf4db23dd0105098d7f`.

`ModelLibrary/nano/manifest.json` records exact URLs, lengths, revisions, and
SHA-256 digests. `ModelsManifest-nano.json` provides the app catalog shape;
its file paths are relative to `ModelLibrary`.

The model set contains the 469,331,008-byte encoder/adaptor,
484,219,776-byte ASR-trained Q4_K_M decoder, and 1,720,512-byte FSMN-VAD.
Total: 955,271,296 bytes. The decoder is the official ASR checkpoint's paired
Qwen3-0.6B weights, not an arbitrary general Qwen3 checkpoint.

## Native integration

The official C++ CLI's fbank, SAN-M encoder/adaptor, embedding injection,
Qwen3 decoding, and text cleanup are extracted reproducibly by
`Scripts/prepare-nano-source.py`. `Sources/CNano/nano_api.inc` supplies the C ABI.
Vendor sources are left at their pinned revisions.

Changes for this integration:

- CPU inference with configurable 1-4 threads (default 2), maximum 30-second
  recording, and VAD/fixed windows bounded to 10 seconds.
- A graph-metadata-sized arena replaces the original 1 GiB arena request.
  Metadata allocation is separate from ggml activation buffers and is not an
  estimate of resident memory.
- Qwen context 512, batch 256, microbatch 128, maximum output slots 1;
  CPU weight repacking is disabled to avoid a second large weight buffer.
- Float32 audio activations are preserved; encoder matmul weights remain f16.
- Native model-load progress, CPU encoder, and decoder cancellation callbacks
  query the app's thread-safe cancellation flag. VAD checks cancellation before
  and after its bounded pass; unloading waits for the serial recognition worker.
- Native errors cross the boundary as status/error strings; missing encoder
  tensors no longer call the CLI's `exit(1)`.
- All internal llama/GGML symbols are hidden in the dynamic framework. The
  exported-symbol list contains exactly five `asr_nano_*` functions. Existing
  Whisper static GGML is not upgraded or reused by Nano.

Supported prompts: automatic, Chinese, English, Japanese. The current native
path does not implement the Python ITN option, hotword prompting, speaker
labels, or per-character timestamps. No cloud fallback is provided.

## Reproduce

From the ASRtest directory, with Xcode and CMake available:

```sh
python3 Scripts/download-nano-models.py
python3 Scripts/build-nano.py --macos
python3 Tests/nano/smoke.py
python3 Tests/nano/coexist.py
```

The build verifies vendor revisions and exported symbols, then creates the
XCFramework. `--macos` additionally builds a macOS framework for the native
smoke suite; it is not shipped in the iOS binary package.

## Validation recorded on 2026-09-20

- iPhone arm64 and arm64 iOS Simulator frameworks compile successfully.
- Swift adapter type-checks against the arm64 iOS Simulator slice.
- macOS same-source C ABI transcribes the official six-second sample as
  `我想问我在滨海新区有房`; cold load about 0.46 seconds, inference about 0.65
  seconds with two threads. These are host measurements, not iPhone estimates.
- Same-source native suite passes empty input, silence with VAD, NaN rejection,
  cancellation before/during inference, and reuse after cancellation.
- macOS suite peak RSS is approximately 1.10 GB; compute cancellation in that
  run returns in about 0.15 seconds. Peak memory and thermal behavior on a
  physical iPhone remain to be measured.
- The arm64 iOS 27 Simulator coexistence probe links the existing static Whisper
  and dynamic Nano in one process, keeps both model contexts alive, transcribes
  with Nano, and verifies Whisper's result before and after is identical.

Evidence: `Tests/nano/macos-results.json`, `Tests/nano/smoke.log`,
`Tests/nano/coexist.log`, and `Tests/nano/build-final.log`.
Successful Simulator execution does not establish physical-iPhone performance
or production recognition accuracy.
