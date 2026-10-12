#!/usr/bin/env python3
"""Check model packaging using manifest content and file sizes, without hashing weights."""

import argparse
import json
from pathlib import Path
import sys


MODEL_IDS = {
    "zipformer", "whisperTiny", "whisperBase", "voskChinese",
    "voskEnglish", "senseVoice", "paraformer", "nano",
}
REPO_ROOT = Path(__file__).resolve().parents[1]


def check_resources(root, expected):
    actual = json.loads((root / "ModelsManifest.json").read_text())
    if actual != expected:
        raise ValueError("ModelsManifest.json does not match the shared model manifest")
    models = expected["models"]
    ids = [model["id"] for model in models]
    if len(ids) != len(MODEL_IDS) or set(ids) != MODEL_IDS:
        raise ValueError("The model manifest must contain all eight supported model groups")
    count = 0
    total = 0
    for model in models:
        if not model["files"]:
            raise ValueError("Model has no required files: " + model["id"])
        for item in model["files"]:
            relative = Path(item["path"])
            if relative.is_absolute() or ".." in relative.parts:
                raise ValueError("Invalid model file path: " + item["path"])
            file = root / "ModelLibrary" / model["id"] / relative
            if not file.is_file():
                raise ValueError("Missing bundled model file: " + str(file))
            if file.stat().st_size != item["bytes"]:
                raise ValueError("Model file size mismatch (check Git LFS files): " + str(file))
            count += 1
            total += item["bytes"]
    print(f"PASS {root.name}: 8 model groups, {count} required files, {total} bytes")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, help="Built iOS app resource directory")
    args = parser.parse_args()
    shared = REPO_ROOT / "shared/assets"
    expected = json.loads((shared / "ModelsManifest.json").read_text())
    check_resources(shared, expected)
    if args.app:
        check_resources(args.app, expected)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError) as error:
        print("error: " + str(error), file=sys.stderr)
        sys.exit(1)
