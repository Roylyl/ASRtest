# Validation status

Last updated: 2026-09-21. Results below apply to the release-candidate tree recorded by the commit containing this document.

## Repository and build checks

| Check | Result | Evidence |
|---|---|---|
| Model identity | PASS | Eight model groups, 42 files and 1,857,000,819 bytes match `ModelsManifest.json`. |
| Runtime identity | PASS | Whisper 53 files, Vosk 7 files and Nano 11 files match `RuntimeArtifactsManifest.json`. |
| Runtime structure | PASS | All three XCFrameworks expose arm64 iPhone and arm64 Simulator slices, headers, module maps and required symbols. |
| Git LFS index | PASS | 69 paths are LFS pointers representing 67 unique objects and 2,192,952,911 stored bytes; the two additional paths reuse the Vosk objects. No ordinary Git blob exceeds 100 MB. |
| Vendored source | PASS | Seven fixed snapshots contain 12,104 indexed items and 492,103,191 materialized bytes; counts match `Vendor/sources.json`, with zero gitlinks and no nested `.git` or `.build` directory. |
| Repository metadata | PASS | `Scripts/check-repository.py` validates required project files, manifests, Vendor counts, LFS attributes and pointer bodies. |
| Source syntax | PASS | Project Python scripts compile, shell scripts pass `bash -n`, the project file and Info.plist pass `plutil`. |
| Unsigned iPhone build | PASS | Generic iOS Debug build completed with `CODE_SIGNING_ALLOWED=NO` and `CODE_SIGNING_REQUIRED=NO`. |
| Fresh local clone | PASS | A no-local clone started with LFS smudging disabled, passed the metadata gate, completed `git lfs pull`, reverified every model and runtime SHA256, passed `git lfs fsck`, and remained clean. |
| Private/generated files | PASS | Personal signing configuration, `LocalBackup`, recordings, logs, DerivedData and generated test bundles are ignored and absent from the index. |

Build environment: Apple Silicon macOS 27.0, Xcode 27.1 (build 27A9269), iOS 27.1 SDK, arm64 generic iOS destination. The App deployment target remains iOS 17.0.

## Reproduction commands

```sh
python3 Scripts/check-repository.py
python3 Scripts/prepare-models.py --verify-only
python3 Scripts/prepare-runtimes.py --verify-only
python3 Scripts/prepare-runtimes.py --check-structure
xcodebuild -project ASRtest.xcodeproj -scheme ASRtest -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath .build/release-check \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

The metadata workflow runs on GitHub without fetching LFS payloads. Full model hash checks and the iOS build require the complete LFS checkout and, for first-time SwiftPM resolution, access to the fixed package artifacts.

## Evidence boundary

Simulator runs on 2026-09-20 covered all eight local inference configurations, repeated sessions, cancellation and error recovery, session logging, model integrity checks, and the primary UI navigation flow. They do not establish physical-iPhone accuracy, latency, memory, power, thermal behavior, or long-duration stability.

The physical-device microphone and performance matrix remains open. Fun-ASR-Nano remains an experimental iOS port. A new runtime built from vendored source must pass App compilation and real inference tests; file structure and exported-symbol checks alone are insufficient.

Licensing remains a public-distribution gate. The SenseVoiceSmall ONNX snapshot needs a confirmed redistribution basis, and the community Vosk binary needs a complete core revision and transitive notice record before the full resource revision is published.
