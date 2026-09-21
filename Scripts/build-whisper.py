#!/usr/bin/env python3
"""Explicit developer rebuild of pinned whisper.cpp CPU/Accelerate iOS libraries.

Fetches the fixed source revision only when --fetch is supplied; otherwise uses
an existing clean checkout. Requires Xcode and CMake. Produces arm64 iOS device
and arm64 simulator static XCFramework slices. No Metal/Core ML backend.
Build outputs need App compilation and inference validation; the checked-in
artifact SHA256 values are NOT reproducibility promises for another compiler/SDK.
"""
from pathlib import Path
import argparse
import importlib.util
import json
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
REVISION = "927cfce34f31707e17f2bff35c349632fb9e2c3a"
SOURCE = ROOT / "Vendor/whisper.cpp"
PACKAGE = ROOT / "Packages/WhisperRuntime"
BUILD = PACKAGE / ".build-native"


def run(arguments):
    subprocess.run([str(value) for value in arguments], check=True)


def output(arguments):
    return subprocess.check_output([str(value) for value in arguments], text=True).strip()


def checkout(fetch):
    marker = SOURCE / ".asrtest-upstream.json"
    if marker.is_file():
        value = json.loads(marker.read_text())
        if (value.get("repo") != "https://github.com/ggml-org/whisper.cpp.git"
                or value.get("commit") != REVISION):
            raise RuntimeError("Vendored Whisper source marker does not match the pinned revision")
        return
    if not (SOURCE / ".git").is_dir():
        if not fetch:
            raise RuntimeError("Pinned source is absent; use --fetch to authorize fetching official source")
        SOURCE.parent.mkdir(parents=True, exist_ok=True)
        if SOURCE.exists() and any(SOURCE.iterdir()):
            raise RuntimeError("Source directory is nonempty but is not a Git checkout")
        run(["git", "init", SOURCE])
        run(["git", "-C", SOURCE, "remote", "add", "origin", "https://github.com/ggml-org/whisper.cpp.git"])
        run(["git", "-C", SOURCE, "fetch", "--depth=1", "origin", REVISION])
        run(["git", "-C", SOURCE, "checkout", "--detach", "FETCH_HEAD"])
    if output(["git", "-C", SOURCE, "rev-parse", "HEAD"]) != REVISION:
        raise RuntimeError("Whisper source revision does not match manifest")
    if output(["git", "-C", SOURCE, "status", "--porcelain", "--untracked-files=no"]):
        raise RuntimeError("Whisper source has tracked modifications; refusing an untraceable rebuild")


def build_slice(sdk, jobs):
    build = BUILD / sdk
    sdk_path = output(["xcrun", "--sdk", sdk, "--show-sdk-path"])
    run(["cmake", "-S", SOURCE, "-B", build, "-G", "Xcode",
         "-DCMAKE_SYSTEM_NAME=iOS", "-DCMAKE_OSX_SYSROOT=" + sdk_path,
         "-DCMAKE_OSX_ARCHITECTURES=arm64", "-DCMAKE_OSX_DEPLOYMENT_TARGET=17.0",
         "-DCMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS=" + sdk,
         "-DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO", "-DBUILD_SHARED_LIBS=OFF",
         "-DWHISPER_BUILD_TESTS=OFF", "-DWHISPER_BUILD_EXAMPLES=OFF", "-DWHISPER_BUILD_SERVER=OFF",
         "-DWHISPER_COREML=OFF", "-DGGML_METAL=OFF", "-DGGML_BLAS=ON",
         "-DGGML_BLAS_VENDOR=Apple", "-DGGML_ACCELERATE=ON", "-DGGML_OPENMP=OFF",
         "-DGGML_NATIVE=OFF", "-DGGML_BACKEND_DL=OFF"])
    run(["cmake", "--build", build, "--config", "Release", "-j", str(jobs)])
    configuration = "Release-" + sdk
    archives = [build / relative / configuration / name for relative, name in [
        ("src", "libwhisper.a"), ("ggml/src", "libggml.a"),
        ("ggml/src", "libggml-base.a"), ("ggml/src", "libggml-cpu.a"),
        ("ggml/src/ggml-blas", "libggml-blas.a")]]
    parakeet = build / "src" / configuration / "libparakeet.a"
    if parakeet.is_file():
        archives.append(parakeet)
    for archive in archives:
        if not archive.is_file():
            raise RuntimeError(f"Expected pinned-source build artifact not found: {archive}")
    framework = build / "framework/whisper.framework"
    if framework.exists():
        shutil.rmtree(framework)
    (framework / "Headers").mkdir(parents=True)
    (framework / "Modules").mkdir()
    run(["xcrun", "libtool", "-static", "-o", framework / "whisper", *archives])
    shutil.copy2(SOURCE / "include/whisper.h", framework / "Headers/whisper.h")
    for header in (SOURCE / "ggml/include").glob("*.h"):
        shutil.copy2(header, framework / "Headers" / header.name)
    (framework / "Modules/module.modulemap").write_text(
        'framework module whisper {\n  header "whisper.h"\n  export *\n}\n')
    info = {"CFBundleExecutable": "whisper", "CFBundleIdentifier": "org.ggml.whisper",
            "CFBundleName": "whisper", "CFBundlePackageType": "FMWK",
            "CFBundleShortVersionString": "1.9.4", "CFBundleVersion": "1",
            "MinimumOSVersion": "17.0",
            "CFBundleSupportedPlatforms": ["iPhoneOS" if sdk == "iphoneos" else "iPhoneSimulator"]}
    with (framework / "Info.plist").open("wb") as stream:
        plistlib.dump(info, stream)
    return framework


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--fetch", action="store_true", help="Allow initial download only when the vendored source snapshot is absent")
    parser.add_argument("--replace", action="store_true", help="Replace an existing local XCFramework after successful build")
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    destination = PACKAGE / "whisper.xcframework"
    if destination.exists() and not args.replace:
        parser.error("An existing runtime is present; use --replace for an intentional rebuild")
    checkout(args.fetch)
    device = build_slice("iphoneos", args.jobs)
    simulator = build_slice("iphonesimulator", args.jobs)
    with tempfile.TemporaryDirectory(prefix=".runtime-whisper-", dir=PACKAGE) as temporary:
        temporary = Path(temporary)
        staging = temporary / "whisper.xcframework"
        run(["xcodebuild", "-create-xcframework", "-framework", device,
             "-framework", simulator, "-output", staging])
        # Validate before replacement; do not compare a rebuild to old binary hashes.
        spec = importlib.util.spec_from_file_location("runtime_preparation", ROOT / "Scripts/prepare-runtimes.py")
        verifier = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(verifier)
        manifest = json.loads((ROOT / "RuntimeArtifactsManifest.json").read_text())
        runtime = next(entry for entry in manifest["runtimes"] if entry["id"] == "whisper")
        verifier.check_structure(staging, runtime)
        previous = temporary / "previous"
        if destination.exists():
            destination.rename(previous)
        try:
            staging.rename(destination)
        except BaseException:
            if previous.exists():
                previous.rename(destination)
            raise
    run(["python3", ROOT / "Scripts/prepare-runtimes.py", "--check-structure", "--runtime", "whisper"])
    print("Whisper source rebuild complete; run App build/inference tests. A different artifact SHA256 is expected.")


if __name__ == "__main__":
    main()
