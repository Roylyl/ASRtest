#!/usr/bin/env python3
"""Fetch the official, revision-pinned Fun-ASR-Nano GGUF bundle and verify SHA-256."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import hashlib
import json
import subprocess

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "ModelLibrary/nano"
REV = "46e849502a867080d66d351b8dfb1018b607e509"
VAD_REV = "6840bae4c5c92ee8c04faaf4db23dd0105098d7f"
FILES = [
    ("funasr-encoder-f16.gguf", "Fun-ASR-Nano-GGUF", REV, 469331008, "f92f91d01a24fbed6c863495b2ee8c6a6788144a02858b75743f0946668de8a2"),
    ("qwen3-0.6b-q4km.gguf", "Fun-ASR-Nano-GGUF", REV, 484219776, "cc5057552aa9dddedcda73ea8889854e8a257eb07d0a561b7234465c1e856f22"),
    ("fsmn-vad.gguf", "fsmn-vad-GGUF", VAD_REV, 1720512, "1270f2559c495f4e7b6e739541151027d360761a3fda43fc147034f5719f5479"),
]

def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(4 * 1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()

def fetch(item):
    name, repo, revision, size, sha = item
    path = DEST / name
    url = f"https://huggingface.co/FunAudioLLM/{repo}/resolve/{revision}/{name}"
    if not (path.exists() and path.stat().st_size == size and digest(path) == sha):
        partial = path.with_suffix(path.suffix + ".partial")
        subprocess.run(["curl", "--fail", "--location", "--retry", "5", "--continue-at", "-", "--output", str(partial), url], check=True)
        if partial.stat().st_size != size or digest(partial) != sha:
            raise RuntimeError(f"Checksum or size mismatch for {name}; partial retained for diagnosis")
        partial.replace(path)
    print(f"Verified {name} ({size} bytes)", flush=True)
    return {"file": name, "url": url, "revision": revision, "bytes": size, "sha256": sha}

if __name__ == "__main__":
    DEST.mkdir(parents=True, exist_ok=True)
    with ThreadPoolExecutor(max_workers=3) as pool:
        files = list(pool.map(fetch, FILES))
    manifest = {"model": "Fun-ASR-Nano", "license": "Apache-2.0", "runtimeRevision": "0339018ba74a7defa3b6b6a96718d17b816be77b", "llamaRevision": "8086439a4cea94c71a5dfb8fe4ad1546aebd640f", "files": files}
    (DEST / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    aggregate = {"models": [{"id": "nano", "revision": REV,
        "files": [{**f, "path": "nano/" + f["file"]} for f in files]}]}
    (DEST / "ModelsManifest-nano.json").write_text(json.dumps(aggregate, indent=2) + "\n")
