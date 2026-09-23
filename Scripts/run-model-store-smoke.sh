#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Tests/model-store-build"
APP="$OUT/ModelStoreSmoke.app"
mkdir -p "$APP"
xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios17.0-simulator \
 -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" -parse-as-library \
 "$ROOT/ASRtest/EngineTypes.swift" "$ROOT/ASRtest/ModelCatalog.swift" \
 "$ROOT/ASRtest/ModelStore.swift" "$ROOT/ASRtest/SessionStore.swift" \
 "$ROOT/Tests/ModelStoreSmoke.swift" -o "$APP/ModelStoreSmoke"
python3 "$ROOT/Tests/prepare-bundled-smoke.py" "$APP"
cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.roylyl.asrtest.model-store-smoke</string>
<key>CFBundleExecutable</key><string>ModelStoreSmoke</string>
<key>CFBundleName</key><string>ModelStoreSmoke</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>MinimumOSVersion</key><string>17.0</string>
<key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
<key>UILaunchScreen</key><dict/>
<key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
xcrun simctl install booted "$APP"
xcrun simctl launch --console --terminate-running-process booted com.roylyl.asrtest.model-store-smoke | tee "$OUT/run.log"
# simctl can return success even if an app exits early during launch.
rg -q "BUNDLED MODEL STORE AND SESSION STORE PASS" "$OUT/run.log"
