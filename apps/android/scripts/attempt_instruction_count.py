#!/usr/bin/env python3
"""One bounded real-workload PMU attempt; retains errors rather than inventing MIPS."""
import argparse
import os
import shutil
import datetime
import json
import pathlib
import re
import subprocess
import time
from zoneinfo import ZoneInfo

from project_paths import APP_ROOT, android_sdk

ROOT = APP_ROOT
OUT = ROOT / 'results/instruction-attempt'
ADB = []
PACKAGE = 'com.roylyl.asrtest'
OUT.mkdir(parents=True, exist_ok=True)

def call(args, timeout=30):
    return subprocess.run(ADB + args, capture_output=True, text=True, timeout=timeout)

def main():
    global ADB
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adb", default=shutil.which("adb") or str(android_sdk()/"platform-tools/adb"))
    parser.add_argument("--serial", default=os.environ.get("ANDROID_SERIAL"))
    parser.add_argument("--simpleperf", type=pathlib.Path, default=android_sdk()/"ndk/29.0.14206865/simpleperf/bin/android/arm64/simpleperf")
    args=parser.parse_args()
    ADB=[args.adb]+(["-s",args.serial] if args.serial else [])
    manifest = {'startedAt':datetime.datetime.now(ZoneInfo('Asia/Shanghai')).isoformat(),
                'purpose':'Instruction-counter feasibility during one actual Whisper tiny utterance',
                'inferenceMips':None,'instructionCount':None,'durationSeconds':3,'steps':[]}
    original_harden = call(['shell','getprop','security.perf_harden']).stdout.strip()
    manifest['originalSecurityPerfHarden'] = original_harden
    started_ms = time.time()*1000
    try:
        enable=call(['shell','setprop','security.perf_harden','0'])
        enabled_value=call(['shell','getprop','security.perf_harden']).stdout.strip()
        manifest['temporaryProfilingConfiguration']={'exitCode':enable.returncode,'value':enabled_value,'stdout':enable.stdout,'stderr':enable.stderr}
        if enable.returncode or enabled_value!='0':
            raise RuntimeError('Shell could not temporarily enable profiling')
        sdk_binary=str(args.simpleperf)
        preparation=[['push',sdk_binary,'/data/local/tmp/asrtest-simpleperf'],
                     ['shell','chmod','755','/data/local/tmp/asrtest-simpleperf'],
                     ['shell','run-as',PACKAGE,'cp','/data/local/tmp/asrtest-simpleperf','files/asrtest-simpleperf'],
                     ['shell','run-as',PACKAGE,'chmod','700','files/asrtest-simpleperf']]
        for args in preparation:
            result=call(args)
            manifest['steps'].append({'command':ADB+args,'exitCode':result.returncode,'stdout':result.stdout,'stderr':result.stderr})
            if result.returncode:
                raise RuntimeError('Profiler preparation failed: '+result.stdout+result.stderr)
        call(['shell','am','force-stop',PACKAGE])
        launch = call(['shell','am','start','-n',PACKAGE+'/.MainActivity','--es','benchModel','whisperTiny','--es','benchCorpus','zh_short','--ei','benchThreads','2','--ei','benchRuns','1'])
        (OUT/'workload-launch.log').write_text(launch.stdout+launch.stderr)
        if launch.returncode:
            raise RuntimeError('Workload launch failed: '+launch.stdout+launch.stderr)
        pids=[]
        deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            pids=call(['shell','pidof',PACKAGE]).stdout.strip().split()
            if pids:
                break
            time.sleep(0.2)
        if not pids:
            raise RuntimeError('App process did not appear after launch')
        pid=pids[0]
        manifest['pid'] = pid
        args = ['shell','run-as',PACKAGE,'files/asrtest-simpleperf','stat','-e','instructions:u','-p',pid,'--duration','3']
        stat = call(args, timeout=15)
        raw = stat.stdout + stat.stderr
        (OUT/'ndk-private-real-workload-stat.log').write_text(raw)
        manifest['steps'].append({'command':ADB+args,'exitCode':stat.returncode,'outputFile':'ndk-private-real-workload-stat.log'})
        counts = re.findall(r'^\s*([0-9,]+)\s+instructions:u\b',raw,re.M)
        manifest['reportedCounts'] = counts
        manifest['counterObserved'] = bool(counts and int(counts[-1].replace(',',''))>0 and 'Permission denied' not in raw)
        manifest['auxiliaryPmuProbeBlocked'] = 'Running child command in app uid isn\'t allowed.' in raw
        manifest['inferenceMipsValid'] = False
        if manifest['counterObserved']:
            count=int(counts[-1].replace(',',''))
            elapsed=re.search(r'Total test time: ([0-9.]+) seconds',raw)
            manifest['instructionCountReported']=count
            if elapsed:
                window=float(elapsed.group(1))
                manifest['elapsedWindowSeconds']=window
                manifest['wholeProcessUserWallClockMips']=count/window/1e6
        manifest['reason'] = 'Nonzero instruction count was observed, but the window includes the whole App and is not aligned with pure inference. Auxiliary per-CPU workload probes can fail after the event counts are printed; those warnings alone do not invalidate the observed count.' if manifest['counterObserved'] else 'No nonzero instruction count was observed.'
        deadline = time.monotonic()+45
        group = None
        while time.monotonic()<deadline:
            result = call(['shell','run-as',PACKAGE,'cat','files/results/benchmark-whisperTiny.json'])
            try:
                current = json.loads(result.stdout)
                if current.get('startedAt',0)>=started_ms and current.get('records') and len(current['records'])==1 and current.get('status') in ('completed','failed','stopped'):
                    group=current
                    break
            except json.JSONDecodeError:
                pass
            time.sleep(1)
        if group:
            (OUT/'real-workload-result.json').write_text(json.dumps(group,ensure_ascii=False,indent=2)+'\n')
            manifest['workloadStatus']=group['status']
            manifest['workloadRecords']=len(group['records'])
        else:
            manifest['workloadStatus']='result-not-collected-within-bounded-wait'
    finally:
        restore = call(['shell','setprop','security.perf_harden',original_harden or '1'])
        current = call(['shell','getprop','security.perf_harden'])
        manifest['securityPerfHardenRestored']={'exitCode':restore.returncode,'value':current.stdout.strip()}
        call(['shell','run-as',PACKAGE,'rm','files/asrtest-simpleperf'])
        call(['shell','rm','/data/local/tmp/asrtest-simpleperf'])
        call(['shell','am','force-stop',PACKAGE])
        call(['shell','am','start','-n',PACKAGE+'/.MainActivity'])
        manifest['endedAt']=datetime.datetime.now(ZoneInfo('Asia/Shanghai')).isoformat()
        (OUT/'attempt-summary.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
        print(json.dumps(manifest,ensure_ascii=False,indent=2))

if __name__ == "__main__":
    main()
