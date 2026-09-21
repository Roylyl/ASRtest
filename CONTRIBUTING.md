# Contributing to ASRtest

Thank you for helping improve ASRtest. Keep changes focused on local, measurable ASR behavior. Cloud inference, chat, summarization, and unrelated assistant features are outside this project's scope.

## Development setup

1. Install Git LFS before cloning, then run `git lfs pull` after checkout.
2. Run `python3 Scripts/prepare-models.py --verify-only` and `python3 Scripts/prepare-runtimes.py --verify-only`.
3. Copy `Config/Local.xcconfig.example` to the ignored `Config/Local.xcconfig`, then enter your own Team ID and unique bundle identifier.
4. Open `ASRtest.xcodeproj` with the `ASRtest` scheme.

Do not commit signing identities, provisioning profiles, recordings, device logs, DerivedData, or generated test bundles. Do not replace a model or runtime and merely update its checksum. Every asset update must identify its upstream repository, immutable revision, license, exact byte size, and SHA256.

## Changes and validation

- Preserve real streaming and batch behavior instead of simulating a common mode.
- Keep inference local and document any new network use.
- Update `ModelsManifest.json`, `RuntimeArtifactsManifest.json`, `THIRD_PARTY_NOTICES.md`, and `Licenses/` when relevant.
- Run the smallest applicable checks first, then an unsigned iPhone build. Model or runtime changes also require actual inference tests.
- Do not report Simulator timing as physical-iPhone performance.

Minimum checks by change type:

| Change | Minimum validation |
|---|---|
| Documentation or community files | `python3 Scripts/check-repository.py`; verify links and licensing statements manually |
| Swift UI or controller code | repository check, applicable smoke test, and an unsigned generic iOS build |
| Model files or manifest | model verification, repository check, affected-model inference, and an unsigned build |
| XCFramework or runtime manifest | runtime identity and structure checks, App build, and affected-runtime inference |
| Nano C/C++ or build scripts | source syntax checks, Nano native tests, coexistence test, App build, and physical-device limits stated explicitly |
| License or upstream-source change | repository check plus a manual review of immutable source, license text, notices, byte size, and SHA256 |

Use this unsigned build command when the change can affect compilation or packaging:

```sh
xcodebuild -project ASRtest.xcodeproj -scheme ASRtest -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath .build/contributor-check \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

Inference fixtures must be 16 kHz mono WAV. Do not commit a contributor's voice, exported session log, personal path, device identifier, or signing data. A check may be marked not applicable only when the pull request explains why the changed behavior cannot affect that check.

Use clear commit messages. A pull request should describe the behavior change, affected models, validation performed, and any unverified device or licensing boundary.

## Licensing contributions

By submitting a contribution, you agree that your original contribution may be distributed under Apache License 2.0. Do not submit code, binaries, datasets, or model weights that you do not have the right to distribute. Third-party content must retain its own notices and must be identified in `THIRD_PARTY_NOTICES.md`.
