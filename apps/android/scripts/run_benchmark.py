#!/usr/bin/env python3
"""Run the real Android APK on a connected device and collect result JSON."""
import argparse
import datetime
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import time

from project_paths import APP_ROOT, DEMO_CORPUS, android_sdk

PROJECT = APP_ROOT
MODELS = ["zipformer", "whisperTiny", "whisperBase", "voskChinese", "voskEnglish", "senseVoice", "paraformer", "nano"]
PACKAGE = "com.roylyl.asrtest"


def locate_adb():
    found = shutil.which("adb")
    candidates = [found, str(android_sdk() / "platform-tools/adb")]
    for candidate in candidates:
        if candidate and pathlib.Path(candidate).is_file():
            return candidate
    raise SystemExit("adb not found; supply --adb /path/to/adb")


class Device:
    def __init__(self, binary, serial):
        self.prefix = [binary] + (["-s", serial] if serial else [])

    def call(self, arguments, timeout=30, check=True):
        result = subprocess.run(self.prefix + arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=timeout)
        if check and result.returncode:
            raise RuntimeError(f"adb {' '.join(arguments)} failed: {result.stderr.strip() or result.stdout.strip()}")
        return result

    def read_json(self, remote):
        result = self.call(["shell", "run-as", PACKAGE, "cat", remote], check=False)
        if result.returncode:
            return None
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError:
            return None

    def process_ids(self):
        result = self.call(["shell", "pidof", PACKAGE], check=False)
        return [value for value in result.stdout.split() if value.isdigit()]

    def capture_crash(self, output, model, process_id):
        if process_id:
            logs = self.call(["logcat", "-d", "-v", "threadtime", f"--pid={process_id}", "-t", "300"], check=False)
            (output / f"process-{model}.log").write_text(logs.stdout + logs.stderr, encoding="utf-8")
        crash = self.call(["logcat", "-b", "crash", "-d", "-v", "threadtime", "-t", "500"], check=False)
        lines = crash.stdout.splitlines()
        line_pattern = re.compile(r"^\d\d-\d\d\s+\S+\s+(\d+)\s+\d+\s+[A-Z]\s+")
        related_logger_ids = set()
        for line in lines:
            match = line_pattern.match(line)
            if match and (PACKAGE in line or (process_id and f"pid: {process_id}," in line)):
                related_logger_ids.add(match.group(1))
        related = [line for line in lines if (line_pattern.match(line) and line_pattern.match(line).group(1) in related_logger_ids) or PACKAGE in line]
        (output / f"crash-{model}.log").write_text("\n".join(related) + "\n", encoding="utf-8")

    def state(self):
        fields = {"model": "ro.product.model", "manufacturer": "ro.product.manufacturer", "androidVersion": "ro.build.version.release", "apiLevel": "ro.build.version.sdk", "soc": "ro.soc.model", "abi": "ro.product.cpu.abi"}
        metadata = {key: self.call(["shell", "getprop", prop]).stdout.strip() for key, prop in fields.items()}
        metadata["memory"] = self.call(["shell", "cat", "/proc/meminfo"]).stdout.splitlines()[:3]
        metadata["battery"] = self.call(["shell", "dumpsys", "battery"], check=False).stdout.strip()
        metadata["recordedAt"] = datetime.datetime.now().astimezone().isoformat()
        return metadata


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adb", default=None)
    parser.add_argument("--serial", default=os.environ.get("ANDROID_SERIAL"))
    parser.add_argument("--models", nargs="+", choices=MODELS, default=MODELS)
    parser.add_argument("--corpus", default="all")
    parser.add_argument("--threads", type=int, default=2)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--timeout", type=int, default=1200, help="Per-model timeout in seconds; partial logs are retained")
    parser.add_argument("--poll", type=float, default=2)
    parser.add_argument("--output", type=pathlib.Path)
    args = parser.parse_args()
    if min(args.runs, args.threads, args.timeout) < 1 or args.poll < 0.2:
        parser.error("runs/threads/timeout must be positive and poll >=0.2")
    corpus = json.loads((DEMO_CORPUS / "corpus.json").read_text(encoding="utf-8"))
    if args.corpus != "all" and args.corpus not in {entry["id"] for entry in corpus}:
        parser.error("Unknown corpus id")
    output = args.output or PROJECT / "evaluation/runs" / datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    output.mkdir(parents=True, exist_ok=True)
    device = Device(args.adb or locate_adb(), args.serial)
    device.call(["get-state"])
    if not device.call(["shell", "pm", "path", PACKAGE], check=False).stdout.strip():
        raise SystemExit("APK not installed; build and install the debug APK before running this script.")
    access = device.call(["shell", "run-as", PACKAGE, "pwd"], check=False)
    if access.returncode:
        raise SystemExit("App is not debuggable: run-as cannot read result files; install the debug APK.")
    manifest = {"kind": "benchmark-driver", "startedAt": datetime.datetime.now().astimezone().isoformat(), "deviceSerial": args.serial, "models": args.models, "corpus": args.corpus, "threads": args.threads, "runs": args.runs, "timeoutSeconds": args.timeout, "isSynthetic": True, "deviceBefore": device.state(), "outcomes": []}

    def save_manifest():
        (output / "driver.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    save_manifest()
    try:
        for model in args.models:
            remote = f"files/results/benchmark-{model}.json"
            old = device.read_json(remote)
            old_id = old.get("id") if isinstance(old, dict) else None
            device.call(["shell", "am", "force-stop", PACKAGE])
            launch = device.call(["shell", "am", "start", "-n", f"{PACKAGE}/.MainActivity", "--es", "benchModel", model, "--es", "benchCorpus", args.corpus, "--ei", "benchThreads", str(args.threads), "--ei", "benchRuns", str(args.runs)])
            (output / f"launch-{model}.txt").write_text(launch.stdout + launch.stderr, encoding="utf-8")
            start = time.monotonic()
            last_progress, current = None, None
            last_process_id, missing_process_count, process_crashed = None, 0, False
            print(f"[{model}] started on {args.serial}; timeout={args.timeout}s", flush=True)
            while time.monotonic() - start < args.timeout:
                candidate = device.read_json(remote)
                if isinstance(candidate, dict) and candidate.get("id") != old_id:
                    current = candidate
                    progress = (candidate.get("status"), len(candidate.get("records", [])))
                    if progress != last_progress:
                        print(f"[{model}] status={progress[0]} records={progress[1]}", flush=True)
                        last_progress = progress
                        (output / f"benchmark-{model}.json").write_text(json.dumps(candidate, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
                    if candidate.get("status") in ("completed", "stopped", "failed"):
                        break
                process_ids = device.process_ids()
                if process_ids:
                    last_process_id = process_ids[0]
                    missing_process_count = 0
                elif time.monotonic() - start >= 15:
                    missing_process_count += 1
                    if missing_process_count >= 3:
                        process_crashed = True
                        device.capture_crash(output, model, last_process_id)
                        print(f"[{model}] app process exited; crash/process logs collected", flush=True)
                        break
                time.sleep(args.poll)
            terminal = isinstance(current, dict) and current.get("status") in ("completed", "stopped", "failed")
            outcome = {"modelId": model, "driverStatus": "collected" if terminal else "process-exited" if process_crashed else "timeout", "elapsedSeconds": round(time.monotonic() - start, 3), "groupId": current.get("id") if current else None, "appStatus": current.get("status") if current else None, "recordCount": len(current.get("records", [])) if current else 0}
            if current:
                (output / f"benchmark-{model}.json").write_text(json.dumps(current, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
                group_id = str(current.get("id", ""))
                if re.fullmatch(r"[a-zA-Z0-9-]+", group_id):
                    events = device.call(["shell", "run-as", PACKAGE, "cat", f"files/results/{group_id}.jsonl"], check=False)
                    if events.returncode == 0:
                        (output / f"{group_id}.jsonl").write_text(events.stdout, encoding="utf-8")
            manifest["outcomes"].append(outcome)
            save_manifest()
            if not terminal:
                print(f"[{model}] {'process exited' if process_crashed else 'timed out'}; retained partial real result, force-stopping before next model", flush=True)
                device.call(["shell", "am", "force-stop", PACKAGE])
    except KeyboardInterrupt:
        manifest["interrupted"] = True
        device.call(["shell", "am", "force-stop", PACKAGE], check=False)
        print("Interrupted; retained already collected results.", flush=True)
    finally:
        manifest["endedAt"] = datetime.datetime.now().astimezone().isoformat()
        try:
            manifest["deviceAfter"] = device.state()
        except (RuntimeError, subprocess.TimeoutExpired) as error:
            manifest["deviceAfterError"] = str(error)
        save_manifest()
    print(f"Actual results: {output}")
    if any(path.name.startswith("benchmark-") for path in output.glob("*.json")):
        subprocess.run([sys.executable, str(PROJECT / "evaluation/evaluate.py"), str(output), "--output", str(output / "report")], check=True)


if __name__ == "__main__":
    main()
