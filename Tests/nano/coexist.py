#!/usr/bin/env python3
from pathlib import Path
import json
import struct
import subprocess
import wave

ROOT = Path(__file__).resolve().parents[2]
TEST = ROOT / "Tests/nano"
NANO = ROOT / "Packages/NanoRuntime/.build-native/iphonesimulator/Release-iphonesimulator"
WHISPER = ROOT / "Packages/WhisperRuntime/whisper.xcframework/ios-arm64-simulator/whisper.framework"
with wave.open(str(ROOT / "Vendor/Fun-ASR/runtime/llama.cpp/tests/sample.wav")) as w:
    frames = w.readframes(w.getnframes())
    (TEST / "sample.f32").write_bytes(b"".join(struct.pack("<f", v / 32768) for (v,) in struct.iter_unpack("<h", frames)))
sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
args = ["xcrun", "clang++", "-std=c++17", "-O2", "-target", "arm64-apple-ios17.0-simulator", "-isysroot", sdk,
        "-I" + str(ROOT / "Packages/NanoRuntime/Sources/CNano/include"), "-I" + str(WHISPER / "Headers"),
        "-F" + str(NANO), "-framework", "CNano", "-framework", "Accelerate", "-framework", "Foundation",
        str(TEST / "coexist.cpp"), str(WHISPER / "whisper"), "-Wl,-rpath," + str(NANO), "-o", str(TEST / "coexist-simulator")]
subprocess.run(args, check=True)
subprocess.run(["codesign", "--force", "--sign", "-", str(TEST / "coexist-simulator")], check=True)
devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "booted", "--json"]))
booted = [d["udid"] for group in devices["devices"].values() for d in group if d["state"] == "Booted"]
if not booted: raise SystemExit("Boot an arm64 iOS simulator before this test")
subprocess.run(["xcrun", "simctl", "spawn", booted[0], str(TEST / "coexist-simulator"), str(ROOT)], check=True)
