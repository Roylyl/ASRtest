#!/usr/bin/env python3
"""Build isolated native Nano frameworks. --macos adds a native smoke-test build."""
from pathlib import Path
import argparse
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "Packages/NanoRuntime"
BUILD = PACKAGE / ".build-native"
FUNASR_REV = "0339018ba74a7defa3b6b6a96718d17b816be77b"
LLAMA_REV = "8086439a4cea94c71a5dfb8fe4ad1546aebd640f"

def run(args):
    subprocess.run([str(x) for x in args], check=True)

def checkout(path, url, revision):
    if not (path / ".git").exists():
        path.mkdir(parents=True, exist_ok=True)
        run(["git", "init", path])
        run(["git", "-C", path, "remote", "add", "origin", url])
        run(["git", "-C", path, "fetch", "--depth=1", "origin", revision])
        run(["git", "-C", path, "checkout", "--detach", "FETCH_HEAD"])
    actual = subprocess.check_output(["git", "-C", str(path), "rev-parse", "HEAD"], text=True).strip()
    if actual != revision:
        raise RuntimeError(f"Unexpected revision at {path}: {actual}")

def build(sdk):
    directory = BUILD / sdk
    sdk_path = subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True).strip()
    run(["cmake", "-S", PACKAGE, "-B", directory, "-G", "Xcode",
         "-DCMAKE_SYSTEM_NAME=" + ("Darwin" if sdk == "macosx" else "iOS"),
         "-DCMAKE_OSX_SYSROOT=" + sdk_path, "-DCMAKE_OSX_ARCHITECTURES=arm64",
         "-DCMAKE_OSX_DEPLOYMENT_TARGET=" + ("14.0" if sdk == "macosx" else "17.0"),
         "-DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO"])
    run(["cmake", "--build", directory, "--config", "Release", "--target", "CNano", "-j", "4"])
    location = directory / ("Release" if sdk == "macosx" else "Release-" + sdk) / "CNano.framework"
    modules = location / "Versions/A/Modules" if sdk == "macosx" else location / "Modules"
    modules.mkdir(parents=True, exist_ok=True)
    (modules / "module.modulemap").write_text('framework module CNano {\n  header "asr_nano.h"\n  export *\n}\n')
    headers = location / "Versions/A/Headers" if sdk == "macosx" else location / "Headers"
    headers.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(PACKAGE / "Sources/CNano/include/asr_nano.h", headers / "asr_nano.h")
    if sdk == "macosx":
        module_link = location / "Modules"
        if module_link.is_dir() and not module_link.is_symlink(): shutil.rmtree(module_link)
        if not module_link.exists(): module_link.symlink_to("Versions/Current/Modules")
        header_link = location / "Headers"
        if not header_link.exists(): header_link.symlink_to("Versions/Current/Headers")
    binary = location / "CNano"
    symbols = subprocess.check_output(["nm", "-gU", str(binary)], text=True)
    exported = [line.split()[-1] for line in symbols.splitlines() if line.strip()]
    expected = (PACKAGE / "nano-exports.txt").read_text().split()
    if sorted(exported) != sorted(expected):
        raise RuntimeError("Unexpected public symbols: " + str(exported))
    info_path = location / "Resources/Info.plist" if sdk == "macosx" else location / "Info.plist"
    with info_path.open("rb") as f:
        info = plistlib.load(f)
    info["MinimumOSVersion"] = "14.0" if sdk == "macosx" else "17.0"
    info["CFBundleSupportedPlatforms"] = ["MacOSX" if sdk == "macosx" else "iPhoneOS" if sdk == "iphoneos" else "iPhoneSimulator"]
    with info_path.open("wb") as f:
        plistlib.dump(info, f)
    run(["codesign", "--force", "--sign", "-", location])
    return location

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--macos", action="store_true")
    parser.add_argument("--macos-only", action="store_true")
    args = parser.parse_args()
    checkout(ROOT / "Vendor/Fun-ASR", "https://github.com/QwenAudio/Fun-ASR.git", FUNASR_REV)
    checkout(ROOT / "Vendor/Fun-ASR/third_party/llama.cpp", "https://github.com/ggml-org/llama.cpp.git", LLAMA_REV)
    run(["python3", ROOT / "Scripts/prepare-nano-source.py"])
    if args.macos or args.macos_only:
        build("macosx")
    if not args.macos_only:
        device = build("iphoneos")
        simulator = build("iphonesimulator")
        output = PACKAGE / "CNano.xcframework"
        staging = PACKAGE / "CNano.staging.xcframework"
        if staging.exists(): shutil.rmtree(staging)
        run(["xcodebuild", "-create-xcframework", "-framework", device, "-framework", simulator, "-output", staging])
        if output.exists(): shutil.rmtree(output)
        staging.rename(output)
        print("Built NanoRuntime/CNano.xcframework; only asr_nano_* are public")
