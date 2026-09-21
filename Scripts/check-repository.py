#!/usr/bin/env python3
"""Validate repository metadata without downloading Git LFS objects or using Xcode."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
LFS_SUFFIXES = {".onnx", ".gguf", ".bin", ".fst", ".mdl", ".ie", ".dubm", ".mat", ".a"}
LFS_EXECUTABLES = {"whisper", "CNano"}


def run_git(*arguments: str, input_text: str | None = None) -> str:
    return subprocess.check_output(
        ["git", *arguments], cwd=ROOT, text=True, input=input_text
    )


def run_git_bytes(*arguments: str) -> bytes:
    return subprocess.check_output(["git", *arguments], cwd=ROOT)


def load_json(relative: str):
    with (ROOT / relative).open(encoding="utf-8") as stream:
        return json.load(stream)


def require(condition: bool, message: str, errors: list[str]) -> None:
    if not condition:
        errors.append(message)


def main() -> int:
    errors: list[str] = []
    required_files = {
        "README.md",
        "LICENSE",
        "NOTICE",
        "CONTRIBUTING.md",
        "CODE_OF_CONDUCT.md",
        "SECURITY.md",
        "CHANGELOG.md",
        "THIRD_PARTY_NOTICES.md",
        ".gitattributes",
        ".gitignore",
        ".github/PULL_REQUEST_TEMPLATE.md",
        ".github/ISSUE_TEMPLATE/bug_report.yml",
        ".github/ISSUE_TEMPLATE/feature_request.yml",
        ".github/ISSUE_TEMPLATE/question.yml",
    }

    tracked = {value for value in run_git("ls-files", "-z").split("\0") if value}
    for relative in sorted(required_files):
        require(relative in tracked, f"required project file is not tracked: {relative}", errors)

    index_rows = [value for value in run_git("ls-files", "-s", "-z").split("\0") if value]
    gitlinks = []
    object_ids = set()
    for row in index_rows:
        metadata, relative = row.split("\t", 1)
        mode, object_id, _stage = metadata.split()
        object_ids.add(object_id)
        if mode == "160000":
            gitlinks.append(relative)
    require(not gitlinks, "gitlinks are not allowed: " + ", ".join(gitlinks), errors)

    models = load_json("ModelsManifest.json")
    bundled_manifest = ROOT / "ASRtest/ModelsManifest.json"
    require(
        bundled_manifest.read_bytes() == (ROOT / "ModelsManifest.json").read_bytes(),
        "ASRtest/ModelsManifest.json differs from the repository manifest",
        errors,
    )
    for model in models["models"]:
        for item in model["files"]:
            relative = f"ModelLibrary/{model['id']}/{item['path']}"
            require(relative in tracked, f"model manifest path is not tracked: {relative}", errors)

    runtimes = load_json("RuntimeArtifactsManifest.json")
    for runtime in runtimes["runtimes"]:
        for item in runtime["artifact_identity"]["files"]:
            relative = f"{runtime['path'].rstrip('/')}/{item}"
            require(relative in tracked, f"runtime manifest path is not tracked: {relative}", errors)

    sources = load_json("Vendor/sources.json")
    for source in sources["sources"]:
        prefix = source["path"].rstrip("/") + "/"
        rows = [relative for relative in tracked if relative.startswith(prefix)]
        if source["name"] == "Fun-ASR":
            nested = prefix + "third_party/llama.cpp/"
            rows = [relative for relative in rows if not relative.startswith(nested)]
        require(
            len(rows) == source["file_count"],
            f"{source['name']} index count is {len(rows)}, expected {source['file_count']}",
            errors,
        )

    lfs_candidates = sorted(
        relative
        for relative in tracked
        if Path(relative).suffix in LFS_SUFFIXES or Path(relative).name in LFS_EXECUTABLES
    )
    for relative in lfs_candidates:
        value = run_git("check-attr", "filter", "--", relative).rstrip().rsplit(": ", 1)[-1]
        require(value == "lfs", f"large/binary asset is not assigned to Git LFS: {relative}", errors)
        pointer = run_git_bytes("show", f":{relative}")
        require(
            pointer.startswith(b"version https://git-lfs.github.com/spec/v1\n")
            and b"\noid sha256:" in pointer
            and b"\nsize " in pointer
            and len(pointer) < 256,
            f"index entry is not a Git LFS pointer: {relative}",
            errors,
        )

    if object_ids:
        output = run_git(
            "cat-file",
            "--batch-check=%(objectname) %(objecttype) %(objectsize)",
            input_text="\n".join(sorted(object_ids)) + "\n",
        )
        oversized = [
            row for row in output.splitlines()
            if len(row.split()) == 3 and row.split()[1] == "blob" and int(row.split()[2]) > 100_000_000
        ]
        require(not oversized, "ordinary Git blob exceeds 100 MB: " + ", ".join(oversized), errors)

    if errors:
        print("Repository validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print(
        "Repository metadata PASS: "
        f"{len(models['models'])} model groups, {len(runtimes['runtimes'])} runtimes, "
        f"{len(sources['sources'])} vendored source snapshots, {len(lfs_candidates)} LFS paths."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
