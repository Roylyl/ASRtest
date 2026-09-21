#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${1:-}" == --help ]]; then
    cat <<'HELP'
Usage: bash Scripts/run-ui-smoke.sh
Runs only on an iOS simulator. By default, exactly one iOS simulator must be booted.
ASR_UI_SIMULATOR: explicitly select an available simulator UDID (boots it if needed).
ASR_UI_DERIVED_DATA: defaults to <repository>/.build/ui-derived.
ASR_UI_SOURCE_PACKAGES: defaults to <repository>/.build/SourcePackages.
The test switches local models and captures UI screenshots; it does not record audio.
HELP
    exit 0
fi
if [[ -n "${ASR_UI_SIMULATOR:-}" ]]; then
    SIMULATOR="$(python3 "$ROOT/Scripts/select-ios-simulator.py" --udid "$ASR_UI_SIMULATOR")"
else
    SIMULATOR="$(python3 "$ROOT/Scripts/select-ios-simulator.py")"
fi
DERIVED="${ASR_UI_DERIVED_DATA:-$ROOT/.build/ui-derived}"
PACKAGES="${ASR_UI_SOURCE_PACKAGES:-$ROOT/.build/SourcePackages}"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
OUT="$ROOT/Tests/UITests/Artifacts/$RUN_ID"
mkdir -p "$OUT" "$ROOT/Preview"
python3 - "$ROOT" "$OUT" <<'PY'
from pathlib import Path
import hashlib,json,sys
root,out=map(Path,sys.argv[1:])
files=sorted((root/'ASRtest').glob('*.swift'))
files += [root/'Tests/UITests/ASRtestUITests.swift', root/'Scripts/run-ui-smoke.sh', root/'ASRtest.xcodeproj/project.pbxproj']
files += sorted((root/'ASRtest.xcodeproj/xcshareddata/xcschemes').glob('*.xcscheme'))
hashes={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
(out/'source-sha256.json').write_text(json.dumps(hashes,ensure_ascii=False,indent=2)+'\n')
PY
xcrun simctl boot "$SIMULATOR" 2>/dev/null || true
xcrun simctl bootstatus "$SIMULATOR" -b
ORIGINAL_APPEARANCE="$(xcrun simctl ui "$SIMULATOR" appearance | tr '[:upper:]' '[:lower:]')"
case "$ORIGINAL_APPEARANCE" in light|dark) ;; *) ORIGINAL_APPEARANCE=light ;; esac
trap 'xcrun simctl ui "$SIMULATOR" appearance "$ORIGINAL_APPEARANCE" >/dev/null 2>&1 || true' EXIT
COMMON=(-project "$ROOT/ASRtest.xcodeproj" -scheme ASRtestUISmoke -configuration Debug
        -destination "platform=iOS Simulator,id=$SIMULATOR" -derivedDataPath "$DERIVED"
        -clonedSourcePackagesDirPath "$PACKAGES" -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO)
xcodebuild "${COMMON[@]}" build-for-testing 2>&1 | tee "$OUT/build.log"
run_case() {
    local appearance="$1" name="$2" test="$3" status=0
    xcrun simctl ui "$SIMULATOR" appearance "$appearance"
    xcodebuild "${COMMON[@]}" test-without-building -only-testing:"ASRtestUITests/ASRtestUITests/$test" \
      -resultBundlePath "$OUT/$name.xcresult" 2>&1 | tee "$OUT/$name.log" || status=$?
    if [[ -d "$OUT/$name.xcresult" ]]; then
        xcrun xcresulttool export attachments --path "$OUT/$name.xcresult" --output-path "$OUT/$name-attachments"
        xcrun xcresulttool get test-results summary --path "$OUT/$name.xcresult" > "$OUT/$name-summary.json"
    fi
    return "$status"
}
run_case light light testPrimaryViewsAndBundledModelNavigation
run_case dark dark testDarkTestPage
python3 - "$ROOT" "$OUT" "$SIMULATOR" <<'PY'
from pathlib import Path
import hashlib,json,shutil,sys
root,out,sim=Path(sys.argv[1]),Path(sys.argv[2]),sys.argv[3]
hashes=json.loads((out/'source-sha256.json').read_text())
changed=[name for name,expected_hash in hashes.items() if hashlib.sha256((root/name).read_bytes()).hexdigest()!=expected_hash]
if changed:raise SystemExit('Sources changed during UI test; rebuild before claiming current verification: '+', '.join(changed))
summaries={mode:json.loads((out/(mode+'-summary.json')).read_text()) for mode in ['light','dark']}
if any(s['result']!='Passed' or s['failedTests']!=0 or s['passedTests']!=1 for s in summaries.values()):
    raise SystemExit('Both UI test cases must pass before publishing screenshots')
expected=['test-light','logs-light','models-light','settings-light','test-dark','model-selector-light','whisper-tiny-light']
shots={}
for mode in ['light','dark']:
    folder=out/(mode+'-attachments')
    for test in json.loads((folder/'manifest.json').read_text()):
        for item in test['attachments']:
            source=folder/item['exportedFileName']
            if source.suffix.lower()!='.png':continue
            name=item['suggestedHumanReadableName']
            for expected_name in expected:
                if expected_name in name:
                    target=root/'Preview'/('ui-'+expected_name+'.png')
                    shutil.copyfile(source,target)
                    shots[expected_name]={'path':str(target),'sha256':hashlib.sha256(target.read_bytes()).hexdigest()}
missing=set(expected)-set(shots)
if missing:raise SystemExit('Missing screenshot attachments: '+', '.join(sorted(missing)))
report={'scheme':'ASRtestUISmoke','target':'ASRtestUITests','simulator_id':sim,
        'artifacts':str(out),'physical_device_tested':False,'microphone_recorded':False,
        'passed_tests':2,'failed_tests':0,'source_sha256':hashes,'sources_unchanged_during_test':True,
        'checks':['three native tabs','log and model-information segments','eight model picker entries reachable','settings switches real model to Whisper tiny; Test reflects selection and ready state; restored Zipformer','bundled-only settings without import/download actions','stopped recording state','light and dark screenshots'],
        'screenshots':shots}
(root/'Tests/UITests/last-run.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print('UI SMOKE PASS; screenshots copied to '+str(root/'Preview'))
PY
