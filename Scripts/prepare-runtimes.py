#!/usr/bin/env python3
"""Offline verification/restoration of ASRtest's ignored local runtime artifacts.

This is a developer preparation tool, not an App download mechanism. No command
in this tool accesses the network. --from accepts a complete ASRtest backup root.
Source rebuilds are separate explicit commands (see RuntimeArtifactsManifest.json).
The manifest hashes identify the original backup; rebuilt libraries are expected
to have different hashes. --check-structure checks packaging, not recognition
correctness, ABI equivalence, provenance, or license compliance.
"""
from pathlib import Path
import argparse
import hashlib
import json
import plistlib
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def inventory(directory):
    if not directory.is_dir() or directory.is_symlink():
        raise ValueError(f"Missing ordinary runtime directory: {directory}")
    files = {}
    for path in sorted(directory.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"Unexpected symbolic link: {path}")
        if path.is_file():
            files[path.relative_to(directory).as_posix()] = {
                "bytes": path.stat().st_size, "sha256": digest(path)
            }
    return files


def verify_identity(directory, runtime):
    actual = inventory(directory)
    expected = runtime["backup_identity"]["files"]
    errors = []
    for relative in sorted(set(actual) | set(expected)):
        if relative not in actual:
            errors.append("missing " + relative)
        elif relative not in expected:
            errors.append("unexpected " + relative)
        elif actual[relative] != expected[relative]:
            errors.append("size/SHA256 mismatch " + relative)
    if errors:
        raise ValueError(f"{runtime['id']} backup identity failed:\n  " + "\n  ".join(errors))
    print(f"PASS {runtime['id']}: {len(expected)} files match backup SHA256")


def inside(directory, relative):
    path = directory / relative
    if not path.resolve().is_relative_to(directory.resolve()):
        raise ValueError(f"Path escapes runtime directory: {relative}")
    return path


def check_structure(directory, runtime):
    with (directory / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    variants = set()
    for library in info.get("AvailableLibraries", []):
        if library.get("SupportedPlatform") != "ios":
            continue
        variant = library.get("SupportedPlatformVariant", "device")
        if variant not in {"device", "simulator"}:
            continue
        if "arm64" not in library.get("SupportedArchitectures", []):
            raise ValueError(f"{runtime['id']}: {variant} does not advertise arm64")
        variants.add(variant)
        location = inside(directory, library["LibraryIdentifier"])
        binary = inside(location, library.get("BinaryPath", library["LibraryPath"]))
        if binary.suffix == ".framework":
            binary = binary / binary.stem
        if not binary.is_file() or binary.stat().st_size == 0:
            raise ValueError(f"Missing nonempty binary: {binary}")
        architectures = subprocess.check_output(["xcrun", "lipo", "-archs", str(binary)], text=True).split()
        if "arm64" not in architectures:
            raise ValueError(f"{runtime['id']}: binary lacks arm64: {binary}")
        framework = location / library["LibraryPath"]
        if framework.suffix == ".framework":
            header = framework / "Headers" / runtime["header"]
            module_map = framework / "Modules/module.modulemap"
        else:
            headers = inside(location, library["HeadersPath"])
            header = headers / runtime["header"]
            module_map = headers / "module.modulemap"
        if not header.is_file() or not module_map.is_file():
            raise ValueError(f"{runtime['id']}: missing header or module map for {variant}")
        symbols = subprocess.check_output(
            ["xcrun", "nm", "-arch", "arm64", "-gU", str(binary)], text=True, stderr=subprocess.DEVNULL
        )
        exported = {line.split()[-1] for line in symbols.splitlines() if line.split()}
        missing = set(runtime["required_symbols"]) - exported
        if missing:
            raise ValueError(f"{runtime['id']}: missing API symbols: {sorted(missing)}")
    if variants != {"device", "simulator"}:
        raise ValueError(f"{runtime['id']}: both iOS device and simulator slices are required")
    print(f"PASS {runtime['id']}: arm64 device/simulator, headers, module map, required symbols")


def restore(source_root, target_root, runtime, replace):
    source = source_root / runtime["path"]
    target = target_root / runtime["path"]
    verify_identity(source, runtime)
    if source.resolve() == target.resolve():
        print(f"SKIP {runtime['id']}: source and destination are identical")
        return
    if target.exists():
        try:
            verify_identity(target, runtime)
            print(f"SKIP {runtime['id']}: destination already matches")
            return
        except ValueError:
            if not replace:
                raise ValueError(f"Destination differs: {target}; use --replace to replace only this runtime")
    if target.is_symlink():
        raise ValueError(f"Refusing symbolic-link destination: {target}")
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".runtime-restore-", dir=target.parent) as temporary:
        temporary = Path(temporary)
        staging = temporary / target.name
        shutil.copytree(source, staging)
        verify_identity(staging, runtime)
        previous = temporary / "previous"
        if target.exists():
            target.rename(previous)
        try:
            staging.rename(target)
        except BaseException:
            if previous.exists():
                previous.rename(target)
            raise
    print(f"RESTORED {runtime['id']}: {target}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    operation = parser.add_mutually_exclusive_group(required=True)
    operation.add_argument("--verify-only", action="store_true", help="Require exact original backup SHA256 for every file; offline")
    operation.add_argument("--check-structure", action="store_true", help="Check rebuilt or original packaging and required APIs using Xcode tools; not identity/inference validation")
    operation.add_argument("--from", dest="source_root", type=Path, help="Restore from a complete local ASRtest backup root after exact SHA256 verification; offline")
    parser.add_argument("--runtime", choices=["all", "whisper", "vosk", "nano"], default="all")
    parser.add_argument("--root", type=Path, default=ROOT, help="Destination/verification ASRtest root (default: this checkout)")
    parser.add_argument("--replace", action="store_true", help="With --from, permit replacement of a differing destination runtime")
    args = parser.parse_args()
    if args.replace and not args.source_root:
        parser.error("--replace requires --from")
    manifest = json.loads((ROOT / "RuntimeArtifactsManifest.json").read_text())
    runtimes = [entry for entry in manifest["runtimes"] if args.runtime in {"all", entry["id"]}]
    failures = []
    for runtime in runtimes:
        try:
            target = args.root.resolve() / runtime["path"]
            if args.source_root:
                restore(args.source_root.resolve(), args.root.resolve(), runtime, args.replace)
            elif args.check_structure:
                check_structure(target, runtime)
            else:
                verify_identity(target, runtime)
        except (ValueError, OSError, subprocess.CalledProcessError, KeyError, plistlib.InvalidFileException) as error:
            failures.append(str(error))
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    if args.check_structure:
        print("Structure checks passed. Rebuild the App and run inference tests before treating new binaries as validated.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
