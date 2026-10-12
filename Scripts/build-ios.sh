#!/usr/bin/env bash
set -euo pipefail
ASR_REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec xcodebuild -project "$ASR_REPO_ROOT/apps/ios/ASRtest.xcodeproj" \
  -scheme ASRtest -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath "$ASR_REPO_ROOT/.build/ios" CODE_SIGNING_ALLOWED=NO "$@" build
