# Contributing to ASRtest
Keep contributions focused on local ASR behavior, model comparison, logging, and platform integration. Cloud inference, chat, and summarization are outside the project scope.

## Development setup
1. Install Git LFS and run `git lfs pull` after cloning to obtain model weights and runtime binaries.
2. For iOS, copy `apps/ios/Config/Local.xcconfig.example` to the ignored `Local.xcconfig` in the same directory, set your own Team ID and bundle identifier, and open `apps/ios/ASRtest.xcodeproj`.
3. For Android, open `apps/android` in Android Studio and select JDK 17 for Gradle. Keep SDK configuration in the ignored `local.properties`.

Build from the repository root:
```sh
./Scripts/build-ios.sh
./Scripts/build-android.sh
```
Shared models and their manifest live under `shared/assets`. Platform runtime binaries and bindings stay under `apps/ios` and `apps/android`; fixed upstream source snapshots stay in `Vendor`.

## Changes and checks
Use the smallest check that covers the change. Do not run full model or runtime hash checks for routine source, documentation, or path edits.

|Change|Relevant check|
|---|---|
|Documentation|Review the changed commands, links, and images|
|Platform source or build paths|Build the affected platform; inspect resource paths if packaging changed|
|ASR behavior or native bindings|Build and exercise the affected model and input mode|
|Model or runtime replacement|Record source, revision, license, and size; check compatibility and run the affected model|
|Download or integrity-sensitive release work|Use the recorded integrity metadata where it is needed|

Preserve real streaming and final-result behavior. Keep model settings fixed during a run, retain cancellation and error states, and do not report Simulator timing as physical-device performance. Different platform binaries and GGML versions must remain separate.

When changing model or runtime assets, update the applicable `shared/assets/ModelsManifest.json`, `apps/ios/RuntimeArtifactsManifest.json`, source notes, and license files. Preserve existing provenance metadata; compute new hashes only when download verification, file integrity, or the release task requires them.

Do not commit signing identities, provisioning profiles, private recordings, device logs, local paths, or generated build outputs. Public audio fixtures must be suitable for redistribution and identify synthesized speech separately from real recordings.

## Pull requests
Describe the resulting behavior, affected platform and models, and the checks actually performed. Distinguish builds, Simulator behavior, and physical-device results. Keep commits focused and use clear messages.

## Licensing contributions
Original contributions are distributed under Apache License 2.0. Do not submit code, binaries, datasets, or model weights without permission to distribute them. Third-party material retains its own license and notices and must be identified in `THIRD_PARTY_NOTICES.md` and the relevant platform source notes.
