# Vendored upstream source snapshots

This directory keeps reviewable, fixed-revision snapshots of the upstream source that explains the native runtimes used by ASRtest. Each snapshot was exported from a clean Git worktree with `git archive`, so it contains only files tracked by the selected upstream commit. Nested `.git` directories, local build output, and `.build` directories are not included. The `.asrtest-upstream.json` file at each snapshot root is ASRtest metadata added after export.

## Snapshot index

| Directory | Upstream repository | Pinned revision | Role in ASRtest |
| --- | --- | --- | --- |
| `sherpa-onnx` | https://github.com/k2-fsa/sherpa-onnx | `11afbd009a7f8c08f4bcf2fc1b265d0df4670fbf` (`1.13.8`) | Source for the sherpa-onnx inference framework used by Zipformer, SenseVoice, and Paraformer integrations. |
| `onnxruntime-libs` | https://github.com/csukuangfj/onnxruntime-libs | `8ebc5ebf92190903c274a7621ba4c96a732335ec` (`1.28.2`) | Swift package wrapper, build recipes, and bindings for the ONNX Runtime libraries resolved by sherpa-onnx. |
| `whisper.cpp` | https://github.com/ggml-org/whisper.cpp | `927cfce34f31707e17f2bff35c349632fb9e2c3a` (`v1.9.4`) | Upstream implementation used as the source reference for the local whisper.cpp runtime. |
| `react-native-vosk` | https://github.com/riderodd/react-native-vosk | `970d3d5e49225a1ebc24decbfd2d9317a02e7660` | Wrapper source and its tracked iOS Vosk distribution, retained as provenance for the app's Vosk integration. |
| `vosk-api` | https://github.com/alphacep/vosk-api | `05adbfcc0df27a1535913c6accd4b7fc60ffd59d` | Reference source for the native Vosk API and recognizer implementation. |
| `Fun-ASR` | https://github.com/QwenAudio/Fun-ASR | `0339018ba74a7defa3b6b6a96718d17b816be77b` | Native Fun-ASR-Nano inference source used by `NanoRuntime`. |
| `Fun-ASR/third_party/llama.cpp` | https://github.com/ggml-org/llama.cpp | `8086439a4cea94c71a5dfb8fe4ad1546aebd640f` | Expanded llama.cpp and GGML source linked into `NanoRuntime`. |

Machine-readable commit, tree, file-count, byte-count, and archive-hash data is in `sources.json`. `archive_sha256` is calculated over the exact output of `git archive --format=tar <commit>` and therefore covers the complete tracked upstream tree, including file modes and symbolic links, but excludes ASRtest's added `.asrtest-upstream.json` marker. The materialized `file_count` and `total_bytes` include that marker; `file_count` includes symbolic links, while `total_bytes` is the sum of regular-file contents. The `Fun-ASR` counts exclude its expanded `third_party/llama.cpp` directory because that nested snapshot has its own entry; aggregate totals therefore do not double count it.

## Build relationship

The Xcode project continues to resolve `sherpa-onnx` and `onnxruntime-libs` through Swift Package Manager at the revisions recorded in `Package.resolved`. Their copies under `Vendor` exist for source review, attribution, and reproducible archival. They are not added to the application target. Linking the vendored copy in addition to the Swift package can produce duplicate definitions.

The `onnxruntime-libs` snapshot is the package wrapper consumed by this project. It is not the Microsoft ONNX Runtime core source repository. Its package manifest resolves platform binaries from release artifacts. The ONNX Runtime core source remains available at https://github.com/microsoft/onnxruntime and is intentionally not duplicated here because this project does not build that tree directly.

The whisper.cpp and Vosk snapshots likewise document upstream implementation and provenance without changing the current Xcode build graph. Runtime artifacts already checked into the project's package directories remain the artifacts used by the app.

Fun-ASR-Nano is the exception to the review-only copies above: `NanoRuntime` uses the vendored Fun-ASR and expanded llama.cpp/GGML source. The two nested snapshots retain independent commit and tree identities, and neither directory contains nested Git metadata.

## License and provenance notes

- `sherpa-onnx/LICENSE` contains the Apache License 2.0 text distributed by that project.
- `whisper.cpp/LICENSE` contains the MIT License. Additional license texts shipped by upstream tests, examples, and bindings remain in their original paths.
- `react-native-vosk/LICENSE` contains the wrapper project's MIT License. Its tracked `ios/libvosk.xcframework` is precompiled binary material, and the wrapper license alone must not be assumed to establish the build revision or all transitive notices for that binary.
- `vosk-api/COPYING` and `vosk-api/go/COPYING` contain the Apache License 2.0 text distributed by that project.
- `Fun-ASR/LICENSE` contains the Apache License 2.0 text. `Fun-ASR/third_party/llama.cpp/LICENSE` contains the llama.cpp MIT License, and its retained component licenses remain in their upstream paths.
- The selected `onnxruntime-libs` revision does not track a `LICENSE` or `NOTICE` file. Its absence is recorded here rather than filled with an inferred license. Review the package repository, the corresponding ONNX Runtime release, and https://github.com/microsoft/onnxruntime before redistributing its binary artifacts.

The `vosk-api` revision is a review reference. There is not enough provenance information in the community-provided iOS binary to claim that it was built from this exact revision. Keep that distinction in downstream notices and release documentation.

The two static archives inside `react-native-vosk/ios/libvosk.xcframework` are large tracked binaries. A public Git host should store them with Git LFS; replacing them with pointer files in a working checkout will make the snapshot incomplete until Git LFS objects are fetched.
