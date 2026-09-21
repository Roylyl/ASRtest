#!/usr/bin/env python3
"""Check Nano/Whisper coexistence using the local iOS simulator XCFrameworks."""
from pathlib import Path
import argparse
import os
import struct
import subprocess
import wave

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--simulator", default=os.environ.get("ASR_TEST_SIMULATOR"), help="Booted iOS simulator UDID; otherwise exactly one must be booted")
args = parser.parse_args()
TEST = ROOT / "Tests/nano"
NANO = Path(os.environ.get("ASR_NANO_SIMULATOR_FRAMEWORKS", ROOT / "Packages/NanoRuntime/CNano.xcframework/ios-arm64-simulator"))
WHISPER = ROOT / "Packages/WhisperRuntime/whisper.xcframework/ios-arm64-simulator/whisper.framework"
SAMPLE = Path(os.environ.get("ASR_NANO_SAMPLE", ROOT / "Vendor/Fun-ASR/runtime/llama.cpp/tests/sample.wav"))
if not (NANO / "CNano.framework/CNano").is_file() or not (WHISPER / "whisper").is_file():
    raise SystemExit("Missing Nano/Whisper iOS simulator XCFrameworks; prepare local runtimes first")
if not SAMPLE.is_file():
    raise SystemExit("Missing official Nano sample; restore sources with Scripts/build-nano.py, or set ASR_NANO_SAMPLE to the same official sample")
selection = ["python3", str(ROOT / "Scripts/select-ios-simulator.py"), "--booted"]
if args.simulator:
    selection += ["--udid", args.simulator]
simulator = subprocess.check_output(selection, text=True).strip()
with wave.open(str(SAMPLE)) as w:
    assert (w.getframerate(), w.getnchannels(), w.getsampwidth()) == (16000, 1, 2)
    frames = w.readframes(w.getnframes())
    (TEST / "sample.f32").write_bytes(b"".join(struct.pack("<f", v / 32768) for (v,) in struct.iter_unpack("<h", frames)))
sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
args = ["xcrun", "clang++", "-std=c++17", "-O2", "-target", "arm64-apple-ios17.0-simulator", "-isysroot", sdk,
        "-I" + str(ROOT / "Packages/NanoRuntime/Sources/CNano/include"), "-I" + str(WHISPER / "Headers"),
        "-F" + str(NANO), "-framework", "CNano", "-framework", "Accelerate", "-framework", "Foundation",
        str(TEST / "coexist.cpp"), str(WHISPER / "whisper"), "-Wl,-rpath," + str(NANO), "-o", str(TEST / "coexist-simulator")]
subprocess.run(args, check=True)
subprocess.run(["codesign", "--force", "--sign", "-", str(TEST / "coexist-simulator")], check=True)
subprocess.run(["xcrun", "simctl", "spawn", simulator, str(TEST / "coexist-simulator"), str(ROOT)], check=True)
