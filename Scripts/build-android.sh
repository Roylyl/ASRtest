#!/usr/bin/env bash
set -euo pipefail
ASR_REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ASR_REPO_ROOT/apps/android"
if [[ -z "${JAVA_HOME:-}" && -x /usr/libexec/java_home ]]; then
  if ASR_JAVA_HOME="$(/usr/libexec/java_home -v 17 2>/dev/null)"; then
    export JAVA_HOME="$ASR_JAVA_HOME"
  else
    echo 'Please install JDK 17 or set JAVA_HOME to a compatible JDK.' >&2
    exit 1
  fi
fi
if [[ $# -eq 0 ]]; then
  set -- :app:assembleDebug --console=plain
fi
exec ./gradlew "$@"
